-- Step 3, checked at the database: a member reads only their own group's positions.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench
--     node tools/sql.mjs --file dev/checks/step3-group-scope.sql
--
-- It impersonates three real people from the bench the way PostgREST does — `set local role authenticated` plus
-- the JWT sub in request.jwt.claims — and reads through the two doors a client has: plan_frames_list() and the
-- table itself. Any false assertion raises, so a passing run is the one row printed at the end.
--
-- Who is who on the bench:
--   testuser4  Gate Crew IC, in one group, no staff role          -> must see Gate Crew only
--   testuser5  Gate Crew IC, second IC of the same group          -> must see the same four rows
--   testuser3  Sound *group admin*, no staff role                 -> must see Sound only (an admin is not staff)
--   testuser1  root + planner                                     -> must see every group
--   testuser2  planner, in no group                               -> must see every group (the role, not the person)
--
-- The bench's two plans matter here:
--   "Clean walk"  4 frames, every group placed at every frame (16 positions) -- a count that cannot pass by being 0
--   "Walkthrough" 6 frames, Gate Crew clean, Sound has one deliberate 200 m jump at +2:00
-- The jump is the positive control for RLS inside plan_check(): the Sound member must see that error; the Gate
-- Crew IC must not, because the row it is computed from is invisible to them.
begin;

-- ---------- the bench must be there ----------
do $$
begin
  if not exists (select 1 from public.plans where id = '0b000000-0000-4000-8000-000000000b02')
     or not exists (select 1 from public.plans where id = '0b000000-0000-4000-8000-000000000b01') then
    raise exception 'The plan bench is missing. Run supabase/fixtures/plan_bench.sql first.';
  end if;
end $$;

-- ---------- 1. a Gate Crew IC sees Gate Crew, and nothing else ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_n integer;
  v_groups integer;
  v_other integer;
  v_frames integer;
  v_keys integer;
  v_keys_elsewhere integer;
  v_refused boolean := false;
begin
  -- The table: four positions of the clean plan, all one group.
  select count(*), count(distinct group_id) into v_n, v_groups
    from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 4 then raise exception 'FAIL 1a: a Gate Crew IC sees % of the clean plan''s 16 positions, expected 4', v_n; end if;
  if v_groups <> 1 then raise exception 'FAIL 1b: the Gate Crew IC sees % groups, expected 1', v_groups; end if;
  select count(*) into v_other from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b02'
     and group_id <> '0b000000-0000-4000-8000-00000000a001';
  if v_other <> 0 then raise exception 'FAIL 1c: % position(s) of other groups are visible to a Gate Crew IC', v_other; end if;

  -- The app's door was the strip in step 3's day: plan_frames_list() answered a member with the frames and their own
  -- group's positions. Step 16 closed that door on purpose -- a member's moments are their timetable now, read with
  -- session_timetable(), and the plan's frames and notes are the planner's working copy -- so this door answers
  -- nothing. The step-16 check asserts the timetable's own scope; this asserts that the old door is shut and that the
  -- positions table (040's rule, which this check is about) is unchanged.
  select count(*) into v_frames from public.plan_frames_list('0b000000-0000-4000-8000-000000000b02');
  if v_frames <> 0 then
    raise exception 'FAIL 1d: plan_frames_list answered a member with % frames, expected none since step 16 (052)', v_frames;
  end if;
  select count(*) into v_frames from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_frames <> 0 then
    raise exception 'FAIL 1e: a member read % frames of a plan directly, expected none since step 16 (052)', v_frames;
  end if;

  -- The 200 m jump in Walkthrough belongs to Sound. A member's plan_check used to compute from the rows they could
  -- see; since step 16 the frames are not theirs to read, so the call walks nothing and answers no errors. That is
  -- the property asserted here now -- and the planner's call, which still reports both problems, is part 4.
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_n <> 0 then raise exception 'FAIL 1g: a Gate Crew IC''s plan_check saw % error(s) of another group', v_n; end if;

  -- And reading is still not writing: the IC is refused by the same function the board uses.
  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b02',
      jsonb_build_object('t_s', 0, 'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
                                                                  jsonb_build_object('lat', 1.33, 'lng', 103.77))));
  exception when others then
    v_refused := sqlerrm like '%Only the root user%';
    if not v_refused then raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 1h: a Gate Crew IC could save a frame'; end if;
end $$;

-- ---------- 2. the second IC of the same group sees the same four rows ----------
reset role;
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer; v_groups integer;
begin
  select count(*), count(distinct group_id) into v_n, v_groups
    from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 4 or v_groups <> 1 then
    raise exception 'FAIL 2: the second Gate Crew IC sees % rows across % groups, expected 4 in 1', v_n, v_groups;
  end if;
end $$;

