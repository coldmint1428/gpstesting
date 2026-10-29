-- Step 10, checked at the database: the board's bulk confirmation (frame_set_verify, 047) and the state half it sits
-- beside, on a plan built for this file so the result does not depend on what an earlier browser run left behind.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step10-flags.sql
--
-- The plan is "Verify bench" (b11): three frames at +0:00 / +5:00 / +10:00. The first two state all three groups
-- (Gate Crew, Sound, Backstage); the third states only Sound. That shape is what makes the two halves of the
-- function testable: a grid of 2 frames x 2 groups is FOUR rows, and asking for a group a frame does not state is a
-- cell it must leave alone rather than invent.
--
-- What is asserted, in order:
--   0. the bench and the new plan are the shape this file assumes, and the signature the client calls exists;
--   1. the Done-when at the database: two frames, two groups, four positions set, every other position untouched;
--   2. twice is once -- the identical call writes nothing and bumps nothing;
--   3. no group list means every position those frames hold;
--   4. patch only -- a frame that carries a group forward has no row to confirm, so it is counted, not created; and a
--      frame the call names but finds nothing to change keeps its revision;
--   5. a frame that states nobody named answers 0, not an error and not a new position;
--   6. six refusals that name their reason, and none of them writes anything (the whole plan is compared);
--   7. the state half through frame_save: off site, the row listed, the rule silent, the flags kept by a payload that
--      only names coordinates; back on site at the same place; and the partial payload the client must never send;
--   8. manual positions do not gate publish;
--   9. a member reads the flags for their own group, and a participant cannot set them;
--  10. the doors, including the PUBLIC grant 042 got wrong;
--  11. a fork copies the flags position by position.
--
-- One transaction, rolled back: the bench is left as the fixture wrote it.
begin;

