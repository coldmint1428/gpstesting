-- supabase/tests/movements_test.sql -- merger Stage 7 (027_movements.sql), run against the real project.
--
-- One transaction that ends with an exception, so nothing is kept: the result is the error text. Readings are inserted
-- with their own times on a future day (newer than any real reading) (the Stage 2 trigger works out zone presence from them), the show clock is set step by step
-- (show.test_now) and both engines are run by hand at those moments. Around a button (which needs a live session) the
-- session's start is moved to just now and back. Accounts: claude_test (root) and testuser1
-- (planner) are the 2 ICs of Group A; komin is the only IC of "M2"; komin2 and testuser3 (made members) the 2 ICs of
-- "M3"; testuser2 is made marshal.
--
-- On 20 Nov 2026 (Singapore): C1 18:00:00 2:00 · C2 18:02:00 1:00 · C3 18:03:00 1:00 (Auto when ready) · C4 18:10:00 1:00.
--   MA  Group A -> FORMATION_1 by C2 start        MA2 Group A -> STAGE_LEFT by C3 start (they never go: C3 holds, missed)
--   MB  M2 -> FORMATION_1 by C2 start, pace 1.0   MB2 M2 -> STAGE_LEFT by 18:08:00 (fixed)
--   MC  M3 -> FORMATION_1 by C1 end, 2 ICs        MD  M3 -> STAGE_LEFT by C4 start (C4 is skipped)
do $test$
declare
  ev uuid := '4395abec-16b6-44a0-b4a1-5f7fd6e5df49';
  u_root uuid := 'cd87c144-9524-4558-9ec5-bc59694b6b0e';
  u_planner uuid := 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';
  u_marshal uuid := 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5';
  u_member uuid := '2906655b-33ad-4e9d-a608-f083e43e22d4';   -- testuser3
  u_k1 uuid := '038d32b0-c00d-4c2c-b418-2619f40330e4';       -- komin
  u_k2 uuid := '47a6bc75-d98d-40e2-a795-147092c99977';       -- komin2
  z1 uuid := '2d88456f-a7a6-4901-a794-307ef1476b7c';         -- FORMATION_1
  z2 uuid := '88453a3f-095f-43d9-b009-74357742a452';         -- STAGE_LEFT
  g_a uuid := '84c7ca4b-c68c-4e8c-830e-fdcafadb904e';        -- Group A
  c_lat double precision := 1.30641608120455;                -- FORMATION_1's middle
  c_lng double precision := 103.767534792423;
  g2 uuid; g3 uuid;
  sh uuid; sh2 uuid; sess uuid; c uuid[];
  ma uuid; ma2 uuid; mb uuid; mb2 uuid; mc uuid; md uuid;
  t0 timestamptz := '2026-11-20 17:55:00+08';
  ts timestamptz;
  k integer; n integer; t text; j jsonb; r record; x double precision; y double precision;
  d1 double precision; d2 double precision; rem2 double precision;
  t1 timestamptz; t2 timestamptz;
  exp_eta timestamptz; exp_leave timestamptz; entered timestamptz;
  passed integer := 0;
  failures text := '';
  err text;
