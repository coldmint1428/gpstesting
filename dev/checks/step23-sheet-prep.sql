-- The bench step 23's browser check reads: a plan worth exporting, and a plan whose walk is one 100 m step.
--
--     node tools/sql.mjs --file dev/checks/step23-sheet-prep.sql
--     node tools/run.mjs dev/checks/step23-csv.mjs --session .tmp/session.json
--
-- Why an event of its own. The sheet's round trip is proved by exporting, throwing the plan away and importing the
-- file into a new plan with the same name, then exporting again and comparing the two files byte for byte. That needs
-- a plan nobody else's check writes to, a name of its own, and a plan with no session (an import is refused once what
-- actually happened has been marked, which is step 23's SQL check's case, not this one's).
--
-- "Sheet bench" is four moments with something in every corner of the file format: a note with a comma and quotation
-- marks, a group carried through a moment that does not state it, a position off site with a manual confirmation, a
-- 16-decimal latitude (so rounding on the way out would show up as a different file), and a moment nobody stands at
-- (which must still survive, as one row with the group cells empty).
--
-- "Sheet gap" is two moments with one impossible walk: Sound is a hundred metres from where it stood a minute earlier,
-- with no frame in between. It is legal to store (the board shows it red; a publish refuses it), which is exactly why
-- it can be exported -- and importing that same file has to be refused in the words the strip already uses.
--
-- "Sheet bench" is the newest plan, so the board opens it; the check switches to the other one by id.
--
-- Safe to re-run: everything this file owns is deleted first.

begin;

delete from public.push_queue     where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.plan_progress  where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.plan_frames    where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.plan_log       where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e23';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e23';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e23',
  'Sheet bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture for step 23 (the plan as a CSV sheet). Rebuilt by dev/checks/step23-sheet-prep.sql; safe to delete.',
  'Bukit Timah',
  now() - interval '2 minutes',
  now() + interval '2 hours'
);

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a231', '0b000000-0000-4000-8000-000000000e23', 'Gate Crew', 'GATE',  '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a232', '0b000000-0000-4000-8000-000000000e23', 'Sound',     'SOUND', '#8a5a2b');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e23', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e23', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner');

-- ---------- Sheet bench: everything a sheet has to carry ----------
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   'Sheet bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now());

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2311', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   0,   'Call, everyone at the "gate"', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2312', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   60,  null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2313', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   120, 'Out for the change', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2314', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   180, 'Back at the gate', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  -- Thirteen decimals: a sheet that rounded to six would write a different number, and the file has to carry this one.
  ('0b000000-0000-4000-8000-0000000f2311', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a231', 1.2966123456789, 103.773102, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f2311', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a232', 1.296621, 103.773211, 'on_site', 'auto'),
  -- 10 m north-east: one frame step, well inside the 25 m.
  ('0b000000-0000-4000-8000-0000000f2312', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a231', 1.2967023, 103.7732444, 'on_site', 'auto'),
  -- Off site, and somebody has to confirm it by hand: two flags a sheet has to carry without saying them differently.
  ('0b000000-0000-4000-8000-0000000f2313', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a231', 1.2967023, 103.7732444, 'off_site', 'manual'),
  -- Sound, stated at the call and again two frames later: 13 m over two steps, so the walk is legal.
  ('0b000000-0000-4000-8000-0000000f2313', '0b000000-0000-4000-8000-00000000b231', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a232', 1.296700, 103.773300, 'on_site', 'manual');
-- The fourth moment states nobody: it must survive a round trip as a row of its own.

-- ---------- Sheet gap: one impossible walk, 100 m in one frame step ----------
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   'Sheet gap', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '1 hour');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2321', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   0,  null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2322', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   60, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f2321', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a231', 1.296500, 103.773000, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f2321', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a232', 1.296600, 103.773100, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f2322', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a231', 1.296500, 103.773000, 'on_site', 'auto'),
  -- 0.0009 degrees of longitude at 1.2966 north: 100.2 m in one step.
  ('0b000000-0000-4000-8000-0000000f2322', '0b000000-0000-4000-8000-00000000b232', '0b000000-0000-4000-8000-000000000e23',
   '0b000000-0000-4000-8000-00000000a232', 1.296600, 103.774000, 'on_site', 'auto');

commit;

select p.name,
       (select count(*) from public.plan_frames f where f.plan_id = p.id) as frames,
       (select count(*) from public.plan_positions pp where pp.plan_id = p.id) as positions,
       (select count(*) from public.plan_check(p.id)) as breaks
from public.plans p
where p.event_id = '0b000000-0000-4000-8000-000000000e23'
order by p.created_at desc;
