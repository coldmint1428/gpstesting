-- Step 29, checked at the database: a timetable row carries the point of the moment it names, so a follower's map can
-- draw their own walk -- and the read still answers one group.
--
--     node tools/sql.mjs --file dev/checks/step29-route.sql
--
-- The check builds its own event inside this transaction and rolls the whole thing back, so no fixture is touched and
-- it can be run at any time. What has to be true, and why each one is here:
--
--   1. A STATED MOMENT HAS A POINT. Gate Crew's +0:00 answers the coordinates the plan drew, on the row a follower
--      reads. This is the whole point of the step: without it the map has nothing to join up.
--   2. A CARRIED FRAME HAS NEITHER POINT NOR PLACE, and answers both nulls together. The plan does not say the group is
--      somewhere at that frame; it says the previous statement stands (062), and carrying the point forward would be a
--      second copy of the walk.
--   3. AN OFF-SITE MOMENT IS NOT A POINT ON THE MAP even though it keeps a coordinate: null point, null place, and the
--      state word that says why (not_required). This is the assertion that stops "a position row exists" being treated
--      as "somebody is there".
--   4. A ROUTE POINT IS A POINT AND NOT A PLACE. A moment in open ground answers its coordinates and a null place, so
--      the two columns are not the same column. The direction is the rule: a null point always has a null place, and a
--      place always has a point -- but a point may stand in no zone at all.
--   5. THE PLACE STILL SITS ON THE POINT. The two flanking moments stand in zones and answer their names, which is
--      step 26's answer unchanged and proves the new columns did not shift the lateral.
--   6. THE MEMBER'S READ IS ONE GROUP, engine and wrapper. A Sound member reads five rows, none of them Gate Crew's, and
--      `session_status` called straight answers the same five: the scope is the engine's (052), not the wrapper's.
--   7. A MARSHAL READS BOTH GROUPS -- ten rows -- and Gate Crew's carried frame is still null in that read.
--   8. AN OUTSIDER IS REFUSED, and `anon` cannot execute: the point is a follower's own walk, not a public map.
--
-- Proven to bite (each restored before the next run, and the check re-run green):
--   * `session_status`'s scope replaced by `where true` -> FAIL 2a: the Sound member reads ten rows.
--   * 065's point join carried forward instead of matched by frame -> FAIL 1c: the carried frame answers a point.
--   * 065's `and pp.state = 'on_site'` deleted -> FAIL 1d: the off-site row answers a point.

begin;

-- ---------- a bench of its own ----------
insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e29', 'Route bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Rolled back by dev/checks/step29-route.sql (the follower''s own map).',
        'Bukit Timah', now() - interval '2 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a291', '0b000000-0000-4000-8000-000000000e29', 'Gate Crew', 'GATE', '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a292', '0b000000-0000-4000-8000-000000000e29', 'Sound', 'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e29', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e29', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e29', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e29', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e29', '00cd023b-0e26-4574-a635-760e782c8029', 'marshal');

-- Gate Crew's IC and Sound's member. The marshal has no group, which is what makes their ten rows the ops read.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a291', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false);

-- Two zones the walk touches at its ends. A box 22 m across, so a point is either plainly inside or plainly outside.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c291', '0b000000-0000-4000-8000-000000000e29', 'GATE', 'Main Gate', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77390 1.32990, 103.77410 1.32990, 103.77410 1.33010, 103.77390 1.33010, 103.77390 1.32990))'), false),
  ('0b000000-0000-4000-8000-00000000c292', '0b000000-0000-4000-8000-000000000e29', 'STAGE', 'Stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77390 1.33062, 103.77410 1.33062, 103.77410 1.33082, 103.77390 1.33082, 103.77390 1.33062))'), false);

-- T+0 fifteen minutes ago, so every moment has passed and the read is judged at now().
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', 'Route walk',
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

