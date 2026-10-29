-- Step 6, checked at the database: push a chunk by naming both ends, and refuse the three things that would be a
-- lie rather than an edit.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step6-push-chunk.sql
--
-- Section 1 is the step's Done-when, on the bench plan built for it: four frames at +0:00 / +1:00 / +2:00 / +3:00,
-- shifting +1:00..+2:00 by +300 moves exactly two and leaves the other two where they were. "Leaves them" means
-- their id, time, revision and note are all unchanged -- a ripple would move them, and a shift that deleted and
-- re-inserted would change their ids.
--
-- Section 2 is the other half of the Done-when: shifting +0:00..+1:00 by +300 would put a frame before T+0, and
-- that is refused.
--
-- Section 3 is the part that is easy to get wrong in the other direction: a bounded chunk is NOT a ripple, so it
-- may pass over a frame that stays put. 0/180/360/420 with 360..420 pulled back to 10..70 crosses the frame at
-- 180, and the result is allowed -- but the strip is ordered by time, so the *pairs* the 25 m rule compares change,
-- and plan_check says so. That is the whole reason crossing does not need a guard of its own.
--
-- Sections 4-6: the unbounded form still works, then what is refused (a stretch with no frame, a backwards stretch,
-- a landing on a frame that stays put), then the ceiling that was unguarded until 044 -- in frame_shift, frame_move
-- and frame_save, all three answering 22023 with a sentence instead of a constraint name.
--
-- Everything runs in one transaction and is rolled back, so the bench is left as the fixture wrote it.
begin;

-- A second plan for the two frames the ceiling tests need. Written as the owner, the way the fixture is, so this
-- file does not depend on the plans table's write policy; its frames are written through frame_save below, which is
-- the path a pasted frame actually takes.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by) values
  ('0b000000-0000-4000-8000-000000000b06', '0b000000-0000-4000-8000-000000000e01',
   'Ceiling bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the bench must still hold the strip this step is about ----------
do $$
declare
  v_times integer[];
  v_gaps integer;
begin
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 60, 120, 180] then
    raise exception 'FAIL 0a: "Push bench" holds % , expected 0/60/120/180. Run supabase/fixtures/plan_bench.sql first.', v_times;
  end if;
  select count(*) into v_gaps from public.plan_check('0b000000-0000-4000-8000-000000000b05');
  if v_gaps <> 0 then
    raise exception 'FAIL 0b: the strip already breaks the 25 m rule (% gaps), so a push could not be told apart from it', v_gaps;
  end if;
end $$;

-- ---------- 1. the Done-when: +1:00..+2:00 pushed by +5m ----------
do $$
declare
  v_moved integer;
  v_times integer[];
  v_untouched jsonb;
  v_moved_rows jsonb;
  v_n integer;
  v_gaps integer;
  v_worst integer;
