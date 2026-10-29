-- Step 8, checked at the database: one save moves several groups by the same distance, and the one-write-per-group
-- version it replaces loses two of the three.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step8-drag-together.sql
--
-- The gesture is drag one badge with three groups ticked. The board computes every moved position and sends ONE
-- frame_save whose `positions` is the frame's own statements plus the three groups -- because frame_save replaces a
-- frame's positions wholesale. Section 1 is that write and what it must leave behind: three rows moved by the same
-- delta, revision bumped once, the other frame byte-identical, and the 25 m rule saying exactly the one thing the
-- move implies (Gate Crew's hop to +1:00 grows from 11 m to 41 m).
--
-- Section 2 is the bug this step exists to avoid, played out: the same three moves issued as three separate saves.
-- The first bumps the revision; the second and third are refused as stale (PT409) -- and the reload that follows
-- keeps only the first. Three badges dragged, one move stored. Then the one-call version with the current revision
-- does what the gesture meant.
--
-- Section 3 proves why the payload has to carry the whole map and not only the groups that moved: a partial map
-- deletes every other position on that frame. Section 4 is a participant refused, and section 5 the doors.
--
-- Everything runs in one transaction and is rolled back, so the bench is left as the fixture wrote it.
begin;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the bench must still hold the strip this step is about ----------
do $$
declare
  v_times integer[];
  v_n integer;
  v_note text;
begin
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_times is distinct from array[0, 60] then
    raise exception 'FAIL 0a: "Copy bench" holds %, expected 0/60. Run supabase/fixtures/plan_bench.sql first.', v_times;
  end if;
  select count(*) into v_n from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';
  if v_n <> 3 then
    raise exception 'FAIL 0b: the frame at +0:00 states % groups, expected 3 (the fixture''s three)', v_n;
  end if;
  select count(*) into v_n from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202';
  if v_n <> 1 then
    raise exception 'FAIL 0c: the frame at +1:00 states % groups, expected only Gate Crew', v_n;
  end if;
  select f.note into v_note from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0202';
  if v_note is distinct from 'one here' then
    raise exception 'FAIL 0d: the frame at +1:00 reads note %, expected "one here"', v_note;
  end if;
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b03');
  if v_n <> 0 then
    raise exception 'FAIL 0e: "Copy bench" already breaks the 25 m rule (% breaks), so the drag could not be told apart from it', v_n;
  end if;
end $$;

-- ---------- 1. the gesture: one save, three groups, the same delta ----------
do $$
declare
  v_before_elsewhere jsonb;
  v_after_elsewhere jsonb;
  v_before_gate jsonb;
  v_after_gate jsonb;
  v_row public.plan_frames;
  v_n integer;
  v_rev integer;
  v_note text;
  v_t integer;
  v_group uuid;
  v_groups uuid[] := array['0b000000-0000-4000-8000-00000000a001',
                           '0b000000-0000-4000-8000-00000000a002',
                           '0b000000-0000-4000-8000-00000000a003']::uuid[];
  v_lat float8;
  v_lng float8;
  v_lat0 float8;
  v_lng0 float8;
  v_lat_gate float8;
  v_lng_gate float8;
  v_breaks jsonb;
  v_moved integer := 0;
begin
  -- Everything the drag must not touch: the other frame, every revision, every note, and the plan's own row.
  select jsonb_agg(jsonb_build_object('frame', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note,
                                      'group', p.group_id, 'lat', p.lat, 'lng', p.lng)
                   order by f.t_s, p.group_id)
    into v_before_elsewhere
    from public.plan_frames f
    join public.plan_positions p on p.frame_id = f.id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b03'
     and f.id <> '0b000000-0000-4000-8000-0000000f0201';

  select jsonb_build_object('lat', p.lat, 'lng', p.lng) into v_before_gate
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';

  -- Three badges dragged 30 m west, at +0:00. One call, with the frame's whole map: its own three statements moved,
  -- and nothing else in the plan anywhere in the payload.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0201',
      't_s', 0,
      'rev', 1,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77473),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3310000, 'lng', 103.77523),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3312000, 'lng', 103.77473)
      )
    )
  );

  if v_row.id <> '0b000000-0000-4000-8000-0000000f0201' then
    raise exception 'FAIL 1a: the save wrote frame %, expected the open one', v_row.id;
  end if;
  if v_row.rev <> 2 then
    raise exception 'FAIL 1b: the frame is on revision % after one save, expected 2 (one call, one bump)', v_row.rev;
  end if;
  if v_row.t_s <> 0 then
    raise exception 'FAIL 1c: the drag moved the frame in time as well, to %', v_row.t_s;
  end if;

  select count(*) into v_n from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_n <> 2 then
    raise exception 'FAIL 1d: the plan now holds % frames, expected 2 (a position writes no frame)', v_n;
  end if;

  select f.rev, f.note, f.t_s into v_rev, v_note, v_t
    from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0201';
  if v_rev <> 2 or v_note is not null or v_t <> 0 then
    raise exception 'FAIL 1e: the frame reads revision % / note % / t %, expected 2 / null / 0', v_rev, v_note, v_t;
  end if;

  -- Nobody was deleted: a payload carrying everyone is what keeps this from wiping the groups that stayed.
  select count(*) into v_n from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';
  if v_n <> 3 then
    raise exception 'FAIL 1f: the frame states % groups after the drag, expected the 3 that were there', v_n;
  end if;

  -- The same delta, group by group: every ticked group moved by exactly what the leader moved.
  foreach v_group in array v_groups loop
    select p.lat, p.lng into v_lat, v_lng
      from public.plan_positions p
     where p.frame_id = '0b000000-0000-4000-8000-0000000f0201' and p.group_id = v_group;
    if v_lat is null or v_lng is null then
      raise exception 'FAIL 1g: group % has no position on the frame after the drag', v_group;
    end if;
    if abs((v_lng - case v_group
                        when '0b000000-0000-4000-8000-00000000a001' then 103.77500
                        when '0b000000-0000-4000-8000-00000000a002' then 103.77550
                        else 103.77500
                      end) + 0.00027) > 1e-9 then
      raise exception 'FAIL 1h: group % did not move 30 m west (lng is %)', v_group, v_lng;
    end if;
    v_moved := v_moved + 1;
  end loop;
  if v_moved <> 3 then
    raise exception 'FAIL 1i: only % groups were moved, expected 3', v_moved;
  end if;

  -- ... and each kept the latitude it had: the drag was east/west, and a shared delta is a translation, not a
  -- redraw of every group to the pointer.
  select p.lat, p.lng into v_lat_gate, v_lng_gate
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
     and p.group_id = '0b000000-0000-4000-8000-00000000a003';
  if abs(v_lat_gate - 1.3312000) > 1e-9 then
    raise exception 'FAIL 1j: Backstage moved in latitude too (%), so the three did not travel by one delta', v_lat_gate;
  end if;

  -- The other group's other moment: byte-identical, note and revision included.
  select p.lat, p.lng into v_lat0, v_lng0
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  select jsonb_build_object('lat', p.lat, 'lng', p.lng) into v_after_gate
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0202'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_after_gate is distinct from v_before_gate then
    raise exception 'FAIL 1k: the frame at +1:00 moved too (before %, after %)', v_before_gate, v_after_gate;
  end if;

  select jsonb_agg(jsonb_build_object('frame', f.id, 't', f.t_s, 'rev', f.rev, 'note', f.note,
                                      'group', p.group_id, 'lat', p.lat, 'lng', p.lng)
                   order by f.t_s, p.group_id)
    into v_after_elsewhere
    from public.plan_frames f
    join public.plan_positions p on p.frame_id = f.id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b03'
     and f.id <> '0b000000-0000-4000-8000-0000000f0201';
  if v_after_elsewhere is distinct from v_before_elsewhere then
    raise exception 'FAIL 1l: the drag changed a row outside the open frame. Before %, after %',
      v_before_elsewhere, v_after_elsewhere;
  end if;

  -- The 25 m rule now has exactly one thing to say, and it is the thing the move implies: Gate Crew's +0:00 is
  -- 30 m further from its +1:00 than it was, so the 11 m hop is 41 m.
  select jsonb_agg(jsonb_build_object('group', c.group_id, 'from', c.from_s, 'to', c.to_s, 'metres', c.metres)
                   order by c.group_id, c.from_s)
    into v_breaks
    from public.plan_check('0b000000-0000-4000-8000-000000000b03') c;
  if jsonb_array_length(v_breaks) <> 1 then
    raise exception 'FAIL 1m: the 25 m rule reports % breaks after the drag, expected exactly one: %',
      jsonb_array_length(v_breaks), v_breaks;
  end if;
  if (v_breaks -> 0 ->> 'group') <> '0b000000-0000-4000-8000-00000000a001'
     or (v_breaks -> 0 ->> 'from')::int <> 0
     or (v_breaks -> 0 ->> 'to')::int <> 60 then
    raise exception 'FAIL 1n: the break is not Gate Crew''s hop from +0:00 to +1:00: %', v_breaks;
  end if;
  if (v_breaks -> 0 ->> 'metres')::int <> 41 then
    raise exception 'FAIL 1o: the hop reads % m, expected 41 (11 m plus a 30 m drag)', v_breaks -> 0 ->> 'metres';
  end if;
