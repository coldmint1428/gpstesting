-- 060_plan_only_engine.sql
--
-- Step 24 of the planning plan: retire the last callers of the run-sheet engine.
--
-- WHAT WAS STILL CALLING IT. Step 21 replaced the two run-sheet cron jobs, but four doors were still open. The two
-- functions that start a session (`start_event`, `schedule_event_start`) still took a run-sheet id; `session_engine`
-- still arbitrated between the two engines; the simulator still drove its virtual groups with `movements` and made
-- those movements with `sim_plan_movements`; and three cron jobs still ticked the show / movement / demo functions
-- every 2-5 s. This file closes them. Deleting what they called is step 25.
--
-- WHY THE START FUNCTIONS LOSE THE PARAMETER, RATHER THAN GAINING A GUARD. A boolean or a check inside the body would
-- leave the door in the catalogue: `start_event(event, sheet)` would still exist, still mean "run a run sheet", and a
-- client written against the old signature would keep working. Dropping the parameter (DROP + create + re-grant,
-- R2/R4) makes the old call a 404 from PostgREST, which is what a caller asking for a retired engine deserves. The
-- column `event_sessions.run_sheet_id` still exists -- step 25 drops it -- so every new session writes null there, and
-- the update branch clears a value a scheduled session may have carried.
--
-- THE SIMULATOR NOW READS THE STRIP. `sim_follow_plan` used to give a virtual group a leg to the middle of the zone of
-- its one active movement, timed off that movement's leave-by. A plan session has no movements, so the function now
-- walks each virtual group to its group's NEXT on-site moment -- the first frame ahead of the clock at which the plan
-- states a position for it -- and times the walk so the group leaves exactly late enough to arrive a minute early.
-- One leg per moment, and a retarget when that moment has passed. The behaviours keep their meanings: `late_2min`
-- adds two minutes to the departure, `stops_halfway` stops at half the leg and STAYS stopped (that is the behaviour;
-- retargeting it to the next moment would quietly turn "never arrives" into "arrives late"), `loses_signal` goes
-- silent for 2.5 minutes from 40 % of the walk, and `wrong_zone` is not touched at all -- it walks into a No-Go zone,
-- which is the thing it exists to prove. A group the plan never places, or a session with no plan, is left alone.
--
-- `sim_plan_movements` HAS NO STRIP COUNTERPART, so it is gone. Its whole job was to translate a Draft run sheet into
-- movements for the virtual groups. On the strip the plan already says where each group stands and when, so there is
-- nothing to generate -- and the panel's "Plan their movements" card goes with it.
--
-- `sim_start` NOW STARTS THE EVENT ON THE PUBLISHED PLAN. It used to call `start_event(event)`, which made a
-- tracking-only session; the virtual groups then followed movements, of which a plan session has none. A rehearsal of
-- nothing is not a rehearsal, so it refuses without a live plan and hands the live plan to `start_event`.
--
-- THE CRON INVENTORY, JOB BY JOB. Ten jobs existed. Three belonged to the engine being retired and are unscheduled in
-- THIS file before their functions are dropped (a 2 s job against a dropped function fills the run log with errors):
-- `gps-show-tick` -> `show_tick()`, `gps-move-tick` -> `move_tick()`, and `zz-walk` -> `zz_walk_tick()`. The last was
-- the unexplained job: a hand-made 5 s walk for ONE hard-coded event, group and person, driven by a hand-set
-- `zz_walk.t0` instead of any session clock. It was a demo that outlived its event and is replaced by the simulator
-- above, so its function and its one-row table go with it. The seven that remain are asserted one by one -- name,
-- schedule, command and last run -- in `dev/checks/step24-retire.sql`: gps-auto-close-sessions,
-- gps-cleanup-expired-locations, gps-end-scheduled-sessions, gps-plan-eta, gps-plan-push, gps-push-reminders and
-- gps-sim-tick. None of them names a retired function.
--
-- WHAT IS DELIBERATELY LEFT. `movements`, `movement_status`, `movement_routes`, `run_sheets`, `cues`, `show_state`,
-- `show_log`, `run_sheet_switches`, `switch_live_run_sheet`, `push_collect_moves`, `move_step`, `show_step`,
-- `rs_runnable`, `session_run_sheets` and the Run sheet tab are step 25's inventory. Nothing in this file's world can
-- call them any more -- a run-sheet session can no longer be created -- but dropping them is a separate, larger
-- migration whose job is to prove that nothing references what it drops.
--
-- R1 (extensions. qualified), R2 (a changed signature is DROPped and recreated), R4 (revoked from public and anon,
-- granted to authenticated) apply below. `notify pgrst, 'reload schema'` is at the end: PostgREST caches signatures,
-- and without it the new `start_event(event, plan)` answers 404 until the cache expires.

