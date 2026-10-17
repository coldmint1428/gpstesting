-- supabase/tests/live_show_test.sql -- merger Stage 6 (026_live_show.sql), run against the real project.
--
-- One transaction that ends with an exception, so nothing is kept: the result is the error text. The show clock is
-- set step by step (show.test_now) and the engine run by hand at those moments, so every rule is checked to the
-- second. Accounts and event as in run_sheets_test.sql: claude_test (root, IC of Group A), testuser1 (planner, IC of
-- Group A), testuser2 (made marshal), testuser3 (made member).
--
-- The test run sheet, on 16 Oct 2026 (Singapore):
--   C1 18:00:00 1:00 Auto      C2 18:01:00 1:00 Flexible (can shorten 0:30)      C3 18:02:00 1:00 Manual
--   C4 18:03:00 1:00 Auto when ready (Group A must be in FORMATION_1, 1 IC, 20 s)  C5 18:05:00 1:00 ANCHOR
--   C6 18:06:00 0:30 Auto
do $test$
declare
  ev uuid := '4395abec-16b6-44a0-b4a1-5f7fd6e5df49';
  u_root uuid := 'cd87c144-9524-4558-9ec5-bc59694b6b0e';
  u_planner uuid := 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';
  u_marshal uuid := 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5';
  u_member uuid := '2906655b-33ad-4e9d-a608-f083e43e22d4';
  z1 uuid := '2d88456f-a7a6-4901-a794-307ef1476b7c';      -- FORMATION_1
  g_a uuid := '84c7ca4b-c68c-4e8c-830e-fdcafadb904e';     -- Group A
  sh uuid; sh2 uuid; sess uuid; c uuid[]; c4 uuid;
  n integer; t text; b boolean; j jsonb; r record;
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
  -- the engine at a moment (as the database, like pg_cron)
  execute $f$
    create function public.zz_at(p_session uuid, p_at text) returns void language plpgsql as $b$
    begin
      execute 'reset role';
      perform set_config('show.test_now', p_at, true);
      perform public.show_step(p_session, p_at::timestamptz);
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
  -- a cue's state in short: status started-ended (Singapore HH:MI:SS)
  execute $f$
    create function public.zz_cue(p_session uuid, p_cue uuid) returns text language sql as $b$
      select sc.status || ' ' || coalesce(to_char(sc.started_at at time zone 'Asia/Singapore', 'HH24:MI:SS'), '-') || '-' ||
             coalesce(to_char(sc.ended_at at time zone 'Asia/Singapore', 'HH24:MI:SS'), '-')
      from public.show_cues sc where sc.session_id = p_session and sc.cue_id = p_cue;
    $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_err(text) to authenticated';

  -- fixtures
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant')
  on conflict do nothing;
  update public.event_sessions set ended_at = now() where event_id = ev and ended_at is null;

  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'Show engine test');
  c := array[
    public.save_cue(sh, '{"code":"C1","title":"One","start_time":"18:00:00","length_s":60}'),
    public.save_cue(sh, '{"code":"C2","title":"Two","start_time":"18:01:00","length_s":60,"type":"flexible","can_shorten_s":30}'),
    public.save_cue(sh, '{"code":"C3","title":"Three","start_time":"18:02:00","length_s":60,"start_mode":"manual"}'),
    public.save_cue(sh, '{"code":"C4","title":"Four","start_time":"18:03:00","length_s":60,"start_mode":"auto_ready"}'),
    public.save_cue(sh, '{"code":"C5","title":"Flypast","start_time":"18:05:00","length_s":60,"type":"anchor"}'),
    public.save_cue(sh, '{"code":"C6","title":"Six","start_time":"18:06:00","length_s":30}')];
  perform public.save_movement(sh, jsonb_build_object('group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[4],
                                                       'min_ics', 1, 'dwell_s', 20));
  perform public.mark_run_sheet_ready(sh);
  perform public.zz_as(u_root);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-10-16 17:59:00+08' where id = sess;

  -- L1 before the show
  perform public.zz_at(sess, '2026-10-16 17:59:30+08');
  select show_date into t from public.show_state where session_id = sess;
  if t = '2026-10-16' then passed := passed + 1; else failures := failures || E'\nL1a show date ' || t; end if;
  select count(*) into n from public.show_cues where session_id = sess and status = 'pending';
  if n = 6 then passed := passed + 1; else failures := failures || E'\nL1b pending ' || n; end if;
  perform public.zz_as(u_marshal);
  j := public.show_board(sess);
  if j ->> 'state' = 'before' and (j -> 'anchor' ->> 'code') = 'C5' then passed := passed + 1; else failures := failures || E'\nL1c board ' || left(j::text, 200); end if;

  -- L2 an Auto cue starts at its exact time even when the engine runs a second later
  perform public.zz_at(sess, '2026-10-16 18:00:01+08');
  t := public.zz_cue(sess, c[1]);
  if t = 'running 18:00:00--' then passed := passed + 1; else failures := failures || E'\nL2 C1 ' || t; end if;

  -- L3 GO on the running cue, GO on a cue that is not next, GO on an anchor, a marshal's GO
  perform public.zz_as(u_planner);
  err := public.zz_err(format('select public.show_go(%L, %L)', sess, c[1]));
  if err like '%already running: started at 18:00:00 by the clock%' then passed := passed + 1; else failures := failures || E'\nL3a ' || err; end if;
  err := public.zz_err(format('select public.show_go(%L, %L)', sess, c[3]));
  if err like 'GO starts the next cue, C2 "Two"%' then passed := passed + 1; else failures := failures || E'\nL3b ' || err; end if;
  err := public.zz_err(format('select public.show_go(%L, %L)', sess, c[5]));
  if err like '%is an anchor: it starts by itself at 18:05:00%' then passed := passed + 1; else failures := failures || E'\nL3c ' || err; end if;
  perform public.zz_as(u_marshal);
  err := public.zz_err(format('select public.show_go(%L, %L)', sess, c[2]));
  if err like '%Only the root or a planner%' then passed := passed + 1; else failures := failures || E'\nL3d marshal ' || err; end if;

  -- L4 +30 s on the running cue moves what follows
  execute 'reset role';
  perform set_config('show.test_now', '2026-10-16 18:00:30+08', true);
  perform public.zz_as(u_planner);
  perform public.show_add_time(sess, 30);
  execute 'reset role';
  select x.projected_start into r from public.show_rows(sess, '2026-10-16 18:00:30+08') x where x.cue_id = c[2];
  if to_char(r.projected_start at time zone 'Asia/Singapore', 'HH24:MI:SS') = '18:01:30' then passed := passed + 1;
  else failures := failures || E'\nL4 C2 projected ' || r.projected_start; end if;

  -- L5 the Flexible cue starts 30 s late and absorbs it: ends on its planned end
  perform public.zz_at(sess, '2026-10-16 18:01:31+08');
  t := public.zz_cue(sess, c[1]) || ' / ' || public.zz_cue(sess, c[2]);
  if t = 'done 18:00:00-18:01:30 / running 18:01:30--' then passed := passed + 1; else failures := failures || E'\nL5a ' || t; end if;
  select x.natural_end, x.absorbed_s into r from public.show_rows(sess, '2026-10-16 18:01:31+08') x where x.cue_id = c[2];
  if to_char(r.natural_end at time zone 'Asia/Singapore', 'HH24:MI:SS') = '18:02:00' and r.absorbed_s = 30 then passed := passed + 1;
  else failures := failures || E'\nL5b ' || r::text; end if;
  select x.delay_s into n from public.show_rows(sess, '2026-10-16 18:01:31+08') x where x.cue_id = c[3];
  if n = 0 then passed := passed + 1; else failures := failures || E'\nL5c C3 delay after absorbing ' || n; end if;

  -- L6 a Manual cue waits for GO, told once
  perform public.zz_at(sess, '2026-10-16 18:02:01+08');
  perform public.zz_at(sess, '2026-10-16 18:02:09+08');
  select status || ' ' || wait_kind into t from public.show_cues where session_id = sess and cue_id = c[3];
  if t = 'pending go' then passed := passed + 1; else failures := failures || E'\nL6a ' || t; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'waiting_go';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nL6b waiting_go logged ' || n; end if;
  perform public.zz_as(u_marshal);
  j := public.show_board(sess);
  if (j ->> 'delay_s')::int = 9 then passed := passed + 1; else failures := failures || E'\nL6c delay ' || (j ->> 'delay_s'); end if;

  -- L7 two planners press GO: the first wins, the second is told who
  execute 'reset role';
  perform set_config('show.test_now', '2026-10-16 18:02:10+08', true);
  perform public.zz_as(u_planner);
  perform public.show_go(sess, c[3]);
  perform public.zz_as(u_root);
  err := public.zz_err(format('select public.show_go(%L, %L)', sess, c[3]));
  if err like '%already running: started at 18:02:10 by testuser1%' then passed := passed + 1; else failures := failures || E'\nL7a ' || err; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'go' and message like 'testuser1 pressed GO: C3 "Three" (10 s late).';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nL7b GO logged ' || n; end if;

  -- L8 "Auto when ready": Group A is not there -> it holds and says who; arrives -> it starts
  perform public.zz_at(sess, '2026-10-16 18:03:11+08');
  select status || ' ' || coalesce(wait_kind, '-') into t from public.show_cues where session_id = sess and cue_id = c[4];
  if t = 'pending groups' then passed := passed + 1; else failures := failures || E'\nL8a C4 ' || t; end if;
  select message into t from public.show_log where session_id = sess and kind = 'waiting_groups';
  if t like '%waiting for Group A%' then passed := passed + 1; else failures := failures || E'\nL8b ' || coalesce(t, 'none'); end if;
  execute 'reset role';
  insert into public.zone_presence (event_id, session_id, zone_id, user_id, group_id, entered_at, last_inside_at)
  values (ev, sess, z1, u_planner, g_a, '2026-10-16 18:03:05+08', '2026-10-16 18:03:30+08');
  perform public.zz_at(sess, '2026-10-16 18:03:20+08');   -- inside 15 s: not yet (needs 20 s)
  select status into t from public.show_cues where session_id = sess and cue_id = c[4];
  if t = 'pending' then passed := passed + 1; else failures := failures || E'\nL8c started too early ' || t; end if;
  perform public.zz_at(sess, '2026-10-16 18:03:26+08');
  t := public.zz_cue(sess, c[4]);
  if t = 'running 18:03:26--' then passed := passed + 1; else failures := failures || E'\nL8d ' || t; end if;

  -- L9 the cue before the anchor runs into it: at risk, told once
  perform set_config('show.test_now', '2026-10-16 18:03:40+08', true);
  perform public.zz_as(u_planner);
  perform public.show_add_time(sess, 60);
  perform public.zz_at(sess, '2026-10-16 18:03:41+08');
  perform public.zz_at(sess, '2026-10-16 18:03:50+08');
  select x.risk_s into n from public.show_rows(sess, '2026-10-16 18:03:50+08') x where x.cue_id = c[5];
  if n = 26 then passed := passed + 1; else failures := failures || E'\nL9a risk ' || n; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'anchor_risk';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nL9b risk alerts ' || n; end if;
  perform public.zz_as(u_marshal);
  j := public.show_board(sess);
  if (j -> 'anchor' ->> 'risk_s')::int = 26 then passed := passed + 1; else failures := failures || E'\nL9c board anchor ' || (j -> 'anchor')::text; end if;

  -- L10 the anchor starts on its time and cuts the cue before it
  perform public.zz_at(sess, '2026-10-16 18:05:02+08');
  t := public.zz_cue(sess, c[4]) || ' / ' || public.zz_cue(sess, c[5]);
  if t = 'done 18:03:26-18:05:00 / running 18:05:00--' then passed := passed + 1; else failures := failures || E'\nL10a ' || t; end if;
  select message into t from public.show_log where session_id = sess and kind = 'anchor_cut';
  if t like 'C4 "Four" was cut 26 s short%' then passed := passed + 1; else failures := failures || E'\nL10b ' || coalesce(t, 'none'); end if;

  -- L11 Hold: the running cue goes on, nothing moves on; Resume ends an overdue cue and moves on
  perform set_config('show.test_now', '2026-10-16 18:05:10+08', true);
  perform public.zz_as(u_root);
  perform public.show_hold(sess);
  err := public.zz_err(format('select public.show_hold(%L)', sess));
  if err like 'The show is already held (by Claude Test%' or err like 'The show is already held (by %' then passed := passed + 1; else failures := failures || E'\nL11a ' || err; end if;
  perform public.zz_at(sess, '2026-10-16 18:06:05+08');
  t := public.zz_cue(sess, c[5]) || ' / ' || public.zz_cue(sess, c[6]);
  if t = 'running 18:05:00-- / pending ---' then passed := passed + 1; else failures := failures || E'\nL11b held ' || t; end if;
  perform set_config('show.test_now', '2026-10-16 18:06:20+08', true);
  perform public.zz_as(u_root);
  perform public.show_resume(sess);
  execute 'reset role';
  t := public.zz_cue(sess, c[5]) || ' / ' || public.zz_cue(sess, c[6]);
  if t = 'done 18:05:00-18:06:20 / running 18:06:20--' then passed := passed + 1; else failures := failures || E'\nL11c resumed ' || t; end if;
  perform public.zz_as(u_root);
  err := public.zz_err(format('select public.show_resume(%L)', sess));
  if err like 'The show is not held%' then passed := passed + 1; else failures := failures || E'\nL11d ' || err; end if;

  -- L12 the end
  perform public.zz_at(sess, '2026-10-16 18:07:00+08');
  select finished_at is not null into b from public.show_state where session_id = sess;
  if b then passed := passed + 1; else failures := failures || E'\nL12a not finished'; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'finished';
  perform public.zz_at(sess, '2026-10-16 18:07:30+08');
  if n = 1 and (select count(*) from public.show_log where session_id = sess and kind = 'finished') = 1 then passed := passed + 1;
  else failures := failures || E'\nL12b finished logged ' || n; end if;
  perform public.zz_as(u_marshal);
  j := public.show_board(sess);
  if j ->> 'state' = 'finished' and jsonb_array_length(j -> 'cues') = 6 and jsonb_array_length(j -> 'log') >= 10 then passed := passed + 1;
  else failures := failures || E'\nL12c board ' || (j ->> 'state'); end if;

  -- L13 who may see
  perform public.zz_as(u_member);
  err := public.zz_err(format('select public.show_board(%L)', sess));
  if err like 'Only the root, planners and marshals%' then passed := passed + 1; else failures := failures || E'\nL13a member board ' || err; end if;
  select count(*) into n from public.show_cues where session_id = sess;
  if n = 0 then passed := passed + 1; else failures := failures || E'\nL13b member reads show_cues ' || n; end if;
  err := public.zz_err(format('select public.show_hold(%L)', sess));
  if err like 'Only the root or a planner%' then passed := passed + 1; else failures := failures || E'\nL13c member hold ' || err; end if;

  -- L14 catching up: no engine run from 17:59 to 18:05:30 -> everything at the time it should have happened
  perform public.zz_as(u_root);
  perform public.end_event(ev);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-10-16 17:59:00+08' where id = sess;
  perform public.zz_at(sess, '2026-10-16 18:05:30+08');
  t := public.zz_cue(sess, c[1]) || ' / ' || public.zz_cue(sess, c[2]) || ' / ' || public.zz_cue(sess, c[3]) || ' / ' ||
       public.zz_cue(sess, c[4]) || ' / ' || public.zz_cue(sess, c[5]);
  if t = 'done 18:00:00-18:01:00 / done 18:01:00-18:02:00 / skipped --- / skipped --- / running 18:05:00--' then passed := passed + 1;
  else failures := failures || E'\nL14a ' || t; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'waiting_go';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nL14b C3 waited for GO first ' || n; end if;
  select note into t from public.show_cues where session_id = sess and cue_id = c[3];
  if t = 'Skipped: the anchor C5 started first' then passed := passed + 1; else failures := failures || E'\nL14c ' || coalesce(t, 'none'); end if;

  -- L15 Skip and end-now
  perform set_config('show.test_now', '2026-10-16 18:05:40+08', true);
  perform public.zz_as(u_planner);
  perform public.show_skip(sess, c[6]);
  perform public.show_skip(sess, c[5]);   -- running: ends now
  execute 'reset role';
  t := public.zz_cue(sess, c[5]) || ' / ' || public.zz_cue(sess, c[6]);
  if t = 'done 18:05:00-18:05:40 / skipped ---' then passed := passed + 1; else failures := failures || E'\nL15a ' || t; end if;
  perform public.zz_as(u_planner);
  err := public.zz_err(format('select public.show_skip(%L, %L)', sess, c[6]));
  execute 'reset role';
  if err like '%has already been skipped%' then passed := passed + 1; else failures := failures || E'\nL15b ' || err; end if;
  select finished_at is not null into b from public.show_state where session_id = sess;
  if b then passed := passed + 1; else failures := failures || E'\nL15c finished after skip'; end if;

  -- L16 a session that starts late: nothing before its start, the show is behind
  perform public.zz_as(u_root);
  perform public.end_event(ev);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-10-16 18:00:40+08' where id = sess;
  perform public.zz_at(sess, '2026-10-16 18:00:41+08');
  t := public.zz_cue(sess, c[1]);
  if t = 'running 18:00:40--' then passed := passed + 1; else failures := failures || E'\nL16a ' || t; end if;
  select x.delay_s into n from public.show_rows(sess, '2026-10-16 18:00:41+08') x where x.cue_id = c[2];
  if n = 40 then passed := passed + 1; else failures := failures || E'\nL16b C2 delay ' || n; end if;

  -- L17 switching the live show to a copy carries the cues that ran (by code)
  perform public.zz_as(u_planner);
  sh2 := public.create_run_sheet(ev, 'Show engine test B', null, sh);
  perform public.save_cue(sh2, jsonb_build_object('id', (select id from public.cues where run_sheet_id = sh2 and code = 'C3'),
          'code', 'C3', 'title', 'Three (new)', 'start_time', '18:02:00', 'length_s', 45, 'start_mode', 'manual',
          'rev', (select rev from public.cues where run_sheet_id = sh2 and code = 'C3')));
  perform public.mark_run_sheet_ready(sh2);
  execute 'reset role';
  perform set_config('show.test_now', '2026-10-16 18:00:50+08', true);
  perform public.zz_as(u_root);
  perform public.switch_live_run_sheet(ev, sh2);
  select string_agg(c2.code || ':' || sc.status, ',' order by c2.position) into t
  from public.show_cues sc join public.cues c2 on c2.id = sc.cue_id where sc.session_id = sess and c2.run_sheet_id = sh2;
  if t = 'C1:running,C2:pending,C3:pending,C4:pending,C5:pending,C6:pending' then passed := passed + 1; else failures := failures || E'\nL17a ' || t; end if;
  select run_sheet_id = sh2 into b from public.show_state where session_id = sess;
  if b then passed := passed + 1; else failures := failures || E'\nL17b state not switched'; end if;
  perform public.zz_at(sess, '2026-10-16 18:02:05+08');
  select x.status || ' ' || x.length_s into t from public.show_rows(sess, '2026-10-16 18:02:05+08') x where x.code = 'C2';
  if t = 'running 60' then passed := passed + 1; else failures := failures || E'\nL17c C2 in the new version ' || t; end if;
  select count(*) into n from public.show_log where session_id = sess and kind = 'switch';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nL17d switch logged ' || n; end if;
  -- the old version's history stays
  select status into t from public.show_cues where session_id = sess and cue_id = c[1];
  if t = 'running' then passed := passed + 1; else failures := failures || E'\nL17e old version history ' || t; end if;

  -- L19 a session that started without a run sheet and switched one on later: cues planned before the switch are
  -- skipped (a late FIRST look by the engine does not do this: L14 caught up instead)
  perform public.zz_as(u_root);
  perform public.end_event(ev);
  sess := public.start_event(ev, null);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-10-16 17:59:00+08' where id = sess;
  perform public.zz_as(u_root);
  perform public.switch_live_run_sheet(ev, sh);
  execute 'reset role';
  select count(*) into n from public.show_cues sc join public.cues c2 on c2.id = sc.cue_id
  where sc.session_id = sess and c2.run_sheet_id = sh and sc.status = 'skipped'
    and sc.note in ('Planned before the run sheet was switched on', 'Missed: its fixed time 18:05:00 passed before the show started');
  if n = 6 then passed := passed + 1; else failures := failures || E'\nL19 skipped after a late switch-on ' || n; end if;

  -- L20 a session that starts after an anchor's fixed time: the anchor is missed, the cues before it still run
  perform public.zz_as(u_root);
  perform public.end_event(ev);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-10-16 18:05:30+08' where id = sess;
  perform public.zz_at(sess, '2026-10-16 18:05:31+08');
  select status || ' ' || coalesce(note, '') into t from public.show_cues where session_id = sess and cue_id = c[5];
  if t like 'skipped Missed: its fixed time 18:05:00 passed%' then passed := passed + 1; else failures := failures || E'\nL20a anchor ' || t; end if;
  t := public.zz_cue(sess, c[1]);
  if t = 'running 18:05:30--' then passed := passed + 1; else failures := failures || E'\nL20b C1 ' || t; end if;

  -- L18 the engine from pg_cron: no signed-in user, several shows, idle shows cost nothing
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('show.test_now', '', true);
  n := public.show_tick();
  if n >= 1 then passed := passed + 1; else failures := failures || E'\nL18 tick handled ' || n; end if;

  execute 'reset role';
  raise exception 'RESULT: % passed, % failed%', passed, (length(failures) - length(replace(failures, E'\n', ''))), failures;
end
$test$;