begin
  -- What "left alone" has to mean: the whole row, not just its time.
  select jsonb_agg(jsonb_build_object('id', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note) order by f.t_s)
    into v_untouched
    from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s in (0, 180);

  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 60, 300, 120);
  if v_moved <> 2 then
    raise exception 'FAIL 1a: shifting +1:00..+2:00 by +300 moved % frames, expected exactly 2', v_moved;
  end if;

  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 180, 360, 420] then
    raise exception 'FAIL 1b: after the push the strip holds %, expected 0/180/360/420', v_times;
  end if;

  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_n <> 4 then
    raise exception 'FAIL 1c: the push left % frames, expected 4 -- it moved them, it did not rewrite them', v_n;
  end if;

  -- The two frames outside the stretch: identical rows, revision and note included.
  select jsonb_agg(jsonb_build_object('id', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note) order by f.t_s)
    into v_moved_rows
    from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s in (0, 180);
  if v_moved_rows is distinct from v_untouched then
    raise exception 'FAIL 1d: the frames outside the stretch changed (before %, after %)', v_untouched, v_moved_rows;
  end if;

  -- The two inside it: same ids, same notes, revision bumped because the row changed. +1:00 came home to +6:00 and
  -- +2:00 to +7:00, so the notes go with them -- 'doors' was on +2:00.
  select jsonb_agg(jsonb_build_object('id', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note) order by f.t_s)
    into v_moved_rows
    from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s in (360, 420);
  if (v_moved_rows -> 0 ->> 'note') is not null or (v_moved_rows -> 1 ->> 'note') <> 'doors' then
    raise exception 'FAIL 1e: the moved frames lost their notes: %', v_moved_rows;
  end if;
  if (v_moved_rows -> 0 ->> 'rev')::int <> 2 or (v_moved_rows -> 1 ->> 'rev')::int <> 2 then
    raise exception 'FAIL 1f: a moved frame did not have its revision bumped: %', v_moved_rows;
  end if;
  if (v_moved_rows -> 0 ->> 'id') <> '0b000000-0000-4000-8000-0000000f0402'
     or (v_moved_rows -> 1 ->> 'id') <> '0b000000-0000-4000-8000-0000000f0403' then
    raise exception 'FAIL 1g: the push wrote different frames instead of moving these: %', v_moved_rows;
  end if;

  -- Positions belong to frames, so they travelled with them: two groups on every frame, still.
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_n <> 8 then
    raise exception 'FAIL 1h: the plan holds % positions after the push, expected 8 (nothing was placed or dropped)', v_n;
  end if;

  -- A push that passes a frame that stays put reorders the strip, and the rule follows the new order: the frame at
  -- +0:00 is now three steps away from the one at +3:00 rather than one. Two groups, two new pairs each.
  select count(*), max(metres) into v_gaps, v_worst from public.plan_check('0b000000-0000-4000-8000-000000000b05');
  if v_gaps <> 4 then
    raise exception 'FAIL 1i: plan_check reports % gap(s) after the reorder, expected 4', v_gaps;
  end if;
  if v_worst not between 70 and 75 then
    raise exception 'FAIL 1j: the longest new pair is % m, expected about 72 (three 24 m steps)', v_worst;
  end if;
end $$;

-- ---------- 2. the refusal, and the front of the plan is not pinned ----------
-- The Done-when's second half is the guard the step lists first: a stretch pushed before T+0. The only delta that
-- can do that is a negative one -- the plan's own wording says +300, which cannot push anything before T+0, so this
-- checks the guard it names and then checks that +300 on the same stretch is *allowed*, because it must be: "we are
-- five minutes behind, push the whole run" is frame_shift(p_from_s => 0, p_to_s => null) and would be impossible if
-- a frame at T+0 were pinned.
do $$
declare
  v_times_before integer[];
  v_times_after integer[];
  v_revs_before jsonb;
  v_revs_after jsonb;
  v_message text;
  v_moved integer;
begin
  select array_agg(f.t_s order by f.t_s), jsonb_agg(f.rev order by f.t_s)
    into v_times_before, v_revs_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';

  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 0, -300, 60);
    raise exception 'FAIL 2a: a stretch pushed before T+0 was accepted';
  exception
    when sqlstate '22023' then
      v_message := sqlerrm;
  end;

  if position('T+0' in v_message) = 0 then
    raise exception 'FAIL 2b: the refusal does not name T+0: %', v_message;
  end if;

  select array_agg(f.t_s order by f.t_s), jsonb_agg(f.rev order by f.t_s)
    into v_times_after, v_revs_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times_after is distinct from v_times_before or v_revs_after is distinct from v_revs_before then
    raise exception 'FAIL 2c: the refused push still changed the plan (% -> %)', v_times_before, v_times_after;
  end if;

  -- The same stretch pushed the other way is legal: the frame at T+0 is an ordinary frame, not an anchor.
  begin
    v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 0, 300, 60);
  exception
    when others then
      raise exception 'FAIL 2d: pushing +0:00..+1:00 by +300 died: % (strip %)', sqlerrm,
        (select array_agg(f.t_s order by f.t_s) from public.plan_frames f
          where f.plan_id = '0b000000-0000-4000-8000-000000000b05');
  end;
  if v_moved <> 1 then
    raise exception 'FAIL 2d: pushing +0:00..+1:00 by +300 moved % frames, expected 1', v_moved;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times_after is distinct from array[180, 300, 360, 420] then
    raise exception 'FAIL 2e: after pushing the first frame the strip holds %, expected 180/300/360/420', v_times_after;
  end if;
  -- Back where it was, so the sections after this one start from 0/180/360/420.
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 300, -300, 300);
  if v_moved <> 1 then
    raise exception 'FAIL 2f: putting the frame back moved % frames, expected 1', v_moved;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times_after is distinct from array[0, 180, 360, 420] then
    raise exception 'FAIL 2g: the strip did not come back (%), expected 0/180/360/420', v_times_after;
  end if;