-- ============================================================
-- 1. The three doors: a session runs a plan, or nothing
-- ============================================================
-- Dropped before the replacements, because a changed signature cannot be `create or replace`d (R2). The old bodies
-- are not copied anywhere: session_engine keeps its document but loses the run-sheet half of it.
drop function public.start_event(uuid, uuid, uuid);
drop function public.schedule_event_start(uuid, timestamptz, uuid, uuid);
drop function public.session_engine(uuid, uuid, uuid);

-- What may run, and when its clock starts. No plan is a tracking-only session: no clock, no engine, which is still a
-- real thing to start. The "never both" rule of 039 has nothing left to arbitrate.
create function public.session_engine(p_event uuid, p_plan uuid)
returns timestamptz
language plpgsql
stable security definer
set search_path = ''
as $body$
declare
  v_plan public.plans;
begin
  if p_plan is null then
    return null;
  end if;
  select * into v_plan from public.plans where id = p_plan and event_id = p_event;
  if not found then
    raise exception 'That plan is not in this event.' using errcode = '42501';
  end if;
  if v_plan.status <> 'live' then
    raise exception '"%" is not published. Publish it before starting the event on it.', v_plan.name
      using errcode = '22023';
  end if;
  return public.plan_t0(p_plan);
end;
$body$;

