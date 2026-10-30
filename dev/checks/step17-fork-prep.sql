-- The bench step 17's browser check reads: a live event that is already a minute and a half into its walk.
--
--     node tools/sql.mjs --file dev/checks/step17-fork-prep.sql
--     node tools/run.mjs dev/checks/step17-fork.mjs --session .tmp/session.json
--
-- Why an event of its own. The plan bench's "Clean walk" T+0 is 18:00 on the fixture's day, which is not a clock a
-- mid-walk copy can be judged by, and the check changes the plan it reads (it copies it and edits the copy), so it
-- needs a bench it can rebuild: one live plan whose clock is already running, two groups, and one open session.
--
-- The walk: five moments five minutes apart. Gate Crew walks 25 m north a frame the whole way; Sound stands at the
-- call and again at the way out. T+0 is ninety seconds ago, so the copy the check takes is anchored between the call
-- and the build -- which is the point: the anchor has to be interpolated, not one of the two dots.
--
-- testuser3 is a plain member of Sound: step 17's screen half is about what a person following the plan sees before
-- and after the copy is published. testuser1 draws the board.

begin;

/* Every plan of the event is deleted as a PLAN, first: its frames and positions go with it through the cascade.
   Deleting a copy's positions on their own would be refused -- the cut freezes them (053) -- and so would deleting
   the original first, because that nulls the copy's fork_of (on delete set null) and leaves a plan this file no
   longer names. That half-state is what this file used to leave behind when it ran after a check had already
   published the copy; the event's own plans are the unit, whatever their fork_of says. */
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e17';

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e17';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e17';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e17',
  'Fork bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 17 (fork without teleporting anyone). Rebuilt by dev/checks/step17-fork-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '90 seconds',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a170', '0b000000-0000-4000-8000-000000000e17', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a171', '0b000000-0000-4000-8000-000000000e17', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e17', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e17', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  -- A participant is an event_roles row as well as a group_members row: is_event_member() reads event_roles (036).
  ('0b000000-0000-4000-8000-000000000e17', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e17', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a171', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false),
  ('0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true,  false);

-- The plan is live and its printed T+0 is the fixture's clock: ninety seconds ago. It is inserted, not published, so
-- the revision the session follows is 1 and the check's own publish of the copy is the visible step to 2.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', 'Doors walk',
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::time,
       'live', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f17a1', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f17a2', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f17a3', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17',  600, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f17a4', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17',  900, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f17a5', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', 1200, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew walks 25 m north a frame, so the anchor the copy takes is a point on a straight line between two dots.
-- Sound stands at the call, and again at the way out: its anchor should be exactly where it stood.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f17a1', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f17a2', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f17a3', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f17a4', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f17a5', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a170', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f17a1', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a171', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f17a5', '0b000000-0000-4000-8000-000000000b17', '0b000000-0000-4000-8000-000000000e17', '0b000000-0000-4000-8000-00000000a171', 1.3340000, 103.77300);

-- The session, on the plan's own clock: t0_at is plan_t0(b17), which is ninety seconds ago.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d017', '0b000000-0000-4000-8000-000000000e17',
       now() - interval '90 seconds', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b17', public.plan_t0('0b000000-0000-4000-8000-000000000b17'), 1;

commit;

select e.id as event, p.id as plan, p.status, s.id as session, s.t0_at,
       (now() - s.t0_at) as clock_age,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plans where event_id = e.id) as plans
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e17';