end $$;

-- ---------- 3. a bounded chunk may pass over a frame that stays put ----------
do $$
declare
  v_moved integer;
  v_times integer[];
  v_kept jsonb;
  v_gaps integer;
  v_worst integer;
begin
  select jsonb_build_object('id', f.id, 'rev', f.rev, 'note', f.note) into v_kept
    from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s = 180;

  -- 360 and 420 come back to 10 and 70, both of which are before the frame that stays at 180.
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 360, -350, 420);
  if v_moved <> 2 then
    raise exception 'FAIL 3a: shifting +6:00..+7:00 by -350 moved % frames, expected 2', v_moved;
  end if;

  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 10, 70, 180] then
    raise exception 'FAIL 3b: after the crossing push the strip holds %, expected 0/10/70/180', v_times;
  end if;

  if (select jsonb_build_object('id', f.id, 'rev', f.rev, 'note', f.note) from public.plan_frames f
       where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s = 180) is distinct from v_kept then
    raise exception 'FAIL 3c: the frame that was passed over changed anyway';
  end if;

  -- Pulling the same two frames back across the frame at +3:00 restores the original walking order, so the rule
  -- has nothing to say again. Crossing is legal in both directions; what the rule reports is the order it leaves.
  select count(*) into v_gaps from public.plan_check('0b000000-0000-4000-8000-000000000b05');
  if v_gaps <> 0 then
    raise exception 'FAIL 3d: after the pull-back plan_check still reports % gap(s), expected 0', v_gaps;
  end if;
end $$;

-- ---------- 4. the unbounded form still travels ----------
do $$
declare
  v_moved integer;
  v_times integer[];
begin
  -- p_to_s left out: everything at or after +3:00 moves, which is the "we are five minutes behind" move.
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 180, 60);
  if v_moved <> 1 then
    raise exception 'FAIL 4a: the ripple moved % frames, expected 1', v_moved;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 10, 70, 240] then
    raise exception 'FAIL 4b: after the ripple the strip holds %, expected 0/10/70/240', v_times;
  end if;

  -- The same shape, with p_to_s named as the last frame: still everything from +4:00 on, still one frame.
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 240, 60, 240);
  if v_moved <> 1 then
    raise exception 'FAIL 4c: a bounded one-frame stretch moved % frames, expected 1', v_moved;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 10, 70, 300] then
    raise exception 'FAIL 4d: the bounded ripple left the strip at %, expected 0/10/70/300', v_times;
  end if;
end $$;

-- ---------- 5. what is refused ----------
do $$
declare
  v_message text;
  v_times_before integer[];
  v_times_after integer[];
begin
  -- A stretch with no frame in it. Returning 0 here would be indistinguishable from a push that worked.
  select array_agg(f.t_s order by f.t_s) into v_times_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 5000, 60, 5100);
    raise exception 'FAIL 5a: a stretch with no frame in it was accepted';
  exception
    when sqlstate '22023' then
      if position('no frame' in sqlerrm) = 0 then
        raise exception 'FAIL 5b: the refusal does not say there is no frame in the stretch: %', sqlerrm;
      end if;
  end;

  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 300, 60, 200);
    raise exception 'FAIL 5c: a backwards stretch was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  -- Landing exactly on a frame that stays put is a collision, not a reordering.
  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 0, 10, 0);
    raise exception 'FAIL 5d: a frame was pushed onto one that stays put';
  exception
    when sqlstate '22023' then
      if position('staying put' in sqlerrm) = 0 then
        raise exception 'FAIL 5e: the collision refusal reads: %', sqlerrm;
      end if;
  end;

  select array_agg(f.t_s order by f.t_s) into v_times_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times_after is distinct from v_times_before then
    raise exception 'FAIL 5f: a refused push changed the strip (% -> %)', v_times_before, v_times_after;
  end if;
end $$;

-- ---------- 6. the ceiling that used to be a constraint violation ----------
do $$
declare
  v_moved integer;
  v_t integer;
  v_row public.plan_frames;
  v_message text;
  v_id uuid;
