-- 038_sos.sql -- SOS: anyone in an event can call for help.
-- Run AFTER 037_attendance.sql (Supabase -> SQL Editor). Can be re-run.
--
-- Pressing SOS turns on the person's GPS (in the app or browser) and sends where they are; while the SOS is active their
-- phone keeps sending its location. Everyone in the event sees the SOS on the map and as a banner, and gets a
-- notification on their phone (not in simulation events).
--   * Anyone in the event can say "I'm on my way". The person who called for help sees who is coming.
--   * The SOS ends when the person who sent it says they are safe, or when the root, a planner, a marshal, or an IC or
--     admin of their group marks it handled.
--   * One active SOS per person per event: pressing SOS again only updates the location.
--   * GPS may be off or refused: the SOS is still sent, without a location.

-- ============================================================
-- 1. Table
-- ============================================================
create table if not exists public.sos_alerts (
  id bigserial primary key,
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  group_id uuid references public.groups (id) on delete set null, -- their group when they sent it
  note text check (note is null or char_length(note) between 1 and 200),
  lat double precision check (lat is null or lat between -90 and 90),
  lng double precision check (lng is null or lng between -180 and 180),
  accuracy real check (accuracy is null or accuracy >= 0), -- metres
  located_at timestamptz, -- when the location was taken
  raised_at timestamptz not null default now(),
  helpers jsonb not null default '[]', -- [{ user_id, name, at }]: who said "I'm on my way"
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null,
  resolution text check (resolution is null or resolution in ('safe', 'handled'))
);
create index if not exists sos_alerts_event on public.sos_alerts (event_id, raised_at desc);
create unique index if not exists sos_alerts_one_active on public.sos_alerts (event_id, user_id) where resolved_at is null;

alter table public.sos_alerts enable row level security;

-- Everyone in the event sees every SOS
drop policy if exists "sos: everyone in the event reads" on public.sos_alerts;
create policy "sos: everyone in the event reads" on public.sos_alerts
  for select to authenticated
  using (public.is_event_member(event_id));

revoke all on table public.sos_alerts from anon, authenticated, public;
grant select on table public.sos_alerts to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.sos_alerts;
exception when duplicate_object then null;
end $$;

-- Phone notifications may be SOS ones (029 had the list before this)
alter table public.push_queue drop constraint if exists push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check
  check (kind in ('get_ready', 'leave_now', 'late', 'message', 'nogo', 'next', 'hold', 'resume', 'change', 'sos'));