-- The plan this file is about, written as the owner before the caller becomes a planner.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01',
   'Verify bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '9 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01',    0, 'six flags',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01',  300, 'nine flags',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0b03', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01',  600, 'twelve flags', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  -- Three groups at +0:00, each 10 m north at +5:00 -- legal steps, so nothing here is a 25 m warning.
  ('0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3340000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3341000, 103.77450, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3342000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3340898, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3341898, 103.77450, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3342898, 103.77400, 'on_site', 'auto'),
  -- +10:00 states only Sound: the two cells the other groups do not own are the ones the function must count, not fill.
  ('0b000000-0000-4000-8000-0000000f0b03', '0b000000-0000-4000-8000-000000000b11', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3342796, 103.77450, 'on_site', 'auto');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the shape this file assumes ----------
do $$
declare
  v_n integer;
  v_times integer[];
begin
  select count(*) into v_n from public.groups where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 4 then
    raise exception 'FAIL 0a: the bench has % groups, expected 4. Run supabase/fixtures/plan_bench.sql first.', v_n;
  end if;

  select array_agg(t_s order by t_s) into v_times from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b11';
  if v_times is distinct from array[0, 300, 600] then
    raise exception 'FAIL 0b: "Verify bench" holds %, expected 0/300/600', v_times;
  end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b11';
  if v_n <> 7 then
    raise exception 'FAIL 0c: "Verify bench" holds % positions, expected 7 (3 + 3 + 1)', v_n;
  end if;
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b11' and (verify <> 'auto' or state <> 'on_site');
  if v_n <> 0 then
    raise exception 'FAIL 0d: % of the new plan''s positions did not get the on_site / auto defaults', v_n;
  end if;
  if to_regprocedure('public.frame_set_verify(uuid, uuid[], uuid[], text)') is null then
    raise exception 'FAIL 0e: frame_set_verify does not exist with the signature the client calls';
  end if;
end $$;

-- ---------- 1. the Done-when at the database: four positions, two frames, and nothing else ----------
do $$
declare
  v_res record;
  v_n integer;
begin
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-0000000f0b02']::uuid[],
    array['0b000000-0000-4000-8000-00000000a001', '0b000000-0000-4000-8000-00000000a002']::uuid[],
    'manual');
  if v_res.frames_touched <> 2 or v_res.positions_set <> 4 then
    raise exception 'FAIL 1a: two frames x two groups set % positions in % frames, expected 4 in 2',
      v_res.positions_set, v_res.frames_touched;
  end if;
  if v_res.positions_skipped <> 0 then
    raise exception 'FAIL 1b: both frames state both groups, yet % cells were reported missing', v_res.positions_skipped;
  end if;

  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b11' and verify = 'manual';
  if v_n <> 4 then
    raise exception 'FAIL 1c: % positions read manual, expected 4', v_n;
  end if;
  -- The third group is in both frames and was not named: its positions must be exactly as they were.
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b11'
     and group_id = '0b000000-0000-4000-8000-00000000a003' and verify <> 'auto';
  if v_n <> 0 then
    raise exception 'FAIL 1d: the unnamed group changed: % of its positions are not auto', v_n;
  end if;
  -- The frame nobody named did not move either.
  select count(*) into v_n from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b03' and p.verify <> 'auto';
  if v_n <> 0 then
    raise exception 'FAIL 1e: a frame outside the call changed: % of its positions are not auto', v_n;
  end if;

  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b01') <> 2
     or (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02') <> 2 then
    raise exception 'FAIL 1f: the two frames touched read rev % and %, expected 2 and 2',
      (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b01'),
      (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02');
  end if;
  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b03') <> 1 then
    raise exception 'FAIL 1g: a frame outside the call had its revision bumped';
  end if;

  -- A flag is not geometry: the plan is still legal, and no row was added or removed.
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b11');
  if v_n <> 0 then
    raise exception 'FAIL 1h: flagging positions made the plan break the 25 m rule % times', v_n;
  end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b11';
  if v_n <> 7 then
    raise exception 'FAIL 1i: the plan holds % positions after the call, expected 7 (a flag is not a row)', v_n;
  end if;
end $$;

-- ---------- 2. twice is once ----------
do $$
declare
  v_res record;
  v_rev1 integer;
  v_rev2 integer;
begin
  select rev into v_rev1 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b01';
  select rev into v_rev2 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02';

  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-0000000f0b02']::uuid[],
    array['0b000000-0000-4000-8000-00000000a001', '0b000000-0000-4000-8000-00000000a002']::uuid[],
    'manual');
  if v_res.frames_touched <> 0 or v_res.positions_set <> 0 then
    raise exception 'FAIL 2a: the same call again set % positions in % frames, expected 0 and 0',
      v_res.positions_set, v_res.frames_touched;
  end if;
  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b01') <> v_rev1
     or (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02') <> v_rev2 then
    raise exception 'FAIL 2b: a call that changed nothing still bumped a revision';
  end if;
end $$;

-- ---------- 3. no group list means every position these frames hold ----------
do $$
declare
  v_res record;
begin
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-0000000f0b02']::uuid[],
    null,
    'auto');
  if v_res.frames_touched <> 2 or v_res.positions_set <> 4 then
    raise exception 'FAIL 3a: clearing the flags of both frames set % positions in % frames, expected 4 in 2',
      v_res.positions_set, v_res.frames_touched;
  end if;
  if v_res.positions_skipped <> 0 then
    raise exception 'FAIL 3b: no groups were named, yet % cells were reported missing', v_res.positions_skipped;
  end if;
  if exists (select 1 from public.plan_positions
              where plan_id = '0b000000-0000-4000-8000-000000000b11' and verify <> 'auto') then
    raise exception 'FAIL 3c: a position in the plan still reads manual after both frames were cleared';
  end if;
end $$;

-- ---------- 4. patch only: a frame that carries a group forward is counted, not filled ----------
do $$
declare
  v_res record;
  v_n integer;
  v_rev2 integer;
begin
  -- +5:00 states both groups, +10:00 states only Sound. So Gate Crew at +10:00 is a cell with no row.
  select rev into v_rev2 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02';
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-0000000f0b03']::uuid[],
    array['0b000000-0000-4000-8000-00000000a001', '0b000000-0000-4000-8000-00000000a002']::uuid[],
    'manual');
  if v_res.positions_set <> 3 or v_res.frames_touched <> 2 then
    raise exception 'FAIL 4a: % positions in % frames, expected 3 in 2 (both at +5:00, Sound at +10:00)',
      v_res.positions_set, v_res.frames_touched;
  end if;
  if v_res.positions_skipped <> 1 then
    raise exception 'FAIL 4b: % cells reported missing, expected 1 (Gate Crew at +10:00)', v_res.positions_skipped;
  end if;
  -- The row it could not confirm was not invented.
  select count(*) into v_n from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f0b03'
     and group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 0 then
    raise exception 'FAIL 4c: confirming a carried-forward position created a statement of it';
  end if;
  if (select verify from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0b03'
         and group_id = '0b000000-0000-4000-8000-00000000a002') <> 'manual' then
    raise exception 'FAIL 4d: the position the call could reach was not set';
  end if;
  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02') <> v_rev2 + 1 then
    raise exception 'FAIL 4e: the frame that changed was not bumped exactly once';
  end if;

  -- A frame named in a later call that has nothing left to change keeps its revision: +5:00 already reads manual.
  select rev into v_rev2 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02';
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-0000000f0b02']::uuid[],
    array['0b000000-0000-4000-8000-00000000a001']::uuid[],
    'manual');
  if v_res.positions_set <> 1 or v_res.frames_touched <> 1 then
    raise exception 'FAIL 4f: % positions in % frames, expected 1 in 1 (+0:00 changes, +5:00 already does)',
      v_res.positions_set, v_res.frames_touched;
  end if;
  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02') <> v_rev2 then
    raise exception 'FAIL 4g: a frame with nothing left to change had its revision bumped';
  end if;
