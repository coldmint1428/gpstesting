-- Step 5, checked at the database: frames_fill spaces one impossible stretch out in a single call.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step5-fill-gap.sql
--
-- Section 1 uses the bench's real defect: "Walkthrough" has Sound 200 m away from where it still was, between
-- +1:00 and +3:00. One call has to insert the frames that split that into legal steps, leave every other
-- group's positions exactly as they were, and leave plan_check with nothing to say.
--
-- Section 2 builds its own two-frame plan, because the case that is easy to get wrong is two groups needing
-- different numbers of steps: frames are shared by the whole plan, so the wanted times have to be merged. It also
-- puts a frame already at one of those times, to prove a wanted time reuses that frame instead of adding a second
-- one at the same second.
--
-- Section 3 is what must be refused: backwards, another plan's frame, another event's group, a group that already
-- stands somewhere in the middle, a permission check, and a stretch too short in time to split at all -- where the
-- function has to catch its own arithmetic and leave nothing behind.
--
-- Everything runs in one transaction and is rolled back, so the bench is left as the fixture wrote it.
begin;

-- ---------- setup: a two-frame plan of its own ----------
-- Written as the owner, the way the fixture is, so this file does not depend on the plans table's write policy.
--   +0:00  Gate Crew, Sound and Backstage placed
--   +3:20  an empty frame, so the union below lands on a time that already exists
--   +5:00  Gate Crew 60 m east, Sound 100 m east, Backstage not mentioned (so it stands still)
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by) values
  ('0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01',
   'Fill bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01',   0, 'start', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0f02', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', 200, 'keep me', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0f03', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', 300, 'end', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  -- The start: three groups, each about 100 m apart on one line. North of every zone the bench has: step 11 makes a
  -- walk that clips a no-go zone an error, and this file is about the fill's merged grid, not about the geometry.
  ('0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3360000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3360000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3362000, 103.77600),
  -- the end: Gate Crew 60 m east, Sound 100 m east
  ('0b000000-0000-4000-8000-0000000f0f03', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3360000, 103.77454),
  ('0b000000-0000-4000-8000-0000000f0f03', '0b000000-0000-4000-8000-000000000b0f', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3360000, 103.77590);

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the bench must still hold the jump ----------
do $$
declare
  v_gap record;
  v_n integer;
begin
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_n <> 2 then
    raise exception 'The walkthrough has % error(s), expected 2 (Sound''s 200 m and Security''s zone crossing). Run supabase/fixtures/plan_bench.sql first.', v_n;
  end if;
  select * into v_gap from public.plan_check('0b000000-0000-4000-8000-000000000b01')
   where group_id = '0b000000-0000-4000-8000-00000000a002';
  if v_gap.group_id <> '0b000000-0000-4000-8000-00000000a002' then
    raise exception 'The gap belongs to group %, expected Sound', v_gap.group_id;
  end if;
  if v_gap.from_s <> 60 or v_gap.to_s <> 180 then
    raise exception 'The gap runs % to %, expected 60 to 180', v_gap.from_s, v_gap.to_s;
  end if;
end $$;

-- ---------- 1. the bench's 200 m jump, filled in one call ----------
do $$
declare
  v_gap record;
  v_res record;
  v_before integer;
  v_after integer;
  v_other_before jsonb;
  v_other_after jsonb;
  v_worst float8 := 0;
  v_prev_lat float8;
  v_prev_lng float8;
  v_t integer;
  v_lat float8;
  v_lng float8;
  v_dx float8;
  v_dy float8;
  v_step float8;
  v_started boolean := false;
  v_off_line integer;
begin
  select * into v_gap from public.plan_check('0b000000-0000-4000-8000-000000000b01');

  select count(*) into v_before from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b01';
  select jsonb_agg(jsonb_build_object('t', f.t_s, 'g', p.group_id, 'lat', p.lat, 'lng', p.lng)
                   order by f.t_s, p.group_id)
    into v_other_before
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b01'
     and p.group_id <> '0b000000-0000-4000-8000-00000000a002';

  -- One call, naming the one group that is failing. This is the whole operation the board's Fill button makes.
  select * into v_res from public.frames_fill(
    '0b000000-0000-4000-8000-000000000b01', v_gap.from_frame, v_gap.to_frame,
    array[v_gap.group_id]::uuid[]);

  if v_res.groups_filled <> 1 then
    raise exception 'FAIL 1a: filled % groups, expected 1', v_res.groups_filled;
  end if;
  if v_res.frames_added <> 8 then
    raise exception 'FAIL 1b: added % frames, expected 8 (200 m at 24 m a step over 120 s)', v_res.frames_added;
  end if;
  if v_res.frames_reused <> 0 then
    raise exception 'FAIL 1c: reused % frames, expected 0 (no frame already at a wanted time)', v_res.frames_reused;
  end if;
  if v_res.positions_written <> 8 then
    raise exception 'FAIL 1d: wrote % positions, expected 8', v_res.positions_written;
  end if;
  if v_res.max_step_m is null or v_res.max_step_m > 25 then
    raise exception 'FAIL 1e: the function reports a longest step of % m', v_res.max_step_m;
  end if;

  -- The plan's own verdict, which is what publish gates on. The fill closes Sound's 200 m; Security's 20 m walk
  -- through the Stores no-go zone is a different rule (step 11) and the fill was never asked to touch it.
  select count(*) into v_after from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_after <> 1 then
    raise exception 'FAIL 1f: plan_check reports % violation(s) after the fill, expected 1 (the zone crossing)', v_after;
  end if;
  select count(*) into v_after from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a002';
  if v_after <> 0 then
    raise exception 'FAIL 1f2: Sound still has % break(s) after the fill', v_after;
  end if;

  select count(*) into v_after from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b01';
  if v_after <> v_before + 8 then
    raise exception 'FAIL 1g: the plan went from % to % frames, expected %', v_before, v_after, v_before + 8;
  end if;

  -- Walking the *frames*, not the stated rows: carrying a position forward never adds a distance, so this is the
  -- same thing plan_check computes, worked out here independently.
  for v_t, v_lat, v_lng in
    select f.t_s, e.lat, e.lng
      from public.plan_frames f
      cross join lateral (
        select p.lat, p.lng
          from public.plan_positions p
          join public.plan_frames pf on pf.id = p.frame_id
         where pf.plan_id = f.plan_id
           and p.group_id = '0b000000-0000-4000-8000-00000000a002'
           and pf.t_s <= f.t_s
         order by pf.t_s desc
         limit 1
      ) e
     where f.plan_id = '0b000000-0000-4000-8000-000000000b01'
     order by f.t_s
  loop
    if v_started then
      v_dx := (v_lng - v_prev_lng) * 111320 * cos(radians((v_lat + v_prev_lat) / 2));
      v_dy := (v_lat - v_prev_lat) * 111320;
      v_step := sqrt(v_dx * v_dx + v_dy * v_dy);
      v_worst := greatest(v_worst, v_step);
    end if;
    v_prev_lat := v_lat;
    v_prev_lng := v_lng;
    v_started := true;
  end loop;
  if v_worst > 25 then
    raise exception 'FAIL 1h: the longest step between neighbouring frames is % m', round(v_worst::numeric, 2);
  end if;

  -- Stated rows only, this time, to prove the samples really sit on the straight line: between the two ends
  -- Sound's line runs due east, so every latitude it states there must still be the one it started from.
  select count(*) into v_off_line
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b01'
     and p.group_id = '0b000000-0000-4000-8000-00000000a002'
     and f.t_s >= v_gap.from_s and f.t_s <= v_gap.to_s
     and abs(p.lat - 1.3302171) > 0.0000001;
  if v_off_line <> 0 then
    raise exception 'FAIL 1i: % of the filled rows are off the straight line', v_off_line;
  end if;

  -- Every other group's rows are what they were, to the coordinate: a fill for Sound is not a licence to rewrite
  -- Gate Crew's timing, and adding frames without positions cannot change anybody's distances.
  select jsonb_agg(jsonb_build_object('t', f.t_s, 'g', p.group_id, 'lat', p.lat, 'lng', p.lng)
                   order by f.t_s, p.group_id)
    into v_other_after
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b01'
     and p.group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_other_after is distinct from v_other_before then
    raise exception 'FAIL 1j: the fill changed other groups'' positions';
  end if;

  -- The ends it was told about did not move, and did not have their rev bumped (nothing was written to them).
  if not exists (select 1 from public.plan_frames
                  where id = '0b000000-0000-4000-8000-0000000f0002' and t_s = 60 and rev = 1) then
    raise exception 'FAIL 1k: the starting frame moved or changed rev';
  end if;
  if not exists (select 1 from public.plan_frames
                  where id = '0b000000-0000-4000-8000-0000000f0004' and t_s = 180 and rev = 1) then
    raise exception 'FAIL 1l: the ending frame moved or changed rev';
  end if;

  if exists (
    select 1 from public.plan_frames
     where plan_id = '0b000000-0000-4000-8000-000000000b01'
     group by t_s having count(*) > 1
  ) then
    raise exception 'FAIL 1m: two frames share a time';
  end if;
end $$;

-- ---------- 2. two groups, different distances, one merged set of times ----------
-- Gate Crew needs 3 steps over 300 s (60 m, so every 100 s) and Sound needs 5 (100 m, so every 60 s). The frames
-- are shared by the whole plan, so the result has to be the union of both grids -- 60, 100, 120, 180, 200, 240 --
-- and the frame already at 200 is reused rather than duplicated. Gate Crew then has more samples than it asked
-- for, at 60 s, which is harmless: more samples on one straight line only shorten a step. Taking Gate Crew's
-- 100 s grid alone would leave Sound's steps at 33 m, so this is the case that shows why the union is the rule.
do $$
declare
  v_res record;
  v_times integer[];
begin
  select * into v_res from public.frames_fill(
    '0b000000-0000-4000-8000-000000000b0f',
    '0b000000-0000-4000-8000-0000000f0f01',
    '0b000000-0000-4000-8000-0000000f0f03',
    array['0b000000-0000-4000-8000-00000000a001', '0b000000-0000-4000-8000-00000000a002']::uuid[]);

  if v_res.groups_filled <> 2 then
    raise exception 'FAIL 2a: filled % groups, expected 2', v_res.groups_filled;
  end if;
  if v_res.frames_added <> 5 then
    raise exception 'FAIL 2b: added % frames, expected 5 (union of 4 and 2 wanted times, one already there)', v_res.frames_added;
  end if;
  if v_res.frames_reused <> 1 then
    raise exception 'FAIL 2c: reused % frames, expected 1 (the frame already at +3:20)', v_res.frames_reused;
  end if;
  if v_res.positions_written <> 12 then
    raise exception 'FAIL 2d: wrote % positions, expected 12 (2 groups x 6 interior times)', v_res.positions_written;
  end if;
  if v_res.max_step_m <> 20 then
    raise exception 'FAIL 2e: the longest step is % m, expected 20 (100 m over 300 s in 60 s steps)', v_res.max_step_m;
  end if;

  -- The merged times, exactly: Gate Crew's own grid plus Sound's own grid, minus the duplicates, plus the ends.
  select array_agg(t_s order by t_s) into v_times
    from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b0f';
  if v_times <> array[0, 60, 100, 120, 180, 200, 240, 300] then
    raise exception 'FAIL 2f: the plan holds frames at %, expected 0,60,100,120,180,200,240,300', v_times;
  end if;

  -- The reused frame kept what it said; it only learnt that it had changed.
  if not exists (select 1 from public.plan_frames
                  where id = '0b000000-0000-4000-8000-0000000f0f02' and note = 'keep me' and rev = 2) then
    raise exception 'FAIL 2g: the reused frame lost its note or its rev did not bump';
  end if;

  if (select count(*) from public.plan_check('0b000000-0000-4000-8000-000000000b0f')) <> 0 then
    raise exception 'FAIL 2h: the merged fill left a violation';
  end if;

  -- Backstage stands still and was not named, so it must still have its one row and nothing anywhere else.
  if (select count(*) from public.plan_positions
       where plan_id = '0b000000-0000-4000-8000-000000000b0f'
         and group_id = '0b000000-0000-4000-8000-00000000a003') <> 1 then
    raise exception 'FAIL 2i: the unnamed group gained or lost positions';
  end if;
end $$;

-- ---------- 3a. a group that already stands in the middle is refused, not overwritten ----------
do $$
declare
  v_n integer;
begin
  -- Backstage has said nothing since +0:00, so the whole stretch is a straight line and there is nothing to fill.
  if (select frames_added from public.frames_fill(
        '0b000000-0000-4000-8000-000000000b0f',
        '0b000000-0000-4000-8000-0000000f0f01',
        '0b000000-0000-4000-8000-0000000f0f03',
        array['0b000000-0000-4000-8000-00000000a003']::uuid[])) <> 0 then
    raise exception 'FAIL 3a: a group standing still had frames added for it';
  end if;

  -- Now it does stand somewhere in between. Filling across that would overwrite a decision.
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
  values ('0b000000-0000-4000-8000-0000000f0f02', '0b000000-0000-4000-8000-000000000b0f',
          '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003',
          1.3303000, 103.77600);

  begin
    perform public.frames_fill(
      '0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f01',
      '0b000000-0000-4000-8000-0000000f0f03',
      array['0b000000-0000-4000-8000-00000000a003']::uuid[]);
    raise exception 'FAIL 3b: a group with a position in the middle was filled across';
  exception
    when sqlstate '22023' then
      select count(*) into v_n from public.plan_positions
       where plan_id = '0b000000-0000-4000-8000-000000000b0f'
         and group_id = '0b000000-0000-4000-8000-00000000a003';
      if v_n <> 2 then
        raise exception 'FAIL 3c: the refused fill still wrote rows (the group has % of 2)', v_n;
      end if;
  end;
end $$;

-- ---------- 3b. backwards, another plan's frame, another event's group ----------
do $$
declare
  v_before integer;
  v_after integer;
begin
  begin
    perform public.frames_fill('0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f03', '0b000000-0000-4000-8000-0000000f0f01',
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4a: a backwards fill was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  begin
    perform public.frames_fill('0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-0000000f0001',
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4b: a frame from another plan was accepted';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.frames_fill('0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-0000000f0f03',
      array['0b000000-0000-4000-8000-00000000a099']::uuid[]);
    raise exception 'FAIL 4c: a group id from no event at all was accepted';
  exception
    when sqlstate '42501' then null;
  end;

  -- A stretch too short in time to split: 100 m in 2 s cannot become 24 m steps at whole seconds. The function has
  -- to notice after writing, and the whole call has to be undone.
  insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
    ('0b000000-0000-4000-8000-0000000f0f04', '0b000000-0000-4000-8000-000000000b0f',
     '0b000000-0000-4000-8000-000000000e01', 600, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
    ('0b000000-0000-4000-8000-0000000f0f05', '0b000000-0000-4000-8000-000000000b0f',
     '0b000000-0000-4000-8000-000000000e01', 602, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
    ('0b000000-0000-4000-8000-0000000f0f04', '0b000000-0000-4000-8000-000000000b0f',
     '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3400000, 103.78000),
    ('0b000000-0000-4000-8000-0000000f0f05', '0b000000-0000-4000-8000-000000000b0f',
     '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3400000, 103.78090);

  select count(*) into v_before from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b0f';
  begin
    perform public.frames_fill('0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f04', '0b000000-0000-4000-8000-0000000f0f05',
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4d: a 100 m stretch in 2 s was "filled"';
  exception
    when sqlstate '22023' then
      select count(*) into v_after from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b0f';
      if v_after <> v_before then
        raise exception 'FAIL 4e: the refused fill left % of its frames behind', v_after - v_before;
      end if;
  end;
end $$;

-- ---------- 3c. a participant cannot fill, even a group they administer ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.frames_fill('0b000000-0000-4000-8000-000000000b0f',
      '0b000000-0000-4000-8000-0000000f0f01', '0b000000-0000-4000-8000-0000000f0f03',
      array['0b000000-0000-4000-8000-00000000a002']::uuid[]);
    raise exception 'FAIL 5: a participant (a group admin) filled a gap';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 4. the doors ----------
-- The default privileges on this schema give every new function an EXECUTE grant to anon as well as authenticated,
-- so "revoke from public" is not enough. 042 got that wrong and 043 fixed it; this is what keeps the next function
-- from repeating it.
do $$
begin
  if has_function_privilege('anon', 'public.frames_fill(uuid, uuid, uuid, uuid[])', 'EXECUTE') then
    raise exception 'FAIL 6a: anon can execute frames_fill';
  end if;
  if not has_function_privilege('authenticated', 'public.frames_fill(uuid, uuid, uuid, uuid[])', 'EXECUTE') then
    raise exception 'FAIL 6b: authenticated cannot execute frames_fill';
  end if;
  if exists (
    select 1
      from pg_proc p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where p.proname = 'frames_fill' and a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'FAIL 6c: frames_fill still carries a PUBLIC execute grant';
  end if;
end $$;

rollback;

select 'step 5: frames_fill spaces a broken stretch out in one call, merges the groups'' steps, refuses what it must, and leaves nothing behind when it refuses' as result;