-- ============================================================
-- 2. Helpers
-- ============================================================
create or replace function public.sos_name(p_user uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((select display_name from public.profiles where id = p_user), 'Someone');
$$;

-- Queue a phone notification for some people (not in simulation events)
create or replace function public.sos_push(p_event uuid, p_users uuid[], p_dedup text, p_title text, p_body text, p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce((select (to_jsonb(e) ->> 'is_simulation')::boolean from public.events e where e.id = p_event), false) then
    return;
  end if;
  insert into public.push_queue (user_id, event_id, kind, dedup, title, body, data)
  select u, p_event, 'sos', p_dedup || ':' || u, p_title, p_body,
         jsonb_build_object('kind', 'sos', 'eventId', p_event, 'sosId', p_id, 'tag', 'sos-' || p_id)
  from unnest(p_users) as u
  on conflict (dedup) do nothing;
  if to_regprocedure('public.push_kick()') is not null then
    execute 'select public.push_kick()';
  end if;
end;
$$;

-- ============================================================
-- 3. Sending an SOS, and its location while it is active (the person in trouble)
-- ============================================================
-- Returns the SOS's id. Location: null when GPS is off or refused.
create or replace function public.raise_sos(p_event uuid, p_lat double precision, p_lng double precision, p_accuracy real, p_note text)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id bigint;
  v_name text;
begin
  if not public.is_event_member(p_event) then
    raise exception 'You are not in this event' using errcode = '42501';
  end if;
  if char_length(coalesce(v_note, '')) > 200 then
    raise exception 'Keep the message under 200 characters';
  end if;

  -- Already active: update it (pressing SOS twice does not alert everyone twice)
  select id into v_id from public.sos_alerts where event_id = p_event and user_id = v_me and resolved_at is null;
  if v_id is not null then
    update public.sos_alerts
    set note = coalesce(v_note, note),
        lat = coalesce(p_lat, lat), lng = coalesce(p_lng, lng), accuracy = coalesce(p_accuracy, accuracy),
        located_at = case when p_lat is null then located_at else now() end
    where id = v_id;
    return v_id;
  end if;

  insert into public.sos_alerts (event_id, user_id, group_id, note, lat, lng, accuracy, located_at)
  values (p_event, v_me, public.my_group_id(p_event), v_note, p_lat, p_lng, p_accuracy,
          case when p_lat is null then null else now() end)
  returning id into v_id;

  v_name := public.sos_name(v_me);
  perform public.sos_push(
    p_event,
    array(select er.user_id from public.event_roles er where er.event_id = p_event and er.user_id <> v_me group by er.user_id),
    'sos:' || v_id,
    'SOS: ' || v_name || ' needs help',
    coalesce(v_note, case when p_lat is null then 'Location unknown. Open the app.' else 'Tap to see where they are.' end),
    v_id
  );
  return v_id;
end;
$$;

-- A new location for my active SOS
create or replace function public.update_sos_location(p_id bigint, p_lat double precision, p_lng double precision, p_accuracy real)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.sos_alerts
  set lat = p_lat, lng = p_lng, accuracy = p_accuracy, located_at = now()
  where id = p_id and user_id = auth.uid() and resolved_at is null;
end;
$$;

-- ============================================================
-- 4. Responding
-- ============================================================
-- "I'm on my way" (anyone in the event). The person in trouble gets a notification.
create or replace function public.help_sos(p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sos_alerts;
  v_me uuid := auth.uid();
  v_name text := public.sos_name(auth.uid());
begin
  select * into s from public.sos_alerts where id = p_id;
  if s.id is null or not public.is_event_member(s.event_id) then
    raise exception 'This SOS no longer exists';
  end if;
  if s.resolved_at is not null then
    raise exception 'This SOS has already ended';
  end if;
  if s.user_id = v_me then
    raise exception 'This is your own SOS';
  end if;
  if exists (select 1 from jsonb_array_elements(s.helpers) h where h ->> 'user_id' = v_me::text) then
    return; -- already on the way
  end if;
  update public.sos_alerts
  set helpers = helpers || jsonb_build_array(jsonb_build_object('user_id', v_me, 'name', v_name, 'at', now()))
  where id = p_id;
  perform public.sos_push(s.event_id, array[s.user_id], 'sos-help:' || p_id || ':' || v_me,
    'Help is coming', v_name || ' is on the way.', p_id);
end;
$$;

-- End an SOS: 'safe' (the person who sent it) or 'handled' (root, planners, marshals, an IC or admin of their group)
create or replace function public.resolve_sos(p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sos_alerts;
  v_me uuid := auth.uid();
begin
  select * into s from public.sos_alerts where id = p_id;
  if s.id is null or not public.is_event_member(s.event_id) then
    raise exception 'This SOS no longer exists';
  end if;
  if s.resolved_at is not null then
    return; -- someone else ended it first
  end if;
  if s.user_id <> v_me
     and not public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])
     and not (s.group_id is not null and exists (
       select 1 from public.group_members
       where group_id = s.group_id and user_id = v_me and (is_ic or is_admin)
     )) then
    raise exception 'Only the person who sent it, a planner, a marshal, or their group''s IC or admin can end an SOS'
      using errcode = '42501';
  end if;
  update public.sos_alerts
  set resolved_at = now(), resolved_by = v_me, resolution = case when s.user_id = v_me then 'safe' else 'handled' end
  where id = p_id;
end;
$$;

-- ============================================================
-- 5. Permissions
-- ============================================================
revoke execute on function public.sos_name(uuid) from public, anon, authenticated;
revoke execute on function public.sos_push(uuid, uuid[], text, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.raise_sos(uuid, double precision, double precision, real, text) from public, anon;
revoke execute on function public.update_sos_location(bigint, double precision, double precision, real) from public, anon;
revoke execute on function public.help_sos(bigint) from public, anon;
revoke execute on function public.resolve_sos(bigint) from public, anon;

grant execute on function public.raise_sos(uuid, double precision, double precision, real, text) to authenticated;
grant execute on function public.update_sos_location(bigint, double precision, double precision, real) to authenticated;
grant execute on function public.help_sos(bigint) to authenticated;
grant execute on function public.resolve_sos(bigint) to authenticated;

notify pgrst, 'reload schema';
