-- Step 7, checked at the database: hold one group where it already stands, and refuse the three writes that would
-- not mean what the word means.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step7-hold-group.sql
--
-- Section 1 is the step's Done-when, on "Copy bench": hold Sound at +0:00 for five minutes, and the row at +5:00 for
-- Sound is the row at +0:00 -- byte for byte, not "about there" -- while no other group gained one. The snapshot
-- before and after is a whole-plan comparison, so "nothing else changed" is compared rather than claimed.
--
-- Section 2 is the frame that is already there: holding Sound to +1:00 reuses that frame, keeps its note and Gate
-- Crew's position, and bumps its revision because the frame gained a row. A second click writes nothing and does not
-- bump it again -- "Hold" twice is the same hold, not an edit.
--
-- Section 3 is the invariant argued in 045: a hold cannot make the 25 m rule worse, because the hop P -> N becomes
-- P -> P plus P -> N. Walkthrough already has one break, so "the same break, the same distance" is something the
-- check can see rather than deduce.
--
-- Section 4 is what is refused: a frame at the wanted moment that already puts the group somewhere else (Twin gap),
-- a group that moves before the moment asked for (Push bench), a group that stands nowhere yet, another event's
-- group, another plan's frame, a hold backwards or of zero seconds, and a target past the three-day ceiling. Section
-- 5 is the default: no group list holds everyone standing at the frame, and nobody else.
--
-- Everything runs in one transaction and is rolled back, so the bench is left as the fixture wrote it.
begin;

-- Two plans and one foreign event the refusals need, written as the owner before the caller becomes a planner:
--   * "Hold bench": a frame and no positions, so "nothing to hold" can be asked for.
--   * "Ceiling bench": one frame at the last legal second and one a hundred seconds before it.
--   * a second event with a group of its own, for "that group belongs to another event".
insert into public.events (id, name, created_by) values
  ('0b000000-0000-4000-8000-000000000e02', 'Some other event', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.groups (id, event_id, name, code) values
  ('0b000000-0000-4000-8000-00000000a101', '0b000000-0000-4000-8000-000000000e02', 'Elsewhere', 'ELSE');

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by) values
  ('0b000000-0000-4000-8000-000000000b06', '0b000000-0000-4000-8000-000000000e01',
   'Hold bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-000000000b07', '0b000000-0000-4000-8000-000000000e01',
   'Ceiling bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
  ('0b000000-0000-4000-8000-0000000f0601', '0b000000-0000-4000-8000-000000000b06', '0b000000-0000-4000-8000-000000000e01', 0, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0701', '0b000000-0000-4000-8000-000000000b07', '0b000000-0000-4000-8000-000000000e01', 259200, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0702', '0b000000-0000-4000-8000-000000000b07', '0b000000-0000-4000-8000-000000000e01', 259100, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0701', '0b000000-0000-4000-8000-000000000b07', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f0702', '0b000000-0000-4000-8000-000000000b07', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3310000, 103.77550);

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the bench must still hold the strips this step is about ----------
do $$
declare
  v_times integer[];
  v_n integer;
begin
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_times is distinct from array[0, 60] then
    raise exception 'FAIL 0a: "Copy bench" holds %, expected 0/60. Run supabase/fixtures/plan_bench.sql first.', v_times;
  end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_n <> 4 then
    raise exception 'FAIL 0b: "Copy bench" holds % positions, expected 4 (the fixture''s four)', v_n;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 60, 120, 180] then
    raise exception 'FAIL 0c: "Push bench" holds %, expected 0/60/120/180', v_times;
  end if;
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b05');
  if v_n <> 0 then
    raise exception 'FAIL 0d: "Push bench" already breaks the 25 m rule (% breaks), so a refusal could not be told apart from it', v_n;
  end if;
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b04';
  if v_times is distinct from array[0, 300] then
    raise exception 'FAIL 0e: "Twin gap" holds %, expected 0/300', v_times;
  end if;
end $$;

-- ---------- 1. the Done-when: Sound held at +0:00 for five minutes ----------
do $$
declare
  v_before jsonb;
  v_after jsonb;
  v_row record;
  v_n integer;
  v_id uuid;
  v_rev integer;
  v_note text;
  v_times integer[];
  v_lat0 float8;
  v_lng0 float8;
  v_lat float8;
  v_lng float8;
