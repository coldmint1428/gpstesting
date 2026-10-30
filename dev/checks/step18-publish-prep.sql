-- The bench step 18's browser check reads: a live event three tabs' worth of planners can publish against.
--
--     node tools/sql.mjs --file dev/checks/step18-publish-prep.sql
--     node tools/run.mjs dev/checks/step18-publish.mjs --session .tmp/session.json
--
-- Why an event of its own. The check copies the live plan, edits the copy in one tab, publishes from that tab, and then
-- publishes the *same copy* from the first tab -- which must be refused as stale. So it needs a bench whose clock is
-- already running (a copy taken mid-walk is the honest case) and one it can rebuild after a run.
--
-- The walk: five moments five minutes apart. Gate Crew walks 25 m north a frame the whole way; Sound stands at the
-- call and again at the way out. T+0 is ninety seconds ago, so the copy starts just past the call and keeps the four
-- later moments -- the last of which (the way out) is the one the second tab edits.
--
-- testuser1 is the root planner and draws both tabs (the harness drives one browser profile, so two tabs share one
-- signed-in session). testuser2 is a second planner on the event, which is where the database half of the step proves
-- that two *different* planners cannot both publish from the same revision.

begin;

/* The copy the check published last time goes first, and the PLAN row is what is deleted: its frames, positions and
   versions go with it. Deleting a copy's positions on their own would be refused -- the cut freezes them (053). */
delete from public.plans where fork_of = '0b000000-0000-4000-8000-000000000b18';

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.plan_frames    where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e18';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e18';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e18',
  'Publish bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 18 (publishing is compare-and-set). Rebuilt by dev/checks/step18-publish-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '90 seconds',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a180', '0b000000-0000-4000-8000-000000000e18', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a181', '0b000000-0000-4000-8000-000000000e18', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e18', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e18', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e18', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  -- A participant is an event_roles row as well as a group_members row: is_event_member() reads event_roles (036).
  ('0b000000-0000-4000-8000-000000000e18', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a181', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false);

-- The plan is live and its printed T+0 is ninety seconds ago. It is inserted, not published, so the revision the
-- session follows is 1 and the check's own publish of the copy is the visible step to 2.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', 'Doors walk',
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::time,
       'live', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f18a1', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f18a2', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f18a3', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18',  600, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f18a4', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18',  900, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f18a5', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', 1200, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew walks 25 m north a frame; Sound stands at the call and again at the way out. The way-out moment has no
-- note, which is the frame the second tab labels.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f18a1', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a180', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f18a2', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a180', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f18a3', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a180', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f18a4', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a180', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f18a5', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a180', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f18a1', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a181', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f18a5', '0b000000-0000-4000-8000-000000000b18', '0b000000-0000-4000-8000-000000000e18', '0b000000-0000-4000-8000-00000000a181', 1.3340000, 103.77300);

-- The session, on the plan's own clock: t0_at is plan_t0(b18), which is ninety seconds ago.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d018', '0b000000-0000-4000-8000-000000000e18',
       now() - interval '90 seconds', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b18', public.plan_t0('0b000000-0000-4000-8000-000000000b18'), 1;

commit;

select e.id as event, p.id as plan, p.status, p.rev, s.id as session, s.t0_at,
       (now() - s.t0_at) as clock_age,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plans where event_id = e.id) as plans
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e18';
