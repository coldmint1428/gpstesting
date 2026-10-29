-- Step 12, checked at the database: the 25 m rule is a budget per frame step, and it is the *frame count* that pays.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/migrate.mjs up          # 049 is what this file is about
--     node tools/sql.mjs --file dev/checks/step12-cumulative.sql
--
-- 048 (and 038 before it) compared every pair of neighbouring statements against a flat 25 m, so a plan that said
-- where a group was at +0:00 and again at +10:00 was impossible unless it moved less than 25 m -- even though the
-- strip gave that group ten frames to walk in. 049 makes the budget 25 m times the number of frame steps between the
-- two statements, which is the decision the stage was built on ("impossibility is cumulative: 25 m per frame step").
--
-- What this file asserts, in order:
--   0. 049 is the body that is live, and the benches are the shape this file assumes;
--   1. the bench's own case: Sound's 200 m is two steps and the sentence says so, and its endpoints are the frames that
--      STATED the position -- not the frame at +2:00 that only carried it;
--   2. a ten-frame strip with a 220 m walk across nine steps is legal, and 230 m across the same nine steps is not:
--      the budget is 225 m and the sentence names it;
--   3. separation is the frame count, not the clock: the same 200 m in the same 100 s is refused with two frames and
--      accepted with eleven -- distance and seconds identical, only the number of slots changed;
--   4. publish follows the same rule, and still refuses with the sentence that names the steps;
--   5. the doors are as 049 left them (anon out, PUBLIC out, authenticated in);
--   6. a member's check still sees only their own group's walk.
--
-- One transaction, rolled back: the bench is left as the fixture wrote it.
begin;

