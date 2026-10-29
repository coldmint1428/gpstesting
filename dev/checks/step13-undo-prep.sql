-- A plan for step 13's browser check: four legal frames, one group standing still across all of them.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step13-undo-prep.sql
--     node tools/run.mjs dev/checks/step13-undo.mjs --session .tmp/session.json
--
-- "Undo bench" is the smallest strip the Done-when can be measured on: four frames a minute apart, Gate Crew at the
-- same coordinate on every one (every hop is 0 m, so the plan is legal), and Sound 100 m east as the map's ruler --
-- the same trick step 12 uses, because "drag it 40 m" has to be a number of pixels the check can work out rather than
-- a number it assumes. A 40 m drag of the middle badge breaks the two hops either side of it (40 m over one step is
-- over the 25 m budget), so "two rows and three red dots" is a count, and undoing it has to leave none.
--
-- The fourth frame is there for the push. Selecting +1:00 and +2:00 and dragging them +1:30 lands them at +2:30 and
-- +3:30 -- and the frame that stayed at +3:00 sits INSIDE that range, which is the one case where undoing a push by
-- its two times would drag a frame that was never part of the edit. Three frames could not show that.
--
-- The strip stands 450 m north of every zone in the bench, so no drag can cross anything, and the plan is written six
-- hours ago so it sorts after every fixture plan and the board still opens "Copy bench" by default (which is what the
-- early checks assume).
--
-- Re-running this file rebuilds only this plan. The check leaves it published with the same four frames and no
-- breaks, so a second run needs this file again (a live plan cannot be published twice).
begin;

delete from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b1b';
delete from public.plan_frames    where plan_id = '0b000000-0000-4000-8000-000000000b1b';
delete from public.plans          where id      = '0b000000-0000-4000-8000-000000000b1b';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b1b', '0b000000-0000-4000-8000-000000000e01',
   'Undo bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '6 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select
  ('0b000000-0000-4000-8000-0000000f1b' || lpad((k + 1)::text, 2, '0'))::uuid,
  '0b000000-0000-4000-8000-000000000b1b',
  '0b000000-0000-4000-8000-000000000e01',
  k * 60,
  case when k = 1 then 'doors' when k = 3 then 'walk on' end,
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
from generate_series(0, 3) k;

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
select
  ('0b000000-0000-4000-8000-0000000f1b' || lpad((k + 1)::text, 2, '0'))::uuid,
  '0b000000-0000-4000-8000-000000000b1b',
  '0b000000-0000-4000-8000-000000000e01',
  '0b000000-0000-4000-8000-00000000a001',
  1.3340000, 103.7730000, 'on_site', 'auto'
from generate_series(0, 3) k;

-- Sound, stated once and carried for the rest of the strip: 100 m east (0.0008985 degrees of longitude at 1.334°).
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f1b01', '0b000000-0000-4000-8000-000000000b1b', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.7738985, 'on_site', 'auto');

commit;

select p.name, p.status,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plan_positions where plan_id = p.id) as positions,
       (select count(*) from public.plan_check(p.id)) as breaks
from public.plans p
where p.id = '0b000000-0000-4000-8000-000000000b1b';