-- Five frames, five minutes apart: four steps, a 100 m budget per walk.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2901', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29',    0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2902', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29',  300, 'move',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2903', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29',  600, 'hold',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2904', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29',  900, 'break', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2905', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', 1200, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew: the main gate, then 20 m north (open ground), carried at +10:00, off site at +15:00, the stage at +20:00.
-- Sound: a parallel lane 33 m west, a point at every frame. 20 m a step keeps both walks inside the 25 m rule.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f2901', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a291', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2902', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a291', 1.3301800, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2904', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a291', 1.3305400, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2905', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a291', 1.3307200, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2901', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', 1.3300000, 103.77370),
  ('0b000000-0000-4000-8000-0000000f2902', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', 1.3301800, 103.77370),
  ('0b000000-0000-4000-8000-0000000f2903', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', 1.3303600, 103.77370),
  ('0b000000-0000-4000-8000-0000000f2904', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', 1.3305400, 103.77370),
  ('0b000000-0000-4000-8000-0000000f2905', '0b000000-0000-4000-8000-000000000b29', '0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-00000000a292', 1.3307200, 103.77370);

update public.plan_positions
   set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f2904'
   and group_id = '0b000000-0000-4000-8000-00000000a291';

-- ---------- open the session through the product's doors ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b29',
                              (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b29'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e29', '0b000000-0000-4000-8000-000000000b29');
  perform set_config('check.session', v_s::text, true);
end $$;

reset role;

-- ---------- 1. what the planner's read answers ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_lat double precision;
  v_lng double precision;
  v_place text;
  v_state text;
begin
  -- 1a. Two groups, five frames: ten rows, one per group per frame.
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 10 then
    raise exception 'FAIL 1a: the planner read % rows, expected 10 (2 groups x 5 frames)', v_n;
  end if;

  -- 1b. Gate Crew's +0:00 answers the point the plan drew, and it is the gate's place.
  select lat, lng, place into v_lat, v_lng, v_place
    from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291'
     and frame_id = '0b000000-0000-4000-8000-0000000f2901';
  if v_lat is null or v_lng is null then
    raise exception 'FAIL 1b: a stated moment answered no point (% , %)', v_lat, v_lng;
  end if;
  if abs(v_lat - 1.3300000) > 1e-9 or abs(v_lng - 103.77400) > 1e-9 then
    raise exception 'FAIL 1b: a stated moment answered the point %, %, not the plan''s', v_lat, v_lng;
  end if;
  if v_place is distinct from 'Main Gate' then
    raise exception 'FAIL 1b: the point inside the gate answered the place %, expected Main Gate', coalesce(v_place, 'nothing');
  end if;

  -- 1c. A carried frame has no point and no place, and answers both nulls.
  select lat, lng, place into v_lat, v_lng, v_place
    from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291'
     and frame_id = '0b000000-0000-4000-8000-0000000f2903';
  if v_lat is not null or v_lng is not null then
    raise exception 'FAIL 1c: a carried frame answered the point %, %, expected none', v_lat, v_lng;
  end if;
  if v_place is not null then
    raise exception 'FAIL 1c: a carried frame answered the place %, expected null', v_place;
  end if;

  -- 1d. An off-site moment is not a point on the map: null point, null place, and the state that says why.
  select lat, lng, place, state into v_lat, v_lng, v_place, v_state
    from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291'
     and frame_id = '0b000000-0000-4000-8000-0000000f2904';
  if v_state is distinct from 'not_required' then
    raise exception 'FAIL 1d: the off-site moment reads %, expected not_required', v_state;
  end if;
  if v_lat is not null or v_lng is not null then
    raise exception 'FAIL 1d: an off-site moment answered the point %, %, expected none', v_lat, v_lng;
  end if;
  if v_place is not null then
    raise exception 'FAIL 1d: an off-site moment answered the place %, expected null', v_place;
  end if;
  -- ... and it really keeps a coordinate in the plan, so 1d is not passing because the row has no position at all.
  select count(*) into v_n
    from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f2904'
     and group_id = '0b000000-0000-4000-8000-00000000a291';
  if v_n <> 1 then
    raise exception 'FAIL 1d: the off-site frame has % position rows, expected the one it keeps', v_n;
  end if;

  -- 1e. A route point is a point and not a place: Sound's +0:00 stands in open ground.
  select lat, lng, place into v_lat, v_lng, v_place
    from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a292'
     and frame_id = '0b000000-0000-4000-8000-0000000f2901';
  if v_lat is null or v_lng is null then
    raise exception 'FAIL 1e: a route point answered no point (% , %)', v_lat, v_lng;
  end if;
  if v_place is not null then
    raise exception 'FAIL 1e: a route point answered the place %, expected null', v_place;
  end if;

  -- 1f. The rule between the two columns, over every row: a null point has a null place, and lat/lng are null together.
  select count(*) into v_n
    from public.session_timetable(v_s)
   where (lat is null) <> (lng is null);
  if v_n <> 0 then
    raise exception 'FAIL 1f: % row(s) answered one of lat/lng and not the other', v_n;
  end if;
  select count(*) into v_n
    from public.session_timetable(v_s)
   where lat is null and place is not null;
  if v_n <> 0 then
    raise exception 'FAIL 1f: % row(s) answered a place with no point', v_n;
  end if;
  select count(*) into v_n
    from public.session_timetable(v_s)
   where place is not null and lat is null;
  if v_n <> 0 then
    raise exception 'FAIL 1f: % row(s) answered a place and no point', v_n;
  end if;

  -- 1g. The walk's other end is the stage, so the place still sits on the point (062's lateral unchanged).
  select place into v_place
    from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291'
     and frame_id = '0b000000-0000-4000-8000-0000000f2905';
  if v_place is distinct from 'Stage' then
    raise exception 'FAIL 1g: the walk''s far end answered the place %, expected Stage', coalesce(v_place, 'nothing');
  end if;

  -- 1h. Every stated on-site moment has a point: Gate Crew's three, Sound's five.
  select count(*) into v_n from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291' and lat is not null;
  if v_n <> 3 then
    raise exception 'FAIL 1h: Gate Crew answered % points, expected 3', v_n;
  end if;
  select count(*) into v_n from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a292' and lat is not null;
  if v_n <> 5 then
    raise exception 'FAIL 1h: Sound answered % points, expected 5', v_n;
  end if;
end $$;

-- ---------- 2. the Sound member's read is one group, engine and wrapper ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_place text;
begin
  -- 2a. Five rows: their own group's, one per frame.
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 5 then
    raise exception 'FAIL 2a: the Sound member read % rows, expected their group''s 5', v_n;
  end if;

  -- 2b. None of Gate Crew's -- not filtered from the rows, absent from the read.
  select count(*) into v_n from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291';
  if v_n <> 0 then
    raise exception 'FAIL 2b: the Sound member read % of Gate Crew''s rows, expected none', v_n;
  end if;

  -- 2c. The engine, called straight, is scoped too (052): the wrapper is not the door that closes.
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 5 then
    raise exception 'FAIL 2c: the Sound member read % rows from session_status, expected 5', v_n;
  end if;

  -- 2d. Their own points arrive, every one of them, and none of them is a place.
  select count(*) into v_n from public.session_timetable(v_s) where lat is not null;
  if v_n <> 5 then
    raise exception 'FAIL 2d: the Sound member read % points, expected 5', v_n;
  end if;
  select count(*) into v_n from public.session_timetable(v_s) where place is not null;
  if v_n <> 0 then
    raise exception 'FAIL 2d: the Sound member read % place(s) in open ground, expected none', v_n;
  end if;
end $$;

-- ---------- 3. a Gate Crew member reads their own walk, carried and off-site frames included ----------
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 5 then
    raise exception 'FAIL 3a: the Gate Crew member read % rows, expected their group''s 5', v_n;
  end if;
  -- The frames nobody is standing on still arrive: the map needs them to know the walk stops.
  select count(*) into v_n from public.session_timetable(v_s) where lat is null;
  if v_n <> 2 then
    raise exception 'FAIL 3b: the Gate Crew member read % frames with no point, expected 2 (carried and off site)', v_n;
  end if;
end $$;

-- ---------- 4. the marshal reads both groups ----------
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_lat double precision;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 10 then
    raise exception 'FAIL 4a: the marshal read % rows, expected 10', v_n;
  end if;
  select count(distinct group_id) into v_n from public.session_timetable(v_s);
  if v_n <> 2 then
    raise exception 'FAIL 4a: the marshal read % group(s), expected 2', v_n;
  end if;
  -- The carried frame is null for the marshal too: the rule is about the plan, not about who is reading.
  select lat into v_lat from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a291'
     and frame_id = '0b000000-0000-4000-8000-0000000f2903';
  if v_lat is not null then
    raise exception 'FAIL 4b: the marshal''s read answered a point for the carried frame';
  end if;
end $$;

-- ---------- 5. an outsider is refused ----------
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
begin
  begin
    perform public.session_timetable(v_s);
    raise exception 'FAIL 5a: an outsider read the route';
  exception when insufficient_privilege then
    null; -- the expected refusal: "You are not in this event."
  end;
  begin
    perform public.session_status(v_s);
    raise exception 'FAIL 5b: an outsider read the engine';
  exception when insufficient_privilege then
    null;
  end;
end $$;

reset role;

-- ---------- 6. anon cannot execute ----------
do $$
begin
  if has_function_privilege('anon', 'public.session_timetable(uuid, timestamptz)', 'execute') then
    raise exception 'FAIL 6a: anon can execute session_timetable';
  end if;
  if not has_function_privilege('authenticated', 'public.session_timetable(uuid, timestamptz)', 'execute') then
    raise exception 'FAIL 6b: authenticated cannot execute session_timetable';
  end if;
end $$;

rollback;
