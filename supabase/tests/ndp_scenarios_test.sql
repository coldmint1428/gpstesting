-- supabase/tests/ndp_scenarios_test.sql -- NDP worst cases across Stages 6-8 + 029 (field hardening, radio), run against
-- the real project.
--
-- One transaction that ends with an exception, so nothing is kept: the result is the error text. Scenarios come from
-- the NDP 2025 show matrices (NE2 / NE4 / 14 Jun): a broadcast anchor after a buffer cue, 2-4 s song sections, a 0 s
-- "long script for buffer" cue, the jump segment cancelled for weather ("No Jump Programme"), a rain hold, bands moving
-- back to back between doors and formations, roads closed, phones with a wrong clock or a rough indoor fix, a zone
-- deleted by mistake, and the radio: stage managers answering the same call, "in position" heard on the radio.
-- Accounts: claude_test (root) and testuser1 (planner) are the 2 ICs of Group A; "Choir S1" = komin (IC), komin2
-- (admin), testuser3 (plain member); komin2 is also made a planner; testuser2 is made marshal. Each scenario runs on
-- its own day in November 2026 with its own session (readings with their own times; the clock is stepped).
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
  s_lat double precision; s_lng double precision;            -- STAGE_LEFT's middle
  g2 uuid; sh uuid; shb uuid; sess uuid; c uuid[]; ma uuid; mb uuid; mc uuid; zt uuid; tok uuid;
  k integer; n integer; ts timestamptz; t text; j jsonb; r record; err text;
  passed integer := 0;
  failures text := '';
