-- A bench for the planning work: an event with enough variety that a check cannot pass by accident.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--
-- The old seed was one group and one plan, which made half of the later checks vacuous: "members see only their
-- own group" needs two members of two groups, "the weighted midpoint of two ICs" needs two ICs in one group, and
-- "a long jump is impossible" needs a long jump that is actually there.
--
-- What it builds, all under one fixed event id so it can be found and rebuilt:
--
--   groups     Gate Crew (two ICs), Sound (one IC, one member), Backstage (one member), Security (one member)
--   people     testuser1 root + planner; testuser2 planner; testuser3/4/5 participants (planners are never in a
--              group -- 036 -- so every IC here is a participant)
--   zones      a no-go zone sitting exactly between two positions of Security 20 m apart, so the straight line
--              crosses it and neither end is inside it; plus an unused obstacle further east
--   plan 1     "Walkthrough" -- six frames, 25 m per step for Gate Crew, one 200 m jump for Sound at +3:00, and
--              the Security pair that clips the no-go zone. Deliberately invalid: it is what publish must refuse
--   plan 2     "Clean walk" -- four frames, every group 25 m per step, nothing crossing. Deliberately valid: it
--              is what publish must accept
--   plan 3     "Copy bench" -- two frames for the copy/paste path: the first states three groups, the second states
--              only Gate Crew and carries a note. Copying the second and pasting it has to reproduce all three
--              positions at their inherited coordinates, not just the one group the frame mentions.
--   plan 4     "Twin gap" -- two groups 200 m away from where they stood, between the same two frames, so one
--              stretch is broken for two groups at once. Deliberately invalid in the same way twice: it is what
--              "fill this stretch" has to fix in one call naming both groups, not one call each.
--   plan 5     "Push bench" -- four frames at +0:00 / +1:00 / +2:00 / +3:00, every step legal and nothing
--              crossing. The exact strip step 6's Done-when names, so "shift +1:00..+2:00 by +5m moves two and
--              leaves the other two" can be clicked rather than argued. It is also the plan a check may push
--              around freely: pushing frames in time can make a legal strip illegal, and that is the point.
--
-- The clock is the other half of the bench. The plan's T+0 is 18:00 and the event's stated start is 18:45, so a
-- session that starts at 18:45 has a T+0 forty-five minutes before its own start. Until 038 that distinction did
-- not exist; from step 2 on, `t0_at` is the truth and `starts_at` is only when the button was pressed. Checks that
-- confuse the two now have something to fail on.
--
-- Re-running this file rebuilds the event from scratch and touches nothing else.
begin;

-- ---------- the event ----------
delete from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.plan_frames    where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e01';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values (
  '0b000000-0000-4000-8000-000000000e01',
  'Plan bench',
  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
  'Fixture event for the planning stage. Rebuilt by supabase/fixtures/plan_bench.sql; safe to delete.',
  'Bukit Timah',
  (current_date + time '18:45') at time zone 'Asia/Singapore',
  (current_date + time '21:00') at time zone 'Asia/Singapore'
);

-- ---------- groups ----------
insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a001', '0b000000-0000-4000-8000-000000000e01', 'Gate Crew', 'GATE',  '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a002', '0b000000-0000-4000-8000-000000000e01', 'Sound',     'SOUND', '#8a5a2b', 'crew'),
  ('0b000000-0000-4000-8000-00000000a003', '0b000000-0000-4000-8000-000000000e01', 'Backstage', 'BACK',  '#3b5a8a', 'crew'),
  ('0b000000-0000-4000-8000-00000000a004', '0b000000-0000-4000-8000-000000000e01', 'Security',  'SEC',   '#7a3742', 'crew');

-- ---------- who is who ----------
-- Planners are never in a group (036), so the ICs are the three participants: two of them in Gate Crew, which is
-- the pair the weighted midpoint is about.
insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e01', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e01', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e01', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  ('0b000000-0000-4000-8000-000000000e01', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e01', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e01', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

