-- A plan for step 9's browser check: "Twin gap", copied, with one of its two 200 m jumps flagged off site.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step9-off-site-prep.sql
--     node tools/run.mjs dev/checks/step9-off-site.mjs --session .tmp/session.json
--
-- The coordinates are Twin gap's, to the digit, because the point of the pair is that the picture is the same and the
-- warning is not: two plans one flag apart. Both groups are 200 m east between +0:00 and +5:00 -- the bench's own
-- arrangement -- so "Twin gap" reports two breaks and "Off-site twin" reports one.
--
-- It is written six hours ago, so it sorts after every fixture plan and the board still opens "Copy bench" by
-- default: a check that needs a plan of its own must not change what every other check sees first.
--
-- Re-running this file rebuilds only that plan.
begin;

delete from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b08';
delete from public.plan_frames    where plan_id = '0b000000-0000-4000-8000-000000000b08';
delete from public.plans          where id      = '0b000000-0000-4000-8000-000000000b08';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01',
   'Off-site twin', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '6 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0801', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01',   0, 'both here',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0802', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01', 300, 'both there', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  -- Gate Crew: on site by the gate, then 200 m east and OFF SITE, waiting to be confirmed by hand.
  ('0b000000-0000-4000-8000-0000000f0801', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77500, 'on_site',  'auto'),
  ('0b000000-0000-4000-8000-0000000f0802', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77680, 'off_site', 'manual'),
  -- Sound: the same walk, and it really is the walk -- this is the break the board must still report.
  ('0b000000-0000-4000-8000-0000000f0801', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3311000, 103.77500, 'on_site',  'auto'),
  ('0b000000-0000-4000-8000-0000000f0802', '0b000000-0000-4000-8000-000000000b08', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3311000, 103.77680, 'on_site',  'auto');

commit;

select p.name,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plan_positions where plan_id = p.id) as positions,
       (select count(*) from public.plan_positions where plan_id = p.id and state = 'off_site') as off_site,
       (select count(*) from public.plan_check(p.id)) as breaks
from public.plans p
where p.id = '0b000000-0000-4000-8000-000000000b08';