begin
  -- The whole plan as it stands, so "nothing else changed" is a comparison of every row rather than a claim about
  -- the rows the test happened to think of.
  select jsonb_agg(jsonb_build_object(
           'frame', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note,
           'group', p.group_id, 'lat', p.lat, 'lng', p.lng) order by f.t_s, p.group_id)
    into v_before
    from public.plan_frames f
    join public.plan_positions p on p.frame_id = f.id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b03';

  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b03',
           '0b000000-0000-4000-8000-0000000f0201',
           300,
           array['0b000000-0000-4000-8000-00000000a002']::uuid[]) r;

  if v_row.held_t_s <> 300 then
    raise exception 'FAIL 1a: the hold landed at %, expected +5:00', v_row.held_t_s;
  end if;
  if v_row.frames_added <> 1 or v_row.frames_reused <> 0 then
    raise exception 'FAIL 1b: the hold added % and reused % frames, expected one new frame',
      v_row.frames_added, v_row.frames_reused;
  end if;
  if v_row.positions_written <> 1 or v_row.groups_held <> 1 then
    raise exception 'FAIL 1c: the hold wrote % positions for % groups, expected 1 and 1',
      v_row.positions_written, v_row.groups_held;
  end if;

  select f.id, f.rev, f.note into v_id, v_rev, v_note
    from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b03' and f.t_s = 300;
  if v_id is distinct from v_row.held_frame_id then
    raise exception 'FAIL 1d: the function reported frame %, but the frame at +5:00 is %', v_row.held_frame_id, v_id;
  end if;
  if v_rev <> 1 then
    raise exception 'FAIL 1e: a new frame arrived on revision %', v_rev;
  end if;
  if v_note is not null then
    raise exception 'FAIL 1f: the hold invented a note: %', v_note;
  end if;

  -- The Done-when, literally: the row at +5:00 for that group is the row at +0:00.
  select p.lat, p.lng into v_lat0, v_lng0
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
     and p.group_id = '0b000000-0000-4000-8000-00000000a002';
  select p.lat, p.lng into v_lat, v_lng
    from public.plan_positions p
   where p.frame_id = v_row.held_frame_id
     and p.group_id = '0b000000-0000-4000-8000-00000000a002';
  if v_lat is distinct from v_lat0 or v_lng is distinct from v_lng0 then
    raise exception 'FAIL 1g: the held row is (%, %), the row it had to equal is (%, %)', v_lat, v_lng, v_lat0, v_lng0;
  end if;

  -- ... and no other group gained one.
  select count(*) into v_n from public.plan_positions p where p.frame_id = v_row.held_frame_id;
  if v_n <> 1 then
    raise exception 'FAIL 1h: the new frame states % groups, expected only Sound', v_n;
  end if;
  if exists (
    select 1 from public.plan_positions p
     where p.frame_id = v_row.held_frame_id
       and p.group_id <> '0b000000-0000-4000-8000-00000000a002'
  ) then
    raise exception 'FAIL 1i: a group that was not held gained a position at +5:00';
  end if;

  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_times is distinct from array[0, 60, 300] then
    raise exception 'FAIL 1j: after the hold the strip holds %, expected 0/60/300', v_times;
  end if;
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b03');
  if v_n <> 0 then
    raise exception 'FAIL 1k: the hold broke the 25 m rule (% breaks) on a plan that had none', v_n;
  end if;

  -- Every row that is not the new frame's own: identical, notes and revisions included.
  select jsonb_agg(jsonb_build_object(
           'frame', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note,
           'group', p.group_id, 'lat', p.lat, 'lng', p.lng) order by f.t_s, p.group_id)
    into v_after
    from public.plan_frames f
    join public.plan_positions p on p.frame_id = f.id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b03'
     and f.t_s <> 300;
  if v_after is distinct from v_before then
    raise exception 'FAIL 1l: the hold changed a row that was not its own. Before %, after %', v_before, v_after;
  end if;
end $$;