end $$;

-- ---------- 5. a frame that states nobody named answers 0 ----------
do $$
declare
  v_res record;
begin
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b03']::uuid[],
    array['0b000000-0000-4000-8000-00000000a003']::uuid[],
    'manual');
  if v_res.positions_set <> 0 or v_res.frames_touched <> 0 or v_res.positions_skipped <> 1 then
    raise exception 'FAIL 5a: set %, touched %, skipped % -- expected 0 / 0 / 1 for a group that frame does not state',
      v_res.positions_set, v_res.frames_touched, v_res.positions_skipped;
  end if;
end $$;

-- ---------- 6. the refusals, each in words, and none of them writes ----------
do $$
declare
  v_res record;
  v_message text;
  v_before jsonb;
  v_after jsonb;
  v_revs_before jsonb;
  v_revs_after jsonb;
begin
  select jsonb_agg(jsonb_build_object('f', p.frame_id, 'g', p.group_id, 'lat', p.lat, 'lng', p.lng,
                                      'state', p.state, 'verify', p.verify) order by p.frame_id, p.group_id)
    into v_before
    from public.plan_positions p where p.plan_id = '0b000000-0000-4000-8000-000000000b11';
  select jsonb_agg(jsonb_build_object('id', f.id, 'rev', f.rev) order by f.id) into v_revs_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b11';

  -- A word outside the two, named in the sentence rather than left to plan_positions_verify_check.
  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-000000000b11',
      array['0b000000-0000-4000-8000-0000000f0b01']::uuid[], null, 'sometimes');
    raise exception 'FAIL 6a: a verify of "sometimes" was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('automatically or by hand' in v_message) = 0 or position('sometimes' in v_message) = 0 then
    raise exception 'FAIL 6b: the refusal reads: %', v_message;
  end if;

  -- An explicit null is not "leave it alone": it is a value nobody can act on.
  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-000000000b11',
      array['0b000000-0000-4000-8000-0000000f0b01']::uuid[], null, null);
    raise exception 'FAIL 6c: a null verify was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('not nothing' in v_message) = 0 then
    raise exception 'FAIL 6d: the refusal reads: %', v_message;
  end if;

  -- No frames at all, and an array of nulls, are both "name something".
  begin
    perform public.frame_set_verify('0b000000-0000-4000-8000-000000000b11', '{}'::uuid[], null, 'manual');
    raise exception 'FAIL 6e: an empty frame list was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('at least one frame' in v_message) = 0 then
    raise exception 'FAIL 6f: the refusal reads: %', v_message;
  end if;
  begin
    perform public.frame_set_verify('0b000000-0000-4000-8000-000000000b11', array[null]::uuid[], null, 'manual');
    raise exception 'FAIL 6g: an array holding only null was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  -- Another plan's frame: refused, not silently skipped -- this would otherwise flag somebody else's work.
  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-000000000b11',
      array['0b000000-0000-4000-8000-0000000f0201']::uuid[], null, 'manual');
    raise exception 'FAIL 6h: a frame from another plan was accepted';
  exception
    when sqlstate '42501' then v_message := sqlerrm;
  end;
  if position('not in this plan' in v_message) = 0 then
    raise exception 'FAIL 6i: the refusal reads: %', v_message;
  end if;

  -- A group in no event at all.
  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-000000000b11',
      array['0b000000-0000-4000-8000-0000000f0b01']::uuid[],
      array['0b000000-0000-4000-8000-00000000ffff']::uuid[], 'manual');
    raise exception 'FAIL 6j: a group from another event was accepted';
  exception
    when sqlstate '42501' then v_message := sqlerrm;
  end;
  if position('another event' in v_message) = 0 then
    raise exception 'FAIL 6k: the refusal reads: %', v_message;
  end if;

  -- A plan that does not exist is a refusal, not a silent zero.
  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-0000000000ff',
      array['0b000000-0000-4000-8000-0000000f0b01']::uuid[], null, 'manual');
    raise exception 'FAIL 6l: a plan id that is not a plan was accepted';
  exception
    when sqlstate '42501' then null;
  end;

  -- None of the six refusals wrote a row or bumped a revision.
  select jsonb_agg(jsonb_build_object('f', p.frame_id, 'g', p.group_id, 'lat', p.lat, 'lng', p.lng,
                                      'state', p.state, 'verify', p.verify) order by p.frame_id, p.group_id)
    into v_after
    from public.plan_positions p where p.plan_id = '0b000000-0000-4000-8000-000000000b11';
  select jsonb_agg(jsonb_build_object('id', f.id, 'rev', f.rev) order by f.id) into v_revs_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b11';
  if v_before is distinct from v_after then
    raise exception 'FAIL 6m: a refused call changed the plan''s positions';
  end if;
  if v_revs_before is distinct from v_revs_after then
    raise exception 'FAIL 6n: a refused call bumped a frame revision';
  end if;

  -- A clean slate for the state half: four rows were manual, every frame is named.
  select * into v_res from public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b01', '0b000000-0000-4000-8000-0000000f0b02', '0b000000-0000-4000-8000-0000000f0b03']::uuid[],
    null, 'auto');
  if v_res.positions_set <> 4 or v_res.frames_touched <> 3 then
    raise exception 'FAIL 6o: clearing every frame set % positions in % frames, expected 4 in 3',
      v_res.positions_set, v_res.frames_touched;
  end if;