end $$;

-- ---------- 2. the same three moves, one save each: two of them are refused ----------
do $$
declare
  v_row public.plan_frames;
  v_message text;
  v_n integer;
  v_rev integer;
  v_lng float8;
  v_lng_a float8;
  v_groups uuid[] := array['0b000000-0000-4000-8000-00000000a001',
                           '0b000000-0000-4000-8000-00000000a002',
                           '0b000000-0000-4000-8000-00000000a003']::uuid[];
  v_group uuid;
  v_map jsonb;
begin
  -- The frame as a client had it: revision 2, the three groups on the row they were dragged to.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0201';
  if v_rev <> 2 then
    raise exception 'FAIL 2a: this section expects a fresh revision 2, the frame reads %', v_rev;
  end if;

  select jsonb_object_agg(p.group_id::text, jsonb_build_object('lat', p.lat, 'lng', p.lng)) into v_map
    from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';

  -- The naive path: move Gate Crew again, on its own, on the revision every badge was read at.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', 2,
      'positions', v_map || jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
                                               jsonb_build_object('lat', 1.3310000, 'lng', 103.77446))
    )
  );
  if v_row.rev <> 3 then
    raise exception 'FAIL 2b: the first single-group save left the frame on revision %, expected 3', v_row.rev;
  end if;

  -- The second badge, still holding the revision it read: the write is stale and the database says so.
  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b03',
      jsonb_build_object(
        'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', 2,
        'positions', v_map || jsonb_build_object('0b000000-0000-4000-8000-00000000a002',
                                                 jsonb_build_object('lat', 1.3310000, 'lng', 103.77496))
      )
    );
    raise exception 'FAIL 2c: the second single-group save was accepted on a stale revision';
  exception
    when sqlstate 'PT409' then v_message := sqlerrm;
  end;
  if position('changed this frame first' in v_message) = 0 then
    raise exception 'FAIL 2d: the stale refusal reads: %', v_message;
  end if;

  -- The third badge, same stale revision, same answer.
  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b03',
      jsonb_build_object(
        'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', 2,
        'positions', v_map || jsonb_build_object('0b000000-0000-4000-8000-00000000a003',
                                                 jsonb_build_object('lat', 1.3312000, 'lng', 103.77446))
      )
    );
    raise exception 'FAIL 2e: the third single-group save was accepted on a stale revision';
  exception
    when sqlstate 'PT409' then v_message := sqlerrm;
  end;

  -- What the planner is left with: Gate Crew moved twice, the other two not at all. Two of the three badges were
  -- dragged and their moves are gone -- the failure this step's one save exists to prevent.
  select p.lng into v_lng_a from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if abs(v_lng_a - 103.77446) > 1e-9 then
    raise exception 'FAIL 2f: Gate Crew is at %, the one save that survived moved it to 103.77446', v_lng_a;
  end if;
  foreach v_group in array array['0b000000-0000-4000-8000-00000000a002',
                                 '0b000000-0000-4000-8000-00000000a003']::uuid[] loop
    select p.lng into v_lng from public.plan_positions p
     where p.frame_id = '0b000000-0000-4000-8000-0000000f0201' and p.group_id = v_group;
    if abs(v_lng - (v_map -> (v_group::text) ->> 'lng')::float8) > 1e-9 then
      raise exception 'FAIL 2g: group % moved even though its save was refused (%)', v_group, v_lng;
    end if;
  end loop;

  -- ... and one call carrying all three, on the revision that is current, does what the gesture meant.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0201';
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', v_rev,
      'positions', v_map || jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77446),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3310000, 'lng', 103.77496),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3312000, 'lng', 103.77446)
      )
    )
  );
  if v_row.rev <> v_rev + 1 then
    raise exception 'FAIL 2h: the one-call save left the frame on revision %, expected %', v_row.rev, v_rev + 1;
  end if;
  foreach v_group in array v_groups loop
    select p.lng into v_lng from public.plan_positions p
     where p.frame_id = '0b000000-0000-4000-8000-0000000f0201' and p.group_id = v_group;
    if abs(v_lng - (case v_group
                      when '0b000000-0000-4000-8000-00000000a001' then 103.77446
                      when '0b000000-0000-4000-8000-00000000a002' then 103.77496
                      else 103.77446
                    end)) > 1e-9 then
      raise exception 'FAIL 2i: group % sits at % after the one-call save, expected %',
        v_group, v_lng, (case v_group when '0b000000-0000-4000-8000-00000000a001' then 103.77446
                                      when '0b000000-0000-4000-8000-00000000a002' then 103.77496
                                      else 103.77446 end);
    end if;
  end loop;