-- ---------- 2. a frame already at the moment is reused, not duplicated ----------
do $$
declare
  v_row record;
  v_rev integer;
  v_note text;
  v_before jsonb;
  v_after jsonb;
  v_n integer;
begin
  -- Gate Crew's row on that frame, and the frame's own note: both are somebody's decision and both must survive.
  select jsonb_build_object('lat', p.lat, 'lng', p.lng) into v_before
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';

  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b03',
           '0b000000-0000-4000-8000-0000000f0201',
           60,
           array['0b000000-0000-4000-8000-00000000a002']::uuid[]) r;

  if v_row.held_frame_id <> '0b000000-0000-4000-8000-0000000f0202' then
    raise exception 'FAIL 2a: the hold did not reuse the frame at +1:00 (% was reported)', v_row.held_frame_id;
  end if;
  if v_row.frames_added <> 0 or v_row.frames_reused <> 1 then
    raise exception 'FAIL 2b: holding to an existing moment added % and reused % frames',
      v_row.frames_added, v_row.frames_reused;
  end if;
  if v_row.positions_written <> 1 then
    raise exception 'FAIL 2c: the reuse wrote % positions, expected one', v_row.positions_written;
  end if;

  select f.rev, f.note into v_rev, v_note from public.plan_frames f where f.id = v_row.held_frame_id;
  if v_rev <> 2 then
    raise exception 'FAIL 2d: the reused frame is on revision %, expected 2 (it gained a position)', v_rev;
  end if;
  if v_note is distinct from 'one here' then
    raise exception 'FAIL 2e: the reuse lost the frame note (reads %)', v_note;
  end if;

  select jsonb_build_object('lat', p.lat, 'lng', p.lng) into v_after
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_after is distinct from v_before then
    raise exception 'FAIL 2f: reusing the frame moved a group that was already on it (before %, after %)', v_before, v_after;
  end if;

  -- Twice is once: the second click finds every group already there, writes nothing, and leaves the revision alone.
  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b03',
           '0b000000-0000-4000-8000-0000000f0201',
           60,
           array['0b000000-0000-4000-8000-00000000a002']::uuid[]) r;
  if v_row.positions_written <> 0 then
    raise exception 'FAIL 2g: holding the same group to the same moment wrote % positions a second time', v_row.positions_written;
  end if;
  if v_row.frames_added <> 0 or v_row.frames_reused <> 0 then
    raise exception 'FAIL 2h: a hold that wrote nothing still reported added % / reused %',
      v_row.frames_added, v_row.frames_reused;
  end if;
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0202';
  if v_rev <> 2 then
    raise exception 'FAIL 2i: a hold that wrote nothing bumped the revision to %', v_rev;
  end if;
  select count(*) into v_n from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_n <> 3 then
    raise exception 'FAIL 2j: the plan holds % frames, expected 3 (0/60/300, no duplicates)', v_n;
  end if;
end $$;

-- ---------- 3. a hold cannot make the 25 m rule worse ----------
do $$
declare
  v_before jsonb;
  v_after jsonb;
  v_row record;
  v_rev integer;
  v_note text;
  v_lat0 float8;
  v_lat float8;
  v_lng0 float8;
  v_lng float8;