end $$;

-- ---------- 7. the state half: off site is a statement written here, and its flags survive a coordinates-only save ----------
do $$
declare
  v_row public.plan_frames;
  v_positions jsonb;
  v_state text;
  v_verify text;
  v_lat float8;
  v_lng float8;
  v_before_lat float8;
  v_before_lng float8;
  v_n integer;
  v_rev integer;
begin
  select p.lat, p.lng into v_before_lat, v_before_lng
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  select rev into v_rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b01';

  -- The board's payload: the frame's own map, with this one group taken off the map and its confirmation asked for.
  -- Every other row is repeated exactly, which is the discipline step 10 is about.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b11',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0b01', 't_s', 0, 'rev', v_rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3340000, 'lng', 103.77400, 'state', 'off_site', 'verify', 'manual'),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3341000, 'lng', 103.77450, 'state', 'on_site', 'verify', 'auto'),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3342000, 'lng', 103.77400, 'state', 'on_site', 'verify', 'auto'))));

  select p.state, p.verify, p.lat, p.lng into v_state, v_verify, v_lat, v_lng
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 7a: the save wrote state % / verify %, expected off_site / manual', v_state, v_verify;
  end if;
  if v_lat <> v_before_lat or v_lng <> v_before_lng then
    raise exception 'FAIL 7b: taking the group off the map moved it';
  end if;
  -- The other two groups are still on the frame, untouched: the full map is what kept them.
  select count(*) into v_n from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f0b01';
  if v_n <> 3 then
    raise exception 'FAIL 7c: the frame holds % positions, expected 3 -- a payload dropped the groups it did not change', v_n;
  end if;

  -- An off-site row is still listed and still ignored by the rule.
  select positions into v_positions
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b11')
   where id = '0b000000-0000-4000-8000-0000000f0b01';
  if v_positions -> '0b000000-0000-4000-8000-00000000a001' ->> 'state' <> 'off_site'
     or v_positions -> '0b000000-0000-4000-8000-00000000a001' ->> 'verify' <> 'manual' then
    raise exception 'FAIL 7d: the list lost the flags: %', v_positions;
  end if;
  if v_positions ? '0b000000-0000-4000-8000-00000000a001' = false then
    raise exception 'FAIL 7e: an off-site group stopped being listed';
  end if;
  if (select count(*) from public.plan_check('0b000000-0000-4000-8000-000000000b11')) <> 0 then
    raise exception 'FAIL 7f: the plan reports a break because of an off-site row';
  end if;

  -- The list's own map fed straight back in: a round trip changes nothing but the revision.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b11',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0b01', 't_s', 0, 'rev', v_row.rev,
                       'positions', v_positions));
  if v_row.rev <> v_rev + 2 then
    raise exception 'FAIL 7g: the round trip left the frame at rev %, expected %', v_row.rev, v_rev + 2;
  end if;
  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 7h: feeding the list back in changed the flags to % / %', v_state, v_verify;
  end if;

  -- A point that names only a coordinate keeps both flags: the drag sends no flags, and it must not undo either.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b11',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0b01', 't_s', 0, 'rev', v_row.rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3340000, 'lng', 103.77410),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3341000, 'lng', 103.77450),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3342000, 'lng', 103.77400))));
  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 7i: a coordinate-only save reset the flags to % / %', v_state, v_verify;
  end if;

  -- Back on site, at a coordinate the planner chose: the state is explicit, the confirmation is not sent and stays.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b11',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0b01', 't_s', 0, 'rev', v_row.rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3340000, 'lng', 103.77400, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3341000, 'lng', 103.77450),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3342000, 'lng', 103.77400))));
  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'on_site' then
    raise exception 'FAIL 7j: an explicit on_site left the state %', v_state;
  end if;
  if v_verify <> 'manual' then
    raise exception 'FAIL 7k: putting the group back on the map reset its confirmation to %', v_verify;
  end if;

  -- A manual flag on the frame the member section reads (Sound at +10:00), through the batch function.
  perform public.frame_set_verify(
    '0b000000-0000-4000-8000-000000000b11',
    array['0b000000-0000-4000-8000-0000000f0b03']::uuid[],
    array['0b000000-0000-4000-8000-00000000a002']::uuid[], 'manual');

  -- The trap the client must never fall into: a payload naming one group leaves one row. This is why every flag
  -- write in the board goes through restatedPositions().
  select rev into v_rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0b02';
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b11',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0b02', 't_s', 300, 'rev', v_rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3342898, 'lng', 103.77400))));
  select count(*) into v_n from public.plan_positions where frame_id = '0b000000-0000-4000-8000-0000000f0b02';
  if v_n <> 1 then
    raise exception 'FAIL 7l: a partial payload left % positions, expected 1 -- the frame was clearly not sent whole', v_n;
  end if;
