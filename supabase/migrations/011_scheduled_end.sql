-- Step 11: schedule when the event ENDS (like the scheduled start).
-- Run AFTER 010_stop_with_pass.sql.
--
-- A planner sets an end time on the scheduled or live session. From that moment the event is no
-- longer live (sharing refused at once), and a job running every minute closes the session the
-- same way End event does (passes cancelled, "Stopped sharing" markers).

alter table public.event_sessions add column scheduled_end timestamptz;
alter table public.event_sessions add constraint event_sessions_scheduled_end_after_start
  check (scheduled_end is null or scheduled_end > starts_at);

-- 'scheduled' = ended by its scheduled end time
alter table public.event_sessions drop constraint event_sessions_end_reason_check;
alter table public.event_sessions add constraint event_sessions_end_reason_check
  check (end_reason in ('ended', 'auto', 'scheduled'));

-- Live = started, not ended, and its scheduled end (if any) not reached
create or replace function public.live_session_id(p_event_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.event_sessions
  where event_id = p_event_id and ended_at is null and starts_at <= now()
    and (scheduled_end is null or scheduled_end > now());
$$;

-- Set or move the end time of the scheduled / live session
create function public.schedule_event_end(p_event_id uuid, p_ends_at timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  open_session public.event_sessions;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can schedule the end' using errcode = '42501';
  end if;
  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;
  if not found then
    raise exception 'Start or schedule the event first';
  end if;
  if p_ends_at is null or p_ends_at <= now() then
    raise exception 'Pick an end time in the future';
  end if;
  if p_ends_at <= open_session.starts_at then
    raise exception 'The end time must be after the start time';
  end if;
  update public.event_sessions set scheduled_end = p_ends_at where id = open_session.id;
end;
$$;

create function public.cancel_scheduled_end(p_event_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the end' using errcode = '42501';
  end if;
  update public.event_sessions set scheduled_end = null
  where event_id = p_event_id and ended_at is null and scheduled_end > now();
  if not found then
    raise exception 'There is no scheduled end to cancel';
  end if;
end;
$$;

-- Moving the start past a scheduled end would make no sense: drop the end then
create or replace function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz)
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
    update public.event_sessions
    set starts_at = p_starts_at, started_by = auth.uid(),
        scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
    where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by)
  values (p_event_id, p_starts_at, auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- Run by pg_cron every minute: close sessions whose scheduled end has passed
create function public.end_scheduled_sessions()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  closed integer := 0;
begin
  for s in
    select id, scheduled_end from public.event_sessions
    where ended_at is null and scheduled_end is not null and scheduled_end <= now()
    for update skip locked
  loop
    update public.event_sessions set ended_at = s.scheduled_end, end_reason = 'scheduled' where id = s.id;
    perform public.close_session_sharing(s.id, s.scheduled_end);
    closed := closed + 1;
  end loop;
  return closed;
end;
$$;

select cron.schedule('gps-end-scheduled-sessions', '* * * * *', 'select public.end_scheduled_sessions()');

revoke execute on function public.schedule_event_end(uuid, timestamptz) from public, anon;
revoke execute on function public.cancel_scheduled_end(uuid) from public, anon;
grant execute on function public.schedule_event_end(uuid, timestamptz) to authenticated;
grant execute on function public.cancel_scheduled_end(uuid) to authenticated;
revoke execute on function public.end_scheduled_sessions() from public, anon, authenticated;

-- The "Stopped sharing" marker must come after the person's last reading, also when that
-- reading has exactly the end time (otherwise the map could still show them as sharing)
create or replace function public.close_session_sharing(p_session_id uuid, p_end timestamptz)
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
  select l.event_id, l.group_id, l.user_id, l.lat, l.lng, l.accuracy, 'stop',
    greatest(p_end, l.recorded_at + interval '1 millisecond')
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
revoke execute on function public.close_session_sharing(uuid, timestamptz) from public, anon, authenticated;
