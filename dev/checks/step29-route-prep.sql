-- The bench step 29's browser check reads: a live plan whose walk is a line a follower can draw, one group whose
-- moments are placed and one whose moments are a route, and two members who must each see only their own.
--
--     node tools/sql.mjs --file dev/checks/step29-route-prep.sql
--     node tools/run.mjs dev/checks/step29-route.mjs --session .tmp/session.json
--
-- Needs two more sessions (the check says so if they are missing):
--     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew's IC)
--     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound's member)
--
-- THE SHAPE OF THE WALK. Five frames, five minutes apart. Gate Crew is at the main gate at +0:00 and +5:00 (two placed
-- moments, so the "next" card has a place to name), carried at +10:00, off site at +15:00, and at the stage at +20:00:
-- the line has one run, a break, and a lone dot -- the three shapes the screen has to draw. Sound walks a parallel lane
-- 33 m west with a point at every frame, all of it in open ground, so its route is a line with five dots and every one
-- of them has a point and no place.
--
-- WHY T+0 IS A FEW SECONDS AGO. The card names the NEXT moment and the dots mark the one the clock is on, so the check
-- needs +0:00 behind it and +5:00 ahead for long enough to open two pages: T+0 is five seconds before this prep commits.
--
-- The prep is idempotent: it deletes the event, its plans, sessions, readings and marks first.

begin;

delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.handover_log   where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.locations      where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.zone_presence  where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.zone_alerts    where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e39';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e39';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e39', 'Route bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 29 (the follower''s own map). Rebuilt by dev/checks/step29-route-prep.sql; safe to delete.',
        'Bukit Timah', now() - interval '2 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a391', '0b000000-0000-4000-8000-000000000e39', 'Gate Crew', 'GATE', '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a392', '0b000000-0000-4000-8000-000000000e39', 'Sound', 'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e39', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e39', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e39', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e39', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a391', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false);

-- The main gate spans the first two moments (a gate area is a place, not a point); the stage is where the walk ends.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c391', '0b000000-0000-4000-8000-000000000e39', 'GATE', 'Main Gate', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77390 1.32990, 103.77410 1.32990, 103.77410 1.33040, 103.77390 1.33040, 103.77390 1.32990))'), false),
  ('0b000000-0000-4000-8000-00000000c392', '0b000000-0000-4000-8000-000000000e39', 'STAGE', 'Stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77390 1.33062, 103.77410 1.33062, 103.77410 1.33082, 103.77390 1.33082, 103.77390 1.33062))'), false);

insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, published_at, created_by)
select '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', 'Route walk',
       (now() at time zone 'Asia/Singapore' - interval '5 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '5 seconds')::time,
       'live', 1, now(), 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f3901', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39',    0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3902', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39',  300, 'move',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3903', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39',  600, 'hold',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3904', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39',  900, 'break', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3905', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', 1200, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- 20 m a step keeps both walks inside the 25 m rule. Gate Crew's +10:00 is carried (no row at all); its +15:00 keeps a
-- coordinate and is off site, which is how a break in the line is written.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f3901', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a391', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3902', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a391', 1.3301800, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3904', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a391', 1.3305400, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3905', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a391', 1.3307200, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3901', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', 1.3300000, 103.77370),
  ('0b000000-0000-4000-8000-0000000f3902', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', 1.3301800, 103.77370),
  ('0b000000-0000-4000-8000-0000000f3903', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', 1.3303600, 103.77370),
  ('0b000000-0000-4000-8000-0000000f3904', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', 1.3305400, 103.77370),
  ('0b000000-0000-4000-8000-0000000f3905', '0b000000-0000-4000-8000-000000000b39', '0b000000-0000-4000-8000-000000000e39', '0b000000-0000-4000-8000-00000000a392', 1.3307200, 103.77370);

update public.plan_positions
   set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f3904'
   and group_id = '0b000000-0000-4000-8000-00000000a391';

insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d391', '0b000000-0000-4000-8000-000000000e39',
       now() - interval '1 minute', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b39', public.plan_t0('0b000000-0000-4000-8000-000000000b39'), 1;

-- ---------- two empty benches, for the sentences a map must say instead of drawing nothing ----------
-- e3a has never been started; e3b is running without a plan. Both are read by the same member as the walk above.
delete from public.event_sessions where event_id in ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-000000000e3b');
delete from public.group_members  where event_id in ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-000000000e3b');
delete from public.event_roles    where event_id in ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-000000000e3b');
delete from public.groups         where event_id in ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-000000000e3b');
delete from public.events         where id in ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-000000000e3b');

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at) values
  ('0b000000-0000-4000-8000-000000000e3a', 'Never started', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
   'Fixture for step 29 (an event that has not been started). Rebuilt by step29-route-prep.sql.', 'Bukit Timah',
   now() + interval '1 hour', now() + interval '3 hours'),
  ('0b000000-0000-4000-8000-000000000e3b', 'No plan tonight', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
   'Fixture for step 29 (an event running without a plan). Rebuilt by step29-route-prep.sql.', 'Bukit Timah',
   now() - interval '2 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a3a1', '0b000000-0000-4000-8000-000000000e3a', 'Gate Crew', 'GATE', '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a3b1', '0b000000-0000-4000-8000-000000000e3b', 'Gate Crew', 'GATE', '#244f3f', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e3a', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e3a', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e3b', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e3b', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e3a', '0b000000-0000-4000-8000-00000000a3a1', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e3b', '0b000000-0000-4000-8000-00000000a3b1', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false);

-- e3b's session runs with no plan at all: no clock, no engine, and so nothing to draw.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
values ('0b000000-0000-4000-8000-00000000d3b1', '0b000000-0000-4000-8000-000000000e3b',
        now() - interval '1 minute', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', null, null, 0);

commit;

select e.id as event, s.id as session, s.t0_at,
       (s.t0_at + interval '5 minutes' - now()) as next_moment_in,
       (select count(*) from public.plan_positions p where p.plan_id = s.plan_id) as positions,
       (select count(*) from public.plan_positions p
         where p.plan_id = s.plan_id and p.group_id = '0b000000-0000-4000-8000-00000000a391') as gate_positions
from public.events e
join public.event_sessions s on s.event_id = e.id
where e.id = '0b000000-0000-4000-8000-000000000e39';
