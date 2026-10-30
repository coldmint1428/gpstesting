-- The bench step 22's browser check reads: a live plan whose walk can be played, and a timeline change that reached
-- one group and not the other.
--
--     node tools/sql.mjs --file dev/checks/step22-play-prep.sql
--     node tools/run.mjs dev/checks/step22-play.mjs --session .tmp/session.json
--
-- Why an event of its own. The plan bench's "Clean walk" is shared by every other check, and its clock is a fixed
-- fixture time that is often in the future; a play of the run and a list of what people were told both need a clock
-- that is moving *now* and a log that is this check's own. So this event is built for this check: two groups (one with
-- two people, so a tally of "1 of 2" means something), one live plan three moments long, one open session whose T+0 is
-- thirty seconds ago, and one published change that moved Gate Crew's last moment and left Sound's walk alone.
--
-- The published change is the point of the member tabs: the log row it wrote is addressed to Gate Crew's two people
-- and to nobody else, so the Gate Crew IC's schedule shows "Your times changed" and the Sound member's does not --
-- the same fact the SQL check asserts at the database, read here as a person reads it.
--
-- It is inserted as a draft and published through plan_publish, so the two publishes are real: the first announces the
-- plan (and tells nobody, because nobody was following it yet), the second moves one group's moment and writes the
-- timeline row. The session is started between them, which is also what makes the row carry a session.
--
-- Safe to re-run: everything this file owns is deleted first.

begin;

delete from public.push_queue     where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.plan_frames    where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.plan_log       where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e32';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e32';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e32',
  'Playback bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 22 (playback, the plan log and one tap to ack). Rebuilt by dev/checks/step22-play-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '2 minutes',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a321', '0b000000-0000-4000-8000-000000000e32', 'Gate Crew', 'GATE',  '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a322', '0b000000-0000-4000-8000-000000000e32', 'Sound',     'SOUND', '#8a5a2b');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e32', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e32', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e32', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  ('0b000000-0000-4000-8000-000000000e32', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e32', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e32', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a321', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a321', '00cd023b-0e26-4574-a635-760e782c8029', true, false),
  ('0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a322', '2906655b-33ad-4e9d-a608-f083e43e22d4', true, true);

insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', 'Playback walk',
       (now() at time zone 'Asia/Singapore' - interval '30 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '30 seconds')::time,
       'draft', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select f.id, '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', f.t_s, f.note,
       'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from (values
    ('0b000000-0000-4000-8000-0000000f3211'::uuid,    0, 'call'),
    ('0b000000-0000-4000-8000-0000000f3212'::uuid,   60, 'stage'),
    ('0b000000-0000-4000-8000-0000000f3213'::uuid,  120, 'out')
  ) f(id, t_s, note);

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state) values
  ('0b000000-0000-4000-8000-0000000f3211', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a321', 1.3300000, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f3212', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a321', 1.3302171, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f3213', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a321', 1.3304342, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f3211', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a322', 1.3340000, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f3212', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a322', 1.3342171, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f3213', '0b000000-0000-4000-8000-000000000b32', '0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-00000000a322', 1.3344342, 103.77300, 'on_site');

-- The first publish: the root announces the plan. Nobody is told -- there is no version to compare it with.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b32', 1);
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e32', '0b000000-0000-4000-8000-000000000b32');
  perform set_config('prep.session', v_s::text, true);
end $$;

-- End of the first publish. Everything below is written as the owner, because it is fixture, not product.
reset role;

-- Gate Crew's last moment moves five metres east: one group's walk changes, and the other's does not.
update public.plan_positions set lng = 103.774045
 where group_id = '0b000000-0000-4000-8000-00000000a321'
   and frame_id = '0b000000-0000-4000-8000-0000000f3213';

-- The second publish: one timeline row, addressed to Gate Crew's two people only.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b32', 2);
end $$;

reset role;

-- The session the presence trigger looks for: start_event set starts_at to now, which is where the plan's clock is.
update public.event_sessions set starts_at = now() - interval '30 seconds'
 where id = current_setting('prep.session')::uuid;

commit;