end $$;

-- ---------- 8. manual positions do not gate publish ----------
do $$
declare
  v_status text;
begin
  if (select verify from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0b03'
         and group_id = '0b000000-0000-4000-8000-00000000a002') <> 'manual' then
    raise exception 'FAIL 8a: Sound at +10:00 is not manual before the publish';
  end if;
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b11', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b11'));
  select status into v_status from public.plans where id = '0b000000-0000-4000-8000-000000000b11';
  if v_status <> 'live' then
    raise exception 'FAIL 8b: publishing a plan with a manually-confirmed position left status %', v_status;
  end if;
end $$;

-- ---------- 9. a member reads their own group's flags, and a participant cannot write them ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_verify text;
  v_n integer;
begin
  -- testuser3 is Sound's group admin: one group, its rows only (040), flags included. The read used to be the board's
  -- door, plan_frames_list(); step 16 (052) closed the frames to everyone but ops staff -- a member's moments come
  -- from session_timetable() -- so the flags a member can read are their own group's rows, asserted here directly.
  select verify into v_verify
    from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f0b03'
     and group_id = '0b000000-0000-4000-8000-00000000a002';
  if not found then
    raise exception 'FAIL 9a: the member cannot read their own group''s position';
  end if;
  if v_verify <> 'manual' then
    raise exception 'FAIL 9b: the member''s read lost the confirmation flag: %', v_verify;
  end if;
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b11'
     and group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_n <> 0 then
    raise exception 'FAIL 9c: the member read % positions belonging to another group', v_n;
  end if;

  begin
    perform public.frame_set_verify(
      '0b000000-0000-4000-8000-000000000b11',
      array['0b000000-0000-4000-8000-0000000f0b03']::uuid[], null, 'auto');
    raise exception 'FAIL 9d: a participant set a verification flag';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 10. the doors ----------