begin
  -- Walkthrough already has two problems -- Sound's 200 m jump (reported between +1:00 and +3:00) and Security's
  -- 20 m walk through the Stores no-go zone (+0:00 to +1:00, step 11). Hold Backstage, which is stated once at
  -- +0:00 and never again, to +5:00: the frame there is reused, and neither problem may move.
  select jsonb_agg(jsonb_build_object('group', c.group_id, 'from', c.from_s, 'to', c.to_s, 'metres', c.metres)
                   order by c.group_id, c.from_s)
    into v_before
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c;
  if jsonb_array_length(v_before) <> 2 then
    raise exception 'FAIL 3a: Walkthrough should have exactly two problems before the hold, it has %: %',
      jsonb_array_length(v_before), v_before;
  end if;

  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b01',
           '0b000000-0000-4000-8000-0000000f0001',
           300,
           array['0b000000-0000-4000-8000-00000000a003']::uuid[]) r;

  if v_row.held_frame_id <> '0b000000-0000-4000-8000-0000000f0006' then
    raise exception 'FAIL 3b: the hold did not reuse Walkthrough''s frame at +5:00 (% was reported)', v_row.held_frame_id;
  end if;
  if v_row.positions_written <> 1 or v_row.frames_added <> 0 then
    raise exception 'FAIL 3c: the hold wrote % positions and added % frames, expected 1 and 0',
      v_row.positions_written, v_row.frames_added;
  end if;

  select f.rev, f.note into v_rev, v_note from public.plan_frames f where f.id = v_row.held_frame_id;
  if v_rev <> 2 or v_note is distinct from 'out' then
    raise exception 'FAIL 3d: the reused frame reads revision % / note %, expected 2 / "out"', v_rev, v_note;
  end if;

  select p.lat, p.lng into v_lat0, v_lng0
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0001'
     and p.group_id = '0b000000-0000-4000-8000-00000000a003';
  select p.lat, p.lng into v_lat, v_lng
    from public.plan_positions p
   where p.frame_id = v_row.held_frame_id
     and p.group_id = '0b000000-0000-4000-8000-00000000a003';
  if v_lat is distinct from v_lat0 or v_lng is distinct from v_lng0 then
    raise exception 'FAIL 3e: Backstage was held to (%, %), not to where it stood (%, %)', v_lat, v_lng, v_lat0, v_lng0;
  end if;

  select jsonb_agg(jsonb_build_object('group', c.group_id, 'from', c.from_s, 'to', c.to_s, 'metres', c.metres)
                   order by c.group_id, c.from_s)
    into v_after
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c;
  if v_after is distinct from v_before then
    raise exception 'FAIL 3f: the hold changed what the 25 m rule says. Before %, after %', v_before, v_after;
  end if;
end $$;

-- ---------- 4. the refusals ----------
do $$
declare
  v_message text;
  v_n integer;
  v_lat float8;
  v_lat0 float8;
  v_row record;
  v_rev integer;