begin
  create temp table zz_pushes (id bigint primary key, at timestamptz) on commit drop;
  grant all on zz_pushes to authenticated;
  execute $f$
    create function public.zz_as(p uuid) returns void language plpgsql as $b$
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
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
  -- all three engines at a moment (as pg_cron would); the pushes queued are noted with the show time
  execute $f$
    create function public.zz_at(p_session uuid, p_at timestamptz) returns integer language plpgsql as $b$
    declare n integer;
    begin
      execute 'reset role';
      perform set_config('show.test_now', p_at::text, true);
      perform public.show_step(p_session, p_at);
      perform public.move_step(p_session, p_at);
      n := public.push_collect_moves(p_session, p_at);
      insert into zz_pushes (id, at) select q.id, p_at from public.push_queue q on conflict do nothing;
      return n;
    end $b$;
  $f$;
  -- a button pressed at a moment (the buttons need a live session: its start moves to just now and back)
  execute $f$
    create function public.zz_btn(p_session uuid, p_at timestamptz, p_user uuid, p_sql text) returns text language plpgsql as $b$
    declare v_start timestamptz; v_err text;
    begin
      execute 'reset role';
      select starts_at into v_start from public.event_sessions where id = p_session;
      perform set_config('show.test_now', p_at::text, true);
      update public.event_sessions set starts_at = now() - interval '1 minute' where id = p_session;
      perform public.zz_as(p_user);
      v_err := public.zz_err(p_sql);
      execute 'reset role';
      update public.event_sessions set starts_at = v_start where id = p_session;
      return v_err;
    end $b$;
  $f$;
  execute $f$
    create function public.zz_read(p_event uuid, p_group uuid, p_user uuid, p_lat double precision, p_lng double precision,
                                   p_at timestamptz, p_acc real default 5)
    returns void language sql as $b$
      insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
      values (p_event, p_group, p_user, p_lat, p_lng, p_acc, 'gps', p_at);
    $b$;
  $f$;
  -- a new session of a Ready version, starting at p_start (the one before ends)
  execute $f$
    create function public.zz_start(p_event uuid, p_sheet uuid, p_start timestamptz, p_root uuid) returns uuid language plpgsql as $b$
    declare v uuid;
    begin
      execute 'reset role';
      update public.event_sessions set ended_at = greatest(now(), starts_at) where event_id = p_event and ended_at is null;
      perform public.zz_as(p_root);
      v := public.start_event(p_event, p_sheet);
      execute 'reset role';
      update public.event_sessions set starts_at = p_start where id = v;
      return v;
    end $b$;
  $f$;
  -- pushes of a kind, as "who@HH:MI:SS" (show time when queued)
  execute $f$
    create function public.zz_q(p_session uuid, p_kind text) returns text language sql as $b$
      select coalesce(string_agg(p.username || '@' || to_char(z.at at time zone 'Asia/Singapore', 'HH24:MI:SS'), ',' order by z.at, p.username), '')
      from public.push_queue q join public.profiles p on p.id = q.user_id join zz_pushes z on z.id = q.id
      where q.session_id = p_session and q.kind = p_kind;
    $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_err(text) to authenticated';

  -- fixtures
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant'),
    (ev, u_k1, 'participant'), (ev, u_k2, 'participant'), (ev, u_k2, 'planner') on conflict do nothing;
  insert into public.groups (event_id, name, colour, sector) values (ev, 'Choir S1', '#198754', 'S1') returning id into g2;
  insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
    (ev, g2, u_k1, true, false), (ev, g2, u_k2, false, true), (ev, g2, u_member, false, false);
  update public.event_sessions set ended_at = now() where event_id = ev and ended_at is null;
  delete from public.push_queue;
  select extensions.st_y(extensions.st_centroid(z.shape::extensions.geometry)), extensions.st_x(extensions.st_centroid(z.shape::extensions.geometry))
    into s_lat, s_lng from public.zones z where z.id = z2;

  -- ============ N1 The show crosses midnight; 2-4 s song sections; a 0 s buffer cue; engine ticks missed ============
  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'N1 midnight', null, null);
  c := array[
    public.save_cue(sh, '{"code":"C1","title":"Countdown","start_time":"23:58:00","length_s":60}'),
    public.save_cue(sh, '{"code":"C2","title":"Intro","start_time":"23:59:00","length_s":2}'),
    public.save_cue(sh, '{"code":"C3","title":"Verse","start_time":"23:59:02","length_s":4}'),
    public.save_cue(sh, '{"code":"C4","title":"Tag","start_time":"23:59:06","length_s":2}'),
    public.save_cue(sh, '{"code":"C5","title":"Long script for buffer","start_time":"23:59:08","length_s":0,"type":"flexible"}'),
    public.save_cue(sh, '{"code":"C6","title":"Silence","start_time":"23:59:08","length_s":3}'),
    public.save_cue(sh, '{"code":"C7","title":"Broadcast","start_time":"00:00:00","day_offset":1,"length_s":60,"type":"anchor"}')];
  select count(*) into n from public.check_run_sheet(sh) x where x::text like '%Has no length%';
  err := public.zz_err(format('select public.mark_run_sheet_ready(%L)', sh));
  if n = 1 and err = 'no error' then passed := passed + 1; else failures := failures || E'\nN1a 0 s cue: warnings ' || n || ', ready: ' || err; end if;
  sess := public.zz_start(ev, sh, '2026-11-20 23:57:00+08', u_root);
  for k in 0 .. 130 by 2 loop
    continue when k between 59 and 65;    -- no engine run from 23:58:58 to 23:59:06
    perform public.zz_at(sess, '2026-11-20 23:58:00+08'::timestamptz + make_interval(secs => k));
  end loop;
  select string_agg(c2.code || ' ' || sc.status || ' ' || to_char(sc.started_at at time zone 'Asia/Singapore', 'DD HH24:MI:SS') ||
                    coalesce('-' || to_char(sc.ended_at at time zone 'Asia/Singapore', 'HH24:MI:SS'), ''), ', ' order by c2.position) into t
  from public.show_cues sc join public.cues c2 on c2.id = sc.cue_id where sc.session_id = sess;
  if t = 'C1 done 20 23:58:00-23:59:00, C2 done 20 23:59:00-23:59:02, C3 done 20 23:59:02-23:59:06, C4 done 20 23:59:06-23:59:08, '
         'C5 done 20 23:59:08-23:59:08, C6 done 20 23:59:08-23:59:11, C7 running 21 00:00:00'
  then passed := passed + 1; else failures := failures || E'\nN1b ' || t; end if;

  -- ============ N2 Two stage managers answer the same radio call with +30 s ============
  sess := public.zz_start(ev, sh, '2026-11-20 23:57:00+08', u_root);
  perform public.zz_at(sess, '2026-11-20 23:58:10+08');
  err := public.zz_btn(sess, '2026-11-20 23:58:10+08', u_planner, format('select public.show_add_time(%L, 30)', sess));
  t := public.zz_btn(sess, '2026-11-20 23:58:12+08', u_k2, format('select public.show_add_time(%L, 30)', sess));
  if err = 'no error' and t = 'testuser1 added +30 s to C1 "Countdown" (2 s ago). Check the clock: press again only if you want more.'
  then passed := passed + 1; else failures := failures || E'\nN2a second +30 within 5 s: ' || err || ' / ' || t; end if;
  -- ... the same person pressing twice means it; someone else 6 s later too
  err := public.zz_btn(sess, '2026-11-20 23:58:13+08', u_planner, format('select public.show_add_time(%L, 30)', sess));
  t := public.zz_btn(sess, '2026-11-20 23:58:19+08', u_k2, format('select public.show_add_time(%L, 30)', sess));
  select added_s into n from public.show_cues where session_id = sess and cue_id = c[1];
  if err = 'no error' and t = 'no error' and n = 90 then passed := passed + 1; else failures := failures || E'\nN2b ' || err || ' / ' || t || ' / added ' || n; end if;

  -- ============ N3 Rain: the show is held for 3 min just before a band's leave-by ============
  -- C1 runs 17:50-18:08; the band (Group A, 150 m out, standing) must be in FORMATION_1 when C2 starts at 18:08
  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'N3 rain hold', null, null);
  c := array[public.save_cue(sh, '{"code":"C1","title":"Pre-parade","start_time":"17:50:00","length_s":1080}'),
             public.save_cue(sh, '{"code":"C2","title":"Bands enter","start_time":"18:08:00","length_s":120}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  perform public.mark_run_sheet_ready(sh);
  sess := public.zz_start(ev, sh, '2026-11-21 17:40:00+08', u_root);
  for k in 0 .. 900 by 10 loop
    ts := '2026-11-21 18:00:00+08'::timestamptz + make_interval(secs => k);
    perform public.zz_read(ev, g_a, u_root, c_lat + 150 / 111320.0, c_lng, ts);
    perform public.zz_read(ev, g_a, u_planner, c_lat + 150 / 111320.0, c_lng + 0.00002, ts);
    if ts = '2026-11-21 18:03:30+08' then
      perform public.zz_btn(sess, ts, u_planner, format('select public.show_hold(%L)', sess));
    elsif ts = '2026-11-21 18:06:30+08' then
      perform public.zz_btn(sess, ts, u_planner, format('select public.show_resume(%L)', sess));
    elsif ts = '2026-11-21 18:12:00+08' then
      perform public.zz_btn(sess, ts, u_planner, format('select public.show_hold(%L)', sess));   -- a 10 s hold
    elsif ts = '2026-11-21 18:12:10+08' then
      perform public.zz_btn(sess, ts, u_planner, format('select public.show_resume(%L)', sess));
    end if;
    perform public.zz_at(sess, ts);
  end loop;
  select string_agg(q.kind || '@' || to_char(z.at at time zone 'Asia/Singapore', 'HH24:MI:SS'), ',') into t
  from public.push_queue q join zz_pushes z on z.id = q.id
  where q.session_id = sess and q.kind in ('get_ready', 'leave_now', 'late') and z.at >= '2026-11-21 18:03:30+08' and z.at < '2026-11-21 18:06:30+08';
  if t is null then passed := passed + 1; else failures := failures || E'\nN3a moves pushed while held: ' || t; end if;
  if public.zz_q(sess, 'hold') = 'claude_test@18:03:50,testuser1@18:03:50' then passed := passed + 1;
  else failures := failures || E'\nN3b hold ' || public.zz_q(sess, 'hold'); end if;
  select string_agg(distinct q.title || ' | ' || q.body, ' // ') into t from public.push_queue q where q.session_id = sess and q.kind = 'resume';
  if public.zz_q(sess, 'resume') = 'claude_test@18:06:30,testuser1@18:06:30'
     and t like 'Show resumed | Leave now for % be inside FORMATION_1 by 18:08:00.' then passed := passed + 1;
  else failures := failures || E'\nN3c resume ' || public.zz_q(sess, 'resume') || ' ' || coalesce(t, 'none'); end if;
  -- "Leave now" was in the resume push: not again; "Running late" after a minute's grace, once
  t := public.zz_q(sess, 'leave_now');
  err := public.zz_q(sess, 'late');
  if t = '' and err like 'claude_test@18:07:%,testuser1@18:07:%' and err >= 'claude_test@18:07:30' then passed := passed + 1;
  else failures := failures || E'\nN3d leave_now ' || t || ' / late ' || err; end if;
  if (select count(*) from public.push_queue where session_id = sess and kind = 'hold') = 2 then passed := passed + 1;
  else failures := failures || E'\nN3e the 10 s hold was pushed'; end if;

  -- ============ N4 Bands back to back: FORMATION_1, then straight on to STAGE_LEFT ============
  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'N4 back to back', null, null);
  c := array[public.save_cue(sh, '{"code":"C1","title":"Bands feature","start_time":"18:00:00","length_s":300}'),
             public.save_cue(sh, '{"code":"C2","title":"Placard","start_time":"18:05:00","length_s":60}'),
             public.save_cue(sh, '{"code":"C3","title":"Choir","start_time":"18:06:00","length_s":60}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  mb := public.save_movement(sh, jsonb_build_object('code', 'MB', 'group_id', g_a, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[3]));
  perform public.mark_run_sheet_ready(sh);
  sess := public.zz_start(ev, sh, '2026-11-22 17:50:00+08', u_root);
  for k in 0 .. 180 by 5 loop
    ts := '2026-11-22 18:02:30+08'::timestamptz + make_interval(secs => k);
    perform public.zz_read(ev, g_a, u_root, c_lat, c_lng, ts);
    perform public.zz_read(ev, g_a, u_planner, c_lat, c_lng + 0.00001, ts);
    perform public.zz_at(sess, ts);
  end loop;
  select to_char(arrived_at at time zone 'Asia/Singapore', 'HH24:MI:SS') into t from public.movement_status where session_id = sess and movement_id = ma;
  select q.title || ' | ' || q.body into err from public.push_queue q where q.session_id = sess and q.kind = 'next' and q.user_id = u_planner;
  if t = '18:02:50' and public.zz_q(sess, 'next') = 'claude_test@18:02:55,testuser1@18:02:55'
     and err like 'Next: Stage Left | Be inside STAGE_LEFT by 18:06:00 · % m to go. Leave now.' then passed := passed + 1;
  else failures := failures || E'\nN4a arrived ' || coalesce(t, '-') || ', next ' || public.zz_q(sess, 'next') || ' ' || coalesce(err, 'none'); end if;
  -- they stay put: no "Leave now" (Next said it), "Running late" only after a minute
  if public.zz_q(sess, 'leave_now') = '' and public.zz_q(sess, 'get_ready') = '' and public.zz_q(sess, 'late') like 'claude_test@18:03:5%,testuser1@18:03:5%'
  then passed := passed + 1; else failures := failures || E'\nN4b leave ' || public.zz_q(sess, 'leave_now') || ' / ready ' || public.zz_q(sess, 'get_ready') || ' / late ' || public.zz_q(sess, 'late'); end if;

  -- ============ N5 No Jump: the live version switches; a road is closed so Group A goes to STAGE_LEFT instead ============
  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'N5 jump (wet weather plan)', null, null);
  c := array[public.save_cue(sh, '{"code":"C1","title":"Red Lions","start_time":"18:00:00","length_s":600}'),
             public.save_cue(sh, '{"code":"C2","title":"Combined salute","start_time":"18:10:00","length_s":60}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  mc := public.save_movement(sh, jsonb_build_object('code', 'MC', 'group_id', g2, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  perform public.mark_run_sheet_ready(sh);
  shb := public.create_run_sheet(ev, 'N5 No Jump', null, sh);
  perform public.save_movement(shb, (select jsonb_build_object('id', m.id, 'rev', m.rev, 'code', 'MA', 'group_id', g_a, 'zone_id', z2,
                                     'deadline_kind', 'cue_start', 'cue_id', (select id from public.cues where run_sheet_id = shb and code = 'C2'))
                                     from public.movements m where m.run_sheet_id = shb and m.code = 'MA'));
  perform public.delete_movement((select id from public.movements where run_sheet_id = shb and code = 'MC'));
  perform public.mark_run_sheet_ready(shb);
  sess := public.zz_start(ev, sh, '2026-11-23 17:50:00+08', u_root);
  for k in 0 .. 60 by 10 loop
    ts := '2026-11-23 18:00:00+08'::timestamptz + make_interval(secs => k);
    perform public.zz_read(ev, g_a, u_root, c_lat + 150 / 111320.0, c_lng, ts);
    perform public.zz_read(ev, g2, u_k1, s_lat + 150 / 111320.0, s_lng, ts);
    perform public.zz_at(sess, ts);
  end loop;
  perform public.zz_btn(sess, '2026-11-23 18:01:00+08', u_planner, format('select public.report_delay(%L, %L, %L, %L)', sess, ma, g_a, 'Road closed'));
  perform public.zz_btn(sess, '2026-11-23 18:01:00+08', u_marshal, format('select public.ops_handle(%L, %L, %L)', sess, ma, g_a));
  perform public.zz_btn(sess, '2026-11-23 18:01:00+08', u_marshal, format('select public.ops_snooze(%L, %L, %L, 300)', sess, ma, g_a));
  err := public.zz_btn(sess, '2026-11-23 18:01:30+08', u_root, format('select public.switch_live_run_sheet(%L, %L)', ev, shb));
  perform public.zz_at(sess, '2026-11-23 18:01:35+08');
  select * into r from public.movement_status where session_id = sess and run_sheet_id = shb and code = 'MA';
  if err = 'no error' and r.delay_note = 'Road closed' and r.handled_by = u_marshal and r.snoozed_until is not null
  then passed := passed + 1; else failures := failures || E'\nN5a kept after the switch: ' || err || ' ' || row(r.delay_note, r.handled_by = u_marshal, r.snoozed_until)::text; end if;
  select string_agg(p.username || ': ' || q.body, ' / ' order by p.username) into t
  from public.push_queue q join public.profiles p on p.id = q.user_id where q.session_id = sess and q.kind = 'change';
  if t = 'claude_test: Go to Stage Left (STAGE_LEFT) instead of FORMATION_1. / komin: Your move to Stage Left (STAGE_LEFT) is cancelled. Wait for instructions. / '
         'komin2: Your move to Stage Left (STAGE_LEFT) is cancelled. Wait for instructions. / testuser1: Go to Stage Left (STAGE_LEFT) instead of FORMATION_1.'
  then passed := passed + 1; else failures := failures || E'\nN5b ' || coalesce(t, 'no change pushes'); end if;

  -- ============ N6 Bad data: a phone clock 10 min fast; a 300 m fix indoors ============
  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'N6 data', null, null);
  c := array[public.save_cue(sh, '{"code":"C1","title":"Pre-show","start_time":"18:00:00","length_s":600}'),
             public.save_cue(sh, '{"code":"C2","title":"Choir feature","start_time":"18:10:00","length_s":60,"start_mode":"auto_ready"}'),
             public.save_cue(sh, '{"code":"C3","title":"Finale","start_time":"18:20:00","length_s":60}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  mb := public.save_movement(sh, jsonb_build_object('code', 'MB', 'group_id', g_a, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[3]));
  mc := public.save_movement(sh, jsonb_build_object('code', 'MC', 'group_id', g2, 'zone_id', z2, 'deadline_kind', 'cue_start', 'cue_id', c[3]));
  perform public.mark_run_sheet_ready(sh);
  sess := public.zz_start(ev, sh, '2026-11-24 17:50:00+08', u_root);
  -- the phone app's upload (report_location) and the website's own insert, both 10 min ahead: stored as now
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess;
  insert into public.tracking_passes (user_id, event_id, group_id, expires_at) values (u_root, ev, g_a, now() + interval '1 hour') returning token into tok;
  perform public.report_location(tok, c_lat + 500 / 111320.0, c_lng, 5, now() + interval '10 minutes');
  select recorded_at into ts from public.locations where user_id = u_root and event_id = ev order by id desc limit 1;
  perform public.zz_as(u_planner);
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values (ev, g_a, u_planner, c_lat + 500 / 111320.0, c_lng, 5, 'gps', now() + interval '10 minutes');
  execute 'reset role';
  select recorded_at into r from public.locations where user_id = u_planner and event_id = ev order by id desc limit 1;
  if abs(extract(epoch from ts - now())) < 5 and abs(extract(epoch from r.recorded_at - now())) < 5 then passed := passed + 1;
  else failures := failures || E'\nN6a future times kept: phone ' || ts || ', website ' || r.recorded_at || ', now ' || now(); end if;
  update public.event_sessions set starts_at = '2026-11-24 17:50:00+08' where id = sess;
  -- under the stand: three 300 m fixes in the zone's middle, then a 5 m one
  perform public.zz_read(ev, g_a, u_root, c_lat + 200 / 111320.0, c_lng, '2026-11-24 18:01:00+08');
  perform public.zz_read(ev, g_a, u_root, c_lat, c_lng, '2026-11-24 18:01:10+08', 300);
  perform public.zz_read(ev, g_a, u_root, c_lat, c_lng, '2026-11-24 18:01:20+08', 300);
  perform public.zz_read(ev, g_a, u_root, c_lat, c_lng, '2026-11-24 18:01:30+08', 300);
  perform public.zz_read(ev, g_a, u_planner, c_lat, c_lng, '2026-11-24 18:01:30+08', 250);
  perform public.zz_at(sess, '2026-11-24 18:01:55+08');
  select count(*) into n from public.zone_presence where session_id = sess and zone_id = z1;
  select ms.status || ' heard ' || ms.ics_sharing into t from public.movement_status ms where ms.session_id = sess and ms.movement_id = ma;
  if n = 0 and t like '% heard 1' then passed := passed + 1; else failures := failures || E'\nN6b rough fixes: stays ' || n || ', MA ' || t; end if;
  perform public.zz_read(ev, g_a, u_root, c_lat, c_lng, '2026-11-24 18:01:40+08', 5);
  select to_char(min(entered_at) at time zone 'Asia/Singapore', 'HH24:MI:SS') into t from public.zone_presence where session_id = sess and zone_id = z1;
  if t = '18:01:40' then passed := passed + 1; else failures := failures || E'\nN6c good fix: entered ' || coalesce(t, 'never'); end if;

  -- ============ N7 A planner deletes a door zone the live show still needs ============
  insert into public.zones (event_id, code, name, kind, shape) select ev, 'TEMP_DOOR', 'Temp door', z.kind, z.shape from public.zones z where z.id = z2
  returning id into zt;
  err := public.zz_err(format('delete from public.zones where id = %L', z2));
  t := public.zz_err(format('delete from public.zones where id = %L', zt));
  if err like 'STAGE_LEFT is used by the live show (movement M% of %): end the show or switch to a version without it first.' and t = 'no error'
  then passed := passed + 1; else failures := failures || E'\nN7 ' || err || ' / unused zone: ' || t; end if;

  -- (claude_test walks out of FORMATION_1 again: two readings outside)
  perform public.zz_read(ev, g_a, u_root, c_lat + 200 / 111320.0, c_lng, '2026-11-24 18:02:10+08');
  perform public.zz_read(ev, g_a, u_root, c_lat + 200 / 111320.0, c_lng, '2026-11-24 18:02:20+08');

  -- ============ N8 Radio: channel / call sign, "in position" heard on the radio, a delay passed on ============
  err := public.zz_btn(sess, '2026-11-24 18:02:00+08', u_planner, format('select public.set_group_radio(%L, %L)', g_a, '  Ch 3   ·  BRAVO '));
  t := public.zz_btn(sess, '2026-11-24 18:02:00+08', u_marshal, format('select public.set_group_radio(%L, %L)', g_a, 'Ch 9'));
  if err = 'no error' and (select radio from public.groups where id = g_a) = 'Ch 3 · BRAVO' and t like 'Only the root or a planner%'
     and public.zz_btn(sess, '2026-11-24 18:02:00+08', u_planner, format('select public.set_group_radio(%L, %L)', g_a, repeat('x', 41))) like 'Keep the radio%'
  then passed := passed + 1; else failures := failures || E'\nN8a radio ' || err || ' / ' || t; end if;
  perform public.zz_as(u_marshal);
  j := public.ops_board(sess);
  perform public.zz_as(u_k2);
  err := public.my_moves(sess) ->> 'can_report' || '/' || (public.my_moves(sess) ->> 'is_ic');
  perform public.zz_as(u_planner);
  t := (public.my_moves(sess) ->> 'radio') || '/' || (public.my_moves(sess) ->> 'can_report') || '/' || (public.my_moves(sess) ->> 'is_ic');
  execute 'reset role';
  if exists (select 1 from jsonb_array_elements(j -> 'rows') e where (e ->> 'group_id')::uuid = g_a and e ->> 'radio' = 'Ch 3 · BRAVO')
     and err = 'true/false' and t = 'Ch 3 · BRAVO/true/true' then passed := passed + 1;
  else failures := failures || E'\nN8b board / my_moves ' || err || ' / ' || t; end if;
  -- a plain member cannot; a marshal heard it on the radio: in position at once (nobody's phone is inside)
  err := public.zz_btn(sess, '2026-11-24 18:03:00+08', u_member, format('select public.mark_in_position(%L, %L, %L)', sess, mc, g2));
  t := public.zz_btn(sess, '2026-11-24 18:03:00+08', u_marshal, format('select public.mark_in_position(%L, %L, %L)', sess, ma, g_a));
  select * into r from public.movement_status where session_id = sess and movement_id = ma;
  if err like 'Only the group''s IC or admin%' and t = 'no error' and r.state = 'done' and r.status = 'arrived' and r.basis = 'reported'
     and r.spare_s = 420 and (select message from public.show_log where session_id = sess and kind = 'radio' order by id desc limit 1)
         = 'Group A in position at FORMATION_1 (radio, testuser2).'
  then passed := passed + 1; else failures := failures || E'\nN8c ' || err || ' / ' || t || ' / ' || row(r.state, r.status, r.basis, r.spare_s)::text; end if;
  err := public.zz_btn(sess, '2026-11-24 18:03:02+08', u_planner, format('select public.mark_in_position(%L, %L, %L)', sess, ma, g_a));
  if err = 'Group A is already in position (since 18:03:00).' then passed := passed + 1; else failures := failures || E'\nN8d twice ' || err; end if;
  -- the engine keeps it, the next movement takes over, and "Auto when ready" C2 no longer waits for Group A
  perform public.zz_at(sess, '2026-11-24 18:03:05+08');
  perform public.zz_at(sess, '2026-11-24 18:03:10+08');
  t := (select state || ' ' || status from public.movement_status where session_id = sess and movement_id = ma) || ' / ' ||
       (select state from public.movement_status where session_id = sess and movement_id = mb);
  if t = 'done arrived / active' and cardinality(public.show_missing_groups(sess, sh, c[2], '2026-11-24 18:03:10+08')) = 0
  then passed := passed + 1; else failures := failures || E'\nN8e ' || t || ' missing ' || public.show_missing_groups(sess, sh, c[2], '2026-11-24 18:03:10+08')::text; end if;
  -- a wrong call: undo
  err := public.zz_btn(sess, '2026-11-24 18:03:20+08', u_marshal, format('select public.mark_in_position(%L, %L, %L, true)', sess, ma, g_a));
  t := (select state || ' ' || status from public.movement_status where session_id = sess and movement_id = ma) || ' / ' ||
       (select state from public.movement_status where session_id = sess and movement_id = mb);
  if err = 'no error' and t = 'active pending / waiting' and public.show_missing_groups(sess, sh, c[2], '2026-11-24 18:03:20+08') = array['Group A']
  then passed := passed + 1; else failures := failures || E'\nN8f undo ' || err || ' / ' || t; end if;
  -- they were already told "Next: Stage Left": the undo corrects it
  select string_agg(p.username || ': ' || q.title || ' | ' || q.body, ' / ' order by p.username) into t
  from public.push_queue q join public.profiles p on p.id = q.user_id where q.session_id = sess and q.kind = 'change';
  if public.zz_q(sess, 'next') like 'claude_test@18:03:%,testuser1@18:03:%'
     and t = 'claude_test: Correction: not in position yet | Keep heading to FORMATION_1: be inside by 18:10:00. / '
             'testuser1: Correction: not in position yet | Keep heading to FORMATION_1: be inside by 18:10:00.'
  then passed := passed + 1; else failures := failures || E'\nN8f2 next ' || public.zz_q(sess, 'next') || ' / correction ' || coalesce(t, 'none'); end if;
  -- a delay heard on the radio, passed on by the marshal; a member of another group still cannot
  perform public.zz_at(sess, '2026-11-24 18:04:05+08');
  err := public.zz_btn(sess, '2026-11-24 18:04:10+08', u_marshal, format('select public.report_delay(%L, %L, %L, %L)', sess, mc, g2, 'Lift stuck'));
  t := public.zz_btn(sess, '2026-11-24 18:04:10+08', u_k1, format('select public.report_delay(%L, %L, %L, %L)', sess, ma, g_a, 'x'));
  if err = 'no error' and t like 'Only a member of this group%'
     and (select message from public.show_log where session_id = sess and kind = 'delay_report' order by id desc limit 1)
         like 'Choir S1 reports a delay (radio, testuser2): "Lift stuck"%'
  then passed := passed + 1; else failures := failures || E'
N8g ' || err || ' / ' || t; end if;
  -- the IC says so from the phone
  err := public.zz_btn(sess, '2026-11-24 18:04:20+08', u_k1, format('select public.mark_in_position(%L, %L, %L)', sess, mc, g2));
  if err = 'no error' and (select message from public.show_log where session_id = sess and kind = 'radio' order by id desc limit 1)
                          = 'Choir S1 in position at STAGE_LEFT (IC, komin).'
  then passed := passed + 1; else failures := failures || E'
N8h IC ' || err; end if;
  -- who can call the new functions
  if not has_function_privilege('anon', 'public.mark_in_position(uuid, uuid, uuid, boolean)', 'execute')
     and not has_function_privilege('anon', 'public.set_group_radio(uuid, text)', 'execute')
     and has_function_privilege('authenticated', 'public.mark_in_position(uuid, uuid, uuid, boolean)', 'execute')
  then passed := passed + 1; else failures := failures || E'\nN8i grants'; end if;

  -- the cron tick still runs every live show
  execute 'reset role';
  perform set_config('show.test_now', '', true);
  n := public.move_tick();
  passed := passed + 1;

  raise exception 'RESULTS: % passed, failures: %', passed, coalesce(nullif(failures, ''), 'none');
end $test$;
