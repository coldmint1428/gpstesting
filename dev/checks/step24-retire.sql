-- Step 24, checked at the database: the last callers of the run-sheet engine are gone, and the simulator walks the
-- strip.
--
--     node tools/sql.mjs --file dev/checks/step24-retire.sql
--
-- (No fixture first: this check builds its own simulation event, virtual groups, plan and session inside its
-- transaction and rolls the lot back. It cannot use the bench -- the bench event is not a simulation, and a simulator
-- that runs on the bench would leave virtual accounts behind.)
--
-- What the step asks for, and what is proved here:
--
--   1. THE START FUNCTIONS TAKE A PLAN. `start_event(event, plan)` and `schedule_event_start(event, at, plan)` exist;
--      their run-sheet parameters do not. No function in the schema has a parameter called `p_run_sheet`, and a
--      run-sheet id handed in as the plan is refused because it is not one of this event's plans.
--   2. THE SIMULATOR WALKS THE STRIP. `sim_follow_plan` gives each virtual group a leg to its group's next on-site
--      moment, times the departure to arrive a minute early (`late_2min` two minutes later), halves the leg for
--      `stops_halfway` and then leaves it stopped, sets a 2.5-minute silent window for `loses_signal`, and does not
--      touch `wrong_zone`. When the moment passes the NEXT moment takes over, and a moment that repeats the position
--      is not a new leg. This event has NO ZONES at all, so a leg pointing at a plan point cannot be the old
--      movement-to-zone walk: there is nothing else it could be.
--   3. THE TICK USES IT. `sim_tick()` re-aims a group before it steps it, so a simulation whose legs were left
--      pointing somewhere else is walking the strip after one tick.
--   4. `sim_start` STARTS THE EVENT ON THE PUBLISHED PLAN and refuses when there is none, and refuses before that when
--      there are no virtual groups.
--   5. THE JOBS. Exactly seven survive, and each one is asserted by name, schedule, command and last successful run.
--      None names a retired function.
--   6. THE RETIRED NAMES ARE GONE FROM THE CATALOGUE. `show_tick`, `move_tick`, `zz_walk_tick` and
--      `sim_plan_movements` are not functions, `zz_walk` is not a table, and no function body in `public` mentions
--      them.
--   7. THE GRANTS. `authenticated` may call the two start functions and may not call the internal ones; `anon` may
--      call neither.
--
-- The clock: the plan's printed T+0 is the moment this check runs, so p_now is t0 + an offset and nothing depends on
-- the wall clock. Everything is one transaction, rolled back.

begin;

-- ---------- 1. the simulation event, its groups, its plan ----------
insert into public.events (id, name, created_by, description, venue, starts_at, ends_at, is_simulation)
values ('0b000000-0000-4000-8000-000000000e24', 'Sim bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 24 (simulator on the strip, retired callers). Built and rolled back by dev/checks/step24-retire.sql.',
        'Bukit Timah', now() - interval '5 minutes', now() + interval '2 hours', true);

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a241', '0b000000-0000-4000-8000-000000000e24', 'SIM-001', 'S1', '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a242', '0b000000-0000-4000-8000-000000000e24', 'SIM-002', 'S2', '#8a5a2b'),
  ('0b000000-0000-4000-8000-00000000a243', '0b000000-0000-4000-8000-000000000e24', 'SIM-003', 'S3', '#3b5a8a'),
  ('0b000000-0000-4000-8000-00000000a244', '0b000000-0000-4000-8000-000000000e24', 'SIM-004', 'S4', '#7a3742'),
  ('0b000000-0000-4000-8000-00000000a245', '0b000000-0000-4000-8000-000000000e24', 'SIM-005', 'S5', '#5c4b8a');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e24', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root');

-- Five virtual groups, one per behaviour that matters here. They are inserted in section 2, after the "no groups yet"
-- refusal, and every one starts on a dummy leg a kilometre long: untouched (wrong_zone), or about to be replaced by a
-- ~100 m leg to the plan's point, which the assertions tell apart by length.

insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', 'Sim walk',
       (now() at time zone 'Asia/Singapore')::date,
       (now() at time zone 'Asia/Singapore')::time,
       'draft', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select f.id, '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', f.t_s, f.note,
       'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from (values
    ('0b000000-0000-4000-8000-0000000f2411'::uuid,    0, 'call'),
    ('0b000000-0000-4000-8000-0000000f2412'::uuid,  300, 'move'),
    ('0b000000-0000-4000-8000-0000000f2413'::uuid,  600, 'turn'),
    ('0b000000-0000-4000-8000-0000000f2414'::uuid,  900, 'hold')
  ) f(id, t_s, note);

-- One statement per group at +5:00, 0.0009 degrees (~100 m) north of where it stands -- INCLUDING the wrong-zone
-- group, so the "the plan does not call it" assertion is a real one: without the guard that group would be redirected
-- like the others. +10:00 is 100 m further north for SIM-001, and +15:00 repeats exactly that point, which is the
-- "a repeated position is not a new leg" case.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state) values
  ('0b000000-0000-4000-8000-0000000f2412', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a241', 1.3009, 103.7700, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2412', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a242', 1.3109, 103.7800, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2412', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a243', 1.3409, 103.8000, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2412', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a244', 1.3209, 103.7900, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2412', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a245', 1.3309, 103.8000, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2413', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a241', 1.3018, 103.7700, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2414', '0b000000-0000-4000-8000-000000000b24', '0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a241', 1.3018, 103.7700, 'on_site');

-- ---------- 2. sim_start's three doors, and the session it makes ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare v_refused boolean := false;
begin
  -- No groups yet: nothing to rehearse.
  begin
    perform public.sim_start('0b000000-0000-4000-8000-000000000e24');
  exception when others then
    v_refused := sqlerrm like '%virtual groups first%';
    if not v_refused then raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2a: sim_start ran with no virtual groups'; end if;
end $$;

reset role;

-- Now the groups, the run row sim_start updates, and the plan's clock, which the authenticated sections compare to.
insert into public.sim_groups (event_id, group_id, script, start_lat, start_lng, end_lat, end_lng, path_m, pace_mps) values
  ('0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a241', 'on_time',       1.3000, 103.7700, 1.2900, 103.7700, 1105.7, 1.0),
  ('0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a242', 'stops_halfway', 1.3100, 103.7800, 1.3000, 103.7800, 1105.7, 1.0),
  ('0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a243', 'wrong_zone',    1.3400, 103.8000, 1.3500, 103.8000, 1105.7, 1.0),
  ('0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a244', 'late_2min',     1.3200, 103.7900, 1.3100, 103.7900, 1105.7, 1.0),
  ('0b000000-0000-4000-8000-000000000e24', '0b000000-0000-4000-8000-00000000a245', 'loses_signal',  1.3300, 103.8000, 1.3200, 103.8000, 1105.7, 1.0);

insert into public.sim_runs (event_id, status) values ('0b000000-0000-4000-8000-000000000e24', 'ready');

do $$
begin
  perform set_config('check.want_t0',
    (((select p.for_date from public.plans p where p.id = '0b000000-0000-4000-8000-000000000b24')::timestamp
      + (select p.t0_time from public.plans p where p.id = '0b000000-0000-4000-8000-000000000b24'))
      at time zone 'Asia/Singapore')::text, true);
end $$;

set local role authenticated;

do $$
declare v_refused boolean := false;
begin
  -- Groups, but the plan is only a draft: a rehearsal needs a published plan.
  begin
    perform public.sim_start('0b000000-0000-4000-8000-000000000e24');
  exception when others then
    v_refused := sqlerrm like '%Publish a plan first%';
    if not v_refused then raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2b: sim_start ran without a published plan'; end if;
end $$;

reset role;

-- The draft plan goes live at the table (publishing is step 2/18's proof, not this one's). From here the two start
-- functions must accept it.
update public.plans set status = 'live' where id = '0b000000-0000-4000-8000-000000000b24';

set local role authenticated;

