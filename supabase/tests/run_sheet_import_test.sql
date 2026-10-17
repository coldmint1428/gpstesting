-- supabase/tests/run_sheet_import_test.sql -- merger Stage 5 (025_run_sheet_import.sql), run against the real project.
--
-- One transaction that ends with an exception, so nothing it creates is kept: the result is the error text
-- ("RESULT: n passed, m failed" and a line per failure). Accounts and event as in run_sheets_test.sql:
--   claude_test (root of "Playback test (Claude)"), testuser1 (planner), testuser2 (made marshal), testuser3 (member).
-- The file side (reading Excel) is tools/run_sheet_file_test.mjs.
do $test$
declare
  ev uuid := '4395abec-16b6-44a0-b4a1-5f7fd6e5df49';     -- Playback test (Claude)
  u_planner uuid := 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';
  u_marshal uuid := 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5';
  u_member uuid := '2906655b-33ad-4e9d-a608-f083e43e22d4';
  base jsonb;
  bad jsonb;
  res jsonb;
  s uuid;
  s2 uuid;
  m uuid;
  n integer;
  n2 integer;
  t text;
  b boolean;
  t0 timestamptz;
  ms_small integer;
  ms_big integer;
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
  execute $f$
    create function public.zz_imp(p_event uuid, p jsonb) returns text language plpgsql as $b$
    begin
      perform public.import_run_sheet(p_event, p);
      return 'no error';
    exception when others then
      return sqlerrm;
    end $b$;
  $f$;
  execute 'grant execute on function public.zz_as(uuid), public.zz_imp(uuid, jsonb) to authenticated';

  -- fixtures
  insert into public.event_roles (event_id, user_id, role) values (ev, u_marshal, 'marshal'), (ev, u_member, 'participant')
  on conflict do nothing;
  delete from public.run_sheets where event_id = ev;
  update public.groups set code = null where event_id = ev and code in ('TKSS_BAND', 'WSSS_BAND', 'YHSS_BAND', 'GROUP_A');
  -- the template's groups and circles as left by earlier imports in the browser / on the phone: gone for this test, so
  -- the import makes them as on a fresh event (rolled back with everything else)
  delete from public.groups where event_id = ev and lower(name) in ('tkss band', 'wsss band', 'yhss band');
  delete from public.layout_objects where object_id in (select z.source_area_id from public.zones z
                                                        where z.event_id = ev and z.code in ('HOLD_D4', 'D4'));
  delete from public.zones where event_id = ev and code in ('HOLD_D4', 'D4');

  -- What the page sends for the template (codes, not ids)
  base := jsonb_build_object(
    'name', 'Imported 1', 'for_date', '2026-08-01',
    'groups', jsonb_build_array(
      jsonb_build_object('row', 4, 'code', 'TKSS_BAND', 'name', 'TKSS Band', 'category', 'Bands', 'sector', 'Padang', 'headcount', 36, 'colour', '#0D6EFD'),
      jsonb_build_object('row', 5, 'code', 'WSSS_BAND', 'name', 'WSSS Band', 'category', 'Bands', 'headcount', 32, 'colour', 'blue'),
      jsonb_build_object('row', 6, 'code', 'YHSS_BAND', 'name', 'YHSS Band', 'category', 'Bands', 'headcount', 32),
      jsonb_build_object('row', 7, 'code', 'GROUP_A', 'name', 'Group A', 'category', '', 'headcount', null)),
    'zones', jsonb_build_array(
      jsonb_build_object('row', 4, 'code', 'FORMATION_1', 'name', 'Formation 1', 'kind', 'zone', 'source', 'polygon', 'capacity', 120),
      jsonb_build_object('row', 5, 'code', 'HOLD_D4', 'name', 'Holding area D4', 'kind', 'zone', 'source', 'circle',
                         'lat', 1.3060, 'lng', 103.7672, 'radius_m', 25, 'capacity', 150),
      jsonb_build_object('row', 6, 'code', 'D4', 'name', 'Door D4', 'kind', 'entrance', 'source', 'circle',
                         'lat', 1.3065, 'lng', 103.7668, 'radius_m', 15)),
    'cues', jsonb_build_array(
      jsonb_build_object('row', 4, 'code', 'C010', 'section', 'Pre-Parade', 'title', 'Broadcast start', 'start_time', '17:30:00', 'length_s', 0, 'type', 'anchor', 'start_mode', 'auto'),
      jsonb_build_object('row', 5, 'code', 'C033', 'section', 'Pre-Parade', 'title', 'Our Singapore Wish', 'start_time', '18:01:35', 'length_s', 157, 'type', 'normal', 'start_mode', 'auto', 'notes', 'Bands enter'),
      jsonb_build_object('row', 6, 'code', 'C034', 'section', 'Pre-Parade', 'title', 'Bands Feature', 'start_time', '18:04:12', 'length_s', 86, 'type', 'normal', 'start_mode', 'auto_ready'),
      jsonb_build_object('row', 7, 'code', 'C099', 'section', 'Fireworks', 'title', 'After midnight', 'start_time', '00:05:00', 'day_offset', 1, 'length_s', 60, 'type', 'flexible', 'can_shorten_s', 30, 'start_mode', 'manual')),
    'movements', jsonb_build_array(
      jsonb_build_object('row', 4, 'code', 'M010', 'group_code', 'TKSS_BAND', 'zone_code', 'HOLD_D4', 'deadline_kind', 'cue_start', 'cue_code', 'C033',
                         'early_s', 60, 'dwell_s', 20, 'amber_s', 30, 'travel_mode', 'on_foot', 'pace_mps', 0.8, 'arrival_point', 'D4'),
      jsonb_build_object('row', 5, 'code', 'M011', 'category', 'Bands', 'zone_code', 'FORMATION_1', 'deadline_kind', 'cue_start', 'cue_code', 'C034',
                         'early_s', 30, 'dwell_s', 20, 'amber_s', 30, 'travel_mode', 'on_foot', 'pace_mps', 0.8, 'leave_by', 'C034 END', 'arrival_point', 'D4'),
      jsonb_build_object('row', 6, 'code', 'M011-1', 'group_code', 'YHSS_BAND', 'parent_code', 'M011', 'zone_code', 'FORMATION_1', 'deadline_kind', 'cue_start',
                         'cue_code', 'C034', 'early_s', 30, 'min_ics', 2, 'dwell_s', 20, 'amber_s', 30, 'travel_mode', 'on_foot', 'pace_mps', 0.8),
      jsonb_build_object('row', 7, 'code', 'M011-2', 'group_code', 'WSSS_BAND', 'parent_code', 'M011', 'skip', true, 'deadline_kind', 'cue_start', 'cue_code', 'C034'),
      jsonb_build_object('row', 8, 'code', 'M020', 'group_code', 'GROUP_A', 'zone_code', 'SECTOR_S3', 'deadline_kind', 'fixed', 'fixed_time', '18:05:00',
                         'early_s', 0, 'min_ics', 1, 'dwell_s', 20, 'amber_s', 60, 'travel_mode', 'fixed_route', 'pace_mps', 1.2, 'route', 'MC_ROUTE', 'notes', 'Fixed')));

  -- I1 who may import
  perform public.zz_as(u_marshal);
  err := public.zz_imp(ev, base);
  if err ilike '%only the root or a planner%' then passed := passed + 1; else failures := failures || E'\nI1a marshal: ' || err; end if;
  perform public.zz_as(u_member);
  err := public.zz_imp(ev, base);
  if err ilike '%only the root or a planner%' then passed := passed + 1; else failures := failures || E'\nI1b member: ' || err; end if;

  -- I2 the template imports
  perform public.zz_as(u_planner);
  t0 := clock_timestamp();
  res := public.import_run_sheet(ev, base);
  ms_small := round(extract(epoch from clock_timestamp() - t0) * 1000);
  s := (res ->> 'sheet_id')::uuid;
  if (res ->> 'cues')::int = 4 and (res ->> 'movements')::int = 3 and (res ->> 'exceptions')::int = 2
     and (res ->> 'groups_created')::int = 3 and (res ->> 'groups_updated')::int = 1 and (res ->> 'zones_created')::int = 2
  then passed := passed + 1; else failures := failures || E'\nI2a counts ' || res::text; end if;
  select r.name || '|' || r.for_date || '|' || r.status into t from public.run_sheets r where r.id = s;
  if t = 'Imported 1|2026-08-01|draft' then passed := passed + 1; else failures := failures || E'\nI2b version ' || coalesce(t, 'none'); end if;
  select string_agg(code || ':' || to_char(start_time, 'HH24:MI:SS') || '+' || day_offset || ':' || type, ',' order by position) into t
  from public.cues where run_sheet_id = s;
  if t = 'C010:17:30:00+0:anchor,C033:18:01:35+0:normal,C034:18:04:12+0:normal,C099:00:05:00+1:flexible'
  then passed := passed + 1; else failures := failures || E'\nI2c cues ' || coalesce(t, 'none'); end if;
  select count(*) into n from public.groups where event_id = ev and code in ('TKSS_BAND', 'WSSS_BAND', 'YHSS_BAND') and category = 'Bands';
  if n = 3 then passed := passed + 1; else failures := failures || E'\nI2d groups ' || n; end if;
  select colour into t from public.groups where event_id = ev and code = 'WSSS_BAND';
  if t = '#0d6efd' then passed := passed + 1; else failures := failures || E'\nI2e bad colour default ' || t; end if;
  select code into t from public.groups where id = '84c7ca4b-c68c-4e8c-830e-fdcafadb904e';
  if t = 'GROUP_A' then passed := passed + 1; else failures := failures || E'\nI2f Group A code ' || coalesce(t, 'null'); end if;
  select count(*) into n from public.zones z join public.layout_objects o on o.object_id = z.source_area_id
  where z.event_id = ev and z.code in ('HOLD_D4', 'D4') and z.is_circle and jsonb_array_length(o.data -> 'points') = 32;
  if n = 2 then passed := passed + 1; else failures := failures || E'\nI2g circles on the bench ' || n; end if;
  select round(extensions.st_distance(extensions.st_centroid(shape::extensions.geometry)::extensions.geography,
               extensions.st_setsrid(extensions.st_makepoint(103.7672, 1.3060), 4326)::extensions.geography))::int,
         capacity
    into n, n2 from public.zones where event_id = ev and code = 'HOLD_D4';
  if n <= 1 and n2 = 150 then passed := passed + 1; else failures := failures || E'\nI2h circle centre off by ' || n || ' m, capacity ' || n2; end if;
  select count(*) into n from public.event_zones(ev) where code = 'HOLD_D4';
  if n = 1 then passed := passed + 1; else failures := failures || E'\nI2i circle in event_zones'; end if;
  select capacity into n from public.zones where event_id = ev and code = 'FORMATION_1';
  if n = 120 then passed := passed + 1; else failures := failures || E'\nI2j existing zone capacity ' || coalesce(n::text, 'null'); end if;
  select (zone_id is not null and arrival_point = 'D4' and pace_mps = 0.8 and early_s = 60) into b from public.movements where run_sheet_id = s and code = 'M010';
  if b then passed := passed + 1; else failures := failures || E'\nI2k M010'; end if;
  select (category = 'Bands' and leave_by = 'C034 END') into b from public.movements where run_sheet_id = s and code = 'M011' and parent_id is null;
  if b then passed := passed + 1; else failures := failures || E'\nI2l M011'; end if;
  select count(*) into n from public.movements x join public.movements p on p.id = x.parent_id
  where x.run_sheet_id = s and p.code = 'M011' and ((x.min_ics = 2 and not x.skip) or (x.skip and x.zone_id is null));
  if n = 2 then passed := passed + 1; else failures := failures || E'\nI2m exceptions ' || n; end if;
  select (zone_id is null and fixed_time = '18:05:00' and route = 'MC_ROUTE' and travel_mode = 'fixed_route' and notes = 'Fixed') into b
  from public.movements where run_sheet_id = s and code = 'M020';
  if b then passed := passed + 1; else failures := failures || E'\nI2n M020 (zone not drawn: empty)'; end if;
  select string_agg(left(message, 40), ' | ') into t from public.check_run_sheet(s) where severity = 'error';
  if t like '%M020: pick the zone%' then passed := passed + 1; else failures := failures || E'\nI2o check flags the missing zone: ' || coalesce(t, 'none'); end if;
  if ms_small < 3000 then passed := passed + 1; else failures := failures || E'\nI2p took ' || ms_small || ' ms'; end if;

  -- I3 all or nothing: a bad cue in row 7 -> nothing at all is kept
  select count(*) into n from public.groups where event_id = ev;
  select count(*) into n2 from public.zones where event_id = ev;
  bad := jsonb_set(base, '{name}', '"Bad 1"');
  bad := jsonb_set(bad, '{groups}', (bad -> 'groups') || jsonb_build_array(jsonb_build_object('row', 8, 'code', 'NEW_GROUP', 'name', 'Brand new', 'category', 'Pipers')));
  bad := jsonb_set(bad, '{zones}', jsonb_build_array(jsonb_build_object('row', 4, 'code', 'NEW_CIRCLE', 'name', 'New', 'kind', 'zone', 'source', 'circle', 'lat', 1.3, 'lng', 103.8, 'radius_m', 30)));
  bad := jsonb_set(bad, '{cues,3,start_time}', '"25:99"');
  err := public.zz_imp(ev, bad);
  if err ilike 'Cues row 7:%start must be a time%' then passed := passed + 1; else failures := failures || E'\nI3a error names the row: ' || err; end if;
  if not exists (select 1 from public.run_sheets where event_id = ev and name = 'Bad 1')
     and (select count(*) from public.groups where event_id = ev) = n
     and (select count(*) from public.zones where event_id = ev) = n2
  then passed := passed + 1; else failures := failures || E'\nI3b something was kept after the error'; end if;

  -- I4 refusals, each naming its row
  bad := jsonb_set(base, '{name}', '"Bad 2"');
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,0,group_code}', '"NOBODY"'));
  if err ilike 'Movements row 4:%no group has the code NOBODY%' then passed := passed + 1; else failures := failures || E'\nI4a ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,0,cue_code}', '"C777"'));
  if err ilike 'Movements row 4:%no cue has the ID C777%' then passed := passed + 1; else failures := failures || E'\nI4b ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,0,zone_code}', '"CAR_PARK"'));
  if err ilike 'Movements row 4:%no-go%' then passed := passed + 1; else failures := failures || E'\nI4c no-go ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,2,parent_code}', '"M010"'));
  if err ilike 'Movements row 6:%for a category%' then passed := passed + 1; else failures := failures || E'\nI4d ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,1,leave_by}', '"later"'));
  if err ilike 'Movements row 5:%must leave by%' then passed := passed + 1; else failures := failures || E'\nI4e ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,4,code}', '"M010"'));
  if err ilike 'Movements row 8:%used twice%' then passed := passed + 1; else failures := failures || E'\nI4f ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{cues,1,code}', '"C010"'));
  if err ilike 'Cues row 5:%used twice%' then passed := passed + 1; else failures := failures || E'\nI4g ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{groups,1,code}', '"TKSS_BAND"'));
  if err ilike 'Groups row 5:%used twice%' then passed := passed + 1; else failures := failures || E'\nI4h ' || err; end if;
  -- (a new zone code: HOLD_D4 exists since I2, and an existing zone is only matched, not drawn again)
  err := public.zz_imp(ev, jsonb_set(jsonb_set(bad, '{zones,1,code}', '"NEW_C1"'), '{zones,1,lat}', '51.5'));
  if err ilike 'Zones row 5:%inside Singapore%' then passed := passed + 1; else failures := failures || E'\nI4i circle outside Singapore ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(jsonb_set(bad, '{zones,1,code}', '"NEW_C1"'), '{zones,1,radius_m}', '3'));
  if err ilike 'Zones row 5:%15 to 5000%' then passed := passed + 1; else failures := failures || E'\nI4j radius ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(base, '{name}', '"IMPORTED 1"'));
  if err ilike 'Event tab:%already a version called%' then passed := passed + 1; else failures := failures || E'\nI4k name taken ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{cues}', '[]'));
  if err ilike '%no cues%' then passed := passed + 1; else failures := failures || E'\nI4l no cues ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{groups,0,code}', '"bad code!"'));
  if err ilike 'Groups row 4:%group code%' then passed := passed + 1; else failures := failures || E'\nI4m ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{cues,0,title}', to_jsonb(repeat('x', 121))));
  if err ilike 'Cues row 4:%cue a name%' then passed := passed + 1; else failures := failures || E'\nI4n ' || err; end if;
  err := public.zz_imp(ev, jsonb_set(bad, '{movements,2,group_code}', '"GROUP_A"'));
  if err ilike 'Movements row 6:%category%' then passed := passed + 1; else failures := failures || E'\nI4o exception for a group outside the category ' || err; end if;
  if not exists (select 1 from public.run_sheets where event_id = ev and name = 'Bad 2')
  then passed := passed + 1; else failures := failures || E'\nI4p a refused import left a version'; end if;

  -- I5 importing again: groups and zones are matched, not created twice
  res := public.import_run_sheet(ev, jsonb_set(base, '{name}', '"Imported 2"'));
  if (res ->> 'groups_created')::int = 0 and (res ->> 'groups_updated')::int = 4 and (res ->> 'zones_created')::int = 0
  then passed := passed + 1; else failures := failures || E'\nI5 second import ' || res::text; end if;

  -- I6 planned-only fields: kept by the editor, copied by Duplicate
  select id into m from public.movements where run_sheet_id = s and code = 'M011' and parent_id is null;
  perform public.save_movement(s, jsonb_build_object('id', m, 'category', 'Bands', 'deadline_kind', 'cue_start',
          'cue_id', (select id from public.cues where run_sheet_id = s and code = 'C034'))); -- no leave_by key: an older page
  select leave_by = 'C034 END' and arrival_point = 'D4' into b from public.movements where id = m;
  if b then passed := passed + 1; else failures := failures || E'\nI6a not sent = kept'; end if;
  perform public.save_movement(s, jsonb_build_object('id', m, 'category', 'Bands', 'deadline_kind', 'cue_start', 'leave_by', '',
          'cue_id', (select id from public.cues where run_sheet_id = s and code = 'C034')));
  select leave_by is null and arrival_point = 'D4' into b from public.movements where id = m;
  if b then passed := passed + 1; else failures := failures || E'\nI6b empty = cleared'; end if;
  s2 := public.create_run_sheet(ev, 'Copy of import', null, s);
  select count(*) into n from public.movements where run_sheet_id = s2 and (route = 'MC_ROUTE' or arrival_point = 'D4');
  if n = 3 then passed := passed + 1; else failures := failures || E'\nI6c copied planned fields ' || n; end if;
  begin
    perform public.save_movement(s, jsonb_build_object('id', m, 'category', 'Bands', 'arrival_point', 'door d4!'));
    failures := failures || E'\nI6d bad arrival point saved';
  exception when others then
    passed := passed + 1;
  end;

  -- I7 NDP size: 400 cues, 200 groups (20 categories), 1500 movements in one import
  bad := jsonb_build_object('name', 'Big', 'groups', '[]'::jsonb, 'zones', '[]'::jsonb, 'cues', '[]'::jsonb, 'movements', '[]'::jsonb);
  bad := jsonb_set(bad, '{groups}', (select jsonb_agg(jsonb_build_object('row', i + 3, 'code', 'BIG_' || i, 'name', 'Big ' || i, 'category', 'Cat' || (i % 20))) from generate_series(1, 200) i));
  bad := jsonb_set(bad, '{cues}', (select jsonb_agg(jsonb_build_object('row', i + 3, 'code', 'X' || i, 'title', 'Cue ' || i,
           'start_time', to_char(time '17:00' + make_interval(secs => i * 30), 'HH24:MI:SS'), 'length_s', 30)) from generate_series(1, 400) i));
  bad := jsonb_set(bad, '{movements}', (select jsonb_agg(case when i <= 20
           then jsonb_build_object('row', i + 3, 'code', 'MV' || i, 'category', 'Cat' || (i - 1), 'zone_code', 'FORMATION_1', 'cue_code', 'X' || i)
           else jsonb_build_object('row', i + 3, 'code', 'MV' || i, 'group_code', 'BIG_' || (1 + i % 200), 'zone_code', 'FORMATION_1', 'cue_code', 'X' || (1 + i % 400)) end)
         from generate_series(1, 1500) i));
  t0 := clock_timestamp();
  res := public.import_run_sheet(ev, bad);
  ms_big := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if (res ->> 'cues')::int = 400 and (res ->> 'movements')::int = 1500 then passed := passed + 1; else failures := failures || E'\nI7a big ' || res::text; end if;
  -- PostgREST stops a request after 8 s for signed-in users
  if ms_big < 6000 then passed := passed + 1; else failures := failures || E'\nI7b big import took ' || ms_big || ' ms'; end if;

  execute 'reset role';
  raise exception 'RESULT: % passed, % failed% (template import % ms, 400 cues + 1500 movements % ms)', passed,
    (length(failures) - length(replace(failures, E'\n', ''))), failures, ms_small, ms_big;
end
$test$;
