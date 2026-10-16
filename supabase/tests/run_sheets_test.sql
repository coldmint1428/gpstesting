-- supabase/tests/run_sheets_test.sql -- merger Stage 4 (024_run_sheets.sql), run against the real project.
--
-- Everything runs in ONE transaction that ends with an exception, so nothing it creates is kept: the result
-- comes back as the error text ("RESULT: n passed, m failed" and a line per failure). Paste it into the SQL
-- editor (or run it through the Supabase tool). Accounts and event are the test ones in README.md:
--   claude_test (root of "Playback test (Claude)"), testuser1 (planner there), testuser2 (made marshal here),
--   testuser3 (made a plain member here), komin2 (not in the event).
do $test$
declare
  ev uuid := '4395abec-16b6-44a0-b4a1-5f7fd6e5df49';     -- Playback test (Claude)
  other_ev uuid := '6746043e-d969-4b3b-b649-3a4fbc391ea5'; -- NDP sim run 1
  u_root uuid := 'cd87c144-9524-4558-9ec5-bc59694b6b0e';
  u_planner uuid := 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';
  u_marshal uuid := 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5';
  u_member uuid := '2906655b-33ad-4e9d-a608-f083e43e22d4';
  u_out uuid := '47a6bc75-d98d-40e2-a795-147092c99977';
  z1 uuid := '2d88456f-a7a6-4901-a794-307ef1476b7c';      -- FORMATION_1
  z2 uuid := '88453a3f-095f-43d9-b009-74357742a452';      -- STAGE_LEFT
  z_nogo uuid := 'ea629864-29c6-4395-ab92-597f861dade1';  -- CAR_PARK (No-Go)
  z_other uuid := 'd2f48a3c-1811-46a7-9a15-c9e6a2c35941'; -- FORMATION_A of another event
  g_a uuid := '84c7ca4b-c68c-4e8c-830e-fdcafadb904e';     -- Group A (has ICs)
  g_b1 uuid; g_b2 uuid; g_b3 uuid; g_other uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; c1 uuid; c2 uuid; c3 uuid; c_anchor uuid; m1 uuid; m_cat uuid; x_skip uuid; x_alt uuid;
  n integer; t text; r record; v_rev integer; sess uuid; b boolean;
  passed integer := 0;
  failures text := '';
  res text;
