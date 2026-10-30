-- Step 26, checked at the database: a timetable row says WHERE the moment is.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step26-place.sql
--
-- What has to be true, and why each one is here:
--
--   1. A PLACE HAS A NAME. A moment whose drawn point stands inside a zone comes back with that zone's name, on the
--      row a member reads. This is the whole point of the step: "7:40 · Main Gate" rather than "7:40".
--   2. A ROUTE POINT HAS NONE. The same read, on a moment in open ground, answers null -- and answers a row, not no
--      row. A route point is a moment; it simply is not a place.
--   3. A NO-GO AREA IS NOT A PLACE. A point inside a no-go zone is inside *a* zone and still gets null: a cordon is
--      not somewhere a group is sent to stand, and "be at the Store room (no-go)" is not an instruction anyone can
--      follow. This is the assertion that stops "inside any zone" being treated as "a place".
--   4. THE TIE-BREAK IS 057's, NOT A SECOND ONE. The point is inside two zones at once (a stage and a general zone)
--      and answers the stage. Assertion 6 first proves the point really is inside both, so the tie-break is being
--      exercised rather than passed vacuously.
--   5. OFF SITE IS NOT A PLACE EITHER, even when the excursion keeps a coordinate inside a zone.
--   6. A CARRIED FRAME HAS NO PLACE. A frame that only carries the group forward has no drawn point, so the answer
--      is null: the plan does not say the group is somewhere at that frame, it says the previous statement stands.
--   7. THE MEMBER'S READ CARRIES IT. The same three answers hold for a group's IC reading their own timetable --
--      the scope narrows which rows answer, not what a row says.
--
-- The check builds its own plan and zones in the bench event, opens a real session through start_event(), and rolls
-- the whole transaction back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a bench of its own ----------
delete from public.plans where id = '0b000000-0000-4000-8000-000000000b26';
delete from public.zones where id in (
  '0b000000-0000-4000-8000-00000000c260', '0b000000-0000-4000-8000-00000000c261',
  '0b000000-0000-4000-8000-00000000c262', '0b000000-0000-4000-8000-00000000c263');
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';

-- T+0 is fifteen minutes ago, so every moment of the plan has passed and the read is judged at now().
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', 'Place bench',
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

-- Six frames, two minutes apart: five steps, which is a 125 m budget per walk.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2641', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',    0, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2642', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',  120, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2643', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',  240, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2644', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',  360, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2645', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',  480, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2646', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01',  600, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew: the main gate at T+0, the stage at +10:00, carried in between.
-- Sound: open ground at T+0, off site at +8:00, the stage at +10:00.
-- Backstage: one statement, inside the store room's no-go area (a single moment cannot cross anything, so the plan
-- still passes the publish gate).
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f2641', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2646', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304000, 103.77450),
  ('0b000000-0000-4000-8000-0000000f2641', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3299000, 103.77370),
  ('0b000000-0000-4000-8000-0000000f2645', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3304000, 103.77450),
  ('0b000000-0000-4000-8000-0000000f2646', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3304000, 103.77450),
  ('0b000000-0000-4000-8000-0000000f2641', '0b000000-0000-4000-8000-000000000b26', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3310000, 103.77500);

update public.plan_positions
   set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f2645'
   and group_id = '0b000000-0000-4000-8000-00000000a002';

-- ---------- the places ----------
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c260', '0b000000-0000-4000-8000-000000000e01', 'GATE', 'Main Gate', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77390 1.32990, 103.77410 1.32990, 103.77410 1.33010, 103.77390 1.33010, 103.77390 1.32990))'), false),
  ('0b000000-0000-4000-8000-00000000c261', '0b000000-0000-4000-8000-000000000e01', 'STAGE', 'Stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77440 1.33030, 103.77460 1.33030, 103.77460 1.33050, 103.77440 1.33050, 103.77440 1.33030))'), false),
  ('0b000000-0000-4000-8000-00000000c262', '0b000000-0000-4000-8000-000000000e01', 'STORE', 'Store room (no-go)', 'no_go',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77490 1.33090, 103.77510 1.33090, 103.77510 1.33110, 103.77490 1.33110, 103.77490 1.33090))'), false),
  -- Deliberately overlapping the stage, so a point inside both proves which one the read names.
  ('0b000000-0000-4000-8000-00000000c263', '0b000000-0000-4000-8000-000000000e01', 'GENERAL', 'The grounds', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77430 1.33020, 103.77470 1.33020, 103.77470 1.33060, 103.77430 1.33060, 103.77430 1.33020))'), false);

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b26', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b26'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b26');
  perform set_config('check.session', v_s::text, true);
