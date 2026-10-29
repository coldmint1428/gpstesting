-- The bench step 19's browser check reads: a live plan two tabs of one planner can edit, one watching the other.
--
--     node tools/sql.mjs --file dev/checks/step19-realtime-prep.sql
--     node tools/run.mjs dev/checks/step19-realtime.mjs --session .tmp/session.json
--
-- Why an event of its own. The check needs a *live* plan with a session on it (so the board opens it on its own and
-- the strip is on), and it edits through those two tabs, so the next run must start from the same three frames. The
-- event is rebuilt from scratch every time: the previous run published the plan (revision 2) and added a fourth
-- frame, and neither may leak into the next run's first assertion.
--
-- The walk: three moments five minutes apart. Gate Crew walks 25 m north a frame; Sound stands at the call and again
-- at the way out. The last moment has no note -- that is the frame the second tab labels.

begin;

delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e19'; -- frames, positions, versions
delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e19';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e19';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e19',
  'Realtime bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 19 (a change reaches the other screens). Rebuilt by dev/checks/step19-realtime-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '2 minutes',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a190', '0b000000-0000-4000-8000-000000000e19', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a191', '0b000000-0000-4000-8000-000000000e19', 'Sound',     'SOUND', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e19', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e19', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  -- A participant is an event_roles row as well as a group_members row: is_event_member() reads event_roles (036).
  ('0b000000-0000-4000-8000-000000000e19', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a191', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, false);

-- Live at revision 1, its printed T+0 two minutes ago: the board opens it without being asked, and the strip is on.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', 'Live walk',
       (now() at time zone 'Asia/Singapore' - interval '2 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '2 minutes')::time,
       'live', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1901', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19',   0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1902', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', 300, 'build', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1903', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', 600, null,    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f1901', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a190', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1902', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a190', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1903', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a190', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1901', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a191', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1903', '0b000000-0000-4000-8000-000000000b19', '0b000000-0000-4000-8000-000000000e19', '0b000000-0000-4000-8000-00000000a191', 1.3340000, 103.77300);

-- The session, on the plan's own clock: t0_at is plan_t0(b19), two minutes ago.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, plan_id, t0_at, plan_rev)
select '0b000000-0000-4000-8000-00000000d019', '0b000000-0000-4000-8000-000000000e19',
       now() - interval '2 minutes', null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
       '0b000000-0000-4000-8000-000000000b19', public.plan_t0('0b000000-0000-4000-8000-000000000b19'), 1;

commit;

select e.id as event, p.id as plan, p.status, p.rev, s.id as session, s.t0_at,
       (now() - s.t0_at) as clock_age,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plans where event_id = e.id) as plans
  from public.events e
  join public.plans p on p.event_id = e.id
  join public.event_sessions s on s.event_id = e.id
 where e.id = '0b000000-0000-4000-8000-000000000e19';