-- A person is in one group per event (group_members_event_id_user_id_key), so the ICs of Gate Crew are two
-- different people and the second member of the bench is in Sound. That is exactly what step 3 needs: two
-- participants who must each see only one group's positions.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true,  false),
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', '00cd023b-0e26-4574-a635-760e782c8029', true,  false),
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, true);

-- ---------- zones ----------
-- Stores: 4.5 m wide, sitting between Security's position at T+0 (103.77490) and at +1:00 (103.77508). The line
-- joins them and crosses this rectangle; neither end is inside it.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c001', '0b000000-0000-4000-8000-000000000e01',
   'STORES', 'Stores (no-go)', 'no_go',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77497 1.32998, 103.77501 1.32998, 103.77501 1.33002, 103.77497 1.33002, 103.77497 1.32998))'),
   false),
  ('0b000000-0000-4000-8000-00000000c002', '0b000000-0000-4000-8000-000000000e01',
   'HOARDING', 'Hoarding (obstacle)', 'obstacle',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77650 1.33040, 103.77660 1.33040, 103.77660 1.33060, 103.77650 1.33060, 103.77650 1.33040))'),
   false);

-- ---------- the clock ----------
-- Starts at 18:45, ends at 19:30. The plan's T+0 is 18:00, so this session's T+0 is before its own start.
insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, end_reason) values
  ('0b000000-0000-4000-8000-00000000d001', '0b000000-0000-4000-8000-000000000e01',
   (current_date + time '18:45') at time zone 'Asia/Singapore',
   (current_date + time '19:30') at time zone 'Asia/Singapore',
   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
   'ended');

-- ---------- plan 1: the walkthrough, deliberately invalid ----------
-- created_at is stated rather than defaulted: plan_list orders by it, and three plans inserted in one transaction
-- would otherwise share a timestamp and come back in whatever order the heap felt like.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01',
   'Walkthrough', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '3 hours');

-- 24 m north is 0.0002171 degrees of latitude; Gate Crew walks one step per frame from 1.33, 103.77400.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01',   0, 'call',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0002', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01',  60, 'doors',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0003', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', 120, 'support',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0004', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', 180, 'on stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0005', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', 240, 'encore',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0006', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', 300, 'out',      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  -- Gate Crew: 25 m north per frame, so its hops are all legal.
  ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0002', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0003', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0004', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0005', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0006', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310855, 103.77400),
  -- Sound: 25 m north at +0:00 and +1:00, then nothing until +3:00, when it is 200 m east of where it still was.
  ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3300000, 103.77450),
  ('0b000000-0000-4000-8000-0000000f0002', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3302171, 103.77450),
  ('0b000000-0000-4000-8000-0000000f0004', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3302171, 103.7762971),
  -- Backstage: stated once, at T+0, and never again.
  ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3302000, 103.77400),
  -- Security: 20 m east, straight through the Stores no-go zone.
  ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3300000, 103.77490),
  ('0b000000-0000-4000-8000-0000000f0002', '0b000000-0000-4000-8000-000000000b01', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3300000, 103.77508);

-- ---------- plan 2: the clean one, deliberately valid ----------
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b02', '0b000000-0000-4000-8000-000000000e01',
   'Clean walk', current_date, '18:00', 'ready', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '2 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0101', '0b000000-0000-4000-8000-000000000b02', '0b000000-0000-4000-8000-000000000e01',   0, 'step up', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0102', '0b000000-0000-4000-8000-000000000b02', '0b000000-0000-4000-8000-000000000e01',  60, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0103', '0b000000-0000-4000-8000-000000000b02', '0b000000-0000-4000-8000-000000000e01', 120, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0104', '0b000000-0000-4000-8000-000000000b02', '0b000000-0000-4000-8000-000000000e01', 180, 'arrive',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Every group takes 24 m a step, along a lane of its own. The lane is numbered per group BEFORE the frames are
-- joined: numbered after the join, the window runs over frames as well, each frame renumbers the groups and every
-- step becomes a diagonal (28 m) instead of a straight 24 m -- which the plan then reports as a violation.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
select
  f.id,
  '0b000000-0000-4000-8000-000000000b02',
  '0b000000-0000-4000-8000-000000000e01',
  g.id,
  1.3290000 + (f.t_s / 60) * 0.0002171,
  103.77200 + (g.lane - 1) * 0.0001000
