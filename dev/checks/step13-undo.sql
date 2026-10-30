-- Step 13, checked at the database: every write the undo stack makes, made in both directions.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step13-undo.sql
--
-- The stack itself is the client's (/src/composables/usePlanUndo.js), and the browser check is what proves the keys.
-- What has to be proved here is the half the client cannot: that each *inverse* is an exact inverse at the database,
-- because an undo that is nearly right is worse than none. Five things, one per section:
--
--   1. A shift named by its two times comes back by its two times. The range that holds the moved frames is the one
--      to ask for, and one call puts the strip back -- the ordinary case, and the one the client tries first.
--   2. And when that range cannot name the stretch, the client must not use it. 044 lets a chunk be pushed past a
--      frame that stays put; after such a push the *staying* frame can sit inside the range the chunk occupies, so
--      shifting that range back would drag a row that was never part of the edit. Section 2 pushes until the range
--      holds three frames having moved two, which is exactly the client's guard, and then puts the two back by id.
--   3. A frame's whole position map is its own inverse, flags included, and writing it does not silently un-say a
--      group the frame never mentioned (the trap `positions` being replaced wholesale sets).
--   4. A delete is undone by creating the frame again WITH ITS ID (041), note, positions and flags included -- and the
--      restore is refused, not fudged, when another frame has taken that moment in the meantime.
--   5. An inverse is a write like any other: the revision is the one the plan has when the undo runs, so a command
--      held across somebody else's edit is refused (PT409) rather than overwriting it.
--
-- Everything runs in one transaction and is rolled back, so the bench is left exactly as the fixture wrote it.
begin;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- the bench must be there ----------
do $$
declare
  v_times integer[];
begin
  select array_agg(t_s order by t_s) into v_times from public.plan_frames
   where plan_id = '0b000000-0000-4000-8000-000000000b05';
  if v_times is distinct from array[0, 60, 120, 180] then
    raise exception 'The push bench is at %, not 0/60/120/180. Run supabase/fixtures/plan_bench.sql first.', v_times;
  end if;
end $$;

-- ---------- 1. a shift, and the same shift the other way ----------
do $$
declare
  v_moved integer;
  v_in_range integer;