create function public.start_event(p_event_id uuid, p_plan uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $body$
declare
  open_session public.event_sessions;
  new_id uuid;
  v_t0 timestamptz;
  v_rev integer;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can start the event' using errcode = '42501';
  end if;
  v_t0 := public.session_engine(p_event_id, p_plan);
  select rev into v_rev from public.plans where id = p_plan;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live';
    end if;
    -- run_sheet_id is cleared, not left alone: a scheduled session used to carry the sheet it was going to run, and
    -- after this file there is no such thing. (The column itself is step 25's.)
    update public.event_sessions
       set starts_at = now(), started_by = auth.uid(),
           run_sheet_id = null, plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0)
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, plan_id, t0_at, plan_rev)
  values (p_event_id, now(), auth.uid(), p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

create function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz, p_plan uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $body$
declare
  open_session public.event_sessions;
  new_id uuid;
  v_t0 timestamptz;
  v_rev integer;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can schedule the event' using errcode = '42501';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Pick a start time in the future';
  end if;
  if p_starts_at > now() + interval '1 year' then
    raise exception 'Pick a start time within the next year';
  end if;
  v_t0 := public.session_engine(p_event_id, p_plan);
  select rev into v_rev from public.plans where id = p_plan;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions
       set starts_at = p_starts_at, started_by = auth.uid(),
           run_sheet_id = null, plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0),
           scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, plan_id, t0_at, plan_rev)
  values (p_event_id, p_starts_at, auth.uid(), p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

comment on function public.start_event(uuid, uuid) is
  'Starts the event now, on a published plan or on nothing (step 24). The run-sheet parameter of 039 is gone.';
comment on function public.schedule_event_start(uuid, timestamptz, uuid) is
  'Schedules the start on a published plan, or on nothing (step 24). The run-sheet parameter of 039 is gone.';

-- The two the client calls; the engine is internal (the old ones were revoked from authenticated too).
revoke all on function public.start_event(uuid, uuid) from public, anon;
grant execute on function public.start_event(uuid, uuid) to authenticated, service_role;

revoke all on function public.schedule_event_start(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.schedule_event_start(uuid, timestamptz, uuid) to authenticated, service_role;

revoke all on function public.session_engine(uuid, uuid) from public, anon, authenticated;
grant execute on function public.session_engine(uuid, uuid) to service_role;

-- ============================================================
-- 2. The simulator walks the strip
-- ============================================================
create or replace function public.sim_follow_plan(p_session uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_plan uuid;
  v_t0 timestamptz;
  v_elapsed double precision;
  v_moment record;
  g record;
  sg public.sim_groups;
  v_lat double precision;
  v_lng double precision;
  v_path double precision;
  v_travel double precision;
  v_depart double precision;
begin
  select es.event_id, es.plan_id, es.t0_at into v_event, v_plan, v_t0
    from public.event_sessions es
   where es.id = p_session;
  -- A tracking-only session has no strip, and a run-sheet session cannot exist any more: leave the groups alone.
  if v_plan is null or v_t0 is null then
    return;
  end if;
  v_elapsed := extract(epoch from (p_now - v_t0));

  for g in
    select x.id, x.group_id
      from public.sim_groups x
     where x.event_id = v_event
     order by x.id
  loop
    select * into sg from public.sim_groups where id = g.id;

    -- wrong_zone walks into a No-Go zone and stays there. The plan does not call it and must not redirect it.
    if sg.script = 'wrong_zone' then
      continue;
    end if;

    -- A group that has already stopped halfway stays where it stopped. Retargeting it to the next moment would turn
    -- "never arrives" into "arrives late", which is a different behaviour.
    if sg.script = 'stops_halfway' and sg.stop_at_m is not null and sg.travelled_m >= sg.stop_at_m - 0.5 then
      continue;
    end if;

    -- The group's next statement in the strip. A frame that does not state this group carries the last statement
    -- forward -- so the next ROW is the next moment, and a group already standing there gets no new leg below.
    select pos.lat, pos.lng, f.t_s
      into v_moment
      from public.plan_positions pos
      join public.plan_frames f on f.id = pos.frame_id
     where f.plan_id = v_plan
       and pos.group_id = g.group_id
       and pos.state = 'on_site'   -- an off-site statement is not somewhere to walk
       and f.t_s > v_elapsed       -- what is ahead of the clock, not what is behind it
     order by f.t_s
     limit 1;
    if not found then
      continue; -- nothing left to walk to: the group stays where it is
    end if;

    -- Where it stands now: along the leg it is on.
    v_lat := coalesce(sg.start_lat + (sg.end_lat - sg.start_lat) * least(sg.travelled_m / nullif(sg.path_m, 0), 1), sg.start_lat);
    v_lng := coalesce(sg.start_lng + (sg.end_lng - sg.start_lng) * least(sg.travelled_m / nullif(sg.path_m, 0), 1), sg.start_lng);

    -- A new leg only when the destination is a different statement. Comparing the point rather than a frame id keeps
    -- the table free of plan bookkeeping: the plan has the id, and this only needs "am I walking where I should be".
    if abs(sg.end_lat - v_moment.lat) > 1e-9 or abs(sg.end_lng - v_moment.lng) > 1e-9 then
      v_path := greatest(extensions.st_distance(
        extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography,
        extensions.st_setsrid(extensions.st_makepoint(v_moment.lng, v_moment.lat), 4326)::extensions.geography), 0.1);
      update public.sim_groups
         set start_lat = v_lat, start_lng = v_lng,
             end_lat = v_moment.lat, end_lng = v_moment.lng,
             path_m = v_path, travelled_m = 0,
             stop_at_m = case when script = 'stops_halfway' then v_path * 0.5 end,
             silent_from_s = null, silent_to_s = null,
             depart_after_s = active_s
       where id = g.id
       returning * into sg;
    end if;

    -- Leave late enough to arrive a minute early. While the group waits this number does not move (both terms grow
    -- together), so it is one departure and not a sliding one; once walking has begun it is left alone, which keeps
    -- a tick from shifting the silent window under the group.
    if sg.travelled_m = 0 then
      v_travel := sg.path_m / greatest(sg.pace_mps, 0.1);
      v_depart := sg.active_s + greatest(0, (v_moment.t_s - v_elapsed) - v_travel - 60)
                  + case when sg.script = 'late_2min' then 120 else 0 end;
      if sg.depart_after_s is null or abs(sg.depart_after_s - v_depart) > 2 then
        update public.sim_groups
           set depart_after_s = v_depart,
               silent_from_s = case when script = 'loses_signal'
                                    then v_depart + (path_m * 0.4) / greatest(pace_mps, 0.1) end,
               silent_to_s = case when script = 'loses_signal'
                                  then v_depart + (path_m * 0.4) / greatest(pace_mps, 0.1) + 150 end
         where id = g.id;
      end if;
    end if;
  end loop;
end;
$body$;

comment on function public.sim_follow_plan(uuid, timestamptz) is
  'Gives each virtual group of a simulation a leg to its next on-site plan moment, timed to arrive a minute early '
  '(step 24). Replaces the movement-driven leg of 027.';

-- Starts the event on the published plan and runs the simulation.
create or replace function public.sim_start(p_event uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_plan uuid;
begin
  perform public.sim_check(p_event);
  if not exists (select 1 from public.sim_groups g where g.event_id = p_event) then
    raise exception 'Set up some virtual groups first';
  end if;
  -- The groups follow the plan now, so a rehearsal needs something to rehearse. Picking the live plan here is the
  -- whole of "start the simulation": it is the same session the Start button would make.
  select p.id into v_plan
    from public.plans p
   where p.event_id = p_event and p.status = 'live'
   order by p.updated_at desc
   limit 1;
  if v_plan is null then
    raise exception 'Publish a plan first: the virtual groups walk to its moments.' using errcode = '22023';
  end if;
  -- The simulation only moves while the event is live: start it if it is not.
  if public.live_session_id(p_event) is null then
    perform public.start_event(p_event, v_plan);
  end if;
  update public.sim_runs
  set status = 'running', started_at = coalesce(started_at, now()), last_tick_at = now()
  where event_id = p_event;
end;
$body$;

-- The tick now hands each running simulation to sim_follow_plan before it moves anybody: the walk has to be aimed at
-- the strip before the step along it is taken. Everything else is 022's body.
create or replace function public.sim_tick()
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_run record;
  v_session uuid;
  v_dt double precision;
  v_inserted int;
  v_total int := 0;
begin
  for v_run in select r.* from public.sim_runs r where r.status = 'running' loop
    v_session := public.live_session_id(v_run.event_id);
    if v_session is null then
      update public.sim_runs set status = 'paused' where event_id = v_run.event_id;
      continue;
    end if;

    perform public.sim_follow_plan(v_session, now());

    v_dt := least(greatest(extract(epoch from (now() - coalesce(v_run.last_tick_at, now()))), 0), 30);

    update public.sim_groups g
    set active_s = g.active_s + v_dt,
        travelled_m = least(
          g.travelled_m + case when g.active_s + v_dt > g.depart_after_s then g.pace_mps * v_dt else 0 end,
          coalesce(g.stop_at_m, g.path_m))
    where g.event_id = v_run.event_id;

    insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
    select g.event_id, g.group_id, s.user_id,
           p.lat + n.r * cos(n.b) / 111320.0,
           p.lng + n.r * sin(n.b) / (111320.0 * cos(radians(p.lat))),
           round((5 + random() * 10)::numeric, 1)::real,
           'gps', now()
    from public.sim_groups g
    join public.sim_ics s on s.group_id = g.group_id
    cross join lateral (
      select g.start_lat + (g.end_lat - g.start_lat) * least(g.travelled_m / nullif(g.path_m, 0), 1) as lat,
             g.start_lng + (g.end_lng - g.start_lng) * least(g.travelled_m / nullif(g.path_m, 0), 1) as lng
    ) p
    cross join lateral (
      select 5 + random() * 10 as r, random() * 2 * pi() as b
    ) n
    where g.event_id = v_run.event_id
      and not (g.silent_from_s is not null and g.active_s between g.silent_from_s and g.silent_to_s);
    get diagnostics v_inserted = row_count;

    update public.sim_runs
    set last_tick_at = now(), ticks = ticks + 1, readings = readings + v_inserted
    where event_id = v_run.event_id;
    v_total := v_total + v_inserted;
  end loop;
  return v_total;
end;
$body$;

-- Its job was to write a run sheet into movements. The strip already says where each group stands and when, so there
-- is nothing left to generate.
drop function public.sim_plan_movements(uuid, uuid, uuid);

-- ============================================================
-- 3. The three tick jobs, unscheduled before their functions go
-- ============================================================
-- The order inside this block is the point: a cron job left pointing at a function this file drops does not fail once,
-- it fails every 2-5 seconds and buries every other error in the run log. `cron.schedule`/`unschedule` write inside
-- this transaction, so the swap is atomic with the drops below.
do $block$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job
     where jobname in ('gps-show-tick', 'gps-move-tick', 'zz-walk');
  end if;
end $block$;

drop function public.show_tick();
drop function public.move_tick();
-- These two never came from a migration in this repository: `zz-walk` was made by hand on one project. A project that
-- never had it must still apply this file, so both are conditional -- the job above is unscheduled either way.
drop function if exists public.zz_walk_tick();
drop table if exists public.zz_walk;

-- ============================================================
-- 4. The catalogue knows about the new signatures
-- ============================================================
-- PostgREST caches what it can call. Without this the app's first `start_event` after the migration answers 404
-- ("function not found") and reads exactly like a broken migration (step 23's finding, revisited).
notify pgrst, 'reload schema';