begin
  -- ---------- helpers (created here, rolled back with everything else) ----------
  execute $f$
    create function public.zz_as(p uuid) returns void language plpgsql as $b$
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    end $b$;
  $f$;
  execute $f$
    create function public.zz_err(p_sql text, p_needle text) returns text language plpgsql as $b$
    begin
      execute p_sql;
      return 'FAIL no error: ' || left(p_sql, 120);
    exception when others then
      if position(lower(p_needle) in lower(sqlerrm)) > 0 then return 'ok'; end if;
      return 'FAIL wrong error "' || sqlerrm || '" for: ' || left(p_sql, 100);
    end $b$;
  $f$;
  execute $f$
    create function public.zz_ok(p_sql text) returns text language plpgsql as $b$
    begin
      execute p_sql;
      return 'ok';
    exception when others then
      return 'FAIL "' || sqlerrm || '" for: ' || left(p_sql, 100);
    end $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_err(text, text), public.zz_ok(text) to authenticated';

  -- ---------- fixtures (as the database owner) ----------
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant')
  on conflict do nothing;
  insert into public.groups (event_id, name, colour, category) values (ev, 'Band 1', '#0d6efd', 'Bands') returning id into g_b1;
  insert into public.groups (event_id, name, colour, category) values (ev, 'Band 2', '#198754', 'bands') returning id into g_b2;
  insert into public.groups (event_id, name, colour, category) values (ev, 'Band 3', '#dc3545', 'Bands') returning id into g_b3;
  insert into public.group_members (event_id, group_id, user_id, is_ic) values (ev, g_b1, u_member, true);
  select id into g_other from public.groups where event_id <> ev limit 1;
  update public.event_sessions set ended_at = now() where event_id = ev and ended_at is null;
  delete from public.run_sheets where event_id = ev; -- start from none (versions made by hand while testing the page)

  -- R1 roles: who may see and change
  perform public.zz_as(u_planner);
  s1 := public.create_run_sheet(ev, 'Rehearsal 1', '2026-07-12');
  if s1 is not null then passed := passed + 1; else failures := failures || E'\nR1a planner could not create'; end if;

  perform public.zz_as(u_marshal);
  select count(*) into n from public.run_sheet_list(ev);
  if n = 1 then passed := passed + 1; else failures := failures || E'\nR1b marshal list count ' || n; end if;
  select count(*) into n from public.check_run_sheet(s1);
  if n >= 1 then passed := passed + 1; else failures := failures || E'\nR1c marshal could not check'; end if;
  res := public.zz_err(format('select public.create_run_sheet(%L, %L)', ev, 'M sheet'), 'only the root or a planner');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1d marshal create ' || res; end if;
  res := public.zz_err(format('select public.save_cue(%L, %L)', s1, '{"title":"x","start_time":"18:00"}'), 'only the root or a planner');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1e marshal save_cue ' || res; end if;

  perform public.zz_as(u_member);
  res := public.zz_err(format('select * from public.run_sheet_list(%L)', ev), 'only the root, planners and marshals');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1f member list ' || res; end if;
  select count(*) into n from public.run_sheets where event_id = ev;
  if n = 0 then passed := passed + 1; else failures := failures || E'\nR1g member sees rows via table: ' || n; end if;
  res := public.zz_err(format('select * from public.run_sheet_moves(%L)', s1), 'only the root, planners and marshals');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1h member moves ' || res; end if;

  perform public.zz_as(u_out);
  res := public.zz_err(format('select * from public.check_run_sheet(%L)', s1), 'only the root, planners and marshals');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1i outsider check ' || res; end if;
  res := public.zz_err(format('select public.delete_run_sheet(%L)', s1), 'only the root or a planner');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1j outsider delete ' || res; end if;
  res := public.zz_err(format('insert into public.cues (run_sheet_id, position, code, title, start_time) values (%L, 1, %L, %L, %L)', s1, 'C99', 'x', '18:00'), '');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR1k outsider direct insert ' || res; end if;

  -- R2 names
  perform public.zz_as(u_planner);
  for t in select unnest(array['', '   ', repeat('x', 61)]) loop
    res := public.zz_err(format('select public.create_run_sheet(%L, %L)', ev, t), 'give the version a name');
    if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR2a bad name ' || res; end if;
  end loop;
  res := public.zz_err(format('select public.create_run_sheet(%L, %L)', ev, ' rehearsal 1 '), 'already a version called');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR2b duplicate name ' || res; end if;
  s2 := public.create_run_sheet(ev, 'NDP Day', '2026-08-09');
  res := public.zz_err(format('select public.update_run_sheet(%L, %L, null)', s2, 'REHEARSAL 1'), 'already a version called');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR2c rename to duplicate ' || res; end if;
  res := public.zz_err(format('select public.create_run_sheet(%L, %L, null, %L)', ev, 'Copy x', gen_random_uuid()), 'not in this event');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR2d copy from unknown ' || res; end if;

  -- R3 cues
  c1 := public.save_cue(s1, '{"section":"Pre-show","title":"Gates open","start_time":"17:00:00","length_s":"1800"}');
  c2 := public.save_cue(s1, '{"section":"Pre-show","title":"Warm up","start_time":"17:30","length_s":"600","type":"flexible","can_shorten_s":"300"}');
  select code into t from public.cues where id = c1;
  if t = 'C01' then passed := passed + 1; else failures := failures || E'\nR3a first code ' || t; end if;
  for r in select * from (values
      ('{"title":"x","start_time":"25:00"}', 'start must be a time'),
      ('{"title":"x","start_time":"abc"}', 'start must be a time'),
      ('{"title":"","start_time":"18:00"}', 'give the cue a name'),
      ('{"title":"x"}', 'give the cue a start time'),
      ('{"title":"x","start_time":"18:00","length_s":"-5"}', 'length (seconds) must be between'),
      ('{"title":"x","start_time":"18:00","length_s":"1.5"}', 'must be a whole number'),
      ('{"title":"x","start_time":"18:00","length_s":"60","type":"flexible","can_shorten_s":"90"}', 'cannot shorten by more'),
      ('{"title":"x","start_time":"18:00","type":"weird"}', 'unknown cue type'),
      ('{"title":"x","start_time":"18:00","code":"C01"}', 'already has the code'),
      ('{"title":"x","start_time":"18:00","code":"bad code!"}', 'a code is 1 to 20')
    ) as v(j, needle) loop
    res := public.zz_err(format('select public.save_cue(%L, %L)', s1, r.j), r.needle);
    if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR3b ' || r.j || ' ' || res; end if;
  end loop;
  c_anchor := public.save_cue(s1, '{"title":"Broadcast","start_time":"17:35","length_s":"30","type":"anchor","start_mode":"manual"}');
  select start_mode into t from public.cues where id = c_anchor;
  if t = 'auto' then passed := passed + 1; else failures := failures || E'\nR3c anchor mode ' || t; end if;
  c3 := public.save_cue(s1, '{"title":"Normal","start_time":"18:00","length_s":"60","type":"normal","can_shorten_s":"30","after_position":"1"}');
  select can_shorten_s, position into r from public.cues where id = c3;
  if r.can_shorten_s = 0 and r.position = 2 then passed := passed + 1; else failures := failures || E'\nR3d normal shorten/insert pos ' || r::text; end if;
  select string_agg(title, '|' order by position) into t from public.cues where run_sheet_id = s1;
  if t = 'Gates open|Normal|Warm up|Broadcast' then passed := passed + 1; else failures := failures || E'\nR3e order after insert ' || t; end if;
  perform public.move_cue(c3, 1);
  perform public.move_cue(c1, -1);
  select string_agg(title, '|' order by position) into t from public.cues where run_sheet_id = s1;
  if t = 'Gates open|Warm up|Normal|Broadcast' then passed := passed + 1; else failures := failures || E'\nR3f move ' || t; end if;
  perform public.delete_cue(c3);
  select string_agg(position::text, ',' order by position) into t from public.cues where run_sheet_id = s1;
  if t = '1,2,3' then passed := passed + 1; else failures := failures || E'\nR3g positions after delete ' || t; end if;
  select rev into v_rev from public.cues where id = c1;
  perform public.save_cue(s1, jsonb_build_object('id', c1, 'rev', v_rev, 'title', 'Gates open', 'start_time', '17:00', 'length_s', 1800));
  res := public.zz_err(format('select public.save_cue(%L, %L)', s1, jsonb_build_object('id', c1, 'rev', v_rev, 'title', 'stale', 'start_time', '17:00')), 'someone else changed this cue');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR3h stale cue ' || res; end if;
  -- the stale error must not be 40001: PostgREST retries that code forever and the save hangs
  begin
    perform public.save_cue(s1, jsonb_build_object('id', c1, 'rev', v_rev, 'title', 'stale', 'start_time', '17:00'));
    t := 'no error';
  exception when others then
    t := sqlstate;
  end;
  if t = 'PT409' then passed := passed + 1; else failures := failures || E'\nR3i stale sqlstate ' || t; end if;

  -- R4 movements
  for r in select * from (values
      ('{}', 'pick who moves'),
      (format('{"group_id":"%s","category":"Bands"}', g_a), 'pick who moves'),
      (format('{"group_id":"%s"}', g_other), 'not in this event'),
      (format('{"group_id":"%s","zone_id":"%s"}', g_a, z_other), 'zone is not in this event'),
      (format('{"group_id":"%s","zone_id":"%s"}', g_a, z_nogo), 'no-go zone'),
      (format('{"group_id":"%s","zone_id":"%s","cue_id":"%s"}', g_a, z1, gen_random_uuid()), 'not in this version'),
      (format('{"group_id":"%s","pace_mps":"fast"}', g_a), 'pace must be a number'),
      (format('{"group_id":"%s","pace_mps":"0"}', g_a), 'pace must be more than 0'),
      (format('{"group_id":"%s","early_s":"9000"}', g_a), 'arrive early by'),
      (format('{"group_id":"%s","fixed_time":"7pm","deadline_kind":"fixed"}', g_a), 'fixed time must be a time')
    ) as v(j, needle) loop
    res := public.zz_err(format('select public.save_movement(%L, %L)', s1, r.j), r.needle);
    if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR4a ' || r.j || ' ' || res; end if;
  end loop;
  m1 := public.save_movement(s1, jsonb_build_object('group_id', g_a, 'zone_id', z1, 'deadline_kind', 'cue_start', 'cue_id', c2, 'early_s', 120));
  m_cat := public.save_movement(s1, jsonb_build_object('category', 'BANDS', 'zone_id', z2, 'deadline_kind', 'cue_end', 'cue_id', c2));
  select code into t from public.movements where id = m_cat;
  if t = 'M02' then passed := passed + 1; else failures := failures || E'\nR4b category code ' || t; end if;
  perform public.save_movement(s1, jsonb_build_object('id', m1, 'group_id', g_a, 'zone_id', z1, 'deadline_kind', 'fixed', 'cue_id', c2, 'fixed_time', '17:20'));
  select (cue_id is null and fixed_time = '17:20') into b from public.movements where id = m1;
  if b then passed := passed + 1; else failures := failures || E'\nR4c fixed keeps cue'; end if;
  res := public.zz_err(format('select public.save_movement(%L, %L)', s1, jsonb_build_object('parent_id', m1, 'group_id', g_a)), 'exception belongs to a movement for a category');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR4d exception of group movement ' || res; end if;
  res := public.zz_err(format('select public.save_movement(%L, %L)', s1, jsonb_build_object('parent_id', m_cat, 'group_id', g_a)), 'pick a group of the category');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR4e exception for outside group ' || res; end if;
  x_skip := public.save_movement(s1, jsonb_build_object('parent_id', m_cat, 'group_id', g_b2, 'skip', true));
  x_alt := public.save_movement(s1, jsonb_build_object('parent_id', m_cat, 'group_id', g_b3, 'zone_id', z1, 'deadline_kind', 'cue_end', 'cue_id', c2, 'early_s', 60));
  res := public.zz_err(format('select public.save_movement(%L, %L)', s1, jsonb_build_object('parent_id', m_cat, 'group_id', g_b3)), 'already has an exception');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR4f second exception ' || res; end if;
  select string_agg(g.name || '>' || (select code from public.zones where id = e.zone_id) || (case when e.is_exception then '*' else '' end), ',' order by g.name)
  into t from public.run_sheet_moves(s1) e join public.groups g on g.id = e.group_id;
  if t = 'Band 1>STAGE_LEFT,Band 3>FORMATION_1*,Group A>FORMATION_1' then passed := passed + 1; else failures := failures || E'\nR4g expansion ' || t; end if;
  res := public.zz_err(format('select public.save_movement(%L, %L)', s1, jsonb_build_object('id', x_skip, 'group_id', g_b2)), 'cannot be turned into an exception');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR4h exception to plain ' || res; end if;

  -- R5 check
  select string_agg(severity || ':' || left(message, 40), ' | ' order by severity, message) into t from public.check_run_sheet(s1);
  if t like '%error:This anchor starts at 17:35:00 but "Warm%' then passed := passed + 1; else failures := failures || E'\nR5a anchor overlap: ' || coalesce(t, 'none'); end if;
  if t like '%has no IC%' then passed := passed + 1; else failures := failures || E'\nR5b no-IC warning: ' || coalesce(t, 'none'); end if;
  if t not like '%Band 2%' then passed := passed + 1; else failures := failures || E'\nR5c skipped group checked: ' || t; end if;
  res := public.zz_err(format('select public.mark_run_sheet_ready(%L)', s1), 'fix 1 problem first');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR5d ready with error ' || res; end if;
  select rev into v_rev from public.cues where id = c_anchor;
  perform public.save_cue(s1, jsonb_build_object('id', c_anchor, 'rev', v_rev, 'title', 'Broadcast', 'start_time', '17:40', 'length_s', 30, 'type', 'anchor'));
  select count(*) into n from public.check_run_sheet(s1) where severity = 'error';
  if n = 0 then passed := passed + 1; else failures := failures || E'\nR5e errors left ' || n; end if;
  s3 := public.create_run_sheet(ev, 'Scratch');
  select string_agg(message, '|') into t from public.check_run_sheet(s3);
  if t = 'Add at least one cue.' then passed := passed + 1; else failures := failures || E'\nR5f empty: ' || coalesce(t, 'none'); end if;
  perform public.save_cue(s3, '{"title":"B","start_time":"18:00","length_s":"0"}');
  perform public.save_cue(s3, '{"title":"A","start_time":"17:00","length_s":"60"}');
  c3 := public.save_cue(s3, '{"title":"Late","start_time":"00:10","day_offset":"1","length_s":"60"}');
  perform public.save_movement(s3, jsonb_build_object('group_id', g_a, 'deadline_kind', 'cue_start', 'cue_id', c3, 'pace_mps', 5));
  perform public.save_movement(s3, jsonb_build_object('category', 'Nobody', 'zone_id', z1, 'deadline_kind', 'fixed', 'fixed_time', '18:00'));
  perform public.save_movement(s3, jsonb_build_object('group_id', g_b1, 'zone_id', z1, 'deadline_kind', 'fixed', 'fixed_time', '19:00', 'min_ics', 3));
  perform public.save_movement(s3, jsonb_build_object('group_id', g_b1, 'zone_id', z2, 'deadline_kind', 'fixed', 'fixed_time', '19:00'));
  select string_agg(message, ' | ' order by message) into t from public.check_run_sheet(s3);
  if t like '%Has no length%' then passed := passed + 1; else failures := failures || E'\nR5g zero length: ' || t; end if;
  if t like '%before "B" above it%' then passed := passed + 1; else failures := failures || E'\nR5h order: ' || t; end if;
  if t not like '%"Late"%' and t not like '%00:10%' then passed := passed + 1; else failures := failures || E'\nR5i next-day cue flagged: ' || t; end if;
  if t like '%pick the zone%' and t like '%walking pace of 5.00%' then passed := passed + 1; else failures := failures || E'\nR5j zone/pace: ' || t; end if;
  if t like '%no group has the category "Nobody"%' then passed := passed + 1; else failures := failures || E'\nR5k empty category: ' || t; end if;
  if t like '%needs 3 ICs inside but Band 1 has only 1%' then passed := passed + 1; else failures := failures || E'\nR5l min ICs: ' || t; end if;
  if t like '%send Band 1 to two different zones%' then passed := passed + 1; else failures := failures || E'\nR5m conflict: ' || t; end if;
  perform public.delete_cue(c3);
  select string_agg(message, ' | ') into t from public.check_run_sheet(s3);
  if t like '%pick the cue it is timed to%' then passed := passed + 1; else failures := failures || E'\nR5n deleted cue: ' || t; end if;

  -- R6 ready, draft again on edit
  n := public.mark_run_sheet_ready(s1);
  select status into t from public.run_sheet_list(ev) where id = s1;
  if t = 'ready' then passed := passed + 1; else failures := failures || E'\nR6a status ' || t; end if;
  perform public.save_cue(s1, '{"title":"Extra","start_time":"19:00","length_s":"60"}');
  select status into t from public.run_sheet_list(ev) where id = s1;
  if t = 'draft' then passed := passed + 1; else failures := failures || E'\nR6b edit keeps ready: ' || t; end if;
  perform public.mark_run_sheet_ready(s1);

  -- R7 start / schedule / used
  perform public.zz_as(u_root);
  res := public.zz_err(format('select public.start_event(%L, %L)', ev, s3), 'is still a draft');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7a start with draft ' || res; end if;
  res := public.zz_err(format('select public.start_event(%L, %L)', other_ev, s1), '');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7b start other event sheet ' || res; end if;
  sess := public.schedule_event_start(ev, now() + interval '2 days', s1);
  select (scheduled_at is not null and status = 'ready') into b from public.run_sheet_list(ev) where id = s1;
  if b then passed := passed + 1; else failures := failures || E'\nR7c scheduled shows'; end if;
  res := public.zz_err(format('select public.delete_run_sheet(%L)', s1), 'picked for the scheduled start');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7d delete scheduled ' || res; end if;
  sess := public.start_event(ev, s1);
  select status, live into r from public.run_sheet_list(ev) where id = s1;
  if r.status = 'used' and r.live then passed := passed + 1; else failures := failures || E'\nR7e used/live ' || r::text; end if;
  res := public.zz_err(format('select public.save_cue(%L, %L)', s1, '{"title":"x","start_time":"18:00"}'), 'already ran on');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7f edit used ' || res; end if;
  res := public.zz_err(format('select public.delete_cue(%L)', c1), 'already ran on');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7g delete cue of used ' || res; end if;
  res := public.zz_err(format('select public.mark_run_sheet_ready(%L)', s1), 'already ran on');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7h ready on used ' || res; end if;
  res := public.zz_err(format('select public.delete_run_sheet(%L)', s1), 'kept as a record');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7i delete used ' || res; end if;
  res := public.zz_ok(format('select public.update_run_sheet(%L, %L, %L)', s1, 'Rehearsal 1 (12 Jul)', '2026-07-12'));
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7j rename used ' || res; end if;
  res := public.zz_err(format('select public.switch_live_run_sheet(%L, %L)', ev, s3), 'is still a draft');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7k switch to draft ' || res; end if;
  s2 := public.create_run_sheet(ev, 'Rehearsal 2', '2026-07-19', s1);
  select count(*) into n from public.cues where run_sheet_id = s2;
  if n = (select count(*) from public.cues where run_sheet_id = s1) then passed := passed + 1; else failures := failures || E'\nR7l copied cues ' || n; end if;
  select count(*) into n from public.movements m where m.run_sheet_id = s2
    and (m.cue_id is null or exists (select 1 from public.cues c where c.id = m.cue_id and c.run_sheet_id = s2))
    and (m.parent_id is null or exists (select 1 from public.movements p where p.id = m.parent_id and p.run_sheet_id = s2));
  if n = 4 then passed := passed + 1; else failures := failures || E'\nR7m copied movements re-linked ' || n; end if;
  select status into t from public.run_sheet_list(ev) where id = s2;
  if t = 'draft' then passed := passed + 1; else failures := failures || E'\nR7n copy status ' || t; end if;
  perform public.mark_run_sheet_ready(s2);
  perform public.switch_live_run_sheet(ev, s2);
  select run_sheet_id = s2 into b from public.event_sessions where id = sess;
  if b then passed := passed + 1; else failures := failures || E'\nR7o switch live'; end if;
  -- the version that ran before the switch stays Used (locked, a record)
  select status into t from public.run_sheet_list(ev) where id = s1;
  if t = 'used' then passed := passed + 1; else failures := failures || E'\nR7r switched-away version status ' || t; end if;
  res := public.zz_err(format('select public.save_cue(%L, %L)', s1, '{"title":"x","start_time":"18:00"}'), 'already ran on');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7s edit switched-away version ' || res; end if;
  res := public.zz_err(format('select public.delete_run_sheet(%L)', s1), 'kept as a record');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7t delete switched-away version ' || res; end if;
  res := public.zz_err(format('select public.switch_live_run_sheet(%L, %L)', ev, s2), 'already running that version');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7u switch to same ' || res; end if;
  select string_agg(coalesce(name, '-'), ' > ' order by from_at) into t from public.session_run_sheets(ev) where session_id = sess;
  if t = 'Rehearsal 1 (12 Jul) > Rehearsal 2' then passed := passed + 1; else failures := failures || E'\nR7v ran with ' || coalesce(t, 'none'); end if;
  perform public.zz_as(u_member);
  res := public.zz_err(format('select * from public.session_run_sheets(%L)', ev), 'only the root, planners and marshals');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7w member ran-with ' || res; end if;
  select count(*) into n from public.run_sheet_switches;
  if n = 0 then passed := passed + 1; else failures := failures || E'\nR7x member sees switches ' || n; end if;
  perform public.zz_as(u_root);
  perform public.end_event(ev);
  res := public.zz_err(format('select public.switch_live_run_sheet(%L, %L)', ev, s2), 'not live');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7p switch not live ' || res; end if;
  res := public.zz_ok(format('select public.start_event(%L)', ev));
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR7q start without sheet ' || res; end if;
  perform public.end_event(ev);

  -- R8 group details
  perform public.zz_as(u_planner);
  perform public.update_group_details(g_b1, ' band 1 ', ' Bands ', 'North', 40);
  select code || '|' || category || '|' || sector || '|' || headcount into t from public.groups where id = g_b1;
  if t = 'BAND_1|Bands|North|40' then passed := passed + 1; else failures := failures || E'\nR8a details ' || t; end if;
  res := public.zz_err(format('select public.update_group_details(%L, %L, null, null, null)', g_b2, 'BAND_1'), 'already has the code');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR8b duplicate code ' || res; end if;
  res := public.zz_err(format('select public.update_group_details(%L, %L, null, null, null)', g_b2, 'b@d'), 'a group code is');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR8c bad code ' || res; end if;
  res := public.zz_err(format('select public.update_group_details(%L, null, null, null, -1)', g_b2), 'headcount must be');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR8d headcount ' || res; end if;
  perform public.zz_as(u_marshal);
  res := public.zz_err(format('select public.update_group_details(%L, null, null, null, null)', g_b2), 'only the root or a planner');
  if res = 'ok' then passed := passed + 1; else failures := failures || E'\nR8e marshal ' || res; end if;

  -- R9 zone deleted under a movement: the check catches it
  execute 'reset role';
  delete from public.zones where id = z2;
  perform public.zz_as(u_planner);
  select string_agg(message, ' | ') into t from public.check_run_sheet(s2);
  if t like '%pick the zone they must reach%' then passed := passed + 1; else failures := failures || E'\nR9 deleted zone: ' || coalesce(t, 'none'); end if;

  -- R10 times after midnight read as "next day" in the check's messages
  s4 := public.create_run_sheet(ev, 'Late show');
  perform public.save_cue(s4, '{"title":"Late","start_time":"23:55","length_s":600}');
  perform public.save_cue(s4, '{"title":"After","start_time":"00:00","day_offset":1,"length_s":60}');
  select string_agg(message, ' | ') into t from public.check_run_sheet(s4);
  if t like '%before "Late" ends (00:05:00 (next day))%' then passed := passed + 1; else failures := failures || E'\nR10a next day end: ' || coalesce(t, 'none'); end if;
  s5 := public.create_run_sheet(ev, 'Forgot next day');
  perform public.save_cue(s5, '{"title":"Late","start_time":"23:00","length_s":60}');
  perform public.save_cue(s5, '{"title":"After","start_time":"00:30","length_s":60}');
  select string_agg(message, ' | ') into t from public.check_run_sheet(s5);
  if t like '%tick "+1 day"%' then passed := passed + 1; else failures := failures || E'\nR10b +1 day hint: ' || coalesce(t, 'none'); end if;
  -- R10c codes past 99 (lpad used to cut C100 to "C10" and loop forever)
  for n in 1..101 loop
    perform public.save_cue(s5, jsonb_build_object('title', 'Cue ' || n, 'start_time', '20:00', 'length_s', 60));
  end loop;
  select string_agg(code, ',' order by position) into t from (select code, position from public.cues where run_sheet_id = s5 order by position offset 98 limit 4) x;
  if t = 'C99,C100,C101,C102' then passed := passed + 1; else failures := failures || E'\nR10c codes past 99: ' || coalesce(t, 'none'); end if;

  execute 'reset role';
  raise exception 'RESULT: % passed, % failed%', passed, (length(failures) - length(replace(failures, E'\n', ''))), failures;
end
$test$;
