-- Step 13: root / planners can delete a recording from the Playback tab.
-- Run AFTER 012_close_expired_first.sql.
--
--   session recording (p_session_id): its readings (start -> end) and the session itself
--   day recording (p_day, readings from before Start/End existed): that day's readings that are
--   not in any session
-- A live session can't be deleted (end it first). Returns how many readings were deleted.

create function public.delete_recording(p_event_id uuid, p_session_id uuid default null, p_day date default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  deleted integer;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can delete recordings' using errcode = '42501';
  end if;

  if p_session_id is not null then
    select * into s from public.event_sessions where id = p_session_id and event_id = p_event_id for update;
    if not found then
      raise exception 'Recording not found';
    end if;
    if s.ended_at is null then
      raise exception 'This event is still live or scheduled. End it before deleting the recording.';
    end if;
    delete from public.locations
    where event_id = p_event_id and recorded_at >= s.starts_at and recorded_at <= s.ended_at;
    get diagnostics deleted = row_count;
    delete from public.event_sessions where id = s.id; -- push_reminders go with it (cascade)
    return deleted;
  end if;

  if p_day is not null then
    delete from public.locations l
    where l.event_id = p_event_id
      and (l.recorded_at at time zone 'Asia/Singapore')::date = p_day
      and not exists (
        select 1 from public.event_sessions es
        where es.event_id = l.event_id and es.starts_at <= l.recorded_at
          and l.recorded_at <= coalesce(es.ended_at, 'infinity'::timestamptz)
      );
    get diagnostics deleted = row_count;
    return deleted;
  end if;

  raise exception 'Say which recording to delete';
end;
$$;

revoke execute on function public.delete_recording(uuid, uuid, date) from public, anon;
grant execute on function public.delete_recording(uuid, uuid, date) to authenticated;
