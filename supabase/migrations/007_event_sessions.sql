-- Step 7: event sessions. ICs can only share while the event is LIVE.
-- Run AFTER 006_self_renewing_pass.sql.
--
-- A session = one "Start event" -> "End event". An event can have many (rehearsal, show day...).
--   starts_at in the future             = scheduled start (goes live by itself at that time)
--   starts_at <= now(), ended_at null   = LIVE
--   ended_at set                        = finished (End event, or automatically after 24 h without uploads)
-- "Live" is checked by the database (tracking pass, phone uploads, website inserts), not only
-- by hiding the Share button.

create extension if not exists pg_cron;

create table public.event_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  starts_at timestamptz not null,
  ended_at timestamptz,
  started_by uuid references public.profiles (id) on delete set null,
  ended_by uuid references public.profiles (id) on delete set null,
  end_reason text check (end_reason in ('ended', 'auto')), -- 'auto' = closed after 24 h without uploads
  created_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= starts_at)
);
-- At most one session per event that is scheduled or live (not ended)
create unique index event_sessions_one_open on public.event_sessions (event_id) where ended_at is null;
create index event_sessions_event_idx on public.event_sessions (event_id, starts_at desc);

alter table public.event_sessions enable row level security;
-- Everyone in the event may see the sessions (to know if sharing is open). Writes only via functions.
create policy "members see sessions" on public.event_sessions
  for select to authenticated using (public.is_event_member(event_id));

-- Live updates: the Share button unlocks / locks itself when a planner starts or ends the event
alter publication supabase_realtime add table public.event_sessions;

-- ============================================================
-- Helpers
-- ============================================================