from public.plan_frames f
cross join (
  select id, row_number() over (order by name) as lane
  from public.groups where event_id = '0b000000-0000-4000-8000-000000000e01'
) g
where f.plan_id = '0b000000-0000-4000-8000-000000000b02';

-- ---------- plan 3: the copy bench ----------
-- Two frames, not six: the point is what a frame *means*, not how long the strip is.
--   +0:00 states three groups (Gate Crew, Sound, Backstage).
--   +1:00 states only Gate Crew, 11 m east of where it was, and carries a note.
-- So +1:00 is a frame that mentions one group and means three. Copying it must snapshot all three; copying only
-- its own row would paste one marker where the planner could see three. Gate Crew's 11 m hop keeps the plan
-- legal, so nothing here trips the 25 m rule or a zone.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01',
   'Copy bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '1 hour');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0201', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01',  0, null,       'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0202', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01', 60, 'one here', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0201', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0201', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3310000, 103.77550),
  ('0b000000-0000-4000-8000-0000000f0201', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3312000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0202', '0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77510);

-- ---------- plan 4: one broken stretch, two groups ----------
-- Created four hours ago, so it sorts last: plan_list orders by created_at desc and the board opens the newest
-- plan, which the earlier checks expect to be "Copy bench".
--
-- Both groups stand 200 m east of where they stood, between the same two frames (+0:00 and +5:00). plan_check
-- therefore reports two errors with the same pair of frames: that is the case where the client has to name both
-- groups in one call, because filling them one at a time would be two round trips and two reloads -- and the
-- second would be written against a plan the first had already changed.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01',
   'Twin gap', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '4 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0301', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01',   0, 'both here',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0302', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01', 300, 'both there', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0301', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0301', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3311000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0302', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77680),
  ('0b000000-0000-4000-8000-0000000f0302', '0b000000-0000-4000-8000-000000000b04', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3311000, 103.77680);

-- ---------- plan 5: the strip step 6 is about ----------
-- Four frames, one minute apart, 24 m and 20 m a step: nothing here breaks a rule, so after a push any red dot
-- is caused by the push and nothing else. One note per frame, so "the notes travel with the frames that moved"
-- is a thing a check can read.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01',
   'Push bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '5 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0401', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01',   0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0402', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01',  60, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0403', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', 120, 'doors',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0404', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', 180, 'walk on', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew one legal step north per frame, Sound 20 m (0.0001797 degrees of longitude at this latitude) east per
-- frame, on a lane of its own north of every other plan so the markers never sit on top of another plan's.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0401', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3320000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f0402', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3322171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f0403', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3324342, 103.77300),
  ('0b000000-0000-4000-8000-0000000f0404', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3326513, 103.77300),
  ('0b000000-0000-4000-8000-0000000f0401', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3320000, 103.77320),
  ('0b000000-0000-4000-8000-0000000f0402', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3320000, 103.7733797),
  ('0b000000-0000-4000-8000-0000000f0403', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3320000, 103.7735594),
  ('0b000000-0000-4000-8000-0000000f0404', '0b000000-0000-4000-8000-000000000b05', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3320000, 103.7737391);

commit;

-- What the run should say. One row, so a caller can see at a glance that the bench is the bench.
select e.name,
       (select count(*) from public.groups      where event_id = e.id) as groups,
       (select count(*) from public.group_members where event_id = e.id) as members,
       (select count(*) from public.zones       where event_id = e.id) as zones,
       (select count(*) from public.plans        where event_id = e.id) as plans,
       (select count(*) from public.plan_frames  where event_id = e.id) as frames,
       (select count(*) from public.plan_positions where event_id = e.id) as positions,
       to_char((select starts_at from public.event_sessions where event_id = e.id), 'HH24:MI') as session_starts,
       (select t0_time::text from public.plans where event_id = e.id order by name limit 1) as plan_t0
from public.events e
where e.id = '0b000000-0000-4000-8000-000000000e01';