begin
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 60, -30, 120);
  if v_moved <> 2 then
    raise exception 'FAIL 1a: the shift moved % frames, expected 2', v_moved;
  end if;
  if (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05')
     is distinct from array[0, 30, 90, 180] then
    raise exception 'FAIL 1b: after the shift the strip is %, expected 0/30/90/180',
      (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05');
  end if;

  -- The range the moved frames now occupy, which is what an undo asks for.
  select count(*) into v_in_range from public.plan_frames
   where plan_id = '0b000000-0000-4000-8000-000000000b05' and t_s between 30 and 90;
  if v_in_range <> 2 then
    raise exception 'FAIL 1c: the moved range holds % frames, expected the 2 that were moved', v_in_range;
  end if;

  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 30, 30, 90);
  if v_moved <> 2 then
    raise exception 'FAIL 1d: the inverse moved % frames, expected 2', v_moved;
  end if;
  if (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05')
     is distinct from array[0, 60, 120, 180] then
    raise exception 'FAIL 1e: the inverse left the strip at %, expected the original 0/60/120/180',
      (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05');
  end if;
end $$;

-- ---------- 2. the push the range cannot undo ----------
-- 60..120 pushed +90 becomes 150..210, which contains the frame that stayed at 180. A range shift back over
-- 150..210 would move three frames having moved two -- so the client moves the two by id instead, and this is the
-- proof that doing so restores the strip exactly, interloper untouched.
do $$
declare
  v_in_range integer;
  v_moved integer;
begin
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b05', 60, 90, 120);
  if v_moved <> 2 then
    raise exception 'FAIL 2a: the push moved % frames, expected 2', v_moved;
  end if;
  if (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05')
     is distinct from array[0, 150, 180, 210] then
    raise exception 'FAIL 2b: after the push the strip is %, expected 0/150/180/210',
      (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05');
  end if;

  -- The guard, stated as the client states it: the range holds more frames than the edit moved.
  select count(*) into v_in_range from public.plan_frames
   where plan_id = '0b000000-0000-4000-8000-000000000b05' and t_s between 150 and 210;
  if v_in_range <> 3 then
    raise exception 'FAIL 2c: the pushed range holds % frames, expected 3 (two moved and one that stayed put)', v_in_range;
  end if;

  -- The fallback: home by id, oldest target first, which is the order the client uses.
  perform public.frame_move('0b000000-0000-4000-8000-0000000f0402', 60,
    (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0402'));
  perform public.frame_move('0b000000-0000-4000-8000-0000000f0403', 120,
    (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0403'));

  if (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05')
     is distinct from array[0, 60, 120, 180] then
    raise exception 'FAIL 2d: moving the two back by id left the strip at %, expected 0/60/120/180',
      (select array_agg(t_s order by t_s) from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b05');
  end if;
  if (select t_s from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0404') <> 180 then
    raise exception 'FAIL 2e: the frame that stayed put was dragged to %',
      (select t_s from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0404');
  end if;
end $$;

-- ---------- 3. a position map is its own inverse ----------
-- The frame in the copy bench states three groups. The edit moves one and takes another off site; the inverse writes
-- the map that was read before it. "Exactly as it was" means: same coordinates, same flags, same three rows -- a
-- payload naming one group would have deleted the other two (the trap step 10 names).
do $$
declare
  v_before jsonb;
  v_after jsonb;
  v_rev integer;
begin
  select jsonb_object_agg(p.group_id::text, jsonb_build_object(
           'lat', p.lat, 'lng', p.lng, 'state', p.state, 'verify', p.verify))
    into v_before
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';
  if (select count(*) from jsonb_object_keys(v_before)) <> 3 then
    raise exception 'FAIL 3a: the frame states % groups, expected 3', (select count(*) from jsonb_object_keys(v_before));
  end if;

  select rev into v_rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0201';
  v_after := jsonb_set(
    jsonb_set(v_before, '{0b000000-0000-4000-8000-00000000a001,lat}', '1.3311000'::jsonb),
    '{0b000000-0000-4000-8000-00000000a002,state}', '"off_site"'::jsonb);
  perform public.frame_save('0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0, 'rev', v_rev, 'positions', v_after));

  if (select p.lat from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
        and p.group_id = '0b000000-0000-4000-8000-00000000a001') <> 1.3311 then
    raise exception 'FAIL 3b: the edit did not land on the position it named';
  end if;
  if (select p.state from public.plan_positions p where p.frame_id = '0b000000-0000-4000-8000-0000000f0201'
        and p.group_id = '0b000000-0000-4000-8000-00000000a002') <> 'off_site' then
    raise exception 'FAIL 3c: the flag did not land';
  end if;

  -- The inverse: the map read before the edit, written back with the revision the frame has now.
  perform public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
    'id', '0b000000-0000-4000-8000-0000000f0201', 't_s', 0,
    'rev', (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0201'),
    'positions', v_before));

  select jsonb_object_agg(p.group_id::text, jsonb_build_object(
           'lat', p.lat, 'lng', p.lng, 'state', p.state, 'verify', p.verify))
    into v_after
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0201';
  if v_after is distinct from v_before then
    raise exception 'FAIL 3d: the inverse left the frame at % instead of %', v_after, v_before;
  end if;
end $$;

-- ---------- 4. a delete, undone with the same id ----------
do $$
declare
  v_map jsonb;
  v_row public.plan_frames;
  v_rows integer;
begin
  select jsonb_object_agg(p.group_id::text, jsonb_build_object(
           'lat', p.lat, 'lng', p.lng, 'state', p.state, 'verify', p.verify))
    into v_map
    from public.plan_positions p
   where p.frame_id = '0b000000-0000-4000-8000-0000000f0404';

  perform public.frame_delete('0b000000-0000-4000-8000-0000000f0404',
    (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0404'));
  if exists (select 1 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0404') then
    raise exception 'FAIL 4a: the frame is still there after delete';
  end if;

  -- Something else takes its moment while it is gone: the restore must refuse rather than move that frame.
  perform public.frame_move('0b000000-0000-4000-8000-0000000f0401', 180,
    (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0401'));
  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b05', jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0404', 't_s', 180, 'note', 'walk on', 'positions', v_map));
    raise exception 'FAIL 4b: the restore was accepted over a frame that had taken the moment';
  exception
    when sqlstate '22023' then null;
  end;

  -- With the moment free again, the same call restores the frame as itself.
  perform public.frame_move('0b000000-0000-4000-8000-0000000f0401', 0,
    (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0401'));
  v_row := public.frame_save('0b000000-0000-4000-8000-000000000b05', jsonb_build_object(
    'id', '0b000000-0000-4000-8000-0000000f0404', 't_s', 180, 'note', 'walk on', 'positions', v_map));
  if v_row.id <> '0b000000-0000-4000-8000-0000000f0404' then
    raise exception 'FAIL 4c: the restore came back as id %, not the one it was given', v_row.id;
  end if;
  if v_row.note <> 'walk on' or v_row.t_s <> 180 then
    raise exception 'FAIL 4d: the restored frame is note % at %, expected "walk on" at 180', v_row.note, v_row.t_s;
  end if;
  select count(*) into v_rows from public.plan_positions where frame_id = '0b000000-0000-4000-8000-0000000f0404';
  if v_rows <> 2 then
    raise exception 'FAIL 4e: the restored frame holds % positions, expected its 2', v_rows;
  end if;
end $$;

-- ---------- 5. an inverse is a write under the current revision ----------
-- The command holds no rev, so the rev is read when the undo runs. Section 3 bumped this frame twice; a command
-- carrying the rev it was recorded with is the thing that must not be accepted.
do $$
declare
  v_stale integer;
begin
  select rev into v_stale from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0202';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b03',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0202', 't_s', 60, 'rev', v_stale, 'note', 'doors'));
  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b03',
      jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0202', 't_s', 60, 'rev', v_stale, 'note', 'one here'));
    raise exception 'FAIL 5a: a write carrying the revision from before the edit was accepted';
  exception
    when sqlstate 'PT409' then null;
  end;
  perform public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
    'id', '0b000000-0000-4000-8000-0000000f0202', 't_s', 60,
    'rev', (select rev from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0202'),
    'note', 'one here'));
  if (select note from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0202') <> 'one here' then
    raise exception 'FAIL 5b: the write with the current revision did not take';
  end if;
end $$;

rollback;

select 'step 13: a shift restores by range or by id, a position map and a delete restore exactly, and an inverse needs the current revision' as result;
