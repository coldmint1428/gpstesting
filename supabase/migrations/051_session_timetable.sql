-- 051_session_timetable.sql
--
-- Step 15 of the planning plan: one read that carries times, state, and the revision the timetable is following.
--
-- WHY ONE READ. A screen that shows a running plan needs three things that used to live in three places: the clock
-- time a moment is due (the session's t0_at plus the frame), what is known about it (pending / late / arrived /
-- missed / not_required, with lateness), and the plan revision the session is following. Asking three times is
-- three chances to disagree, and the third one is the number that decides whether what is on screen is current.
-- session_timetable() answers all of it in one call, one row per group per frame, so the screen needs no second
-- read for a group's name either.
--
-- t0_at WINS. planned_at = event_sessions.t0_at + plan_frames.t_s, never plans.for_date + plans.t0_time. Those
-- two columns stay what they were in 037: display hints for a plan that has not been started. Moving them after a
-- session has begun must not move the timetable -- the session's clock is the one people were told about, and step
-- 15's check moves the plan's date and time under a running session to prove the read does not follow.
--
-- plan_rev IS THE REVISION THE SESSION FOLLOWS, AND PUBLISHING IS WHAT MOVES IT. 039 gave the session its own
-- plan_rev and said "publishing again moves it, which is how a screen holding the old timetable can tell it is
-- holding the old timetable". The second half was never true: plan_publish bumped plans.rev and nothing touched
-- event_sessions, so a running session kept the revision it started on for ever and the column could only ever
-- answer "what did it start on". This file gives plan_publish the write it promised, in the same transaction as
-- the plan's own bump -- so no reader can see the plan at 4 and the session still at 3. A session that has ended
-- keeps the number it ran: a closed show is history, not a screen waiting to be refreshed.
--
-- THE STATES ARE 050's. This is a read over session_status(), not a second derivation of it: the five-state rule
-- and the carry-forward walk live in one place (step 14, already proved), and the wrapper exists so that a screen
-- does not have to join groups and re-invent the revision. 050's function stays callable exactly as it was.
--
-- WHO READS WHAT. 040's rule, the same as every other plan read: ops staff (root, planner, marshal) read every
-- group; anyone else reads only their own group. A member with no group gets no rows. Step 16 builds the screen
-- for that read; the rule is here from the first call, because a new read that ignored it would be a regression
-- the day it shipped.
--
-- R4 on the new function, and R8 on plan_publish: its body is 048's, not 038's.

-- ---------- the read ----------
-- drop / create rather than create-or-replace: a later change to this function's columns has to be a DROP anyway
-- (the return type cannot be replaced), and a re-applied file must not silently keep an old shape (the lesson of
-- 050's column rename). Nothing depends on this function yet.
drop function if exists public.session_timetable(uuid, timestamptz);

create function public.session_timetable(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid,
  group_name text,
  frame_id uuid,
  t_s integer,
  planned_at timestamptz,
  state text,
  lateness interval,
  marked_at timestamptz,
  marked_by uuid,
  plan_rev integer
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_rev integer;
begin
  select s.event_id, s.plan_rev into v_event, v_rev
    from public.event_sessions s
   where s.id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;

  -- The session's own clock and state machine do the work (050). A session with no plan, an outsider, and a
  -- session that does not exist are all refused there with the sentences step 14 proved.
  return query
  select st.group_id,
         g.name,
         st.frame_id,
         st.t_s,
         st.planned_at,
         st.state,
         st.lateness,
         st.marked_at,
         st.marked_by,
         v_rev
    from public.session_status(p_session, p_at) st
    join public.groups g on g.id = st.group_id
   where public.has_event_role(v_event, array['root', 'planner', 'marshal'])
      or st.group_id = public.my_group_id(v_event)
   order by st.t_s, g.name, st.group_id;
end;
$body$;

comment on function public.session_timetable(uuid, timestamptz) is
  'One read for a running timetable: a row per group per frame with the planned clock time (from t0_at), '
  'pending/late/arrived/missed/not_required, lateness, and the plan revision the session follows (051).';

-- ---------- publishing moves the revision the session follows ----------
-- 048's body, with one addition at the end: the open session running this plan takes the new revision in the same
-- transaction. (R8: copied from the latest definition, not from 038's original.)
create or replace function public.plan_publish(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_row public.plans;
  v_errors integer;
  v_first text;
  v_message text;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can publish a plan.' using errcode = '42501';
  end if;

  -- The 25 m rule is a warning while a plan is being drawn and a hard gate before anyone's timetable depends on
  -- it. Without this, "the limit" was only ever advice: the board coloured frames red and then let you publish.
  select count(*) into v_errors
    from public.plan_check(p_plan) c
   where c.severity = 'error';

  if v_errors > 0 then
    select c.message into v_first
      from public.plan_check(p_plan) c
     where c.severity = 'error'
     order by c.from_s, c.to_s, c.group_id
     limit 1;
    v_message := case
      when v_errors = 1 then format('This plan cannot be published yet: %s.', v_first)
      else format('This plan cannot be published yet (%s problems). The first is: %s.', v_errors, v_first)
    end;
    raise exception '%', v_message using errcode = '22023';
  end if;

  update public.plans
     set status = 'archived', updated_by = auth.uid(), updated_at = now()
   where event_id = v_event and status = 'live' and id <> p_plan;

  update public.plans
     set status = 'live', published_at = now(), rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_plan
  returning * into v_row;

  -- The revision a running session follows. A session that has ended keeps the one it ran. This is what a screen
  -- holding the old timetable compares a fresh read against (step 15), and it is written here, not by a trigger,
  -- so the two bumps are one statement's worth of truth.
  update public.event_sessions
     set plan_rev = v_row.rev
   where plan_id = p_plan
     and ended_at is null;

  return v_row;
end;
$body$;

-- One-time truth for sessions that started before this file: the revision in force is the plan's current one,
-- because a session has always read the plan's current frames. Without this backfill a live session begun before
-- 051 would report the revision it started on and look stale to itself for ever.
update public.event_sessions s
   set plan_rev = p.rev
  from public.plans p
 where s.plan_id = p.id
   and s.ended_at is null
   and s.plan_rev <> p.rev;

-- ---------- grants (R4) ----------
revoke execute on function public.session_timetable(uuid, timestamptz) from public, anon;
grant execute on function public.session_timetable(uuid, timestamptz) to authenticated;
-- `create or replace` keeps plan_publish's grants, but naming them is what keeps a future re-create honest.
revoke execute on function public.plan_publish(uuid) from public, anon;
grant execute on function public.plan_publish(uuid) to authenticated;