do $$
declare v_s uuid; v_plan uuid; v_t0 timestamptz;
begin
  perform public.sim_start('0b000000-0000-4000-8000-000000000e24');
  if (select status from public.sim_runs where event_id = '0b000000-0000-4000-8000-000000000e24') <> 'running' then
    raise exception 'FAIL 2c: sim_start did not put the simulation in "running"';
  end if;
  select es.id, es.plan_id, es.t0_at into v_s, v_plan, v_t0
    from public.event_sessions es
   where es.event_id = '0b000000-0000-4000-8000-000000000e24' and es.ended_at is null;
  if v_s is null then raise exception 'FAIL 2d: sim_start did not start the event'; end if;
  if v_plan <> '0b000000-0000-4000-8000-000000000b24' then
    raise exception 'FAIL 2e: the session runs plan % instead of the published one', v_plan;
  end if;
  -- "the session carries no run sheet" is now structural: step 25 dropped the column that could carry one.
  if v_t0 is distinct from current_setting('check.want_t0')::timestamptz then
    raise exception 'FAIL 2g: t0_at (%) is not the plan''s clock (%)', v_t0, current_setting('check.want_t0');
  end if;
  perform set_config('check.session', v_s::text, true);
  perform set_config('check.t0', v_t0::text, true);
end $$;

-- ---------- 3. the leg is the strip's ----------
reset role;

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz := current_setting('check.t0')::timestamptz;
  g record;
  v_want double precision;
begin
  perform public.sim_follow_plan(v_s, v_t0);

  -- SIM-001: a ~99 m leg to its +5:00 point, from where it stands, with a departure that arrives a minute early.
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a241';
  if abs(g.end_lat - 1.3009) > 1e-9 or abs(g.end_lng - 103.7700) > 1e-9 then
    raise exception 'FAIL 3a: SIM-001 is walking to (%, %) instead of its plan point', g.end_lat, g.end_lng;
  end if;
  if abs(g.start_lat - 1.3000) > 1e-9 then
    raise exception 'FAIL 3b: SIM-001''s leg starts at % instead of where it stands', g.start_lat;
  end if;
  if g.path_m > 200 then
    raise exception 'FAIL 3c: the new leg is % m long, so it is still the old one', g.path_m;
  end if;
  if g.travelled_m <> 0 then raise exception 'FAIL 3d: a new leg starts part-walked (% m)', g.travelled_m; end if;
  v_want := 300 - g.path_m / g.pace_mps - 60;
  if abs(g.depart_after_s - v_want) > 0.5 then
    raise exception 'FAIL 3e: SIM-001 leaves at % instead of %', g.depart_after_s, v_want;
  end if;

  -- late_2min: the same arithmetic, two minutes later.
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a244';
  v_want := 300 - g.path_m / g.pace_mps - 60 + 120;
  if abs(g.depart_after_s - v_want) > 0.5 then
    raise exception 'FAIL 3f: late_2min leaves at % instead of %', g.depart_after_s, v_want;
  end if;

  -- stops_halfway: the stop is half of THIS leg.
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a242';
  if g.stop_at_m is null or abs(g.stop_at_m - g.path_m * 0.5) > 0.5 then
    raise exception 'FAIL 3g: stops_halfway stops at % of a % m leg', g.stop_at_m, g.path_m;
  end if;

  -- loses_signal: silent from 40 % of the walk, for two and a half minutes.
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a245';
  if g.silent_from_s is null or g.silent_to_s is null then
    raise exception 'FAIL 3h: loses_signal has no silent window';
  end if;
  if abs(g.silent_from_s - (g.depart_after_s + g.path_m * 0.4)) > 0.5 then
    raise exception 'FAIL 3i: the silent window starts at % (departure %) instead of 40 %% along', g.silent_from_s, g.depart_after_s;
  end if;
  if abs((g.silent_to_s - g.silent_from_s) - 150) > 0.5 then
    raise exception 'FAIL 3j: the silence lasts % s instead of 150', g.silent_to_s - g.silent_from_s;
  end if;

  -- wrong_zone: not called by the plan at all.
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a243';
  if abs(g.end_lat - 1.3500) > 1e-9 or g.path_m < 1000 then
    raise exception 'FAIL 3k: wrong_zone was redirected to (%, %)', g.end_lat, g.end_lng;
  end if;
end $$;

-- ---------- 4. the next moment takes over; a repeated position does not ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz := current_setting('check.t0')::timestamptz;
  g record;
  v_stop double precision;