begin
  -- (a) The frame at the wanted moment already puts the group somewhere else. Twin gap's +5:00 has Gate Crew 200 m
  -- east of where it stands at +0:00; holding would silently rewrite that decision.
  select p.lat into v_lat0 from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b04',
      '0b000000-0000-4000-8000-0000000f0301',
      300,
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4a: the hold overwrote a position somebody had placed';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('already stands somewhere else' in v_message) = 0 or position('+5:00' in v_message) = 0 then
    raise exception 'FAIL 4b: the refusal reads: %', v_message;
  end if;
  select p.lat into v_lat from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_lat is distinct from v_lat0 then
    raise exception 'FAIL 4c: the refused hold still moved Gate Crew (%, was %)', v_lat, v_lat0;
  end if;
  select count(*) into v_n from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b04';
  if v_n <> 2 then
    raise exception 'FAIL 4d: the refused hold left % frames, expected the fixture''s 2', v_n;
  end if;

  -- (b) The group moves before the moment asked for. Push bench states Gate Crew at +1:00, +2:00 and +3:00; a hold to
  -- +5:00 would add a 72 m jump back, not a delay. The sentence names the frame it moves at.
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b05',
      '0b000000-0000-4000-8000-0000000f0401',
      300,
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4e: a group that moves before the target was "held" anyway';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('moves before' in v_message) = 0 or position('+1:00' in v_message) = 0 then
    raise exception 'FAIL 4f: the refusal reads: %', v_message;
  end if;
  select count(*) into v_n from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_n <> 4 then
    raise exception 'FAIL 4g: the refused hold left % frames, expected 4', v_n;
  end if;

  -- (c) A group that stands nowhere yet: Security is in no frame of Copy bench, so there is nothing to hold.
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b03',
      '0b000000-0000-4000-8000-0000000f0201',
      60,
      array['0b000000-0000-4000-8000-00000000a004']::uuid[]);
    raise exception 'FAIL 4h: a group that was never placed was held anyway';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('stands nowhere' in v_message) = 0 or position('Security' in v_message) = 0 then
    raise exception 'FAIL 4i: the refusal reads: %', v_message;
  end if;

  -- (d) Another event's group.
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b03',
      '0b000000-0000-4000-8000-0000000f0201',
      60,
      array['0b000000-0000-4000-8000-00000000a101']::uuid[]);
    raise exception 'FAIL 4j: a group from another event was held';
  exception
    when sqlstate '42501' then v_message := sqlerrm;
  end;
  if position('another event' in v_message) = 0 then
    raise exception 'FAIL 4k: the refusal reads: %', v_message;
  end if;

  -- (e) Another plan's frame.
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b03',
      '0b000000-0000-4000-8000-0000000f0301',
      60,
      null);
    raise exception 'FAIL 4l: a frame from another plan was held';
  exception
    when sqlstate '42501' then v_message := sqlerrm;
  end;
  if position('not in this plan' in v_message) = 0 then
    raise exception 'FAIL 4m: the refusal reads: %', v_message;
  end if;

  -- (f) A plan that does not exist.
  begin
    perform public.frame_hold('0b000000-0000-4000-8000-00000000dead', '0b000000-0000-4000-8000-0000000f0201', 60, null);
    raise exception 'FAIL 4n: a plan that does not exist was held';
  exception
    when sqlstate '42501' then v_message := sqlerrm;
  end;
  if position('does not exist' in v_message) = 0 then
    raise exception 'FAIL 4o: the refusal reads: %', v_message;
  end if;

  -- (g) A hold that does not run forward, and one with no length at all.
  begin
    perform public.frame_hold('0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-0000000f0201', 0, null);
    raise exception 'FAIL 4p: a zero-second hold was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('runs forward' in v_message) = 0 then
    raise exception 'FAIL 4q: the refusal reads: %', v_message;
  end if;
  begin
    perform public.frame_hold('0b000000-0000-4000-8000-000000000b03', '0b000000-0000-4000-8000-0000000f0201', -60, null);
    raise exception 'FAIL 4r: a hold backwards was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  -- (h) Nothing to hold: a frame with no positions at all.
  begin
    perform public.frame_hold('0b000000-0000-4000-8000-000000000b06', '0b000000-0000-4000-8000-0000000f0601', 60, null);
    raise exception 'FAIL 4s: an empty plan was held';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('Nothing to hold' in v_message) = 0 then
    raise exception 'FAIL 4t: the refusal reads: %', v_message;
  end if;

  -- (i) The ceiling, named rather than arrived at through plan_frames_t_range.
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b07',
      '0b000000-0000-4000-8000-0000000f0701',
      1,
      array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
    raise exception 'FAIL 4u: a hold past the ceiling was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
    when check_violation then
      raise exception 'FAIL 4v: the hold let the table constraint answer instead of naming the limit';
  end;
  if position('three days' in v_message) = 0 or position('t_range' in v_message) > 0 then
    raise exception 'FAIL 4w: the ceiling refusal reads: %', v_message;
  end if;

  -- ... and the last legal second is accepted, reusing the frame that is already there.
  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b07',
           '0b000000-0000-4000-8000-0000000f0702',
           100,
           array['0b000000-0000-4000-8000-00000000a002']::uuid[]) r;
  if v_row.held_t_s <> 259200 then
    raise exception 'FAIL 4x: the hold landed at %, expected 259200', v_row.held_t_s;
  end if;
  if v_row.held_frame_id <> '0b000000-0000-4000-8000-0000000f0701' then
    raise exception 'FAIL 4y: the last legal second did not reuse the frame standing there';
  end if;
  if v_row.positions_written <> 1 then
    raise exception 'FAIL 4z: the boundary hold wrote % positions, expected one', v_row.positions_written;
  end if;
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0701';
  if v_rev <> 2 then
    raise exception 'FAIL 4aa: the reused ceiling frame is on revision %', v_rev;
  end if;
end $$;

-- ---------- 5. no group list holds everyone standing there, and nobody else ----------
do $$
declare
  v_row record;
  v_n integer;
  v_groups uuid[];
  v_lat0 float8;
  v_lng0 float8;
  v_lat float8;
  v_lng float8;
  v_group uuid;
  v_before jsonb;
  v_after jsonb;