begin
  execute $f$
    create function public.zz_as(p uuid) returns void language plpgsql as $b$
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    end $b$;
  $f$;
  -- both engines at a moment (as the database, like pg_cron)
  execute $f$
    create function public.zz_at(p_session uuid, p_at timestamptz) returns void language plpgsql as $b$
    begin
      execute 'reset role';
      perform set_config('show.test_now', p_at::text, true);
      perform public.show_step(p_session, p_at);
      perform public.move_step(p_session, p_at);
    end $b$;
  $f$;
  execute $f$
    create function public.zz_err(p_sql text) returns text language plpgsql as $b$
    begin
      execute p_sql;
      return 'no error';
    exception when others then
      return sqlerrm;
    end $b$;
  $f$;
  execute $f$
    create function public.zz_ms(p_session uuid, p_move uuid, p_group uuid) returns text language sql as $b$
      select ms.state || ' ' || ms.status || coalesce(' (next ' || ms.cand_status || ')', '')
      from public.movement_status ms where ms.session_id = p_session and ms.movement_id = p_move and ms.group_id = p_group;
    $b$;
  $f$;
  -- a reading n metres north (+) of FORMATION_1's middle, accuracy 5 m
  execute $f$
    create function public.zz_read(p_event uuid, p_group uuid, p_user uuid, p_north double precision, p_at timestamptz,
                                   p_lat double precision default 1.30641608120455, p_lng double precision default 103.767534792423)
    returns void language sql as $b$
      insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
      values (p_event, p_group, p_user, p_lat + p_north / 111320.0, p_lng, 5, 'gps', p_at);
    $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_err(text) to authenticated';

  -- fixtures
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant'),
    (ev, u_k1, 'participant'), (ev, u_k2, 'participant') on conflict do nothing;
  insert into public.groups (event_id, name, colour, sector) values (ev, 'M2 test', '#198754', 'Padang') returning id into g2;
  insert into public.groups (event_id, name, colour, sector) values (ev, 'M3 test', '#6f42c1', 'S3') returning id into g3;
  insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
    (ev, g2, u_k1, true, true), (ev, g3, u_k2, true, true), (ev, g3, u_member, true, false);
  update public.event_sessions set ended_at = now() where event_id = ev and ended_at is null;

  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'Movements engine test');
  c := array[
    public.save_cue(sh, '{"code":"C1","title":"One","start_time":"18:00:00","length_s":120}'),
    public.save_cue(sh, '{"code":"C2","title":"Two","start_time":"18:02:00","length_s":60}'),
    public.save_cue(sh, '{"code":"C3","title":"Three","start_time":"18:03:00","length_s":60,"start_mode":"auto_ready"}'),
    public.save_cue(sh, '{"code":"C4","title":"Four","start_time":"18:10:00","length_s":60}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  ma2 := public.save_movement(sh, jsonb_build_object('code', 'MA2', 'group_id', g_a, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[3]));
  mb := public.save_movement(sh, jsonb_build_object('code', 'MB', 'group_id', g2, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2],
                                                    'pace_mps', 1.0));
  mb2 := public.save_movement(sh, jsonb_build_object('code', 'MB2', 'group_id', g2, 'zone_id', z2, 'deadline_kind', 'fixed',
                                                     'fixed_time', '18:08:00', 'pace_mps', 1.0));
  mc := public.save_movement(sh, jsonb_build_object('code', 'MC', 'group_id', g3, 'zone_id', z1, 'deadline_kind', 'cue_end', 'cue_id', c[1],
                                                    'min_ics', 2));
  md := public.save_movement(sh, jsonb_build_object('code', 'MD', 'group_id', g3, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[4]));
  perform public.mark_run_sheet_ready(sh);
  perform public.zz_as(u_root);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;

  -- Readings, all inserted now in time order (the trigger works out presence as it would have live)
  -- komin (M2): stands 240 m north of the middle until 17:56:00, then walks south at 1 m/s and stays in the middle
  perform public.zz_read(ev, g2, u_k1, 240, '2026-11-20 17:54:50+08');
  perform public.zz_read(ev, g2, u_k1, 240, '2026-11-20 17:55:00+08');
  perform public.zz_read(ev, g2, u_k1, 240, '2026-11-20 17:55:30+08');
  -- claude_test (Group A): seen twice, 300 m north, then nothing
  perform public.zz_read(ev, g_a, u_root, 300, '2026-11-20 17:54:00+08');
  perform public.zz_read(ev, g_a, u_root, 300, '2026-11-20 17:55:00+08');
  for k in 0 .. 960 by 10 loop
    ts := '2026-11-20 17:56:00+08'::timestamptz + make_interval(secs => k);
    perform public.zz_read(ev, g2, u_k1, greatest(240 - k, 0), ts);
    -- testuser1 (Group A): inside FORMATION_1 from 17:57:30
    if ts >= '2026-11-20 17:57:30+08' then perform public.zz_read(ev, g_a, u_planner, 0, ts); end if;
    -- komin2 (M3): 150 m north from 18:00:00, inside from 18:02:20; testuser3 from 18:01:00, inside from 18:02:20
    if ts >= '2026-11-20 18:00:00+08' then
      perform public.zz_read(ev, g3, u_k2, case when ts >= '2026-11-20 18:02:20+08' then 5 else 150 end, ts);
    end if;
    if ts >= '2026-11-20 18:01:00+08' then
      perform public.zz_read(ev, g3, u_member, case when ts >= '2026-11-20 18:02:20+08' then -5 else 160 end, ts);
    end if;
  end loop;

  select extensions.st_distance(z.shape, extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat + 240 / 111320.0), 4326)::extensions.geography)
    into d1 from public.zones z where z.id = z1;
  select extensions.st_distance(z.shape, extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat), 4326)::extensions.geography)
    into d2 from public.zones z where z.id = z2;

  -- M1 17:55:00, the show opens: one row per movement and group, the first of each group active
  perform public.zz_at(sess, t0);
  select count(*) into n from public.movement_status where session_id = sess;
  if n = 6 then passed := passed + 1; else failures := failures || E'\nM1a rows ' || n; end if;
  t := public.zz_ms(sess, mb, g2) || ' / ' || public.zz_ms(sess, mb2, g2) || ' / ' || public.zz_ms(sess, md, g3);
  if t = 'active on_track / waiting pending / waiting pending' then passed := passed + 1; else failures := failures || E'\nM1b ' || t; end if;
  -- standing still: ETA = now + straight x 1.3 / planned pace + stay inside (rounded up to 5 s); leave by = deadline - 20 s - that
  exp_eta := to_timestamp(ceil(extract(epoch from t0 + make_interval(secs => d1 * 1.3 / 1.0 + 20)) / 5) * 5);
  exp_leave := to_timestamp(floor(extract(epoch from '2026-11-20 18:02:00+08'::timestamptz - make_interval(secs => 20 + d1 * 1.3)) / 5) * 5);
  select * into r from public.movement_status where session_id = sess and movement_id = mb and group_id = g2;
  if r.eta = exp_eta and r.leave_by = exp_leave and r.spare_s = public.show_secs('2026-11-20 18:02:00+08'::timestamptz - exp_eta)
     and r.basis = 'straight' and r.remaining_m = round(d1 * 1.3)::real and r.speed_mps = 1.0 and r.moving_since is null
     and r.deadline = '2026-11-20 18:02:00+08' then passed := passed + 1;
  else failures := failures || E'\nM1c MB ' || row(r.eta, exp_eta, r.leave_by, exp_leave, r.spare_s, r.basis, r.remaining_m, d1, r.speed_mps)::text; end if;
  -- M3: nobody has shared yet -> no signal
  select * into r from public.movement_status where session_id = sess and movement_id = mc and group_id = g3;
  if r.status = 'no_signal' and r.ics_sharing = 0 and r.eta is null then passed := passed + 1; else failures := failures || E'\nM1d MC ' || r.status; end if;

  -- M2 moving: 17:57:00 progress 1.3 m/s (in "x 1.3" metres) -> moving, still the planned pace; 17:57:30 half and half
  perform public.zz_at(sess, '2026-11-20 17:57:00+08');
  select * into r from public.movement_status where session_id = sess and movement_id = mb and group_id = g2;
  if r.moving_since = '2026-11-20 17:57:00+08' and r.speed_mps = 1.0 then passed := passed + 1;
  else failures := failures || E'\nM2a ' || row(r.moving_since, r.speed_mps)::text; end if;
  exp_leave := r.leave_by;
  perform public.zz_at(sess, '2026-11-20 17:57:30+08');
  select * into r from public.movement_status where session_id = sess and movement_id = mb and group_id = g2;
  if round(r.speed_mps::numeric, 2) = 1.15 and r.leave_by = exp_leave then passed := passed + 1;
  else failures := failures || E'\nM2b speed / kept leave by ' || row(r.speed_mps, r.leave_by, exp_leave)::text; end if;

  -- M3 arrival needs "stay inside" (20 s), and one IC with no signal does not block: Group A's claude_test was last seen
  -- 17:55:00 (no signal from 17:57:00); testuser1 inside from 17:57:30
  perform public.zz_at(sess, '2026-11-20 17:57:45+08');
  select * into r from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  if r.status <> 'arrived' and r.ics_inside = 1 and r.ics_no_signal = 1 and r.ics_required = 1 and r.eta = '2026-11-20 17:57:50+08'
  then passed := passed + 1; else failures := failures || E'\nM3a ' || row(r.status, r.ics_inside, r.ics_no_signal, r.ics_required, r.eta)::text; end if;
  perform public.zz_at(sess, '2026-11-20 17:58:00+08');
  select * into r from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  if r.status = 'arrived' and r.state = 'done' and r.arrived_at = '2026-11-20 17:57:50+08' and r.spare_s = 250 then passed := passed + 1;
  else failures := failures || E'\nM3b ' || row(r.status, r.state, r.arrived_at, r.spare_s)::text; end if;
  -- ... and the group's next movement takes over at the next evaluation
  perform public.zz_at(sess, '2026-11-20 17:58:05+08');
  t := public.zz_ms(sess, ma2, g_a);
  if t like 'active %' then passed := passed + 1; else failures := failures || E'\nM3c MA2 ' || t; end if;

  -- M4 komin arrives: at the moment he entered + 20 s, well before 18:02:00
  select zp.entered_at into entered from public.zone_presence zp where zp.session_id = sess and zp.user_id = u_k1 and zp.zone_id = z1;
  perform public.zz_at(sess, entered + interval '19 seconds');
  t := public.zz_ms(sess, mb, g2);
  if t like 'active %' then passed := passed + 1; else failures := failures || E'\nM4a too early ' || t; end if;
  perform public.zz_at(sess, entered + interval '20 seconds');
  select * into r from public.movement_status where session_id = sess and movement_id = mb and group_id = g2;
  if r.status = 'arrived' and r.arrived_at = entered + interval '20 seconds' and r.basis = 'inside' then passed := passed + 1;
  else failures := failures || E'\nM4b ' || row(r.status, r.arrived_at, entered, r.basis)::text; end if;

  -- M5 18:00:00: MB2 active from the middle of FORMATION_1 to STAGE_LEFT; M3: one of 2 required ICs heard -> no signal
  perform public.zz_at(sess, '2026-11-20 18:00:00+08');
  select * into r from public.movement_status where session_id = sess and movement_id = mb2 and group_id = g2;
  rem2 := d2 * 1.3;
  if r.state = 'active' and r.status = 'on_track' and r.remaining_m = round(rem2)::real and r.deadline = '2026-11-20 18:08:00+08'
  then passed := passed + 1; else failures := failures || E'\nM5a MB2 ' || row(r.state, r.status, r.remaining_m, rem2, r.deadline)::text; end if;
  select * into r from public.movement_status where session_id = sess and movement_id = mc and group_id = g3;
  if r.status = 'no_signal' and r.ics_sharing = 1 and r.ics_required = 2 then passed := passed + 1;
  else failures := failures || E'\nM5b MC ' || row(r.status, r.ics_sharing, r.ics_required)::text; end if;

  -- M6 simulation: a virtual group with a movement walks it, leaving a minute before its leave-by ("2 min late": a minute after)
  update public.events set is_simulation = true where id = ev;
  insert into public.sim_groups (event_id, group_id, script, target_zone_id, start_lat, start_lng, end_lat, end_lng, path_m, pace_mps)
  values (ev, g2, 'late_2min', z1, c_lat, c_lng, c_lat + 0.001, c_lng, 111, 1.3);
  perform public.zz_at(sess, '2026-11-20 18:00:00+08');
  select ms.leave_by, ms.remaining_m into r from public.movement_status ms where ms.session_id = sess and ms.movement_id = mb2 and ms.group_id = g2;
  exp_leave := r.leave_by;
  if r.remaining_m = round(d2)::real then passed := passed + 1; else failures := failures || E'\nM6a straight in a simulation ' || r.remaining_m || ' vs ' || d2; end if;
  select * into r from public.sim_groups where group_id = g2;
  x := extensions.st_distance(extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat), 4326)::extensions.geography,
         (select extensions.st_centroid(z.shape::extensions.geometry)::extensions.geography from public.zones z where z.id = z2));
  if r.movement_id = mb2 and abs(r.path_m - x) < 0.5 and r.pace_mps = 1.0 and r.travelled_m = 0
     and abs(r.depart_after_s - greatest(0, extract(epoch from exp_leave - '2026-11-20 18:00:00+08'::timestamptz) - 60 + 120)) < 0.01
  then passed := passed + 1; else failures := failures || E'\nM6b leg ' || row(r.movement_id = mb2, r.path_m, x, r.pace_mps, r.depart_after_s, exp_leave)::text; end if;
  -- the simulator panel: one movement per virtual group in a Draft version (root only), not twice
  perform public.zz_as(u_planner);
  sh2 := public.create_run_sheet(ev, 'Sim plan test');
  c[5] := public.save_cue(sh2, '{"code":"S1","title":"Band","start_time":"18:30:00","length_s":60}');
  err := public.zz_err(format('select public.sim_plan_movements(%L, %L, %L)', ev, sh2, c[5]));
  if err like '%Only the root%' then passed := passed + 1; else failures := failures || E'\nM6c planner ' || err; end if;
  perform public.zz_as(u_root);
  n := public.sim_plan_movements(ev, sh2, c[5]);
  err := public.zz_err(format('select public.sim_plan_movements(%L, %L, %L)', ev, sh2, c[5]));
  if n = 1 and err like 'Every virtual group already has%' then passed := passed + 1; else failures := failures || E'\nM6d ' || n || ' / ' || err; end if;
  execute 'reset role';
  update public.events set is_simulation = false where id = ev;

  -- M7 the deadline moves with the show: +30 s on C1 -> C1 ends 18:02:30, C3 starts 18:03:30
  perform public.zz_at(sess, '2026-11-20 18:00:30+08');
  perform set_config('show.test_now', '2026-11-20 18:00:30+08', true);
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess; -- the buttons need a live session
  perform public.zz_as(u_planner);
  perform public.show_add_time(sess, 30);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;
  perform public.zz_at(sess, '2026-11-20 18:00:31+08');
  select deadline into ts from public.movement_status where session_id = sess and movement_id = mc and group_id = g3;
  if ts = '2026-11-20 18:02:30+08' then passed := passed + 1; else failures := failures || E'\nM7a MC deadline ' || ts; end if;
  select deadline, planned_deadline into r from public.movement_status where session_id = sess and movement_id = ma2 and group_id = g_a;
  if r.deadline = '2026-11-20 18:03:30+08' and r.planned_deadline = '2026-11-20 18:03:00+08' then passed := passed + 1;
  else failures := failures || E'\nM7b MA2 ' || r::text; end if;

  -- M8 M3 both inside from 18:02:20: projected late at 18:02:30, arrived late at 18:02:40 (at once). M3 was "no signal"
  -- until then, and a signal that comes back is a fact: the new status shows at once, not on the 2nd look (031).
  perform public.zz_at(sess, '2026-11-20 18:02:30+08');
  t := public.zz_ms(sess, mc, g3);
  if t = 'active late' then passed := passed + 1; else failures := failures || E'\nM8a ' || t; end if;
  perform public.zz_at(sess, '2026-11-20 18:02:45+08');
  select * into r from public.movement_status where session_id = sess and movement_id = mc and group_id = g3;
  if r.status = 'arrived_late' and r.late_s = 10 and r.arrived_at = '2026-11-20 18:02:40+08' and r.ics_inside = 2 then passed := passed + 1;
  else failures := failures || E'\nM8b ' || row(r.status, r.late_s, r.arrived_at, r.ics_inside)::text; end if;

  -- M9 a status changes only after 2 evaluations agree: MB2 (komin standing in FORMATION_1) drops below 30 s spare
  -- around t1 and below 0 around t2
  t1 := '2026-11-20 18:08:00+08'::timestamptz - make_interval(secs => rem2 + 20 + 15);
  t1 := to_timestamp(floor(extract(epoch from t1) / 5) * 5);
  t2 := t1 + interval '40 seconds';
  if t1 > '2026-11-20 18:02:45+08' then passed := passed + 1; else failures := failures || E'\nM9 setup t1 ' || t1; end if;
  perform public.zz_at(sess, t1);
  t := public.zz_ms(sess, mb2, g2);
  if t = 'active on_track (next at_risk)' then passed := passed + 1; else failures := failures || E'\nM9a ' || t; end if;
  perform public.zz_at(sess, t1 + interval '5 seconds');
  t := public.zz_ms(sess, mb2, g2);
  if t = 'active at_risk' then passed := passed + 1; else failures := failures || E'\nM9b ' || t; end if;
  -- an acknowledged problem stays acknowledged while it does not get worse
  perform public.zz_as(u_marshal);
  perform public.ops_ack(sess, mb2, g2);
  perform public.zz_at(sess, t2);
  select * into r from public.movement_status where session_id = sess and movement_id = mb2 and group_id = g2;
  if r.status = 'at_risk' and r.cand_status = 'late' and r.acked_status = 'at_risk' then passed := passed + 1;
  else failures := failures || E'\nM9c ' || row(r.status, r.cand_status, r.acked_status)::text; end if;
  perform public.zz_at(sess, t2 + interval '5 seconds');
  select * into r from public.movement_status where session_id = sess and movement_id = mb2 and group_id = g2;
  if r.status = 'late' and r.late_s = -r.spare_s and r.late_s > 0 and r.status_since = t2 + interval '5 seconds' then passed := passed + 1;
  else failures := failures || E'\nM9d ' || row(r.status, r.late_s, r.spare_s, r.status_since)::text; end if;

  -- M10 C3 waits for Group A in STAGE_LEFT ("Auto when ready"): MA2's deadline stays when C3 was due, 18:03:30, and
  -- does not slide with the wait. GO starts C3 at 18:04:40; it runs to 18:05:40 without them: missed. C4 skipped: M3's
  -- movement to it is skipped.
  perform public.zz_at(sess, '2026-11-20 18:04:40+08');
  select * into r from public.movement_status where session_id = sess and movement_id = ma2 and group_id = g_a;
  t := public.zz_ms(sess, ma2, g_a);
  if r.deadline = '2026-11-20 18:03:30+08' and r.status = 'late' and r.late_s >= 70
     and (select wait_kind from public.show_cues where session_id = sess and cue_id = c[3]) = 'groups' then passed := passed + 1;
  else failures := failures || E'\nM10a waiting ' || row(r.deadline, r.status, r.late_s)::text; end if;
  perform set_config('show.test_now', '2026-11-20 18:04:40+08', true);
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess;
  perform public.zz_as(u_planner);
  perform public.show_go(sess, c[3]);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;
  perform public.zz_at(sess, '2026-11-20 18:05:41+08');
  select * into r from public.movement_status where session_id = sess and movement_id = ma2 and group_id = g_a;
  if r.status = 'missed' and r.state = 'done' and r.late_s = 131 and r.deadline = '2026-11-20 18:03:30+08' then passed := passed + 1;
  else failures := failures || E'\nM10b ' || row(r.status, r.state, r.late_s, r.deadline)::text; end if;
  perform set_config('show.test_now', '2026-11-20 18:05:45+08', true);
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess;
  perform public.zz_as(u_planner);
  perform public.show_skip(sess, c[4]);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;
  perform public.zz_at(sess, '2026-11-20 18:05:45+08');
  t := public.zz_ms(sess, md, g3);
  if t = 'done skipped' then passed := passed + 1; else failures := failures || E'\nM10c ' || t; end if;

  -- M11 who sees what: ops roles read the board; a member reads only their group's rows; nobody else
  perform public.zz_as(u_marshal);
  j := public.ops_board(sess);
  if jsonb_array_length(j -> 'rows') = 6 then passed := passed + 1; else failures := failures || E'\nM11a board rows ' || jsonb_array_length(j -> 'rows'); end if;
  perform public.zz_as(u_member);
  err := public.zz_err(format('select public.ops_board(%L)', sess));
  if err like 'Only the root, planners and marshals%' then passed := passed + 1; else failures := failures || E'\nM11b ' || err; end if;
  select count(*) into n from public.movement_status where session_id = sess;
  if n = 2 then passed := passed + 1; else failures := failures || E'\nM11c member sees ' || n; end if;
  perform public.zz_as(u_k1);
  err := public.zz_err(format('select public.ops_ack(%L, %L, %L)', sess, mb2, g2));
  if err like 'Only the root, planners and marshals%' then passed := passed + 1; else failures := failures || E'\nM11d ' || err; end if;
  execute 'reset role';
  select count(*) into n from public.movement_routes;
  perform public.zz_as(u_marshal);
  err := public.zz_err('select count(*) from public.movement_routes');
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nM11e routes readable: ' || err; end if;
  err := public.zz_err(format('select public.route_claim(5)'));
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nM11f route_claim: ' || err; end if;
  err := public.zz_err(format('select public.move_step(%L, now())', sess));
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nM11g move_step: ' || err; end if;

  -- M12 I'll handle it: one person at a time, the second is told who; pressed again it is let go
  t := public.ops_handle(sess, mb2, g2);
  perform public.zz_as(u_planner);
  err := public.zz_err(format('select public.ops_handle(%L, %L, %L)', sess, mb2, g2));
  if t = 'handling' and err like 'testuser2% is already handling it%' then passed := passed + 1; else failures := failures || E'\nM12a ' || t || ' / ' || err; end if;
  perform public.zz_as(u_marshal);
  t := public.ops_handle(sess, mb2, g2);
  j := public.ops_board(sess);
  if t = 'released' and not exists (select 1 from jsonb_array_elements(j -> 'rows') e where e ->> 'handled_by' is not null) then passed := passed + 1;
  else failures := failures || E'\nM12b ' || t; end if;
  -- snooze 1-30 min only
  err := public.zz_err(format('select public.ops_snooze(%L, %L, %L, 30)', sess, mb2, g2));
  perform public.ops_snooze(sess, mb2, g2, 120);
  select snoozed_until into ts from public.movement_status where session_id = sess and movement_id = mb2 and group_id = g2;
  if err like 'Snooze between%' and ts = '2026-11-20 18:07:45+08' then passed := passed + 1; else failures := failures || E'\nM12c ' || err || ' / ' || ts; end if;

  -- M13 message a group: ops only; the group's members read it, other groups do not; it is in the show's log
  perform public.zz_as(u_member);
  err := public.zz_err(format('select public.message_group(%L, %L, %L)', sess, g2, 'hi'));
  if err like 'Only the root, planners and marshals%' then passed := passed + 1; else failures := failures || E'\nM13a ' || err; end if;
  perform public.zz_as(u_planner);
  err := public.zz_err(format('select public.message_group(%L, %L, %L)', sess, g2, '   '));
  perform public.message_group(sess, g2, 'Please head to STAGE_LEFT now');
  if err like 'Write a message%' then passed := passed + 1; else failures := failures || E'\nM13b ' || err; end if;
  perform public.zz_as(u_k1);
  select count(*) into n from public.group_messages where group_id = g2;
  perform public.zz_as(u_member);
  select count(*) into k from public.group_messages where group_id = g2;
  if n = 1 and k = 0 then passed := passed + 1; else failures := failures || E'\nM13c own group ' || n || ', other ' || k; end if;
  execute 'reset role';
  select count(*) into n from public.show_log where session_id = sess and kind = 'message' and message = 'testuser1 messaged M2 test: "Please head to STAGE_LEFT now"';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nM13d log ' || n; end if;

  -- M14 Keep holding only on a cue that waits for groups; a marshal's sector
  execute 'reset role';
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess; -- the buttons need a live session
  perform public.zz_as(u_planner);
  err := public.zz_err(format('select public.show_keep_holding(%L, %L)', sess, c[3]));
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;
  perform public.zz_as(u_planner);
  if err like 'That cue is not waiting for groups%' then passed := passed + 1; else failures := failures || E'\nM14a ' || err; end if;
  perform public.set_marshal_sector(ev, u_marshal, ' Padang ');
  err := public.zz_err(format('select public.set_marshal_sector(%L, %L, %L)', ev, u_k1, 'S1'));
  if err like 'That person is not a marshal%' then passed := passed + 1; else failures := failures || E'\nM14b ' || err; end if;
  perform public.zz_as(u_marshal);
  err := public.zz_err(format('select public.set_marshal_sector(%L, %L, %L)', ev, u_marshal, 'S1'));
  j := public.ops_board(sess);
  if err like 'Only the root or a planner%' and j ->> 'my_sector' = 'Padang' then passed := passed + 1; else failures := failures || E'\nM14c ' || err || ' / ' || coalesce(j ->> 'my_sector', 'none'); end if;

  -- M15 distance still to go: inside, last 50 m straight, straight x factor, along a route, off the route
  execute 'reset role';
  select * into r from public.move_dist((select shape from public.zones where id = z1), null, c_lat, c_lng, 1.3);
  t := r.remaining_m || ' ' || r.basis;
  select * into r from public.move_dist((select shape from public.zones where id = z1), null, c_lat + 75 / 111320.0, c_lng, 1.3);
  t := t || ' / ' || (r.basis || ' ' || (r.remaining_m < 50));
  select * into r from public.move_dist((select shape from public.zones where id = z1), null, c_lat + 240 / 111320.0, c_lng, 1.3);
  t := t || ' / ' || (r.basis || ' ' || (abs(r.remaining_m - d1 * 1.3) < 0.01));
  if t = '0 inside / straight true / straight true' then passed := passed + 1; else failures := failures || E'\nM15a ' || t; end if;
  -- an L-shaped route from 245 m north: 150 m east, then back west and south to the zone
  select * into r from public.move_dist((select shape from public.zones where id = z1),
    extensions.st_makeline(array[extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat + 245 / 111320.0), 4326),
                                 extensions.st_setsrid(extensions.st_makepoint(c_lng + 150 / 111320.0, c_lat + 245 / 111320.0), 4326),
                                 extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat + 46 / 111320.0), 4326)])::extensions.geography,
    c_lat + 245 / 111320.0, c_lng + 75 / 111320.0, 1.3);
  x := r.remaining_m;
  t := r.basis;
  select * into r from public.move_dist((select shape from public.zones where id = z1),
    extensions.st_makeline(array[extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat + 245 / 111320.0), 4326),
                                 extensions.st_setsrid(extensions.st_makepoint(c_lng + 150 / 111320.0, c_lat + 245 / 111320.0), 4326),
                                 extensions.st_setsrid(extensions.st_makepoint(c_lng, c_lat + 46 / 111320.0), 4326)])::extensions.geography,
    c_lat + 245 / 111320.0, c_lng - 80 / 111320.0, 1.3);
  if t = 'route' and x between 75 + 245 and 75 + 260 and r.basis = 'straight' then passed := passed + 1;
  else failures := failures || E'\nM15b route ' || t || ' ' || x || ', off route ' || r.basis; end if;

  -- M16 OneMap routes: real events only, claimed once, saved route used by the engine
  execute 'reset role';
  select count(*) into n from public.route_claim(50) w where w.session_id = sess and w.movement_id = mb2 and w.group_id = g2;
  select count(*) into k from public.route_claim(50) w where w.session_id = sess and w.movement_id = mb2 and w.group_id = g2;
  if n = 1 and k = 0 then passed := passed + 1; else failures := failures || E'\nM16a claimed ' || n || ' then ' || k; end if;
  perform public.route_save(sess, mb2, g2,
    jsonb_build_array(jsonb_build_array(c_lat, c_lng), jsonb_build_array(c_lat, c_lng + 60 / 111320.0),
                      jsonb_build_array(c_lat - 200 / 111320.0, c_lng)),
    420, 350, c_lat, c_lng, c_lat - 200 / 111320.0, c_lng);
  perform public.zz_at(sess, '2026-11-20 18:05:50+08');
  select * into r from public.movement_status where session_id = sess and movement_id = mb2 and group_id = g2;
  select extensions.st_length(path) into x from public.movement_routes where session_id = sess and movement_id = mb2 and group_id = g2;
  if r.basis = 'route' and abs(r.remaining_m - x) <= 1 then passed := passed + 1; else failures := failures || E'\nM16b ' || row(r.basis, r.remaining_m, x)::text; end if;
  select count(*) into n from public.route_wanted(50) w where w.session_id = sess and w.movement_id = mb2;
  if n = 0 then passed := passed + 1; else failures := failures || E'\nM16c fresh route wanted again'; end if;
  perform public.zz_as(u_marshal);
  j := public.ops_board(sess);
  if exists (select 1 from jsonb_array_elements(j -> 'rows') e where (e ->> 'movement_id')::uuid = mb2 and e -> 'route' ->> 'type' = 'LineString')
  then passed := passed + 1; else failures := failures || E'\nM16d no route on the board for a late group'; end if;

  -- M17 the cron tick runs every live show without error (none is live outside this transaction)
  execute 'reset role';
  n := public.move_tick();
  if n >= 0 then passed := passed + 1; end if;

  raise exception 'RESULTS: % passed, failures: %', passed, coalesce(nullif(failures, ''), 'none');
end $test$;