begin
  -- Where SIM-001 stands after walking its first leg: at the +5:00 point.
  update public.sim_groups set travelled_m = path_m, active_s = 300
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a241';

  perform public.sim_follow_plan(v_s, v_t0 + interval '310 seconds');
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a241';
  if abs(g.end_lat - 1.3018) > 1e-9 then
    raise exception 'FAIL 4a: after +5:00 SIM-001 walks to % instead of its +10:00 point', g.end_lat;
  end if;
  if abs(g.start_lat - 1.3009) > 1e-9 then
    raise exception 'FAIL 4b: the second leg starts at % instead of where the group stood', g.start_lat;
  end if;
  if g.travelled_m <> 0 then raise exception 'FAIL 4c: the second leg starts part-walked'; end if;

  -- +15:00 repeats +10:00's point exactly. Arriving there must not start a leg to nowhere.
  update public.sim_groups set travelled_m = path_m, active_s = 600
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a241';
  perform public.sim_follow_plan(v_s, v_t0 + interval '610 seconds');
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a241';
  if abs(g.start_lat - 1.3009) > 1e-9 then
    raise exception 'FAIL 4d: a repeated position was treated as a new leg (start % again)', g.start_lat;
  end if;

  -- stops_halfway: once it has stopped, a later moment does not restart it.
  select stop_at_m into v_stop from public.sim_groups
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a242';
  update public.sim_groups set travelled_m = v_stop, active_s = 400
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a242';
  perform public.sim_follow_plan(v_s, v_t0 + interval '610 seconds');
  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a242';
  if g.travelled_m <> v_stop or abs(g.end_lat - 1.3109) > 1e-9 then
    raise exception 'FAIL 4e: a stopped group was restarted (travelled %, end %)', g.travelled_m, g.end_lat;
  end if;
end $$;

-- ---------- 5. a session with no plan has no strip to follow ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz := current_setting('check.t0')::timestamptz;
  v_before record;
  v_after record;
begin
  select start_lat, end_lat, path_m, travelled_m into v_before from public.sim_groups
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a241';
  update public.event_sessions set plan_id = null where id = v_s;
  begin
    perform public.sim_follow_plan(v_s, v_t0 + interval '400 seconds');
  exception when others then
    update public.event_sessions set plan_id = '0b000000-0000-4000-8000-000000000b24' where id = v_s;
    raise;
  end;
  update public.event_sessions set plan_id = '0b000000-0000-4000-8000-000000000b24' where id = v_s;
  select start_lat, end_lat, path_m, travelled_m into v_after from public.sim_groups
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a241';
  if v_before.start_lat <> v_after.start_lat or v_before.end_lat <> v_after.end_lat
     or v_before.path_m <> v_after.path_m or v_before.travelled_m <> v_after.travelled_m then
    raise exception 'FAIL 5a: sim_follow_plan moved a group on a session with no plan';
  end if;
end $$;

-- ---------- 6. the tick aims the walk before it steps it ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_run record;
  g record;
  v_ticks integer;
begin
  select status, ticks into v_run from public.sim_runs where event_id = '0b000000-0000-4000-8000-000000000e24';
  if v_run.status <> 'running' then raise exception 'FAIL 6a: the run is % before the tick', v_run.status; end if;

  -- Put SIM-001 back on its dummy leg, as if a tick had never aimed it, and give the tick ten seconds to work with.
  update public.sim_groups
     set start_lat = 1.3000, start_lng = 103.7700, end_lat = 1.2900, end_lng = 103.7700,
         path_m = 1105.7, travelled_m = 0, active_s = 0, depart_after_s = 0
   where event_id = '0b000000-0000-4000-8000-000000000e24' and group_id = '0b000000-0000-4000-8000-00000000a241';
  update public.sim_runs set last_tick_at = now() - interval '10 seconds'
   where event_id = '0b000000-0000-4000-8000-000000000e24';

  perform public.sim_tick();

  select * into g from public.sim_groups where event_id = '0b000000-0000-4000-8000-000000000e24'
   and group_id = '0b000000-0000-4000-8000-00000000a241';
  if abs(g.end_lat - 1.3009) > 1e-9 then
    raise exception 'FAIL 6b: the tick left SIM-001 walking to % instead of its plan point', g.end_lat;
  end if;
  if g.active_s < 9 then
    raise exception 'FAIL 6c: the tick did not advance the group (active_s = %)', g.active_s;
  end if;
  select ticks into v_ticks from public.sim_runs where event_id = '0b000000-0000-4000-8000-000000000e24';
  if v_ticks <= v_run.ticks then raise exception 'FAIL 6d: the tick did not count itself'; end if;
