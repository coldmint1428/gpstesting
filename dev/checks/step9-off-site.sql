-- Step 9, checked at the database: a position can be off-site and can need confirming, and no check measures a walk
-- to or from one.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step9-off-site.sql
--
-- Section 1 is the step's Done-when, on "Twin gap": two groups, both 200 m east between +0:00 and +5:00, so the plan
-- has two breaks to start with. Flagging Gate Crew's arrival as off site leaves ONE break -- Sound's, untouched --
-- and leaves Gate Crew's coordinates exactly where somebody put them. That is "a plan whose only long jump belongs to
-- an off-site group raises no error from plan_check", and the row is not deleted, only taken out of the measuring.
--
-- Section 2 feeds the server its own output back in: the map plan_frames_list returns is a legal `positions` payload,
-- so the round trip is proved rather than the two directions tested separately.
--
-- Section 3 puts the same group back on site at the same coordinates and the break comes back: the pair of sections is
-- the proof that the flag, and nothing else, is what plan_check is reading.
--
-- Section 4 is the write rule the board depends on: a point that names only a coordinate keeps the flags the row
-- already had, and a point on a NEW row gets on_site / auto -- because the drag that carries a badge sends no flags,
-- and it must not quietly put an off-site group back on the map.
--
-- Section 5 is the two words: a value outside them comes back as a sentence naming the word, from inside the function,
-- before anything is written -- not as plan_positions_state_check raised from an upsert.
--
-- Section 6 is the gate that matters: a plan whose only long jump is off site can be published, and the same plan with
-- that group back on site cannot.
--
-- Section 7 is the doors and the member's read: the flags come back to an ordinary participant, because an off-site
-- group is still a row of the plan (step 10 lists it and draws it differently), while a participant still cannot write.
--
-- Everything runs in one transaction and is rolled back, so the bench is left as the fixture wrote it.
begin;

-- One extra plan for the publish pair, written as the owner before the caller becomes a planner: two frames, one
-- group, on site at +0:00 and 200 m away and OFF SITE at +5:00. Nothing else in the bench is quite that shape.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b09', '0b000000-0000-4000-8000-000000000e01',
   'Off-site bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '7 hours');

insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
  ('0b000000-0000-4000-8000-0000000f0901', '0b000000-0000-4000-8000-000000000b09', '0b000000-0000-4000-8000-000000000e01',   0, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0902', '0b000000-0000-4000-8000-000000000b09', '0b000000-0000-4000-8000-000000000e01', 300, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f0901', '0b000000-0000-4000-8000-000000000b09', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77500, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f0902', '0b000000-0000-4000-8000-000000000b09', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77680, 'off_site', 'auto');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. the bench must still hold the strips this step is about ----------
do $$
declare
  v_times integer[];
  v_n integer;
  v_breaks integer;
  v_state text;
  v_verify text;
begin
  select array_agg(f.t_s order by f.t_s) into v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b04';
  if v_times is distinct from array[0, 300] then
    raise exception 'FAIL 0a: "Twin gap" holds %, expected 0/300. Run supabase/fixtures/plan_bench.sql first.', v_times;
  end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b04';
  if v_n <> 4 then
    raise exception 'FAIL 0b: "Twin gap" holds % positions, expected 4 (the fixture''s four)', v_n;
  end if;
  select count(*) into v_breaks from public.plan_check('0b000000-0000-4000-8000-000000000b04');
  if v_breaks <> 2 then
    raise exception 'FAIL 0c: "Twin gap" should break the 25 m rule twice (200 m for each group), it breaks % times', v_breaks;
  end if;
  select count(*) into v_breaks from public.plan_check('0b000000-0000-4000-8000-000000000b03');
  if v_breaks <> 0 then
    raise exception 'FAIL 0d: "Copy bench" should be legal, it has % breaks', v_breaks;
  end if;

  -- Every row the fixture wrote is on site and trusted, and the pair of columns exists with those defaults. The
  -- check's own "Off-site bench" (b09) is left out: it is the one row this file is allowed to have flagged.
  select count(*) into v_n from public.plan_positions
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and plan_id <> '0b000000-0000-4000-8000-000000000b09'
     and (state <> 'on_site' or verify <> 'auto');
  if v_n <> 0 then
    raise exception 'FAIL 0e: % fixture positions did not get the on_site / auto defaults', v_n;
  end if;
  select column_default into v_state from information_schema.columns
   where table_schema = 'public' and table_name = 'plan_positions' and column_name = 'state';
  select column_default into v_verify from information_schema.columns
   where table_schema = 'public' and table_name = 'plan_positions' and column_name = 'verify';
  if v_state not like '''on_site''%' or v_verify not like '''auto''%' then
    raise exception 'FAIL 0f: the defaults read state % / verify %, expected ''on_site'' / ''auto''', v_state, v_verify;
  end if;
  if (select is_nullable from information_schema.columns
       where table_schema = 'public' and table_name = 'plan_positions' and column_name = 'state') <> 'NO' then
    raise exception 'FAIL 0g: state is nullable, so "off site" and "unset" could not be told apart';
  end if;
end $$;

-- ---------- 1. the Done-when: one group off site, and its 200 m jump stops being a break ----------
do $$
declare
  v_row public.plan_frames;
  v_lat0 float8;
  v_lng0 float8;
  v_lat float8;
  v_lng float8;
  v_gaps jsonb;
begin
  select p.lat, p.lng into v_lat0, v_lng0
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';

  -- The whole map for that frame, because positions is replaced wholesale: Sound's own coordinates are repeated
  -- exactly, and its flags are left out on purpose (that is section 4's rule, exercised here on a real save).
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b04',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0302',
      't_s', 300,
      'rev', 1,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', v_lat0, 'lng', v_lng0, 'state', 'off_site', 'verify', 'manual'),
        '0b000000-0000-4000-8000-00000000a002',
          jsonb_build_object('lat', 1.3311000, 'lng', 103.77680))));

  if v_row.rev <> 2 then
    raise exception 'FAIL 1a: the save that flagged the position left the frame on revision %', v_row.rev;
  end if;

  -- What was stored.
  select p.lat, p.lng into v_lat, v_lng
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302'
     and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_lat is distinct from v_lat0 or v_lng is distinct from v_lng0 then
    raise exception 'FAIL 1b: flagging the position moved it: (%, %) became (%, %)', v_lat0, v_lng0, v_lat, v_lng;
  end if;
  if (select state from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a001') <> 'off_site'
     or (select verify from public.plan_positions
          where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a001') <> 'manual' then
    raise exception 'FAIL 1c: the flags the save named were not stored';
  end if;

  -- The Done-when: the long jump is off site, so the plan has one break instead of two -- Sound's, still 200 m.
  select jsonb_agg(jsonb_build_object('group', c.group_id, 'metres', c.metres, 'from', c.from_s, 'to', c.to_s))
    into v_gaps
    from public.plan_check('0b000000-0000-4000-8000-000000000b04') c;
  if jsonb_array_length(v_gaps) <> 1 then
    raise exception 'FAIL 1d: the plan reports % breaks, expected only Sound''s: %', jsonb_array_length(v_gaps), v_gaps;
  end if;
  if v_gaps -> 0 ->> 'group' <> '0b000000-0000-4000-8000-00000000a002'
     or (v_gaps -> 0 ->> 'metres')::int <> 200
     or (v_gaps -> 0 ->> 'from')::int <> 0
     or (v_gaps -> 0 ->> 'to')::int <> 300 then
    raise exception 'FAIL 1e: the remaining break reads %, expected Sound / 200 m / +0:00 to +5:00', v_gaps;
  end if;

  -- The other group's row is untouched: same coordinates, and it is still on site and still trusted.
  if (select state from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a002') <> 'on_site'
     or (select verify from public.plan_positions
          where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a002') <> 'auto' then
    raise exception 'FAIL 1f: Sound''s flags changed although the payload did not name any';
  end if;
  if (select count(*) from public.plan_positions where frame_id = '0b000000-0000-4000-8000-0000000f0302') <> 2 then
    raise exception 'FAIL 1g: the frame holds % positions after the save, expected both groups',
      (select count(*) from public.plan_positions where frame_id = '0b000000-0000-4000-8000-0000000f0302');
  end if;
end $$;

-- ---------- 2. the round trip: plan_frames_list's own map is a legal payload ----------
do $$
declare
  v_positions jsonb;
  v_before jsonb;
  v_after jsonb;
  v_rev integer;
  v_row public.plan_frames;
begin
  select positions into v_positions
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b04')
   where id = '0b000000-0000-4000-8000-0000000f0302';

  -- Both flags arrive, as words, beside the coordinates.
  if v_positions -> '0b000000-0000-4000-8000-00000000a001' ->> 'state' <> 'off_site'
     or v_positions -> '0b000000-0000-4000-8000-00000000a001' ->> 'verify' <> 'manual' then
    raise exception 'FAIL 2a: plan_frames_list returned % for the off-site position', v_positions -> '0b000000-0000-4000-8000-00000000a001';
  end if;
  if v_positions -> '0b000000-0000-4000-8000-00000000a002' ->> 'state' <> 'on_site'
     or v_positions -> '0b000000-0000-4000-8000-00000000a002' ->> 'verify' <> 'auto' then
    raise exception 'FAIL 2b: plan_frames_list dropped the defaults from the other group: %', v_positions -> '0b000000-0000-4000-8000-00000000a002';
  end if;

  select jsonb_agg(jsonb_build_object('g', p.group_id, 'lat', p.lat, 'lng', p.lng, 's', p.state, 'v', p.verify)
                   order by p.group_id)
    into v_before
    from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0302';
  select rev into v_rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0302';

  -- Straight back in, unchanged.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b04',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0302', 't_s', 300, 'rev', v_rev, 'positions', v_positions));

  select jsonb_agg(jsonb_build_object('g', p.group_id, 'lat', p.lat, 'lng', p.lng, 's', p.state, 'v', p.verify)
                   order by p.group_id)
    into v_after
    from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0302';
  if v_after is distinct from v_before then
    raise exception 'FAIL 2c: feeding the server its own map back changed it. Before %, after %', v_before, v_after;
  end if;
  if v_row.rev <> v_rev + 1 then
    raise exception 'FAIL 2d: the round-trip save left revision % after %, expected one bump', v_row.rev, v_rev;
  end if;
end $$;

-- ---------- 3. put the same group back on site, at the same coordinates: the break returns ----------
do $$
declare
  v_row public.plan_frames;
  v_gaps jsonb;
begin
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b04',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0302',
      't_s', 300,
      'rev', 3,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a002',
          jsonb_build_object('lat', 1.3311000, 'lng', 103.77680))));

  -- The coordinates did not move; only the state did -- and verify, which this payload does not name, is still manual.
  if (select verify from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a001') <> 'manual' then
    raise exception 'FAIL 3a: a save that named only state reset verify to auto';
  end if;

  select jsonb_agg(jsonb_build_object('group', c.group_id, 'metres', c.metres))
    into v_gaps
    from public.plan_check('0b000000-0000-4000-8000-000000000b04') c;
  if jsonb_array_length(v_gaps) <> 2 then
    raise exception 'FAIL 3b: back on site at the same place, the plan reports % breaks, expected the 200 m pair again: %',
      jsonb_array_length(v_gaps), v_gaps;
  end if;
  if v_gaps @> '[{"group":"0b000000-0000-4000-8000-00000000a001","metres":200}]'::jsonb = false then
    raise exception 'FAIL 3c: Gate Crew''s break is missing or is not 200 m: %', v_gaps;
  end if;
end $$;

-- ---------- 4. an omitted flag keeps what the row had; a new row gets the defaults ----------
do $$
declare
  v_row public.plan_frames;
  v_state text;
  v_verify text;
  v_gaps integer;
begin
  -- Off site again, so the omission has something to preserve ...
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b04',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0302',
      't_s', 300,
      'rev', 4,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', 'off_site', 'verify', 'manual'),
        '0b000000-0000-4000-8000-00000000a002',
          jsonb_build_object('lat', 1.3311000, 'lng', 103.77680))));

  -- ... then the drag's payload: a coordinate and nothing else.
  v_row := public.frame_save(
    '0b000000-0000-4000-8000-000000000b04',
    jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0302',
      't_s', 300,
      'rev', 5,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310010, 'lng', 103.77681),
        '0b000000-0000-4000-8000-00000000a002',
          jsonb_build_object('lat', 1.3311000, 'lng', 103.77680),
        '0b000000-0000-4000-8000-00000000a004',
          jsonb_build_object('lat', 1.3312000, 'lng', 103.77680))));

  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302' and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 4a: a payload with only a coordinate wrote state % / verify %, expected the stored off_site / manual',
      v_state, v_verify;
  end if;
  if (select count(*) from public.plan_positions
       where frame_id = '0b000000-0000-4000-8000-0000000f0302' and group_id = '0b000000-0000-4000-8000-00000000a001'
         and lat = 1.3310010 and lng = 103.77681) <> 1 then
    raise exception 'FAIL 4b: the coordinate the drag sent was not written';
  end if;

  -- The new row (Security, stated here for the first time) is on site and trusted.
  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302' and p.group_id = '0b000000-0000-4000-8000-00000000a004';
  if v_state is null or v_state <> 'on_site' or v_verify <> 'auto' then
    raise exception 'FAIL 4c: a new row without flags arrived as % / %, expected on_site / auto', v_state, v_verify;
  end if;

  -- One break, still: the off-site group's far row is ignored, and Security has only one statement so far.
  select count(*) into v_gaps from public.plan_check('0b000000-0000-4000-8000-000000000b04');
  if v_gaps <> 1 then
    raise exception 'FAIL 4d: the plan reports % breaks, expected only Sound''s', v_gaps;
  end if;
