-- The bench step 21's browser check reads: a live plan whose +1:00 moment is two seconds from being due, one group whose
-- position is `auto` and whose IC is already inside the zone its moment stands in, and one group whose position is
-- `manual` and whose IC is inside its zone too.
--
--     node tools/sql.mjs --file dev/checks/step21-ops-prep.sql
--     node tools/run.mjs dev/checks/step21-ops.mjs --session .tmp/session.json
--
-- The two groups are the two halves of step 21's arrival marking: the deployed 5 s tick closes the auto one by itself
-- (the check watches it appear, with nothing clicked), and the manual one waits for a person -- which is what the check
-- then does, and what the group's own IC would do on a phone today.
--
-- WHY THE CLOCK IS 40 SECONDS IN. The moment has to be comfortably ahead when the page opens -- the check watches the
-- two buttons appear, then the tick close the moment behind them -- and close enough that the wait is a few seconds. Gate
-- Crew's +1:00 is due twenty seconds after this file commits, and the cron job runs every five.
--
-- The prep is idempotent: it deletes the event, its plans, sessions, readings and hand-backs first. The zone is a plain
-- box around the +1:00 statement, 24 m deep, so the +0:00 statement is outside it -- the point of "inside ITS zone".

begin;

delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.handover_log   where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.locations      where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.zone_presence  where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.zone_alerts    where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e31';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e31';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e31', 'Push bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 21 (auto close, arrival marking, hand-back). Rebuilt by dev/checks/step21-ops-prep.sql; safe to delete.',
        'Bukit Timah', now() - interval '3 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a311', '0b000000-0000-4000-8000-000000000e31', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a312', '0b000000-0000-4000-8000-000000000e31', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e31', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e31', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e31', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e31', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a311', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a312', '00cd023b-0e26-4574-a635-760e782c8029', true, false);

-- A box 24 m deep around each group's +1:00 statement.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c311', '0b000000-0000-4000-8000-000000000e31', 'GATE_Z', 'Gate stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77382 1.33010, 103.77418 1.33010, 103.77418 1.33034, 103.77382 1.33034, 103.77382 1.33010))'), false),
  ('0b000000-0000-4000-8000-00000000c312', '0b000000-0000-4000-8000-000000000e31', 'SOUND_Z', 'Sound stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77282 1.33410, 103.77318 1.33410, 103.77318 1.33434, 103.77282 1.33434, 103.77282 1.33410))'), false);

-- Published and live, revision 1, its printed T+0 forty seconds ago: the +1:00 moment is due in twenty seconds.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, published_at, created_by)
select '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', 'Push walk',
       (now() at time zone 'Asia/Singapore' - interval '40 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '40 seconds')::time,
       'live', 1, now(), 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f3101', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31',   0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3102', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31',  60, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3103', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', 120, 'out',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f3101', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a311', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3102', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a311', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3103', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a311', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3101', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a312', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f3102', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a312', 1.3342171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f3103', '0b000000-0000-4000-8000-000000000b31', '0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a312', 1.3342171, 103.77300);

-- Gate Crew's position is trusted as drawn (auto: the tick may close it); Sound's is manual (a person must).
update public.plan_positions set verify = 'manual'
 where group_id = '0b000000-0000-4000-8000-00000000a312';

insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d031', '0b000000-0000-4000-8000-000000000e31',
       now() - interval '3 minutes', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b31', public.plan_t0('0b000000-0000-4000-8000-000000000b31'), 1;

-- Both ICs are already standing inside the zone their group's +1:00 moment is in. Gate Crew's reading is older than its
-- moment, so its close is dated from the plan; Sound's close, if it were automatic, would be dated from the reading.
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a311',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3302171, 103.77400, 5, 'gps', now() - interval '40 seconds'),
  ('0b000000-0000-4000-8000-000000000e31', '0b000000-0000-4000-8000-00000000a312',
   '00cd023b-0e26-4574-a635-760e782c8029', 1.3342171, 103.77300, 6, 'gps', now() - interval '30 seconds');

commit;

select e.id as event, p.id as plan, s.id as session, s.t0_at,
       s.t0_at + interval '60 seconds' as stage_moment,
       (s.t0_at + interval '60 seconds' - now()) as due_in,
       (select count(*) from public.zone_presence where event_id = e.id) as presences,
       (select count(*) from public.plan_progress where event_id = e.id) as marks
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e31';
