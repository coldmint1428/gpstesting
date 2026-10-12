-- Step 9: push reminders - "Event started, tap to share" reaches ICs even when the app is closed.
-- Run AFTER 008_playback.sql.
--
-- How it works:
--   1. The phone app registers its Firebase push token (register_push_token) after login.
--   2. Every minute while any session is live, pg_cron calls the Edge Function "send-reminders"
--      (pg_net HTTP call, protected by a random secret kept in Supabase Vault).
--   3. The function asks claim_push_reminders() which ICs still haven't shared in the live
--      session, and sends each of their phones a push through Firebase Cloud Messaging (FCM).
--      Each IC gets the first reminder at the start, then one every 10 min, at most 6.
--   4. Planners can press "Remind ICs" (same function, at most once a minute per IC).
--
-- ONE-TIME SETUP PER SUPABASE PROJECT (not in this file because it differs per project):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   Edge Function secret FCM_SERVICE_ACCOUNT = the Firebase service-account JSON.

create extension if not exists pg_net;

-- Phones that can receive pushes (one row per phone; a phone belongs to whoever logged in last)
create table public.push_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens (user_id);
alter table public.push_tokens enable row level security; -- no policies: only through functions

-- How often each IC was reminded in a session (limits: every 10 min, at most 6)
create table public.push_reminders (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  sent_count integer not null default 0,
  last_sent_at timestamptz not null default now(),
  primary key (session_id, user_id)
);
alter table public.push_reminders enable row level security; -- no policies

-- ---------- Called by the phone app ----------
create function public.register_push_token(p_token text, p_platform text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_token is null or length(p_token) < 20 or length(p_token) > 4096 then
    raise exception 'Invalid push token';
  end if;
  insert into public.push_tokens (token, user_id, platform) values (p_token, auth.uid(), p_platform)
  on conflict (token) do update set user_id = auth.uid(), platform = p_platform, updated_at = now();
end;
$$;

create function public.unregister_push_token(p_token text)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
$$;

-- ---------- Called by the Edge Function (service role only) ----------

-- ICs who should get a reminder now; records the reminder. p_event_id = only that event,
-- p_force = a planner pressed "Remind ICs" (skip the 10-min / 6-times limits, keep 1 min).
create function public.claim_push_reminders(p_event_id uuid default null, p_force boolean default false)
returns table (token text, user_id uuid, event_id uuid, event_name text, reminder_no integer, forced boolean)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  r record;
begin
  for r in
    select s.id as session_id, s.event_id, e.name, gm.user_id, coalesce(pr.sent_count, 0) as sent_count
    from public.event_sessions s
    join public.events e on e.id = s.event_id
    join public.group_members gm on gm.event_id = s.event_id and gm.is_ic
    left join public.push_reminders pr on pr.session_id = s.id and pr.user_id = gm.user_id
    where s.ended_at is null and s.starts_at <= now()
      and (p_event_id is null or s.event_id = p_event_id)
      -- hasn't shared in this session yet
      and not exists (
        select 1 from public.locations l
        where l.event_id = s.event_id and l.user_id = gm.user_id and l.recorded_at >= s.starts_at
      )
      -- and hasn't just pressed Share (pass made, first reading not in yet)
      and not exists (
        select 1 from public.tracking_passes tp
        where tp.user_id = gm.user_id and tp.event_id = s.event_id and tp.revoked_at is null
          and tp.expires_at > now() and tp.created_at >= s.starts_at
      )
      and (
        pr.user_id is null
        or (p_force and pr.last_sent_at < now() - interval '1 minute')
        or (not p_force and pr.sent_count < 6 and pr.last_sent_at < now() - interval '10 minutes')
      )
  loop
    insert into public.push_reminders (session_id, user_id, sent_count, last_sent_at)
    values (r.session_id, r.user_id, 1, now())
    on conflict (session_id, user_id)
    do update set sent_count = public.push_reminders.sent_count + 1, last_sent_at = now();

    return query
      select t.token, r.user_id, r.event_id, r.name, r.sent_count + 1, p_force
      from public.push_tokens t where t.user_id = r.user_id;
  end loop;
end;
$$;

-- Firebase said this token is no longer valid (app uninstalled / data cleared)
create function public.delete_push_token(p_token text)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_tokens where token = p_token;
$$;

-- Is this the secret pg_cron sends? (the Edge Function checks every call)
create function public.check_push_cron_secret(p_secret text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from vault.decrypted_secrets where name = 'push_cron_secret' and decrypted_secret = p_secret
  );
$$;

-- Random secret shared by pg_cron and the Edge Function (never leaves the database otherwise)
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'push_cron_secret',
  'pg_cron -> Edge Function send-reminders');

-- Every minute, but only while some session is live (otherwise no HTTP call at all)
select cron.schedule('gps-push-reminders', '* * * * *', $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')
    ),
    body := '{}'::jsonb
  )
  where exists (select 1 from public.event_sessions where ended_at is null and starts_at <= now())
    and exists (select 1 from vault.decrypted_secrets where name = 'project_url');
$job$);

-- ---------- Permissions (one function at a time) ----------
revoke execute on function public.register_push_token(text, text) from public, anon;
revoke execute on function public.unregister_push_token(text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;
grant execute on function public.unregister_push_token(text) to authenticated;
revoke execute on function public.claim_push_reminders(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.delete_push_token(text) from public, anon, authenticated;
revoke execute on function public.check_push_cron_secret(text) from public, anon, authenticated;
grant execute on function public.claim_push_reminders(uuid, boolean) to service_role;
grant execute on function public.delete_push_token(text) to service_role;
grant execute on function public.check_push_cron_secret(text) to service_role;