-- ---------- the two plans this file is about ----------
-- Far north of every fixture plan (1.3450+ vs 1.3327) and of the zones (1.3406 and below), so adding them cannot
-- change what any other plan reports. Four hours old at least, so nothing opens differently.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b13', '0b000000-0000-4000-8000-000000000e01',
   'Step bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '12 hours'),
  ('0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',
   'Ticks bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '13 hours');

-- A ten-frame strip, one minute apart. Gate Crew is stated at the first and the last frame only: the eight frames in
-- between carry the position forward, exactly the shape a planner leaves behind when only the ends matter.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select
  ('0b000000-0000-4000-8000-0000000f0d' || lpad((k + 1)::text, 2, '0'))::uuid,
  '0b000000-0000-4000-8000-000000000b13',
  '0b000000-0000-4000-8000-000000000e01',
  k * 60, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
from generate_series(0, 9) k;

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0d01', '0b000000-0000-4000-8000-000000000b13', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3450, 103.7700000),
  -- 220 m east: nine steps allow 225 m, so this walk is legal even though it is nine times the flat 25 m.
  ('0b000000-0000-4000-8000-0000000f0d10', '0b000000-0000-4000-8000-000000000b13', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3450, 103.7719768);

-- Two frames a hundred seconds apart, 200 m walked. This one is a break at 1 step, and section 3 turns the same walk
-- into a legal one by adding frames -- not by moving anything, and not by changing the clock.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0e01', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',   0, 'go',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0e02', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', 100, 'arrive', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0e01', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3470, 103.7700000),
  ('0b000000-0000-4000-8000-0000000f0e02', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3470, 103.7717966);

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. what this file assumes ----------
do $$
declare
  v_def text;
  v_n integer;
  v_times integer[];
begin
  v_def := pg_get_functiondef('public.plan_check(uuid)'::regprocedure);
  if position('v_step_m' in v_def) = 0 or position('steps, so the limit is' in v_def) = 0 then
    raise exception 'FAIL 0a: plan_check is not the 049 body (it still compares a flat 25 m). Run node tools/migrate.mjs up.';
  end if;
  -- R8: the pace and zone rules 048 added must still be in the body this one replaced.
  if position('faster than running' in v_def) = 0 or position('extensions.st_intersects' in v_def) = 0 then
    raise exception 'FAIL 0b: the 049 body lost the zone or the pace rule that 048 added';
  end if;

  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b01';
  if v_n <> 6 then
    raise exception 'FAIL 0c: Walkthrough holds % frames, expected 6. Run supabase/fixtures/plan_bench.sql first.', v_n;
  end if;
  select array_agg(t_s order by t_s) into v_times
    from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b13';
  if v_times is distinct from array[0, 60, 120, 180, 240, 300, 360, 420, 480, 540] then
    raise exception 'FAIL 0d: Step bench holds %, expected ten frames a minute apart', v_times;
  end if;
end $$;

-- ---------- 1. the bench's own walk: two steps, and the pair a planner can actually fix ----------
do $$
declare
  v_n integer;
  v_row record;
begin
  select * into v_row
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a002';
  if not found then
    raise exception 'FAIL 1a: Walkthrough does not report Sound''s 200 m at all';
  end if;
  -- Sound states its position at +1:00 and again at +3:00, and says nothing at +2:00. The pair has to be the two
  -- statements: +2:00 is the frame that only carried the old position forward, and nothing there can be moved.
  if v_row.from_s <> 60 or v_row.to_s <> 180 then
    raise exception 'FAIL 1b: Sound''s walk is reported from % to %, expected 60 to 180 (the stated frames)', v_row.from_s, v_row.to_s;
  end if;
  if v_row.metres < 199 or v_row.metres > 201 then
    raise exception 'FAIL 1c: Sound''s walk reads % m, expected about 200', v_row.metres;
  end if;
  if position('2 steps' in v_row.message) = 0 or position('the limit is 50 m' in v_row.message) = 0 then
    raise exception 'FAIL 1d: the sentence does not say two steps allow 50 m: %', v_row.message;
  end if;
  if position('+1:00' in v_row.message) = 0 or position('+3:00' in v_row.message) = 0 then
    raise exception 'FAIL 1e: the sentence does not name the two moments: %', v_row.message;
  end if;
  -- One step is still one step: Security's crossing sentence keeps the 25 m wording every older check reads.
  select count(*) into v_n
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a004'
     and position('the limit is 25 m' in c.message) > 0;
  if v_n <> 0 then
    raise exception 'FAIL 1f: Security''s crossing is reported as a distance break too';
  end if;
end $$;

-- ---------- 2. the strip: nine steps allow 225 m, and 230 m is a break ----------
do $$
declare
  v_n integer;
  v_msg text;
  v_row record;
begin
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b13');
  if v_n <> 0 then
    raise exception 'FAIL 2a: a 220 m walk across nine steps is legal and was reported % time(s): %',
      v_n, (select string_agg(c.message, ' | ') from public.plan_check('0b000000-0000-4000-8000-000000000b13') c);
  end if;

  -- 230 m across the same nine steps: over the 225 m the budget allows, by five metres.
  update public.plan_positions
     set lng = 103.7720667
   where frame_id = '0b000000-0000-4000-8000-0000000f0d10'
     and group_id = '0b000000-0000-4000-8000-00000000a001';

  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b13');
  if v_n <> 1 then
    raise exception 'FAIL 2b: 230 m across nine steps is reported % time(s), expected once', v_n;
  end if;
  select * into v_row from public.plan_check('0b000000-0000-4000-8000-000000000b13') limit 1;
  if v_row.from_s <> 0 or v_row.to_s <> 540 then
    raise exception 'FAIL 2c: the break runs from % to %, expected 0 to 540', v_row.from_s, v_row.to_s;
  end if;
  if v_row.metres < 229 or v_row.metres > 231 then
    raise exception 'FAIL 2d: the break reads % m, expected about 230', v_row.metres;
  end if;
  if position('9 steps' in v_row.message) = 0 or position('the limit is 225 m' in v_row.message) = 0 then
    raise exception 'FAIL 2e: the sentence does not say nine steps allow 225 m: %', v_row.message;
  end if;

  -- The frames in between are the budget, and they are what the board marks: nine steps is ten frames. Section 3 is
  -- the other end of it -- the same walk with the slots taken away -- on a plan of its own, so this strip stays legal
  -- for section 4's positive control.
  update public.plan_positions
     set lng = 103.7719768
   where frame_id = '0b000000-0000-4000-8000-0000000f0d10'
     and group_id = '0b000000-0000-4000-8000-00000000a001';
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b13');
  if v_n <> 0 then
    raise exception 'FAIL 2f: the 220 m walk is legal again and is reported % time(s)', v_n;
  end if;
end $$;

-- ---------- 3. the frame count pays, not the clock ----------
do $$
declare
  v_n integer;
  v_msg text;
begin
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b14') c;
  if v_n <> 1 or position('the limit is 25 m' in v_msg) = 0 then
    raise exception 'FAIL 3a: two frames and 200 m reads % error(s): %', v_n, v_msg;
  end if;

  -- The same 200 m, the same 100 s, nine more frames. Nothing is moved; the walk simply has ten slots instead of one.
  insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
  select
    ('0b000000-0000-4000-8000-0000000f0f' || lpad(k::text, 2, '0'))::uuid,
    '0b000000-0000-4000-8000-000000000b14',
    '0b000000-0000-4000-8000-000000000e01',
    k * 10, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from generate_series(1, 9) k;

  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b14') c;
  if v_n <> 0 then
    raise exception 'FAIL 3b: the same 200 m in the same 100 s is still refused with ten slots: %', v_msg;
  end if;

  -- And the pace rule has not been quietly widened by the budget: 200 m in 100 s is 2 m/s, but 20 m in one second is
  -- still a sprint. Shrinking the clock instead of the distance is what the pace rule is for, and with the budget in
  -- place the distance has to be legal for the pace to be the thing that speaks.
  update public.plan_positions
     set lng = 103.7701797
   where frame_id = '0b000000-0000-4000-8000-0000000f0e02'
     and group_id = '0b000000-0000-4000-8000-00000000a002';
  update public.plan_frames set t_s = 1 where id = '0b000000-0000-4000-8000-0000000f0e02';
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b14') c;
  if v_n <> 1 or position('faster than running' in v_msg) = 0 then
    raise exception 'FAIL 3c: 20 m in a second reads % error(s), expected a pace: %', v_n, v_msg;
  end if;

  -- Put it back the way section 4 needs it: 200 m, one frame later, ten slots.
  update public.plan_positions
     set lng = 103.7717966
   where frame_id = '0b000000-0000-4000-8000-0000000f0e02'
     and group_id = '0b000000-0000-4000-8000-00000000a002';
  update public.plan_frames set t_s = 100 where id = '0b000000-0000-4000-8000-0000000f0e02';
end $$;

-- ---------- 4. publish follows the budget, and still says what refused it ----------
do $$
declare
  v_msg text;
  v_status text;
  v_row public.plans;
begin
  -- The strip is legal as it stands (section 2 put it back to 220 m), so it publishes: the positive control.
  select * into v_row from public.plan_publish('0b000000-0000-4000-8000-000000000b13', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b13'));
  if v_row.status <> 'live' then
    raise exception 'FAIL 4a: a legal ten-frame strip would not publish (status %)', v_row.status;
  end if;

  -- Now 230 m, which is five metres past what nine steps pay for.
  update public.plan_positions
     set lng = 103.7720667
   where frame_id = '0b000000-0000-4000-8000-0000000f0d10'
     and group_id = '0b000000-0000-4000-8000-00000000a001';
  update public.plans set status = 'draft' where id = '0b000000-0000-4000-8000-000000000b13';

  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b13', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b13'));
    raise exception 'FAIL 4b: a plan with a 230 m walk across nine steps was published';
  exception
    when others then
      v_msg := sqlerrm;
  end;
  if position('cannot be published' in v_msg) = 0 then
    raise exception 'FAIL 4c: the refusal does not say it refused: %', v_msg;
  end if;
  if position('230 m' in v_msg) = 0 or position('9 steps' in v_msg) = 0 or position('225 m' in v_msg) = 0 then
    raise exception 'FAIL 4d: the refusal does not say the walk had nine steps and 225 m to spend: %', v_msg;
  end if;
  select status into v_status from public.plans where id = '0b000000-0000-4000-8000-000000000b13';
  if v_status <> 'draft' then
    raise exception 'FAIL 4e: after the refusal the plan reads %, expected draft', v_status;
  end if;

  -- One step is still one step for publish too, so the bench keeps the sentence older checks read.
  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b01', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b01'));
    raise exception 'FAIL 4f: the bench walkthrough was published';
  exception
    when others then
      v_msg := sqlerrm;
  end;
  if position('cannot be published' in v_msg) = 0 or position('Stores' in v_msg) = 0 then
    raise exception 'FAIL 4g: the walkthrough''s refusal does not name the crossing first: %', v_msg;
  end if;