-- ---------- 3. a group admin sees their group, not the event ----------
reset role;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer; v_groups integer; v_other integer; v_err integer;
begin
  select count(*), count(distinct group_id) into v_n, v_groups
    from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 4 then raise exception 'FAIL 3a: the Sound admin sees % of 16 positions, expected 4', v_n; end if;
  if v_groups <> 1 then raise exception 'FAIL 3b: the Sound admin sees % groups, expected 1', v_groups; end if;
  select count(*) into v_other from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b02'
     and group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_other <> 0 then raise exception 'FAIL 3c: % position(s) of other groups are visible to the Sound admin', v_other; end if;

  -- A member's plan_check walks nothing now that the frames are closed (052), so their own group's 200 m jump is not
  -- reported to them either: the function the board uses is a planner's tool. The planner's call is the control (4d).
  select count(*) into v_err from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_err <> 0 then raise exception 'FAIL 3d: a member''s plan_check returned % errors, expected none (052 closed the frames)', v_err; end if;
end $$;

-- ---------- 4. a planner sees every group of every plan ----------
reset role;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer; v_groups integer; v_bad integer; v_keys_missing integer; v_err integer;
begin
  select count(*), count(distinct group_id) into v_n, v_groups
    from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 16 then raise exception 'FAIL 4a: a planner sees % of the clean plan''s 16 positions', v_n; end if;
  if v_groups <> 4 then raise exception 'FAIL 4b: a planner sees % groups, expected 4', v_groups; end if;

  -- Every frame carries all four groups -- the fix must not have narrowed the planner's own view.
  select count(*) into v_bad
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b02') t
   where (select count(*) from jsonb_object_keys(t.positions)) <> 4;
  if v_bad <> 0 then raise exception 'FAIL 4c: % frame(s) do not carry all four groups for a planner', v_bad; end if;

  -- The positive control for the policy: the 200 m jump that the members could not see is visible here, and so is
  -- Security's 20 m walk through the Stores no-go zone that step 11 taught plan_check to report.
  select count(*) into v_err from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_err <> 2 then raise exception 'FAIL 4d: the planner''s plan_check returned % errors, expected 2 (Sound''s 200 m and Security''s crossing)', v_err; end if;
end $$;

-- ---------- 5. the second planner sees the same, because it is the role ----------
reset role;
set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 16 then raise exception 'FAIL 5: the other planner sees % of 16 positions', v_n; end if;
end $$;

-- ---------- 6. a marshal is ops staff too (and losing the duty loses the view) ----------
-- A marshal stands on the floor and already sees every group's movement (027). The plan says the same thing, so
-- this is checked with a real marshal role, then removed again: the duty is not the bench's normal state.
reset role;
insert into public.event_roles (event_id, user_id, role)
values ('0b000000-0000-4000-8000-000000000e01', '00cd023b-0e26-4574-a635-760e782c8029', 'marshal');
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 16 then raise exception 'FAIL 6a: a marshal sees % of 16 positions, expected every group', v_n; end if;
end $$;

reset role;
delete from public.event_roles
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and user_id = '00cd023b-0e26-4574-a635-760e782c8029' and role = 'marshal';
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
set local role authenticated;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 4 then
    raise exception 'FAIL 6b: after the marshal duty ended the IC still sees % positions, expected 4', v_n;
  end if;
end $$;

-- ---------- 7. finding 20: no PUBLIC execute left on the plan surface ----------
reset role;

do $$
declare v_bad text; v_n integer;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where n.nspname = 'public'
     and p.proname in ('plan_list', 'plan_save', 'plan_delete', 'plan_fork', 'plan_publish', 'plan_frames_list',
                       'frame_save', 'frame_move', 'frame_delete', 'frame_shift', 'plan_check', 'plan_clock',
                       'plan_frames_check_scope', 'plan_positions_check_scope', 'activities_check_scope')
     and a.grantee = 0 and a.privilege_type = 'EXECUTE';
  if v_bad is not null then raise exception 'FAIL 7a: PUBLIC can still execute %', v_bad; end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('plan_list', 'plan_save', 'plan_delete', 'plan_fork', 'plan_publish', 'plan_frames_list',
                       'frame_save', 'frame_move', 'frame_delete', 'frame_shift', 'plan_check', 'plan_clock',
                       'plan_frames_check_scope', 'plan_positions_check_scope', 'activities_check_scope')
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'FAIL 7b: anon can still execute %', v_bad; end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('plan_list', 'plan_save', 'plan_delete', 'plan_fork', 'plan_publish', 'plan_frames_list',
                       'frame_save', 'frame_move', 'frame_delete', 'frame_shift', 'plan_check', 'plan_clock')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'FAIL 7c: authenticated lost execute on %', v_bad; end if;

  select count(*) into v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('plan_list', 'plan_save', 'plan_delete', 'plan_fork', 'plan_publish', 'plan_frames_list',
                       'frame_save', 'frame_move', 'frame_delete', 'frame_shift', 'plan_check', 'plan_clock')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_n <> 12 then raise exception 'FAIL 7d: authenticated has execute on % of the 12 client functions', v_n; end if;
end $$;

commit;

select jsonb_build_object(
  'gate_crew_ic', '4 positions, 1 group, no foreign keys',
  'second_ic', 'same 4',
  'sound_admin', '4 positions, no plan_check errors (the frames are closed)',
  'planner', '16 positions, 4 groups, sees the 200 m error',
  'marshal', '16 while on duty, 4 after',
  'grants', 'PUBLIC 0, anon 0, authenticated 12 of 12'
) as step3;
