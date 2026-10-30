-- The bench step 28's browser check reads: a live plan two moments into its walk, one group whose IC is about to press
-- "We're here", and one group whose IC is standing on its moment so the tick closes it by itself.
--
--     node tools/sql.mjs --file dev/checks/step28-here-prep.sql
--     node tools/run.mjs dev/checks/step28-here.mjs --session .tmp/session.json
--
-- Needs two more sessions (the check says so if they are missing):
--     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew IC)
--     node tools/authlink.mjs 00cd023b-0e26-4574-a635-760e782c8029 .tmp/session5.json   (Gate Crew's second IC)
--
-- WHY THE FIRST MOMENT IS DUE AND THE NEXT IS FIVE MINUTES AWAY. The press belongs to the moment the clock is on, and
-- the screen only offers it there: a check that has to open a page, click and reload needs that moment to stay current
-- for longer than a few seconds, so the strip is +0:00 / +5:00 / +10:00 and T+0 is a few seconds before the prep
-- commits. The second group's +0:00 is the tick's: its IC has a reading on the point and a zone around it, so the
-- deployed five-second job closes it -- which is how the ops board's "the phone was there" gets something to say
-- beside Gate Crew's "by hand".
--
-- The prep is idempotent: it deletes the event, its plans, sessions, readings and marks first.

begin;

delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.handover_log   where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.locations      where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.zone_presence  where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.zone_alerts    where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e38';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e38';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e38', 'Here bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 28 (the IC''s own "we''re here" press). Rebuilt by dev/checks/step28-here-prep.sql; safe to delete.',
        'Bukit Timah', now() - interval '2 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a381', '0b000000-0000-4000-8000-000000000e38', 'Gate Crew', 'GATE', '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a382', '0b000000-0000-4000-8000-000000000e38', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e38', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e38', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e38', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e38', '00cd023b-0e26-4574-a635-760e782c8029', 'participant'),
  ('0b000000-0000-4000-8000-000000000e38', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');

-- Gate Crew has two ICs (the press is the first one's; the second must see it already done), Sound has one.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a381', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a381', '00cd023b-0e26-4574-a635-760e782c8029', true, false),
  ('0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a382', '2906655b-33ad-4e9d-a608-f083e43e22d4', true, false);

-- A box 40 m deep around each group's +0:00 point, so the moment is a PLACE (062) and the tick has its gate (063).
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c381', '0b000000-0000-4000-8000-000000000e38', 'GATE_Z', 'Gate stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77362 1.33080, 103.77438 1.33080, 103.77438 1.33120, 103.77362 1.33120, 103.77362 1.33080))'), false),
  ('0b000000-0000-4000-8000-00000000c382', '0b000000-0000-4000-8000-000000000e38', 'SOUND_Z', 'Sound stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77262 1.33480, 103.77338 1.33480, 103.77338 1.33520, 103.77262 1.33520, 103.77262 1.33480))'), false);

-- Published and live, T+0 a few seconds ago, so +0:00 is the moment the clock is on and +5:00 is still ahead.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, published_at, created_by)
select '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', 'Here walk',
       (now() at time zone 'Asia/Singapore' - interval '5 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '5 seconds')::time,
       'live', 1, now(), 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f3801', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38',   0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3802', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', 300, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3803', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', 600, 'out',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- 24 m north a step in each group's own lane, so nothing here trips the 25 m rule.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f3801', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a381', 1.3310000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3802', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a381', 1.3312171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3803', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a381', 1.3314342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f3801', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a382', 1.3350000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f3802', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a382', 1.3352171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f3803', '0b000000-0000-4000-8000-000000000b38', '0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a382', 1.3354342, 103.77300);

insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d381', '0b000000-0000-4000-8000-000000000e38',
       now() - interval '1 minute', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b38', public.plan_t0('0b000000-0000-4000-8000-000000000b38'), 1;

-- Sound's IC is standing on its +0:00 point, so the tick closes that moment by itself. Gate Crew has NO reading: the
-- only way its moment closes is the press this bench exists for.
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e38', '0b000000-0000-4000-8000-00000000a382',
   '2906655b-33ad-4e9d-a608-f083e43e22d4', 1.3350000, 103.77300, 5, 'gps', now());

commit;

select e.id as event, s.id as session, s.t0_at, (s.t0_at + interval '5 minutes' - now()) as next_moment_in,
       (select count(*) from public.plan_progress where event_id = e.id) as marks_before_the_tick
from public.events e
join public.event_sessions s on s.event_id = e.id
where e.id = '0b000000-0000-4000-8000-000000000e38';