end $$;

-- ---------- 5. the doors ----------
do $$
declare
  v_n integer;
begin
  if has_function_privilege('anon', 'public.plan_check(uuid)', 'execute') then
    raise exception 'FAIL 5a: anon can execute plan_check';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_check(uuid)', 'execute') then
    raise exception 'FAIL 5b: authenticated cannot execute plan_check';
  end if;
  select count(*) into v_n
    from pg_proc p,
         lateral aclexplode(coalesce(p.proacl, '{}'::aclitem[])) a
   where p.oid = 'public.plan_check(uuid)'::regprocedure
     and a.grantee = 0
     and a.privilege_type = 'EXECUTE';
  if v_n > 0 then
    raise exception 'FAIL 5c: plan_check is still granted to PUBLIC';
  end if;
end $$;

-- ---------- 6. a member cannot see another group's walk at all ----------
-- Until step 16 a member's plan_check computed from their own group's positions and proved it never named another
-- group's stretch. 052 closed the plan's frames to everyone but ops staff, so the call now walks nothing: the
-- assertion is the silence (no other group's stretch can be named by a function that reads no frames), and the
-- planner's reads earlier in this file are the positive control.
do $$
declare
  v_n integer;
  v_msg text;
begin
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c;
  if v_n <> 0 then
    raise exception 'FAIL 6a: a member''s check reads % error(s), expected none since 052: %', v_n, v_msg;
  end if;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
end $$;

rollback;

select 'step 12: the 25 m rule is 25 m per frame step -- nine steps allow 225 m, and the pair named is the two statements' as result;
