-- ============================================================
-- 084: delete a group.
--   Root / planners only. Its people stay in the event with no group (their group row goes, so any IC or group admin
--   duty there goes too). Whatever hangs off the group goes with it: its timeline items, frames, attendance and
--   recorded locations (every table references groups with ON DELETE CASCADE).
--   Refused while the event is live: a running event has ICs sharing for that group right now.
-- ============================================================

create or replace function public.delete_group(p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.groups where id = p_group;
  if v_event is null then
    raise exception 'That group no longer exists';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can delete a group' using errcode = '42501';
  end if;
  if exists (select 1 from public.event_sessions where event_id = v_event and ended_at is null and starts_at <= now()) then
    raise exception 'The event is live. End it before deleting a group';
  end if;
  delete from public.groups where id = p_group;
end;
$$;

revoke execute on function public.delete_group(uuid) from public, anon;
grant execute on function public.delete_group(uuid) to authenticated;

notify pgrst, 'reload schema';
