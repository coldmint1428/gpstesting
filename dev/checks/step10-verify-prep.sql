-- A plan for step 10's browser check: "Flags bench" -- three frames, three groups, every position trusted and on
-- site, and the shape the bulk controls are about.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step10-verify-prep.sql
--     node tools/run.mjs dev/checks/step10-flags.mjs --session .tmp/session.json
--
-- +0:00 and +5:00 each state Gate Crew, Sound and Backstage (so a bulk confirmation over the two frames x two groups
-- is FOUR positions, and the third group is there to be left alone). +10:00 states only Sound, so the board has a
-- frame that carries the other two forward -- the case the confirmation buttons must not invent a position for.
--
-- It is written eight hours ago, so it sorts after every fixture plan and the board still opens "Copy bench" by
-- default: a check that needs a plan of its own must not change what every other check sees first.
--
-- Re-running this file rebuilds only that plan.
begin;

delete from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b10';
delete from public.plan_frames    where plan_id = '0b000000-0000-4000-8000-000000000b10';
delete from public.plans          where id      = '0b000000-0000-4000-8000-000000000b10';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01',
   'Flags bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '8 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0a01', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01',    0, 'six flags',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0a02', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01',  300, 'nine flags',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0a03', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01',  600, 'twelve flags', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Three groups at +0:00, each 10 m north at +5:00 -- legal steps, so a red dot after an edit is caused by the edit.
-- +10:00 moves Sound another 10 m and states nobody else.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f0a01', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3295000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a01', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3296000, 103.77450, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a01', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3297000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a02', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3295898, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a02', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3296898, 103.77450, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a02', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3297898, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0a03', '0b000000-0000-4000-8000-000000000b10', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3297796, 103.77450, 'on_site', 'auto');

commit;

select p.name,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plan_positions where plan_id = p.id) as positions,
       (select count(*) from public.plan_positions where plan_id = p.id and verify = 'manual') as manual,
       (select count(*) from public.plan_check(p.id)) as breaks
from public.plans p
where p.id = '0b000000-0000-4000-8000-000000000b10';
