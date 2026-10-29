-- The bench step 20's browser check reads: a live plan whose clock is a few seconds in, three groups in three
-- different states, and two ICs whose midpoint puts their group a metre off the walk.
--
--     node tools/sql.mjs --file dev/checks/step20-ops-prep.sql
--     node tools/run.mjs dev/checks/step20-ops.mjs --session .tmp/session.json
--
-- Why an event of its own. The check watches a status flip, so it needs a clock whose next moment is ahead when the
-- page opens and whose group is already walking when it does. The bench's own event is rebuilt by every other check
-- and has an ended session; this one is rebuilt from scratch on every run, so the first assertion always meets the
-- same numbers: Gate Crew's first leg is 45 s (it is walking when the page opens), Sound's first moment is that same
-- +0:45 (it has not started), and Backstage appears at +1:45.
--
-- The two readings are Gate Crew's ICs, 20 m apart: testuser4 is 5 m accurate at the point the walk expects, testuser5
-- is 20 m north and 20 m accurate. The midpoint is 1.18 m from the walk, so the board should say "1 m from the walk",
-- not 10 m and not 20 m -- the same number step20-ops.sql asserts in degrees.
--
-- T+0 is two seconds ago and the session's starts_at ten seconds ago, so the presence trigger finds the session for
-- both readings (021 needs starts_at at or before the reading's own time).

begin;

delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.locations      where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.zone_presence  where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.zone_alerts    where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e20';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e20';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e20',
  'Ops bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 20 (the ops board and where a group really is). Rebuilt by dev/checks/step20-ops-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '2 minutes',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a200', '0b000000-0000-4000-8000-000000000e20', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a201', '0b000000-0000-4000-8000-000000000e20', 'Sound',     'SOUND', '#8a5a2b', 'crew'),
  ('0b000000-0000-4000-8000-00000000a202', '0b000000-0000-4000-8000-000000000e20', 'Backstage', 'BACK',  '#3b5a8a', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e20', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e20', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e20', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e20', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200', '00cd023b-0e26-4574-a635-760e782c8029', true, false);

-- Published and live, revision 1, its printed T+0 two seconds ago.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, published_at, created_by)
select '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', 'Ops walk',
       (now() at time zone 'Asia/Singapore' - interval '2 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '2 seconds')::time,
       'live', 1, now(), 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2101', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20',   0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2102', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20',  45, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2103', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', 105, 'out',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f2101', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2102', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2102', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a201', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2103', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a201', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2103', '0b000000-0000-4000-8000-00000000b020', '0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a202', 1.3350000, 103.77500);

insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d020', '0b000000-0000-4000-8000-000000000e20',
       now() - interval '10 seconds', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-00000000b020', public.plan_t0('0b000000-0000-4000-8000-00000000b020'), 1;

-- Gate Crew's two ICs, 20 m apart (0.0001797 degrees of latitude).
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3300000, 103.77400,  5, 'gps', now() - interval '10 seconds'),
  ('0b000000-0000-4000-8000-000000000e20', '0b000000-0000-4000-8000-00000000a200',
   '00cd023b-0e26-4574-a635-760e782c8029', 1.3301797, 103.77400, 20, 'gps', now() - interval '5 seconds');

commit;

select e.id as event, p.id as plan, p.status, s.id as session, s.t0_at,
       (now() - s.t0_at) as clock_age, s.starts_at,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.locations where event_id = e.id) as readings,
       (select count(*) from public.group_positions where event_id = e.id) as positions
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e20';