end $$;

-- ---------- 3. a partial map deletes the rest, so the payload carries everyone ----------
do $$
declare
  v_row public.plan_frames;
  v_n integer;
  v_lat float8;
begin
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', 4,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77420)
      )
    )
  );
  if v_row.rev <> 5 then
    raise exception 'FAIL 3a: the partial save left the frame on revision %, expected 5', v_row.rev;
  end if;
  select count(*) into v_n from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';
  if v_n <> 1 then
    raise exception 'FAIL 3b: a map naming one group left % positions, expected 1 (the others are deleted)', v_n;
  end if;
  select p.lat into v_lat from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_lat is null then
    raise exception 'FAIL 3c: the partial save lost the group it did name';
  end if;
end $$;

-- ---------- 4. a participant cannot drag a plan ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b03',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', 5,
                         'positions', jsonb_build_object(
                           '0b000000-0000-4000-8000-00000000a001',
                           jsonb_build_object('lat', 1.3310000, 'lng', 103.77400)))
    );
    raise exception 'FAIL 4a: a participant (a group admin) dragged the plan';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 5. the doors ----------
do $$
begin
  if to_regprocedure('public.frame_save(uuid, jsonb)') is null then
    raise exception 'FAIL 5a: frame_save does not exist with the signature the client calls';
  end if;
  if has_function_privilege('anon', 'public.frame_save(uuid, jsonb)', 'EXECUTE') then
    raise exception 'FAIL 5b: anon can execute frame_save';
  end if;
  if not has_function_privilege('authenticated', 'public.frame_save(uuid, jsonb)', 'EXECUTE') then
    raise exception 'FAIL 5c: authenticated cannot execute frame_save';
  end if;
end $$;

rollback;

select 'step 8: one save moves every ticked group by the same delta -- three separate saves lose two of the three to a stale revision, and a partial map would delete the groups that stayed' as result;