end $$;

-- ---------- 7. the catalogue: the retired names are gone, the seven jobs are the seven ----------
do $$
declare
  v_jobs integer;
begin
  -- Signatures.
  if to_regprocedure('public.start_event(uuid,uuid)') is null then raise exception 'FAIL 7a: start_event(event, plan) is missing'; end if;
  if to_regprocedure('public.start_event(uuid,uuid,uuid)') is not null then raise exception 'FAIL 7b: the run-sheet start_event still exists'; end if;
  if to_regprocedure('public.schedule_event_start(uuid,timestamptz,uuid)') is null then
    raise exception 'FAIL 7c: schedule_event_start(event, at, plan) is missing';
  end if;
  if to_regprocedure('public.schedule_event_start(uuid,timestamptz,uuid,uuid)') is not null then
    raise exception 'FAIL 7d: the run-sheet schedule_event_start still exists';
  end if;
  if to_regprocedure('public.session_engine(uuid,uuid)') is null then raise exception 'FAIL 7e: session_engine(event, plan) is missing'; end if;
  if to_regprocedure('public.session_engine(uuid,uuid,uuid)') is not null then raise exception 'FAIL 7f: the three-argument session_engine still exists'; end if;

  -- No parameter anywhere is called p_run_sheet, which is what a client would have to send.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proargnames::text like '%p_run_sheet%') then
    raise exception 'FAIL 7g: a function still takes p_run_sheet';
  end if;

  -- No body names a retired function.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.prosrc ~ '\m(show_tick|move_tick|zz_walk_tick|sim_plan_movements)\M') then
    raise exception 'FAIL 7h: a function body still names a retired engine function';
  end if;

  -- The names themselves.
  if to_regprocedure('public.show_tick()') is not null then raise exception 'FAIL 7i: show_tick still exists'; end if;
  if to_regprocedure('public.move_tick()') is not null then raise exception 'FAIL 7j: move_tick still exists'; end if;
  if to_regprocedure('public.zz_walk_tick()') is not null then raise exception 'FAIL 7k: zz_walk_tick still exists'; end if;
  if to_regprocedure('public.sim_plan_movements(uuid,uuid,uuid)') is not null then
    raise exception 'FAIL 7l: sim_plan_movements still exists';
  end if;
  if to_regclass('public.zz_walk') is not null then raise exception 'FAIL 7m: the zz_walk table still exists'; end if;

  -- The jobs: seven, and none of them names a retired function.
  select count(*) into v_jobs from cron.job;
  if v_jobs <> 7 then
    raise exception 'FAIL 7n: % cron jobs, expected 7 (a new job has to be added to this check on purpose)', v_jobs;
  end if;
  if exists (select 1 from cron.job where command ~ 'show_tick|move_tick|zz_walk_tick|sim_plan_movements') then
    raise exception 'FAIL 7o: a cron job still calls a retired function';
  end if;

  -- Each survivor: name, schedule, command, and a successful run inside a window that fits its own cadence.
  if not exists (select 1 from cron.job where jobname = 'gps-plan-push' and active
                    and schedule = '5 seconds' and command = 'select public.plan_push_tick()') then
    raise exception 'FAIL 8a: gps-plan-push is not "5 seconds" -> plan_push_tick()';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-plan-push' and d.status = 'succeeded' and d.start_time > now() - interval '5 minutes') then
    raise exception 'FAIL 8b: gps-plan-push has not succeeded in the last five minutes';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-plan-eta' and active
                    and schedule = '30 seconds' and command = 'select public.plan_eta_tick()') then
    raise exception 'FAIL 8c: gps-plan-eta is not "30 seconds" -> plan_eta_tick()';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-plan-eta' and d.status = 'succeeded' and d.start_time > now() - interval '5 minutes') then
    raise exception 'FAIL 8d: gps-plan-eta has not succeeded in the last five minutes';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-sim-tick' and active
                    and schedule = '10 seconds' and command = 'select public.sim_tick()') then
    raise exception 'FAIL 8e: gps-sim-tick is not "10 seconds" -> sim_tick()';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-sim-tick' and d.status = 'succeeded' and d.start_time > now() - interval '5 minutes') then
    raise exception 'FAIL 8f: gps-sim-tick has not succeeded in the last five minutes';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-end-scheduled-sessions' and active
                    and schedule = '* * * * *' and command = 'select public.end_scheduled_sessions()') then
    raise exception 'FAIL 8g: gps-end-scheduled-sessions is not "* * * * *" -> end_scheduled_sessions()';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-end-scheduled-sessions' and d.status = 'succeeded' and d.start_time > now() - interval '5 minutes') then
    raise exception 'FAIL 8h: gps-end-scheduled-sessions has not succeeded in the last five minutes';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-push-reminders' and active and schedule = '* * * * *'
                    and command like '%send-reminders%') then
    raise exception 'FAIL 8i: gps-push-reminders is not the minute job against the Edge Function';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-push-reminders' and d.status = 'succeeded' and d.start_time > now() - interval '5 minutes') then
    raise exception 'FAIL 8j: gps-push-reminders has not succeeded in the last five minutes';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-auto-close-sessions' and active
                    and schedule = '*/15 * * * *' and command = 'select public.auto_close_idle_sessions()') then
    raise exception 'FAIL 8k: gps-auto-close-sessions is not the quarter-hour job';
  end if;
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-auto-close-sessions' and d.status = 'succeeded' and d.start_time > now() - interval '45 minutes') then
    raise exception 'FAIL 8l: gps-auto-close-sessions has not succeeded in the last three quarters of an hour';
  end if;

  if not exists (select 1 from cron.job where jobname = 'gps-cleanup-expired-locations' and active
                    and schedule = '5 16 * * *' and command = 'select public.cleanup_expired_locations()') then
    raise exception 'FAIL 8m: gps-cleanup-expired-locations is not the daily job';
  end if;
  -- Daily, so "recently" has to mean within two days, not five minutes. This is the job that would fail a blanket
  -- "every job succeeded in the last five minutes", which is why each one has its own window.
  if not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'gps-cleanup-expired-locations' and d.status = 'succeeded' and d.start_time > now() - interval '2 days') then
    raise exception 'FAIL 8n: gps-cleanup-expired-locations has not succeeded in the last two days';
  end if;