end $$;

reset role;

-- ---------- what the read answers ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_place text;
  v_also text;
begin
  -- 1. Six frames, three groups: eighteen rows, one per group per frame.
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 18 then
    raise exception 'FAIL 1a: the timetable answered % rows, expected 18 (3 groups x 6 frames)', v_n;
  end if;

  -- 2. The place: Gate Crew's first moment is inside Main Gate.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a001'
     and frame_id = '0b000000-0000-4000-8000-0000000f2641';
  if v_place is distinct from 'Main Gate' then
    raise exception 'FAIL 1b: Gate Crew at +0:00 stands in %, expected Main Gate', coalesce(v_place, 'nothing');
  end if;

  -- 3. A carried frame has no point, so no place.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a001'
     and frame_id = '0b000000-0000-4000-8000-0000000f2643';
  if v_place is not null then
    raise exception 'FAIL 1c: a carried frame answered the place %, expected null', v_place;
  end if;

  -- 4. A route point: Sound's +0:00 stands in open ground, and still answers a row.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a002'
     and frame_id = '0b000000-0000-4000-8000-0000000f2641';
  if v_place is not null then
    raise exception 'FAIL 1d: a route point answered the place %, expected null', v_place;
  end if;

  -- 4b. ... and it really stands in no zone at all, so that null is not vacuous.
  select count(*) into v_n
    from public.zones z
   where z.event_id = '0b000000-0000-4000-8000-000000000e01'
     and extensions.st_dwithin(z.shape,
           extensions.st_setsrid(extensions.st_makepoint(103.77370, 1.3299000), 4326)::extensions.geography, 0);
  if v_n <> 0 then
    raise exception 'FAIL 1i: the route point stands in % zones, expected none', v_n;
  end if;

  -- 5. The tie-break is exercised, not assumed: the stage point really is inside both zones.
  select string_agg(z.name, ', ' order by z.name) into v_also
    from public.zones z
   where z.event_id = '0b000000-0000-4000-8000-000000000e01'
     and extensions.st_dwithin(z.shape,
           extensions.st_setsrid(extensions.st_makepoint(103.77450, 1.3304000), 4326)::extensions.geography, 0);
  if v_also is distinct from 'Stage, The grounds' then
    raise exception 'FAIL 1e: the stage point stands in "%", expected both Stage and The grounds', coalesce(v_also, 'nothing');
  end if;

  -- 6. So the read names the stage.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a002'
     and frame_id = '0b000000-0000-4000-8000-0000000f2646';
  if v_place is distinct from 'Stage' then
    raise exception 'FAIL 1f: a point inside the stage and the grounds answered %, expected Stage', coalesce(v_place, 'nothing');
  end if;

  -- 7. A no-go area is a zone and is not a place.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a003'
     and frame_id = '0b000000-0000-4000-8000-0000000f2641';
  if v_place is not null then
    raise exception 'FAIL 1g: a point inside a no-go area answered the place %, expected null', v_place;
  end if;

  -- 7b. ... and it really is inside that no-go zone, so 1g is not passing on a point in open ground.
  select count(*) into v_n
    from public.zones z
   where z.event_id = '0b000000-0000-4000-8000-000000000e01'
     and extensions.st_dwithin(z.shape,
           extensions.st_setsrid(extensions.st_makepoint(103.77500, 1.3310000), 4326)::extensions.geography, 0);
  if v_n <> 1 then
    raise exception 'FAIL 1j: the no-go point stands in % zones, expected exactly the store room', v_n;
  end if;

  -- 8. Off site is not a place, even with a coordinate inside one.
  select place into v_place from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a002'
     and frame_id = '0b000000-0000-4000-8000-0000000f2645';
  if v_place is not null then
    raise exception 'FAIL 1h: an off-site moment answered the place %, expected null', v_place;
  end if;
end $$;

-- ---------- the same answers through the member's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_place text;
  v_n integer;
begin
  -- The IC of Gate Crew reads their own group's timetable: six rows, and the place on the first one.
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 6 then
    raise exception 'FAIL 2a: the IC read % rows, expected their group''s 6', v_n;
  end if;

  select place into v_place from public.session_timetable(v_s)
   where frame_id = '0b000000-0000-4000-8000-0000000f2646';
  if v_place is distinct from 'Stage' then
    raise exception 'FAIL 2b: the IC''s read answered the place %, expected Stage', coalesce(v_place, 'nothing');
  end if;
end $$;

reset role;

rollback;
