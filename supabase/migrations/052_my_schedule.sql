-- 052_my_schedule.sql
--
-- Step 16 of the planning plan: the member's schedule is the timetable, and the plan surface closes behind it.
--
-- WHAT WAS OPEN. 037 and 038 gave plans and frames the read policy `is_event_member`, which was right while the
-- timeline page showed the plan to everyone. It also meant a member of Backstage could read the frames and notes of
-- a plan nobody had published (step 3's finding 23), and 050 gave plan_progress the same membership read, so a
-- member could read what Sound recorded (step 14's debt). Both were left for this step on purpose: the member's read
-- path was going to be their own timetable, and until there was one, closing the board would have taken the timetable
-- away and given nothing back.
--
-- WHAT THE MEMBER READS NOW. session_timetable() (051) answers with a row per group per frame: the clock time, what
-- the clock makes of it, and the revision the session follows. 040's rule is applied to it. That is the whole read
-- path, so the rest closes:
--
--   plans            ops staff (root, planner, marshal) read every plan; everyone else reads the live one.
--   plan_frames      ops staff only. A member's times come from the timetable, which is scoped to their group and
--                    exists only while a session is running that plan.
--   plan_progress    ops staff every row; everyone else their own group's.
--   plan_positions   unchanged from 040: ops staff every group, everyone else their own group's. A group's own
--                    coordinates without their times are not a timetable, and step 3's check asserts that rule.
--
-- And anon loses the tables as well as the functions: the default ACL grants arwdDxtm on a new public table to anon
-- (finding 1), which 050 revoked for plan_progress only. Nothing leaked -- the policies answer anon with no rows --
-- but "reachable with the anon key" is the shape finding 1 was about.
--
-- WHY THE ENGINE IS SCOPED TOO. session_status() is executable by authenticated and returns every group's rows. A
-- scope that lives only in the wrapper is a scope a client steps around by calling the engine, so the rule moves to
-- where the rows are made and session_timetable() stops repeating it. (Step 15 put it in the read because the read
-- was the only caller; now it has a home.) The rules the two functions carry -- the five states, the carry-forward
-- walk, lateness from t0_at -- are 050's, unchanged; only the rows a caller may see change.
--
-- WHAT THE TIMETABLE GAINS. plan_name and note. A schedule with a clock time and a state but no name of what is
-- happening is a list of numbers: the frame's note ("doors", "step up") is the label the planner wrote, and the plan's
-- name is what the person was told to follow. Both come back from the same call (step 15's "one read"), so a refresh
-- is still one request. The return type changes, so this is DROP + CREATE + re-GRANT (R2, R4).
--
-- R8: both bodies are the latest definitions (session_status from 050, session_timetable from 051), not the originals.
-- R1: every extension call would be qualified; this file calls none.

-- ---------- 1. the plan surface closes behind the timetable ----------
-- Ops staff keep everything: they are the people who draw and run the plan. A member keeps only what the live plan
-- says, because that is what was announced; a draft is somebody's working copy.

drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select to authenticated
  using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal'])
    -- The live plan is for the event's people, not for every authenticated user: publishing announces the plan to
    -- the event, and the second half of this clause is what says whose event it is.
    or (status = 'live' and public.is_event_member(event_id))
  );

comment on policy plans_read on public.plans is
  'Ops staff read every plan; everyone else reads only the live one (052, step 16).';

-- Frames are the plan itself -- times and notes. A member's copy of those is their timetable, scoped to their group
-- and only for a session that is running the plan, so there is no reason to hand out the strip as well.
drop policy if exists plan_frames_read on public.plan_frames;
create policy plan_frames_read on public.plan_frames for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']));

comment on policy plan_frames_read on public.plan_frames is
  'Ops staff only: a member''s moments come from session_timetable(), scoped to their group (052, step 16).';

-- plan_positions is deliberately left as 040 wrote it: ops staff read every group, everyone else their own group's.
-- What finding 23 and step 14's debt named was the plan (its frames and notes) and the outcomes, not a group's own
-- coordinates; 040's policy is the rule step 3's check asserts, and a member's coordinates without their times are
-- not a timetable. The read that names a moment's place and time is session_timetable(), and that is the one the
-- screen uses.

-- What was recorded is about a group's night, so a group reads its own record; the ops read everybody's.
drop policy if exists plan_progress_read on public.plan_progress;
create policy plan_progress_read on public.plan_progress for select to authenticated
  using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal'])
    or group_id = public.my_group_id(event_id)
  );

comment on policy plan_progress_read on public.plan_progress is
  'Ops staff read every outcome; everyone else reads their own group''s (052, step 16).';

-- ---------- 1b. anon loses the tables as well as the functions ----------
-- The default ACL grants arwdDxtm on a new public table to anon (finding 1). 050 revoked it for plan_progress and
-- the three older plan tables were left with it: the policies returned no rows to anon, so nothing leaked, but
-- "reachable with the anon key" is the shape finding 1 was about, and this is the file where the plan surface is
-- supposed to be closed. Revoked here, and SELECT granted back to authenticated so the grants say what the
-- policies mean.
--
-- (037's activities table is deliberately not touched: the ledger says 037 is applied, the table is not in the
-- database -- 038 replaced plan_list so nothing needed it, and no client ever read it. A policy for a table that
-- is not there aborts the file; see the plan document's note on it.)
revoke all on table public.plans from anon;
revoke all on table public.plan_frames from anon;
revoke all on table public.plan_positions from anon;
revoke all on table public.plan_progress from anon;
grant select on table public.plans, public.plan_frames, public.plan_positions to authenticated;
grant select on table public.plan_progress to authenticated;

-- ---------- 2. the engine applies the same scope ----------
-- 050's body, with one WHERE clause: the group the caller is allowed to see. It is deliberately the same expression
-- the timetable used to carry, moved here so that no other caller can ask the engine about somebody else's group.
create or replace function public.session_status(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid, frame_id uuid, t_s integer, planned_at timestamptz,
  state text, lateness interval, marked_at timestamptz, marked_by uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_at timestamptz := coalesce(p_at, now());
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if v_session.plan_id is null or v_session.t0_at is null then
    raise exception 'That session is not running a plan.' using errcode = '22023';
  end if;

  return query
  with frames as (
    select f.id, f.t_s from public.plan_frames f where f.plan_id = v_session.plan_id
  ), stated as (
    select p.group_id, f.t_s, p.state
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = v_session.plan_id
  ), cells as (
    -- Every frame crossed with every group that stands somewhere in this plan, minus the frames that come
    -- before the group's first statement: that group is not part of the plan yet, so it has no state to have.
    select fr.id as frame_id, fr.t_s, g.group_id, pos.state as pos_state
      from frames fr
      cross join (select distinct s.group_id from stated s) g
      cross join lateral (
        select st.state
          from stated st
         where st.group_id = g.group_id and st.t_s <= fr.t_s
         order by st.t_s desc
         limit 1
      ) pos
  )
  select c.group_id,
         c.frame_id,
         c.t_s,
         v_session.t0_at + make_interval(secs => c.t_s) as planned_at,
         case
           when m.state is not null then m.state
           when c.pos_state = 'off_site' then 'not_required'
           when v_session.t0_at + make_interval(secs => c.t_s) < v_at then 'late'
           else 'pending'
         end,
         case
           when m.state is not null then m.marked_at - (v_session.t0_at + make_interval(secs => c.t_s))
           when c.pos_state = 'off_site' then null
           when v_session.t0_at + make_interval(secs => c.t_s) < v_at
             then v_at - (v_session.t0_at + make_interval(secs => c.t_s))
           else null
         end as lateness,
         m.marked_at,
         m.marked_by
    from cells c
    left join public.plan_progress m
      on m.session_id = v_session.id
     and m.frame_id = c.frame_id
     and m.group_id = c.group_id
   -- 040's scope: ops staff read every group, everyone else their own. Moved here in step 16; the timetable no
   -- longer repeats it, so there is one place the rule is written.
   where public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal'])
      or c.group_id = public.my_group_id(v_session.event_id)
   order by c.t_s, c.group_id;
end;
$body$;

comment on function public.session_status(uuid, timestamptz) is
  'One row per group per frame: planned clock time, pending/late/arrived/missed/not_required, lateness from t0_at, '
  'scoped to the caller (ops staff every group, everyone else their own) (050, scope 052).';

-- ---------- 3. the timetable carries the names the schedule shows ----------
-- 051's body with plan_name, note and the scope left to the engine. Dropped rather than replaced because the return
-- type changes (R2), and re-granted (R4).
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
  note text,
  plan_name text,
  plan_rev integer
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_plan uuid;
  v_rev integer;
  v_plan_name text;
begin
  select s.event_id, s.plan_id, s.plan_rev into v_event, v_plan, v_rev
    from public.event_sessions s
   where s.id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;

  -- A session with no plan has no name to show; session_status() refuses it below with its own sentence.
  select p.name into v_plan_name from public.plans p where p.id = v_plan;

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
         f.note,
         v_plan_name,
         v_rev
    from public.session_status(p_session, p_at) st
    join public.groups g on g.id = st.group_id
    left join public.plan_frames f on f.id = st.frame_id
   order by st.t_s, g.name, st.group_id;
end;
$body$;

comment on function public.session_timetable(uuid, timestamptz) is
  'One read for a running timetable: a row per group per frame with the planned clock time (from t0_at), '
  'pending/late/arrived/missed/not_required, lateness, the frame''s note, the plan''s name, and the revision the '
  'session follows; scoped to the caller (051, names 052).';

-- ---------- grants (R4) ----------
revoke execute on function public.session_status(uuid, timestamptz) from public, anon;
revoke execute on function public.session_timetable(uuid, timestamptz) from public, anon;
grant execute on function public.session_status(uuid, timestamptz) to authenticated;
grant execute on function public.session_timetable(uuid, timestamptz) to authenticated;