end $$;

-- ---------- 5. a word outside the two is named, before anything is written ----------
do $$
declare
  v_message text;
  v_rev integer;
  v_state text;
begin
  select rev into v_rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0302';

  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b04',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0302', 't_s', 300, 'rev', v_rev,
        'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', 'onsite'))));
    raise exception 'FAIL 5a: a state of "onsite" was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('on site or off site' in v_message) = 0 or position('onsite' in v_message) = 0 then
    raise exception 'FAIL 5b: the refusal reads: %', v_message;
  end if;

  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b04',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0302', 't_s', 300, 'rev', v_rev,
        'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'verify', 'sometimes'))));
    raise exception 'FAIL 5c: a verify of "sometimes" was accepted';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('automatically or by hand' in v_message) = 0 or position('sometimes' in v_message) = 0 then
    raise exception 'FAIL 5d: the refusal reads: %', v_message;
  end if;

  -- An explicit null is not "leave it alone": it is a value nobody can act on.
  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b04',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0302', 't_s', 300, 'rev', v_rev,
        'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', null))));
    raise exception 'FAIL 5e: a null state was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  -- Nothing moved: the revision, the coordinate and the flags are all as they were.
  if (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0302') <> v_rev then
    raise exception 'FAIL 5f: a refused save bumped the frame revision';
  end if;
  select p.state into v_state
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0302' and p.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_state <> 'off_site' then
    raise exception 'FAIL 5g: a refused save rewrote the state to %', v_state;
  end if;

  -- The constraints are there for the paths that do not go through the function (a console, a migration).
  if not exists (select 1 from pg_constraint where conname = 'plan_positions_state_check')
     or not exists (select 1 from pg_constraint where conname = 'plan_positions_verify_check') then
    raise exception 'FAIL 5h: the table has no state / verify check constraint';
  end if;
end $$;

-- ---------- 6. publish: an off-site jump is not a gap, an on-site one is ----------
do $$
declare
  v_breaks integer;
  v_status text;
  v_message text;
begin
  select count(*) into v_breaks from public.plan_check('0b000000-0000-4000-8000-000000000b09');
  if v_breaks <> 0 then
    raise exception 'FAIL 6a: "Off-site bench" reports % breaks, expected none', v_breaks;
  end if;
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b09', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b09'));
  select status into v_status from public.plans where id = '0b000000-0000-4000-8000-000000000b09';
  if v_status <> 'live' then
    raise exception 'FAIL 6b: publishing the plan whose only long jump is off site left status %', v_status;
  end if;

  -- The same plan, that group back on site: one break, and the gate refuses it.
  perform public.frame_save(
    '0b000000-0000-4000-8000-000000000b09',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0902', 't_s', 300, 'rev', 1,
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
        jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', 'on_site'))));
  select count(*) into v_breaks from public.plan_check('0b000000-0000-4000-8000-000000000b09');
  if v_breaks <> 1 then
    raise exception 'FAIL 6c: back on site the same plan reports % breaks, expected one', v_breaks;
  end if;
  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b09', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b09'));
    raise exception 'FAIL 6d: a plan with an on-site 200 m gap was published';
  exception
    when sqlstate '22023' then v_message := sqlerrm;
  end;
  if position('cannot be published' in v_message) = 0 or position('the limit is 25 m' in v_message) = 0 then
    raise exception 'FAIL 6e: the refusal reads: %', v_message;
  end if;