begin
  select jsonb_agg(jsonb_build_object('group', c.group_id, 'metres', c.metres) order by c.group_id)
    into v_before
    from public.plan_check('0b000000-0000-4000-8000-000000000b04') c;

  select r.* into v_row
    from public.frame_hold(
           '0b000000-0000-4000-8000-000000000b04',
           '0b000000-0000-4000-8000-0000000f0301',
           60,
           null) r;

  if v_row.frames_added <> 1 or v_row.held_t_s <> 60 then
    raise exception 'FAIL 5a: the default hold added % frames and landed at %', v_row.frames_added, v_row.held_t_s;
  end if;
  if v_row.groups_held <> 2 or v_row.positions_written <> 2 then
    raise exception 'FAIL 5b: the default hold held % groups and wrote % positions, expected the 2 standing there',
      v_row.groups_held, v_row.positions_written;
  end if;

  select array_agg(p.group_id order by p.group_id) into v_groups
    from public.plan_positions p where p.frame_id = v_row.held_frame_id;
  if v_groups is distinct from array['0b000000-0000-4000-8000-00000000a001',
                                     '0b000000-0000-4000-8000-00000000a002']::uuid[] then
    raise exception 'FAIL 5c: the new frame states %, expected Gate Crew and Sound only', v_groups;
  end if;

  -- Each of them stands exactly where it stood at +0:00.
  foreach v_group in array v_groups loop
    select p.lat, p.lng into v_lat0, v_lng0
      from public.plan_positions p
     where p.frame_id = '0b000000-0000-4000-8000-0000000f0301' and p.group_id = v_group;
    select p.lat, p.lng into v_lat, v_lng
      from public.plan_positions p
     where p.frame_id = v_row.held_frame_id and p.group_id = v_group;
    if v_lat is distinct from v_lat0 or v_lng is distinct from v_lng0 then
      raise exception 'FAIL 5d: % was held to (%, %), not to where it stood (%, %)', v_group, v_lat, v_lng, v_lat0, v_lng0;
    end if;
  end loop;

  -- The two 200 m breaks are still there, at the same distance: the hold split each hop into a zero-metre one and
  -- the same 200 m one.
  select jsonb_agg(jsonb_build_object('group', c.group_id, 'metres', c.metres) order by c.group_id)
    into v_after
    from public.plan_check('0b000000-0000-4000-8000-000000000b04') c;
  if v_after is distinct from v_before then
    raise exception 'FAIL 5e: the hold changed the breaks. Before %, after %', v_before, v_after;
  end if;
end $$;

-- ---------- 6. the doors ----------
do $$
begin
  if to_regprocedure('public.frame_hold(uuid, uuid, integer, uuid[])') is null then
    raise exception 'FAIL 6a: frame_hold does not exist with the signature the client calls';
  end if;
  if has_function_privilege('anon', 'public.frame_hold(uuid, uuid, integer, uuid[])', 'EXECUTE') then
    raise exception 'FAIL 6b: anon can execute frame_hold';
  end if;
  if not has_function_privilege('authenticated', 'public.frame_hold(uuid, uuid, integer, uuid[])', 'EXECUTE') then
    raise exception 'FAIL 6c: authenticated cannot execute frame_hold';
  end if;
  -- The default privileges on this schema grant anon directly, so "revoked from PUBLIC" is not the question.
  if exists (
    select 1
      from pg_proc p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where p.proname = 'frame_hold' and p.pronargs = 4
       and a.grantee in (0, (select oid from pg_roles where rolname = 'anon'))
       and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'FAIL 6d: frame_hold still carries an EXECUTE grant for PUBLIC or anon';
  end if;
end $$;

-- ---------- 7. a participant cannot hold, even a group they administer ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.frame_hold(
      '0b000000-0000-4000-8000-000000000b03',
      '0b000000-0000-4000-8000-0000000f0201',
      60,
      array['0b000000-0000-4000-8000-00000000a002']::uuid[]);
    raise exception 'FAIL 7a: a participant (a group admin) held a group';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

rollback;

select 'step 7: a hold states the group again where it stands at a later moment -- one call, one partial write, no other group touched -- and refuses to overwrite a decision, to contradict a move, or to pass the ceiling' as result;
