-- A plan for step 12's browser check: ten evenly spaced frames, one group standing still across all of them.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step12-stretch-prep.sql
--     node tools/run.mjs dev/checks/step12-stretch.mjs --session .tmp/session.json
--
-- This is the Done-when's strip: ten frames, fifteen seconds apart, Gate Crew in one place for the whole of it. Every
-- neighbouring pair is 0 m, so the plan is legal before the check does anything. The check then drags the badge on the
-- middle frame 200 m east, which breaks the two hops either side of it and leaves the other seven alone -- so "every
-- frame in the stretch is marked" is a count the check can take (three), and "publish still fails for the two
-- neighbouring hops" is a queue it can count (two rows).
--
-- Sound is the second group, and it never moves: it is the check's ruler (100 m east of Gate Crew, so the map can say
-- how many pixels a metre is without assuming a zoom), and the contrast for the marks -- the stretch is Gate Crew's,
-- and Sound's lane must stay clean.
--
-- The strip stands 450 m north of every zone in the bench, so the drag cannot cross anything, and the plan is written
-- six hours ago so it sorts after every fixture plan and the board still opens "Copy bench" by default.
--
-- Re-running this file rebuilds only that plan. The check leaves it with a 200 m hop, so run this again before a
-- second run.
begin;

delete from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b1a';
delete from public.plan_frames    where plan_id = '0b000000-0000-4000-8000-000000000b1a';
delete from public.plans          where id      = '0b000000-0000-4000-8000-000000000b1a';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b1a', '0b000000-0000-4000-8000-000000000e01',
   'Stretch bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '6 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select
  ('0b000000-0000-4000-8000-0000000f1a' || lpad((k + 1)::text, 2, '0'))::uuid,
  '0b000000-0000-4000-8000-000000000b1a',
  '0b000000-0000-4000-8000-000000000e01',
  k * 15, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
from generate_series(0, 9) k;

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
select
  ('0b000000-0000-4000-8000-0000000f1a' || lpad((k + 1)::text, 2, '0'))::uuid,
  '0b000000-0000-4000-8000-000000000b1a',
  '0b000000-0000-4000-8000-000000000e01',
  '0b000000-0000-4000-8000-00000000a001',
  1.3340000, 103.7730000, 'on_site', 'auto'
from generate_series(0, 9) k;

-- Sound, stated once and carried for the rest of the strip: 100 m east (0.0008985 degrees of longitude at 1.334°).
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f1a01', '0b000000-0000-4000-8000-000000000b1a', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.7738985, 'on_site', 'auto');

commit;

select p.name,
       (select count(*) from public.plan_frames where plan_id = p.id) as frames,
       (select count(*) from public.plan_positions where plan_id = p.id) as positions,
       (select min(t_s) from public.plan_frames where plan_id = p.id) as first_s,
       (select max(t_s) from public.plan_frames where plan_id = p.id) as last_s,
       (select count(*) from public.plan_check(p.id)) as breaks
from public.plans p
where p.id = '0b000000-0000-4000-8000-000000000b1a';