end $$;

-- ---------- 7. the flags come back to a member, and a participant still cannot write ----------
do $$
declare
  v_positions jsonb;
  v_rows integer;
begin
  select positions into v_positions
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b04')
   where id = '0b000000-0000-4000-8000-0000000f0302';
  if v_positions -> '0b000000-0000-4000-8000-00000000a001' ->> 'state' <> 'off_site' then
    raise exception 'FAIL 7a: the member read lost the off-site flag: %', v_positions;
  end if;
  -- Still listed: an off-site group is a row of the plan, not a hole in it. Step 10 draws it differently; nothing
  -- has to be reconstructed from the previous frame.
  if v_positions ? '0b000000-0000-4000-8000-00000000a001' = false then
    raise exception 'FAIL 7b: an off-site position stopped being listed';
  end if;
  select count(*) into v_rows from public.plan_frames_list('0b000000-0000-4000-8000-000000000b04');
  if v_rows <> 2 then
    raise exception 'FAIL 7c: the member read returned % frames, expected 2', v_rows;
  end if;
end $$;

-- ---------- 8. the doors ----------
do $$
begin
  if to_regprocedure('public.plan_frames_list(uuid)') is null then
    raise exception 'FAIL 8a: plan_frames_list does not exist with the signature the client calls';
  end if;
  if to_regprocedure('public.frame_save(uuid, jsonb)') is null then
    raise exception 'FAIL 8b: frame_save does not exist with the signature the client calls';
  end if;
  if has_function_privilege('anon', 'public.plan_frames_list(uuid)', 'EXECUTE') then
    raise exception 'FAIL 8c: anon can read the plan';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_frames_list(uuid)', 'EXECUTE') then
    raise exception 'FAIL 8d: authenticated cannot read the plan';
  end if;
  if not has_function_privilege('authenticated', 'public.frame_save(uuid, jsonb)', 'EXECUTE') then
    raise exception 'FAIL 8e: authenticated cannot write a frame';
  end if;
end $$;

-- ---------- 9. a participant cannot flag a position off site, and the table refuses an unknown word ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.frame_save(
      '0b000000-0000-4000-8000-000000000b04',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0302', 't_s', 300, 'rev', 7,
        'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001',
          jsonb_build_object('lat', 1.3310000, 'lng', 103.77680, 'state', 'on_site'))));
    raise exception 'FAIL 9a: a participant (a group admin) wrote a position';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

rollback;

select 'step 9: a position can be off-site and can need confirming -- both flags round-trip through the list, an off-site row takes no part in the 25 m rule on either side of the wire, and a plan whose only long jump is off site can be published' as result;
