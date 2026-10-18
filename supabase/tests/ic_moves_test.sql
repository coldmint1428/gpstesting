-- supabase/tests/ic_moves_test.sql -- merger Stage 8 (028_ic_moves.sql), run against the real project.
--
-- One transaction that ends with an exception, so nothing is kept (no push is sent either: the queued rows and the
-- pg_net request are rolled back). Readings with their own times on a future day go through the zone trigger; the show
-- clock is stepped and both engines run by hand, then the push collector, as move_tick does.
-- Accounts: claude_test and testuser1 are the 2 ICs of Group A (testuser1 has a phone registered for pushes); komin is
-- the IC, komin2 the admin and testuser3 a plain member of "P2"; testuser2 is made marshal.
--
-- 20 Nov 2026: C1 17:56:00 4:00 · C2 18:00:00 1:00 · C3 18:10:00 1:00. MA Group A -> FORMATION_1 by C2 (standing 120 m
-- north: leave by about 17:58:10); MB P2 -> FORMATION_1 by C3.
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
  g_a uuid := '84c7ca4b-c68c-4e8c-830e-fdcafadb904e';        -- Group A
  c_lat double precision := 1.30641608120455;
  c_lng double precision := 103.767534792423;
  g2 uuid; sh uuid; sess uuid; c uuid[]; ma uuid; mb uuid;
  ts timestamptz; l1 timestamptz; l2 timestamptz;
  k integer; n integer; t text; j jsonb; r record;
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
  -- both engines and the push collector at a moment (as move_tick does)
  execute $f$
    create function public.zz_at(p_session uuid, p_at timestamptz) returns integer language plpgsql as $b$
    begin
      execute 'reset role';
      perform set_config('show.test_now', p_at::text, true);
      perform public.show_step(p_session, p_at);
      perform public.move_step(p_session, p_at);
      return public.push_collect_moves(p_session, p_at);
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
    create function public.zz_read(p_event uuid, p_group uuid, p_user uuid, p_lat double precision, p_lng double precision, p_at timestamptz)
    returns void language sql as $b$
      insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
      values (p_event, p_group, p_user, p_lat, p_lng, 5, 'gps', p_at);
    $b$;
  $f$;
  -- queued pushes of a kind (and who for, by username)
  execute $f$
    create function public.zz_q(p_kind text) returns text language sql as $b$
      select coalesce(string_agg(p.username, ',' order by p.username), '') from public.push_queue q join public.profiles p on p.id = q.user_id
      where q.kind = p_kind;
    $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_err(text) to authenticated';

  -- fixtures
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant'),
    (ev, u_k1, 'participant'), (ev, u_k2, 'participant') on conflict do nothing;
  insert into public.groups (event_id, name, colour) values (ev, 'P2 test', '#198754') returning id into g2;
  insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
    (ev, g2, u_k1, true, false), (ev, g2, u_k2, false, true), (ev, g2, u_member, false, false);
  update public.event_sessions set ended_at = now() where event_id = ev and ended_at is null;
  delete from public.push_queue;   -- (this transaction only)

  perform public.zz_as(u_planner);
  sh := public.create_run_sheet(ev, 'IC pushes test');
  c := array[
    public.save_cue(sh, '{"code":"C1","title":"One","start_time":"17:56:00","length_s":240}'),
    public.save_cue(sh, '{"code":"C2","title":"Two","start_time":"18:00:00","length_s":60}'),
    public.save_cue(sh, '{"code":"C3","title":"Three","start_time":"18:10:00","length_s":60}')];
  ma := public.save_movement(sh, jsonb_build_object('code', 'MA', 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[2]));
  mb := public.save_movement(sh, jsonb_build_object('code', 'MB', 'group_id', g2, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c[3]));
  perform public.mark_run_sheet_ready(sh);
  perform public.zz_as(u_root);
  sess := public.start_event(ev, sh);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;

  -- Group A's 2 ICs and komin stand 120 m north of the zone's middle; then testuser1 walks into the No-Go CAR_PARK
  for k in 0 .. 360 by 10 loop
    ts := '2026-11-20 17:54:50+08'::timestamptz + make_interval(secs => k);
    perform public.zz_read(ev, g_a, u_root, c_lat + 120 / 111320.0, c_lng - 3 / 111320.0, ts);
    perform public.zz_read(ev, g_a, u_planner, c_lat + 120 / 111320.0, c_lng + 3 / 111320.0, ts);
    perform public.zz_read(ev, g2, u_k1, c_lat + 120 / 111320.0, c_lng, ts);
  end loop;
  perform public.zz_read(ev, g_a, u_planner, 1.30545015039468, c_lng, '2026-11-20 18:01:00+08');

  -- P1 leave by from the movements engine; nothing queued 61 s before it, "Get ready" to both ICs 60 s before
  perform public.zz_at(sess, '2026-11-20 17:55:00+08');
  select leave_by into l1 from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  if l1 between '2026-11-20 17:57:30+08' and '2026-11-20 17:58:50+08' then passed := passed + 1; else failures := failures || E'\nP1a leave by ' || l1; end if;
  perform public.zz_at(sess, l1 - interval '61 seconds');
  if public.zz_q('get_ready') = '' then passed := passed + 1; else failures := failures || E'\nP1b early ' || public.zz_q('get_ready'); end if;
  n := public.zz_at(sess, l1 - interval '60 seconds');
  select title || ' | ' || body into t from public.push_queue where kind = 'get_ready' and user_id = u_planner;
  if public.zz_q('get_ready') = 'claude_test,testuser1' and n = 2 and t = 'Get ready: leave at ' || public.sg_hms(l1) ||
     ' | Head to ' || (select name from public.zones where id = z1) || ' (FORMATION_1). Be inside by 18:00:00.'
  then passed := passed + 1; else failures := failures || E'\nP1c ' || public.zz_q('get_ready') || ' ' || n || ' / ' || coalesce(t, 'none'); end if;
  select data ->> 'kind' || '|' || (data ->> 'eventId') || '|' || (data ->> 'tag') into t from public.push_queue where kind = 'get_ready' and user_id = u_planner;
  if t = 'move|' || ev || '|move-MA-' || g_a then passed := passed + 1; else failures := failures || E'\nP1d data ' || t; end if;

  -- P2 +30 s on the running cue moves the leave by: nothing at the old time, "Leave now" at the new one, once
  perform set_config('show.test_now', (l1 - interval '40 seconds')::text, true);
  update public.event_sessions set starts_at = now() - interval '1 minute' where id = sess; -- the buttons need a live session
  perform public.zz_as(u_planner);
  perform public.show_add_time(sess, 30);
  execute 'reset role';
  update public.event_sessions set starts_at = '2026-11-20 17:50:00+08' where id = sess;
  perform public.zz_at(sess, l1 - interval '35 seconds');
  select leave_by into l2 from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  if l2 = l1 + interval '30 seconds' then passed := passed + 1; else failures := failures || E'\nP2a leave by after +30 s ' || l2 || ' was ' || l1; end if;
  perform public.zz_at(sess, l1);
  if public.zz_q('leave_now') = '' then passed := passed + 1; else failures := failures || E'\nP2b at the old time ' || public.zz_q('leave_now'); end if;
  n := public.zz_at(sess, l2);
  select title || ' | ' || body into t from public.push_queue where kind = 'leave_now' and user_id = u_root;
  if public.zz_q('leave_now') = 'claude_test,testuser1' and t like 'Leave now for % | Be inside FORMATION_1 by 18:00:30 · % m to go.'
  then passed := passed + 1; else failures := failures || E'\nP2c ' || public.zz_q('leave_now') || ' / ' || coalesce(t, 'none'); end if;
  n := public.zz_at(sess, l2 + interval '4 seconds');
  if n = 0 and (select count(*) from public.push_queue where kind = 'leave_now') = 2 then passed := passed + 1; else failures := failures || E'\nP2d sent twice ' || n; end if;

  -- P3 still standing: late after 2 looks, but "Running late" only a minute after the leave-by (a group that has just
  -- set off is not seen moving yet); then once, to both
  perform public.zz_at(sess, l2 + interval '10 seconds');
  perform public.zz_at(sess, l2 + interval '15 seconds');
  perform public.zz_at(sess, l2 + interval '20 seconds');
  select status into t from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  if t = 'late' and public.zz_q('late') = '' then passed := passed + 1; else failures := failures || E'\nP3 grace ' || t || ' / ' || public.zz_q('late'); end if;
  perform public.zz_at(sess, l2 + interval '60 seconds');
  select status into t from public.movement_status where session_id = sess and movement_id = ma and group_id = g_a;
  select body into err from public.push_queue where kind = 'late' and user_id = u_planner;
  if t = 'late' and public.zz_q('late') = 'claude_test,testuser1' and err like 'At your pace you arrive %:% late (be inside FORMATION_1 by 18:00:30). Tell your planner if you are held up.'
  then passed := passed + 1; else failures := failures || E'\nP3a ' || t || ' / ' || public.zz_q('late') || ' / ' || coalesce(err, 'none'); end if;
  perform public.zz_at(sess, l2 + interval '65 seconds');
  if (select count(*) from public.push_queue where kind = 'late') = 2 then passed := passed + 1; else failures := failures || E'\nP3b late twice'; end if;

  -- P4 a group that is already on its way gets no "Leave now"; the IC and the admin do, a plain member does not
  update public.movement_status set leave_by = '2026-11-20 18:00:10+08', moving_since = '2026-11-20 17:59:00+08'
  where session_id = sess and movement_id = mb and group_id = g2;
  n := public.push_collect_moves(sess, '2026-11-20 18:00:20+08');
  if n = 0 then passed := passed + 1; else failures := failures || E'\nP4a moving group pushed ' || n; end if;
  update public.movement_status set moving_since = null where session_id = sess and movement_id = mb and group_id = g2;
  n := public.push_collect_moves(sess, '2026-11-20 18:00:20+08');
  select string_agg(p.username, ',' order by p.username) into t from public.push_queue q join public.profiles p on p.id = q.user_id
  where q.kind = 'leave_now' and q.data ->> 'groupId' = g2::text;
  if n = 2 and t = 'komin,komin2' then passed := passed + 1; else failures := failures || E'\nP4b ' || n || ' ' || coalesce(t, 'none'); end if;

  -- P5 a planner's message: a push to the group's IC and admin (not the plain member), once each
  perform public.zz_as(u_planner);
  perform public.message_group(sess, g2, 'Move to the gate now');
  execute 'reset role';
  select string_agg(p.username || ':' || q.title || ':' || q.body, ',' order by p.username) into t
  from public.push_queue q join public.profiles p on p.id = q.user_id where q.kind = 'message';
  if t = 'komin:Message from testuser1:Move to the gate now,komin2:Message from testuser1:Move to the gate now' then passed := passed + 1;
  else failures := failures || E'\nP5 ' || coalesce(t, 'none'); end if;

  -- P6 a No-Go entry: a push to the IC who walked in (not in simulation events)
  -- (only this test's entry: a real No-Go entry of the last 2 minutes would be queued too)
  n := public.push_collect_nogo();
  select q.title || ' | ' || q.body into t from public.push_queue q
  where q.dedup = 'nogo:' || (select a.id from public.zone_alerts a where a.event_id = ev and a.user_id = u_planner
                                and a.at = '2026-11-20 18:01:00+08');
  if n >= 1 and t = 'You are in a No-Go area | Please leave ' || (select name from public.zones where code = 'CAR_PARK' and event_id = ev) || ' (CAR_PARK) now.'
  then passed := passed + 1; else failures := failures || E'\nP6a ' || n || ' / ' || coalesce(t, 'none'); end if;
  n := public.push_collect_nogo();
  update public.events set is_simulation = true where id = ev;
  perform public.zz_read(ev, g_a, u_root, 1.30545015039468, c_lng, '2026-11-20 18:01:10+08');
  k := public.push_collect_nogo();
  update public.events set is_simulation = false where id = ev;
  if n = 0 and k = 0 and (select count(*) from public.zone_alerts where event_id = ev and user_id = u_root and at = '2026-11-20 18:01:10+08') = 1
  then passed := passed + 1; else failures := failures || E'\nP6b again ' || n || ', simulation ' || k; end if;

  -- P7 the Edge Function's claim: every unsent push once, one row per registered phone (only testuser1 has one)
  select count(*) into n from public.push_queue where sent_at is null;
  select count(*) into k from public.claim_push_queue(500);
  if k = (select count(*) from public.push_queue where user_id = u_planner) and (select count(*) from public.push_queue where sent_at is null) = 0 and n > k
  then passed := passed + 1; else failures := failures || E'\nP7a claimed ' || k || ' of ' || n; end if;
  if (select count(*) from public.claim_push_queue(500)) = 0 and not public.push_due() then passed := passed + 1; else failures := failures || E'\nP7b claimed twice'; end if;

  -- P8 my_moves: a member reads their group's movements (zone, cue); someone without a group is refused
  perform public.zz_as(u_planner);
  j := public.my_moves(sess);
  if jsonb_array_length(j -> 'rows') = 1 and j -> 'rows' -> 0 ->> 'zone_code' = 'FORMATION_1' and j -> 'rows' -> 0 ->> 'cue_code' = 'C2'
     and j -> 'rows' -> 0 -> 'zone' ->> 'type' = 'Polygon' and (j ->> 'group_id')::uuid = g_a then passed := passed + 1;
  else failures := failures || E'\nP8a ' || left(j::text, 300); end if;
  perform public.zz_as(u_member);
  j := public.my_moves(sess);
  if jsonb_array_length(j -> 'rows') = 1 and (j -> 'rows' -> 0 ->> 'movement_id')::uuid = mb then passed := passed + 1; else failures := failures || E'\nP8b member ' || left(j::text, 200); end if;
  perform public.zz_as(u_marshal);
  err := public.zz_err(format('select public.my_moves(%L)', sess));
  if err like 'You are not in a group of this event%' then passed := passed + 1; else failures := failures || E'\nP8c ' || err; end if;

  -- P9 Tell planner: delayed (any member of the group, once a minute; since 029 ops can pass on one heard on the radio);
  --    planners see it on the board and in the log
  perform public.zz_as(u_k1);
  err := public.zz_err(format('select public.report_delay(%L, %L, %L, %L)', sess, ma, g_a, 'x'));
  if err like 'Only a member of this group%' then passed := passed + 1; else failures := failures || E'\nP9a other group ' || err; end if;
  perform public.zz_as(u_member);
  perform public.report_delay(sess, mb, g2, '  Stuck at the gate  ');
  err := public.zz_err(format('select public.report_delay(%L, %L, %L, null)', sess, mb, g2));
  if err like 'Already told at % by testuser3.%' then passed := passed + 1; else failures := failures || E'\nP9b twice ' || err; end if;
  perform public.zz_as(u_marshal);
  j := public.ops_board(sess);
  select e into j from jsonb_array_elements(j -> 'rows') e where (e ->> 'movement_id')::uuid = mb;
  if j ->> 'delay_note' = 'Stuck at the gate' and j ->> 'delay_by' = 'testuser3' and j ? 'delay_at' then passed := passed + 1;
  else failures := failures || E'\nP9c board ' || coalesce(j::text, 'none'); end if;
  execute 'reset role';
  select message into t from public.show_log where session_id = sess and kind = 'delay_report';
  if t = 'P2 test reports a delay (testuser3): "Stuck at the gate" · due in FORMATION_1 by 18:10:00.' then passed := passed + 1;
  else failures := failures || E'\nP9d log ' || coalesce(t, 'none'); end if;
  -- acknowledged by a marshal: stays acknowledged although the group is on track (the engine keeps the answer)
  perform public.zz_as(u_marshal);
  perform public.ops_ack(sess, mb, g2);
  perform public.zz_at(sess, '2026-11-20 18:01:20+08');
  perform public.zz_at(sess, '2026-11-20 18:01:25+08');
  select status, acked_status into r from public.movement_status where session_id = sess and movement_id = mb and group_id = g2;
  if r.status = 'on_track' and r.acked_status = 'on_track' then passed := passed + 1; else failures := failures || E'\nP9e ' || r::text; end if;

  -- P10 who may call what
  perform public.zz_as(u_planner);
  err := public.zz_err('select count(*) from public.push_queue');
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nP10a queue readable: ' || err; end if;
  err := public.zz_err('select public.claim_push_queue(5)');
  t := public.zz_err('select public.push_collect_nogo()');
  if err like '%permission denied%' and t like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nP10b ' || err || ' / ' || t; end if;
  err := public.zz_err('select public.push_kick()');
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nP10c ' || err; end if;

  -- P11 the cron jobs' statements run (nothing live outside this transaction)
  execute 'reset role';
  perform public.push_collect_nogo();
  perform public.push_kick();
  n := public.move_tick();
  passed := passed + 1;

  raise exception 'RESULTS: % passed, failures: %', passed, coalesce(nullif(failures, ''), 'none');
end $test$;