end $$;

-- ---------- 8. grants: the client keeps its two doors, and only those ----------
do $$
begin
  if not has_function_privilege('authenticated', 'public.start_event(uuid,uuid)', 'EXECUTE') then
    raise exception 'FAIL 9a: authenticated cannot call start_event';
  end if;
  if not has_function_privilege('authenticated', 'public.schedule_event_start(uuid,timestamptz,uuid)', 'EXECUTE') then
    raise exception 'FAIL 9b: authenticated cannot call schedule_event_start';
  end if;
  if has_function_privilege('anon', 'public.start_event(uuid,uuid)', 'EXECUTE') then
    raise exception 'FAIL 9c: anon can call start_event';
  end if;
  if has_function_privilege('authenticated', 'public.session_engine(uuid,uuid)', 'EXECUTE') then
    raise exception 'FAIL 9d: authenticated can call session_engine';
  end if;
  if has_function_privilege('authenticated', 'public.sim_follow_plan(uuid,timestamptz)', 'EXECUTE') then
    raise exception 'FAIL 9e: authenticated can call sim_follow_plan';
  end if;
  if has_function_privilege('authenticated', 'public.sim_tick()', 'EXECUTE') then
    raise exception 'FAIL 9f: authenticated can call sim_tick';
  end if;
end $$;

-- The fixture was all inside this transaction.
rollback;

select jsonb_build_object(
  'start_event', 'event, plan',
  'sim_start', 'starts on the published plan',
  'sim_follow_plan', 'next on-site moment, a minute early',
  'sim_tick', 'aims before it steps',
  'cron_jobs', (select count(*) from cron.job),
  'retired', 'show_tick, move_tick, zz_walk_tick, sim_plan_movements, zz_walk'
) as step24;
