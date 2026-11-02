-- 076: session_marks() -- the part of a running timetable that changes between two publishes, and nothing else.
--
-- WHY. 2 Nov load test: every phone re-read `session_timetable` every 30 s and again at every planned moment. On the
-- NDP plan (436 frames) that is 436 rows for a member (0.18 s of database) and 8,720 for a planner (1.1 s), and the
-- reads were about 95 % of the database's work; 35 simulated phones were enough to make the app slow for everyone.
-- Yet between two publishes only two things in it change: the marks (an arrival tapped, or detected from GPS, 064)
-- and the clock. The clock is the phone's own (corrected by `now` below), so the app now reads the whole timetable once
-- per published version and asks only this between publishes (src/lib/timetableReader.js).
--
-- WHAT IT ANSWERS (one jsonb):
--   now       the database's clock, so the phone can correct its own before judging "late"
--   plan_id, plan_rev, t0_at, ended_at
--             what the timetable is ABOUT: when one differs from the copy on the phone, the phone reads the whole
--             timetable again (a publish, a new T+0, a hold), with no live notice needed
--   marks     [{ group_id, frame_id, state, marked_at, marked_by }], the same rows session_status() joins
--
-- WHO SEES WHAT: exactly session_status()'s rules (it is the same scope, written the same way): a person in the event,
-- root and planners every group, everyone else their own group.

create or replace function public.session_marks(p_session uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_session public.event_sessions;
  v_all boolean;
  v_group uuid;
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;

  v_all := public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal']);
  v_group := public.my_group_id(v_session.event_id);

  return jsonb_build_object(
    'now', now(),
    'plan_id', v_session.plan_id,
    'plan_rev', v_session.plan_rev,
    't0_at', v_session.t0_at,
    'ended_at', v_session.ended_at,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'group_id', m.group_id, 'frame_id', m.frame_id, 'state', m.state,
               'marked_at', m.marked_at, 'marked_by', m.marked_by))
        from public.plan_progress m
       where m.session_id = v_session.id
         and (v_all or m.group_id = v_group)
    ), '[]'::jsonb)
  );
end
$$;

revoke execute on function public.session_marks(uuid) from public, anon;
grant execute on function public.session_marks(uuid) to authenticated;