do $$
begin
  if not has_function_privilege('authenticated', 'public.frame_set_verify(uuid, uuid[], uuid[], text)', 'EXECUTE') then
    raise exception 'FAIL 10a: authenticated cannot call frame_set_verify';
  end if;
  if has_function_privilege('anon', 'public.frame_set_verify(uuid, uuid[], uuid[], text)', 'EXECUTE') then
    raise exception 'FAIL 10b: anon can call frame_set_verify';
  end if;
  -- The schema''s default ACL also writes a PUBLIC entry (=X/postgres). R4 is about both, and 042 forgot the anon one.
  if exists (
    select 1 from pg_proc pr
     where pr.oid = 'public.frame_set_verify(uuid, uuid[], uuid[], text)'::regprocedure
       and pr.proacl is not null
       and pr.proacl::text ~ '(^|,)=X/'
  ) then
    raise exception 'FAIL 10c: frame_set_verify still carries a PUBLIC execute grant';
  end if;
end $$;

-- ---------- 11. a fork copies the flags position by position ----------
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_copy public.plans;
  v_diff integer;
  v_n integer;
begin
  v_copy := public.plan_fork('0b000000-0000-4000-8000-000000000b11');
  -- Every copied row must match the source at the same time and group, flags included (046). A fork that dropped
  -- them would turn "off site, confirm by hand" into "on site, trusted" in the operation whose whole purpose is
  -- "the same plan, elsewhere".
  select count(*) into v_diff
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
    join public.plan_frames g on g.plan_id = v_copy.id and g.t_s = f.t_s
    join public.plan_positions q on q.frame_id = g.id and q.group_id = p.group_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b11'
     and (p.lat <> q.lat or p.lng <> q.lng or p.state <> q.state or p.verify <> q.verify);
  if v_diff <> 0 then
    raise exception 'FAIL 11a: % copied positions differ from the source (coordinates or flags)', v_diff;
  end if;
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b11';
  select count(*) into v_diff from public.plan_positions where plan_id = v_copy.id;
  if v_diff <> v_n then
    raise exception 'FAIL 11b: the copy holds % positions, the source %', v_diff, v_n;
  end if;
end $$;

rollback;

select 'step 10: bulk confirmation sets the flag on the rows the named frames already hold, in one call, one revision per frame touched, and never invents a position for a frame that does not state the group' as result;
