-- The bench step 16's browser check reads: a live event whose timetable already has every word on it.
--
--     node tools/sql.mjs --file dev/checks/step16-schedule-prep.sql
--     node tools/run.mjs dev/checks/step16-schedule.mjs --session .tmp/session.json
--
-- Why an event of its own, and not the plan bench. The plan bench is shared by every other check, and its "Clean
-- walk" T+0 is 18:00 on the fixture's day -- often in the future, which is exactly the clock a schedule must not be
-- judged by. This event is built for this check and can be rebuilt without touching anybody else's den: two groups,
-- one live plan, one open session whose T+0 is fifteen minutes ago, and four recorded outcomes.
--
-- What the five moments were built to say, as the Sound member reads them:
--
--   +0:00    arrived, two minutes late        (the call)
--   +5:00    not required                     (off site at the build)
--   +10:00   late, unmarked                   (nobody has said anything and the clock has passed it)
--   +13:00   missed, decided a minute after   (the curtain)
--   +25:00   pending                          (the way out, still to come)
--
-- so one screen carries every word the timetable can print. Gate Crew is the other group: arrived, arrived on site,
-- late, arrived, pending -- present so that "the member sees only Sound" has something it must not show, and so the
-- marshal's read has two rows a moment rather than one.
--
-- testuser3 is a plain member of Sound on purpose: step 16's done-when is about a member, not an IC or an admin.
-- testuser5 is a marshal with no group, so the ops read is proved on the same fixture. testuser1 draws the board.

begin;

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.plan_frames    where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e16';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e16';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e16',
  'Schedule bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 16 (the member''s schedule). Rebuilt by dev/checks/step16-schedule-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '15 minutes',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a160', '0b000000-0000-4000-8000-000000000e16', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a161', '0b000000-0000-4000-8000-000000000e16', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e16', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e16', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e16', '00cd023b-0e26-4574-a635-760e782c8029', 'marshal'),
  -- A participant is an event_roles row as well as a group_members row: is_event_member() reads event_roles, so a
  -- person who is only "in a group" is not a member of the event at all (036's shape, and why the bench fixture
  -- lists participants here too).
  ('0b000000-0000-4000-8000-000000000e16', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e16', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a161', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false),
  ('0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true,  false);

-- The plan is already live and its clock is the fixture's: T+0 fifteen minutes ago. It is inserted rather than
-- published so the revision the session follows is 1 and the check's own republish is the visible step to 2.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', 'Doors walk',
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::time,
       'live', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f16a1', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f16a2', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f16a3', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',  600, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f16a4', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',  780, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f16a5', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', 1500, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew walks 25 m north a frame. Sound stands at the call, is off site for the build, and is back 25 m north
-- at +10:00, where it stays. Legal, so a republish passes the gate.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f16a1', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f16a2', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f16a3', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f16a4', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f16a5', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a160', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f16a1', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a161', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f16a2', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a161', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f16a3', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16', '0b000000-0000-4000-8000-00000000a161', 1.3342171, 103.77300);

update public.plan_positions
   set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f16a2'
   and group_id = '0b000000-0000-4000-8000-00000000a161';

-- The session is opened the way the app opens one, except for the door: the fixture writes the row so the clock is
-- exactly fifteen minutes old when the check starts. t0_at is the plan's own T+0, not now() -- the two are the same
-- here and the read must agree with the plan.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d016', '0b000000-0000-4000-8000-000000000e16',
       now() - interval '15 minutes', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b16', public.plan_t0('0b000000-0000-4000-8000-000000000b16'), 1;

-- What was recorded. The planner is the ops person who would have said it; a plain member marks nothing.
insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select '0b000000-0000-4000-8000-00000000d016', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',
       '0b000000-0000-4000-8000-0000000f16a1', '0b000000-0000-4000-8000-00000000a161', 'arrived',
       t0_at + interval '120 seconds', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from public.event_sessions where id = '0b000000-0000-4000-8000-00000000d016';

insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select '0b000000-0000-4000-8000-00000000d016', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',
       '0b000000-0000-4000-8000-0000000f16a4', '0b000000-0000-4000-8000-00000000a161', 'missed',
       t0_at + interval '840 seconds', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from public.event_sessions where id = '0b000000-0000-4000-8000-00000000d016';

insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select '0b000000-0000-4000-8000-00000000d016', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',
       '0b000000-0000-4000-8000-0000000f16a1', '0b000000-0000-4000-8000-00000000a160', 'arrived',
       t0_at, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from public.event_sessions where id = '0b000000-0000-4000-8000-00000000d016';

insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select '0b000000-0000-4000-8000-00000000d016', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e16',
       '0b000000-0000-4000-8000-0000000f16a4', '0b000000-0000-4000-8000-00000000a160', 'arrived',
       t0_at + interval '810 seconds', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from public.event_sessions where id = '0b000000-0000-4000-8000-00000000d016';

commit;

select e.id as event, p.id as plan, s.id as session, s.t0_at,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plan_progress where session_id = s.id) as marks,
       (select string_agg(distinct state, ',' order by state) from public.plan_progress where session_id = s.id) as states
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e16';
