-- 056_plan_ops.sql
--
-- Step 20 of the planning plan: the ops picture of a running plan -- which moment each group is on, how long the strip
-- gives it, and where its ICs actually are.
--
-- WHAT THIS READ IS FOR. 051 answers "what does the timetable say": one row per group per moment, with the five states
-- of what happened (pending / late / arrived / missed / not_required). An ops board asks a different question: "who is
-- under way, where should they be right now, and where are they really". That is three columns of a different table,
-- and until this file a plan session had none of them: the old ops board reads movement_status, which belongs to the
-- run-sheet engine (027) and dies with it, so a plan session showed a map and nothing else.
--
-- ONE ROW PER GROUP PER MOMENT, AND THE STATUS IS THE MOMENT'S. The plan sketched the three words as a group's own
-- state (pending / active / done). A group has two or three moments, so a group's own state flips twice and then says
-- the same word for the rest of the night -- "active" from its first moment to its last, however many frames pass.
-- The three words are worth keeping (they are 027's vocabulary, so nobody has to learn a second one), so they are
-- attached to the unit the strip actually has: a MOMENT, and the walk that begins at it.
--
--     pending   the clock has not reached this moment yet
--     active    this is the group's current moment -- the clock is at or past it, and has not reached its next one
--     done      a later moment of the group's is current (or this is the last moment and the clock has reached it)
--
-- So as the clock passes each moment exactly one row of that group flips pending -> active, and the row it left flips
-- active -> done. That is the sentence the step's done-when asks to see, and it is also what an ops board wants: the
-- active row is "what this group is doing now", the next pending row is "what it does after", and the done rows are
-- the walk behind it. A group's own status is still one word in the screen -- active if any row is, else done if all
-- are, else pending -- but it is derived from rows rather than being the only thing the read knows.
--
-- THE LAST MOMENT HAS NO WALK, SO IT SKIPS "active". There is nothing left to walk to, so that row is pending until
-- its own instant and done from then on; the walk TO it is the active row before it. A group with a single moment is
-- therefore pending and then done, and that is honest: a plan that states a group once has asked for one instant, not
-- a walk. It is also why a moment's status is not the same question as "has this group finished its plan" -- a group
-- whose last moment has passed is done, and this read does not pretend to know whether it arrived (step 21 marks it).
--
-- TRAVEL TIME IS THE STRIP'S INTERVAL, NOT THE CLOCK'S LATENESS AND NOT A WALKING ESTIMATE. `travel_s` is the
-- difference between this moment and the group's next: the time the strip gives that walk. Deliberately not
-- `now - t_s` (that is lateness, 050's job) and deliberately not metres / 1.4 m/s: the plan does not state a route,
-- 048 measures a straight line only as a lower bound, and a pace the strip never agreed to would be this read
-- inventing a number. The last moment has no next, so its travel_s is null. A group standing still between two
-- moments still has a travel_s -- it is the time the strip gives to get from one statement to the other, which may be
-- an instruction not to move.
--
-- WHERE A GROUP REALLY IS. The accuracy-weighted midpoint of its ICs' newest readings, asked at p_at: weight
-- 1 / accuracy^2 over readings from the last two minutes with 0 < accuracy <= 100 m, one reading per person, and a
-- 'stop' row is not a position. That is 021's rule exactly -- the rule the live map and the group_positions table
-- have used since Stage 2 -- and it is here in one place now: `group_position_at()` is called by this read and by
-- 021's refresh_group_position(), so a group's position cannot mean one thing on the map and another on the ops board.
-- The function is INTERNAL (no execute grant to anybody): it is called by the two security-definer readers, so it is
-- not a new door and needs no policy of its own.
--
-- WHY NOT READ group_positions. It is the right table for "the last reading that arrived", which is what the live map
-- wants. This read is asked AT AN INSTANT (p_at), because a check has to stand at a chosen second and a planner wants
-- to ask "how did this look at 18:20"; group_positions is written by a trigger only when a reading arrives and a
-- session covers its time, so asking it about the past would answer with the present. The numbers are the same rule
-- and the check asserts that the two agree on the same readings.
--
-- "NO SIGNAL" IS NOT ZERO METRES. With no usable reading the position columns are null and `off_m` is null; the screen
-- says "no signal", not "on the walk". `actual_ics` counts the ICs that are sharing at all (any accuracy, stop rows
-- excluded) -- "how many phones are sending", which is not the same as how many were used to place the group. A
-- reading older than two minutes is not used at all, so a group whose ICs went quiet is placed nowhere rather than at
-- its last known spot pretending to be current.
--
-- WHO READS WHAT. 040's rule, the same as every plan read: ops staff (root, planner, marshal) read every group, and
-- everyone else reads only their own. The scope is applied FIRST, in `visible`, before any per-group function is
-- called: plan_position_at() refuses a group the caller may not read (053), so a read that computed first and filtered
-- afterwards would raise for a member instead of answering for their group. The `locations` rows are read with this
-- function's own rights behind that membership check -- the same way 050 and 051 read the plan behind theirs.
--
-- THE CLOCK IS t0_at. planned_at = event_sessions.t0_at + plan_frames.t_s, never plans.for_date + plans.t0_time (039,
-- 050): the session's clock is the one people were told. p_at is a parameter so a check can stand at a chosen second;
-- it is NOT consulted against ended_at -- a closed show is read at its close by the screen that asks, and the read
-- does not get to decide that the night is over (step 14's debt, left to the caller in step 16 and kept here).
--
-- AN OFF-SITE MOMENT HAS NO DISTANCE FROM THE WALK. `expected_state` is 046's flag, and when the plan has the group
-- off site, `off_m` is null: there is no place on the map to measure to, and a distance would be a fiction. The
-- position columns still say where the phones are, which is the honest answer to a different question.
--
-- R4 ON THE READ; THE HELPER IS NOT A DOOR. plan_ops is revoked from public and anon and granted to authenticated;
-- group_position_at is revoked from public, anon AND authenticated. refresh_group_position keeps the grants 021 gave it
-- (none to authenticated) and its body is 021's, with only the midpoint moved out (R8: copied from the latest
-- definition, not from where the function was first written).

-- ---------- one group's position at an instant ----------
-- Not STABLE on purpose: its first caller is the trigger on locations, and in an AFTER trigger a STABLE function may
-- be planned against the calling query's snapshot -- the one taken before the row that fired the trigger. A read that
-- has to see the reading it was called for cannot claim to be stable.
create or replace function public.group_position_at(p_event uuid, p_group uuid, p_at timestamptz)
returns table (lat double precision, lng double precision, accuracy real, ics integer, last_seen timestamptz)
language sql
security definer
set search_path = ''
as $body$
  with latest as (
    select distinct on (l.user_id) l.user_id, l.lat, l.lng, l.accuracy, l.source, l.recorded_at
      from public.locations l
     where l.event_id = p_event
       and l.group_id = p_group
       and l.recorded_at <= p_at
       and l.recorded_at > p_at - interval '2 minutes'
     order by l.user_id, l.recorded_at desc
  ), sharing as (
    select s.user_id, s.lat, s.lng, s.accuracy, s.recorded_at
      from latest s
     where s.source <> 'stop'
  ), usable as (
    select u.lat, u.lng, u.accuracy, 1.0 / (u.accuracy * u.accuracy) as w
      from sharing u
     where u.accuracy > 0 and u.accuracy <= 100
  )
  select (select sum(u.lat * u.w) / nullif(sum(u.w), 0) from usable u),
         (select sum(u.lng * u.w) / nullif(sum(u.w), 0) from usable u),
         (select min(u.accuracy) from usable u),
         (select count(*)::int from sharing s),
         (select max(l2.recorded_at) from latest l2);
$body$;

comment on function public.group_position_at(uuid, uuid, timestamptz) is
  'A group''s accuracy-weighted midpoint at an instant: newest reading per IC from the last 2 minutes, '
  'weight 1/accuracy^2 for 0 < accuracy <= 100 m, stop rows are not positions (021''s rule, 056).';

-- ---------- the ops read ----------
-- Drop / create rather than create-or-replace: a later change to these columns has to be a DROP anyway, and a
-- re-applied file must not silently keep an old shape.
drop function if exists public.plan_ops(uuid, timestamptz);

create function public.plan_ops(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid,
  group_name text,
  frame_id uuid,
  t_s integer,
  planned_at timestamptz,
  note text,
  status text,
  next_t_s integer,
  next_at timestamptz,
  travel_s integer,
  plan_lat double precision,
  plan_lng double precision,
  plan_state text,
  plan_verify text,
  expected_lat double precision,
  expected_lng double precision,
  expected_state text,
  actual_lat double precision,
  actual_lng double precision,
  actual_accuracy real,
  actual_ics integer,
  actual_at timestamptz,
  off_m integer
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_at timestamptz := coalesce(p_at, now());
  v_clock integer;
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

  -- The plan's own clock, as an offset: negative before T+0, which is a legal instant to ask about (nothing has
  -- happened, every moment is pending, and plan_position_at has nothing to say).
  v_clock := floor(extract(epoch from (v_at - v_session.t0_at)))::int;

  return query
  with visible as (
    -- 040's rule, applied before anything is computed for a group (see the header).
    select g.id as group_id, g.name as group_name
      from public.groups g
     where g.event_id = v_session.event_id
       and (public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal'])
            or g.id = public.my_group_id(v_session.event_id))
  ), stated as (
    -- The group's own moments: a frame it is not stated at is not a moment of its plan.
    select pos.group_id, f.id as frame_id, f.t_s, f.note, pos.lat, pos.lng, pos.state, pos.verify
      from public.plan_positions pos
      join public.plan_frames f on f.id = pos.frame_id
      join visible v on v.group_id = pos.group_id
     where f.plan_id = v_session.plan_id
  ), moments as (
    select s.group_id, s.frame_id, s.t_s, s.note, s.lat, s.lng, s.state, s.verify,
           lead(s.t_s) over (partition by s.group_id order by s.t_s) as next_t_s
      from stated s
  ), expected as (
    -- Where the walk has the group at this instant, once per group (053's arithmetic, not a second copy of it).
    select m.group_id, e.lat, e.lng, e.state
      from (select distinct s.group_id from stated s) m
      cross join lateral public.plan_position_at(v_session.plan_id, m.group_id, v_clock) e
  ), ground as (
    -- Where its ICs say it is, once per group.
    select m.group_id, p.lat, p.lng, p.accuracy, p.ics, p.last_seen
      from (select distinct s.group_id from stated s) m
      cross join lateral public.group_position_at(v_session.event_id, m.group_id, v_at) p
  )
  select m.group_id,
         v.group_name,
         m.frame_id,
         m.t_s,
         v_session.t0_at + make_interval(secs => m.t_s),
         m.note,
         case
           when v_at < v_session.t0_at + make_interval(secs => m.t_s) then 'pending'
           when m.next_t_s is not null
                and v_at < v_session.t0_at + make_interval(secs => m.next_t_s) then 'active'
           else 'done'
         end,
         m.next_t_s,
         case when m.next_t_s is not null
              then v_session.t0_at + make_interval(secs => m.next_t_s) end,
         case when m.next_t_s is not null then m.next_t_s - m.t_s end,
         m.lat,
         m.lng,
         m.state,
         m.verify,
         e.lat,
         e.lng,
         e.state,
         p.lat,
         p.lng,
         p.accuracy,
         p.ics,
         p.last_seen,
         case when e.state = 'on_site' and p.lat is not null then
           round(extensions.st_distance(
             extensions.st_setsrid(extensions.st_makepoint(p.lng, p.lat), 4326)::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(e.lng, e.lat), 4326)::extensions.geography))::int
         end
    from moments m
    join visible v on v.group_id = m.group_id
    left join expected e on e.group_id = m.group_id
    left join ground p on p.group_id = m.group_id
   order by v.group_name, m.t_s;
end;
$body$;

comment on function public.plan_ops(uuid, timestamptz) is
  'The ops picture of a plan session: one row per group per moment with pending/active/done, the travel time the '
  'strip gives (to the group''s next moment), and where its ICs are at p_at (056).';

-- ---------- the live midpoint is the same rule ----------
-- 021's body, with the midpoint moved into group_position_at(). Everything the trigger needs is unchanged: the same
-- window, the same weight, the same columns, the same speed over the last ~60 s.
create or replace function public.refresh_group_position(p_session uuid, p_event uuid, p_group uuid, p_at timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_fix record;
begin
  if p_group is null then return; end if;

  select * into v_fix from public.group_position_at(p_event, p_group, p_at);

  with latest as (
    select distinct on (l.user_id) l.user_id, l.lat, l.lng, l.accuracy, l.source, l.recorded_at
    from public.locations l
    where l.event_id = p_event and l.group_id = p_group
      and l.recorded_at > p_at - interval '2 minutes'
    order by l.user_id, l.recorded_at desc
  ),
  sharing as (
    select * from latest where source <> 'stop'
  ),
  speeds as (
    -- each sharing IC: distance from its reading ~60 s earlier (30-90 s back) to now, per second
    select extensions.st_distance(
             extensions.st_setsrid(extensions.st_makepoint(s.lng, s.lat), 4326)::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(e.lng, e.lat), 4326)::extensions.geography
           ) / greatest(extract(epoch from (s.recorded_at - e.recorded_at)), 1) as mps
    from sharing s
    cross join lateral (
      select l.lat, l.lng, l.recorded_at
      from public.locations l
      where l.event_id = p_event and l.user_id = s.user_id and l.source <> 'stop'
        and l.recorded_at between s.recorded_at - interval '90 seconds' and s.recorded_at - interval '30 seconds'
      order by l.recorded_at desc
      limit 1
    ) e
  )
  insert into public.group_positions (session_id, group_id, event_id, lat, lng, accuracy, speed_mps, last_seen, ics_sharing, updated_at)
  values (p_session, p_group, p_event,
          v_fix.lat, v_fix.lng, v_fix.accuracy, (select avg(mps) from speeds),
          v_fix.last_seen, coalesce(v_fix.ics, 0), now())
  on conflict (session_id, group_id) do update
    set lat = excluded.lat, lng = excluded.lng, accuracy = excluded.accuracy, speed_mps = excluded.speed_mps,
        last_seen = excluded.last_seen, ics_sharing = excluded.ics_sharing, updated_at = now();
end;
$$;

-- ---------- grants (R4) ----------
revoke execute on function public.plan_ops(uuid, timestamptz) from public, anon;
grant execute on function public.plan_ops(uuid, timestamptz) to authenticated;
-- Internal: the two security-definer readers above are the only callers, and neither of them is a door for it.
revoke execute on function public.group_position_at(uuid, uuid, timestamptz) from public, anon, authenticated;
-- 021's grants, named again so a re-create in a later file does not quietly open either function.
revoke execute on function public.refresh_group_position(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