begin
  -- frame_save first, on the empty second plan: a pasted frame must not be able to reach the raw constraint.
  begin
    v_row := public.frame_save('0b000000-0000-4000-8000-000000000b06', '{"t_s": 259300}');
    raise exception 'FAIL 6a: frame_save wrote a frame past the ceiling';
  exception
    when sqlstate '22023' then null;
    when check_violation then
      raise exception 'FAIL 6b: frame_save let the table constraint answer instead of naming the limit';
  end;

  -- Three days exactly is the last legal second, and it is allowed.
  v_row := public.frame_save('0b000000-0000-4000-8000-000000000b06', '{"t_s": 259200}');
  if v_row.t_s <> 259200 then
    raise exception 'FAIL 6c: frame_save refused the last legal second';
  end if;
  if v_row.rev <> 1 then
    raise exception 'FAIL 6d: a new frame arrived with revision %', v_row.rev;
  end if;
  v_id := v_row.id;

  -- frame_move, the path the inspector's time field and a single dot drag take.
  begin
    v_row := public.frame_move(v_id, 259201, 1);
    raise exception 'FAIL 6e: frame_move pushed a frame past the ceiling';
  exception
    when sqlstate '22023' then null;
    when check_violation then
      raise exception 'FAIL 6f: frame_move let the table constraint answer instead of naming the limit';
  end;
  v_row := public.frame_move(v_id, 600, 1);
  if v_row.t_s <> 600 then
    raise exception 'FAIL 6g: frame_move could not take the frame back inside the range';
  end if;
  v_row := public.frame_move(v_id, 259200, 2);
  if v_row.t_s <> 259200 then
    raise exception 'FAIL 6h: frame_move refused the last legal second';
  end if;

  -- frame_shift: a chunk whose far end lands exactly on the ceiling, then one second further. The last frame of the
  -- strip is at +5:00 by now (section 4c moved it there).
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 300, 259200 - 300, 300);
  if v_moved <> 1 then
    raise exception 'FAIL 6i: the frame was not moved to the ceiling (% frames)', v_moved;
  end if;
  select f.t_s into v_t from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b05' and f.t_s > 1000;
  if v_t <> 259200 then
    raise exception 'FAIL 6j: the last legal second is %, expected 259200', v_t;
  end if;

  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 259200, 1, 259200);
    raise exception 'FAIL 6k: frame_shift pushed a frame past the ceiling';
  exception
    when sqlstate '22023' then
      v_message := sqlerrm;
    when check_violation then
      raise exception 'FAIL 6l: frame_shift let the table constraint answer instead of naming the limit';
  end;
  if position('three days' in v_message) = 0 or position('t_range' in v_message) > 0 then
    raise exception 'FAIL 6m: the ceiling refusal reads: %', v_message;
  end if;
end $$;

-- ---------- 7. the doors ----------
do $$
begin
  -- The 3-argument function is gone, not merely shadowed: an overload left behind would keep the old, unguarded
  -- behaviour reachable by name.
  if to_regprocedure('public.frame_shift(uuid, integer, integer)') is not null then
    raise exception 'FAIL 7a: the old three-argument frame_shift still exists';
  end if;
  if to_regprocedure('public.frame_shift(uuid, integer, integer, integer)') is null then
    raise exception 'FAIL 7b: the four-argument frame_shift does not exist';
  end if;
  if has_function_privilege('anon', 'public.frame_shift(uuid, integer, integer, integer)', 'EXECUTE') then
    raise exception 'FAIL 7c: anon can execute frame_shift';
  end if;
  if not has_function_privilege('authenticated', 'public.frame_shift(uuid, integer, integer, integer)', 'EXECUTE') then
    raise exception 'FAIL 7d: authenticated cannot execute frame_shift';
  end if;
  -- The default privileges on this schema grant anon directly, so "revoked from PUBLIC" is not the question.
  if exists (
    select 1
      from pg_proc p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where p.proname = 'frame_shift' and p.pronargs = 4
       and a.grantee in (0, (select oid from pg_roles where rolname = 'anon'))
       and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'FAIL 7e: frame_shift still carries an EXECUTE grant for PUBLIC or anon';
  end if;
end $$;

-- ---------- 8. a participant cannot push, even a group they administer ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.frame_shift('0b000000-0000-4000-8000-000000000b05', 0, 60, 0);
    raise exception 'FAIL 8a: a participant (a group admin) pushed a chunk';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

rollback;

select 'step 6: a chunk moves by naming both ends, the frames outside it are untouched, crossing over a still frame reorders the strip (and plan_check follows), and the ceiling answers in words' as result;