-- The live session of an event (null if not live)
create function public.live_session_id(p_event_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.event_sessions
  where event_id = p_event_id and ended_at is null and starts_at <= now();
$$;

create function public.event_is_live(p_event_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.live_session_id(p_event_id) is not null;
$$;

-- Internal: when a session ends, cancel every tracking pass of the event and leave a
-- "Stopped sharing" marker for everyone whose latest reading in this session is GPS.
-- Returns how many people were stopped.
create function public.close_session_sharing(p_session_id uuid, p_end timestamptz)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  stopped integer;
begin
  select * into s from public.event_sessions where id = p_session_id;

  update public.tracking_passes set revoked_at = now()
  where event_id = s.event_id and revoked_at is null;

  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  select l.event_id, l.group_id, l.user_id, l.lat, l.lng, l.accuracy, 'stop', greatest(p_end, l.recorded_at)
  from (
    select distinct on (user_id) * from public.locations
    where event_id = s.event_id and recorded_at >= s.starts_at
    order by user_id, recorded_at desc
  ) l
  where l.source = 'gps';
  get diagnostics stopped = row_count;
  return stopped;
end;
$$;

-- ============================================================
-- Actions for root / planners (Event status card)
-- ============================================================

-- Start now. If a start was scheduled for later, it starts now instead.
create function public.start_event(p_event_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  open_session public.event_sessions;
  new_id uuid;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can start the event' using errcode = '42501';
  end if;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live';
    end if;
    update public.event_sessions set starts_at = now(), started_by = auth.uid() where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by)
  values (p_event_id, now(), auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- Schedule (or move) a start time. The event goes live by itself at that time.
create function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  open_session public.event_sessions;
  new_id uuid;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can schedule the event' using errcode = '42501';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Pick a start time in the future';
  end if;
  if p_starts_at > now() + interval '1 year' then
    raise exception 'Pick a start time within the next year';
  end if;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions set starts_at = p_starts_at, started_by = auth.uid() where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by)
  values (p_event_id, p_starts_at, auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- Cancel a scheduled start that hasn't happened yet
create function public.cancel_scheduled_start(p_event_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the schedule' using errcode = '42501';
  end if;
  delete from public.event_sessions
  where event_id = p_event_id and ended_at is null and starts_at > now();
  if not found then
    raise exception 'There is no scheduled start to cancel';
  end if;
end;
$$;

-- End the live session: everyone's sharing stops. Returns how many people were stopped.
create function public.end_event(p_event_id uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  live_id uuid;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can end the event' using errcode = '42501';
  end if;

  select id into live_id from public.event_sessions
  where event_id = p_event_id and ended_at is null and starts_at <= now() for update;
  if live_id is null then
    raise exception 'The event is not live';
  end if;

  update public.event_sessions set ended_at = now(), ended_by = auth.uid(), end_reason = 'ended'
  where id = live_id;
  return public.close_session_sharing(live_id, now());
end;
$$;

-- Run by pg_cron every 15 min: a live session with no uploads for 24 h closes itself
-- (a planner forgot to press End). It ends at the time of its last upload.
create function public.auto_close_idle_sessions()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  end_at timestamptz;
  closed integer := 0;
begin
  for s in
    select es.id, es.starts_at,
      (select max(l.recorded_at) from public.locations l
       where l.event_id = es.event_id and l.recorded_at >= es.starts_at) as last_upload
    from public.event_sessions es
    where es.ended_at is null and es.starts_at <= now() - interval '24 hours'
  loop
    end_at := greatest(coalesce(s.last_upload, s.starts_at), s.starts_at);
    if end_at <= now() - interval '24 hours' then
      update public.event_sessions set ended_at = end_at, end_reason = 'auto' where id = s.id;
      perform public.close_session_sharing(s.id, end_at);
      closed := closed + 1;
    end if;
  end loop;
  return closed;
end;
$$;

select cron.schedule('gps-auto-close-sessions', '*/15 * * * *', 'select public.auto_close_idle_sessions()');

-- ============================================================
-- Sharing only while live
-- ============================================================

-- Phone app: no tracking pass before the event starts
create or replace function public.start_tracking_pass(p_event_id uuid, p_group_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_token uuid;
begin
  if not public.is_ic_of(p_event_id, p_group_id) then
    raise exception 'Only the group''s IC can share location' using errcode = '42501';
  end if;
  if not public.event_is_live(p_event_id) then
    raise exception 'The event has not started yet. Sharing opens when a planner starts it.';
  end if;

  update public.tracking_passes set revoked_at = now()
  where user_id = auth.uid() and event_id = p_event_id and revoked_at is null;

  insert into public.tracking_passes (user_id, event_id, group_id)
  values (auth.uid(), p_event_id, p_group_id)
  returning token into new_token;
  return new_token;
end;
$$;

-- Phone uploads: refused (HTTP 403) once the event is no longer live
create or replace function public.report_location(
  p_token uuid,
  p_lat double precision,
  p_lng double precision,
  p_accuracy real,
  p_recorded_at timestamptz
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  pass public.tracking_passes;
begin
  select * into pass from public.tracking_passes
  where token = p_token and revoked_at is null and expires_at > now();
  if not found then
    raise exception 'Tracking pass is invalid, stopped or expired' using errcode = 'PT403';
  end if;

  if not exists (
    select 1 from public.group_members
    where user_id = pass.user_id and event_id = pass.event_id and group_id = pass.group_id and is_ic
  ) then
    raise exception 'No longer the IC of this group' using errcode = 'PT403';
  end if;

  if not public.event_is_live(pass.event_id) then
    raise exception 'The event is not live' using errcode = 'PT403';
  end if;

  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;

  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values (pass.event_id, pass.group_id, pass.user_id, p_lat, p_lng, p_accuracy, 'gps', coalesce(p_recorded_at, now()));

  -- Self-renewing: still sharing = still valid for another 24 h (max 7 days after Share)
  update public.tracking_passes
  set expires_at = least(now() + interval '24 hours', created_at + interval '7 days')
  where token = p_token;
end;
$$;

-- Website sharing: same rule through Row Level Security
drop policy "ICs insert own group locations" on public.locations;
create policy "ICs insert own group locations while live" on public.locations
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_ic_of(event_id, group_id)
    and public.event_is_live(event_id)
  );

-- ============================================================
-- Permissions (one function at a time - never "all functions")
-- ============================================================
revoke execute on function public.live_session_id(uuid) from public, anon;
revoke execute on function public.event_is_live(uuid) from public, anon;
revoke execute on function public.start_event(uuid) from public, anon;
revoke execute on function public.schedule_event_start(uuid, timestamptz) from public, anon;
revoke execute on function public.cancel_scheduled_start(uuid) from public, anon;
revoke execute on function public.end_event(uuid) from public, anon;
grant execute on function public.live_session_id(uuid) to authenticated;
grant execute on function public.event_is_live(uuid) to authenticated;
grant execute on function public.start_event(uuid) to authenticated;
grant execute on function public.schedule_event_start(uuid, timestamptz) to authenticated;
grant execute on function public.cancel_scheduled_start(uuid) to authenticated;
grant execute on function public.end_event(uuid) to authenticated;
-- Internal only (called by other functions / pg_cron)
revoke execute on function public.close_session_sharing(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.auto_close_idle_sessions() from public, anon, authenticated;
