-- Step 4, checked at the database: frame_save accepts a client-supplied id when it creates a frame.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step4-frame-id.sql
--
-- The rule, and why undo needs it: an id may be named only when it is free.
--   * already in this plan -> the ordinary update path (a stale rev is still PT409)
--   * in another plan      -> refused, never moved or duplicated across plans
--   * nowhere              -> created with that id
-- Step 13's undo restores a deleted frame this way, so rows that point at the id (progress in step 14, fork
-- origins in step 17) keep pointing at it.
--
-- Everything here runs in one transaction and is rolled back, so the bench is left exactly as the fixture wrote
-- it -- the browser check that follows still expects "Copy bench" to have two frames.
begin;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- the bench must be there, at two frames ----------
do $$
declare
  v_n integer;
begin
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_n <> 2 then
    raise exception 'The copy bench is not at two frames (it has %). Run supabase/fixtures/plan_bench.sql first.', v_n;
  end if;
end $$;

-- ---------- 1. a create that names its own id, with positions ----------
do $$
declare
  v_row public.plan_frames;
  v_n integer;
begin
  v_row := public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
    'id', '0b000000-0000-4000-8000-0000000f0299',
    't_s', 300,
    'note', 'restored',
    'positions', jsonb_build_object(
      '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77550),
      '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3311000, 'lng', 103.77550))));

  if v_row.id <> '0b000000-0000-4000-8000-0000000f0299' then
    raise exception 'FAIL 1a: frame_save returned id %, not the one it was given', v_row.id;
  end if;
  if v_row.rev <> 1 then
    raise exception 'FAIL 1b: a frame created with a client id starts at rev %, expected 1', v_row.rev;
  end if;
  if v_row.note <> 'restored' then
    raise exception 'FAIL 1c: the note came back as %, expected "restored"', v_row.note;
  end if;
  select count(*) into v_n from public.plan_positions where frame_id = v_row.id;
  if v_n <> 2 then
    raise exception 'FAIL 1d: the new frame holds % positions, expected 2', v_n;
  end if;
end $$;

-- ---------- 2. the same call again is an update, not a second frame ----------
-- This is what makes a retried restore safe: the id is the identity, so a paste that is sent twice does not
-- leave two frames on the strip.
do $$
declare
  v_row public.plan_frames;
  v_n integer;
begin
  v_row := public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
    'id', '0b000000-0000-4000-8000-0000000f0299',
    't_s', 300,
    'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77560))));

  if v_row.rev <> 2 then
    raise exception 'FAIL 2a: the second write left rev at %, expected 2', v_row.rev;
  end if;
  select count(*) into v_n from public.plan_frames
   where plan_id = '0b000000-0000-4000-8000-000000000b03' and t_s = 300;
  if v_n <> 1 then
    raise exception 'FAIL 2b: there are % frames at +5:00, expected 1', v_n;
  end if;
  select count(*) into v_n from public.plan_positions where frame_id = v_row.id;
  if v_n <> 1 then
    raise exception 'FAIL 2c: the replacement left % positions, expected 1 (positions are replaced wholesale)', v_n;
  end if;
end $$;

-- ---------- 3. a stale rev is still refused, client id or not ----------
do $$
begin
  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0299', 't_s', 300, 'rev', 1));
    raise exception 'FAIL 3: a stale rev was accepted';
  exception
    when sqlstate 'PT409' then null;
  end;
end $$;

-- ---------- 4. an id that belongs to another plan is refused, and stays where it was ----------
do $$
declare
  v_owner uuid;
  v_n integer;
begin
  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object(
      'id', '0b000000-0000-4000-8000-0000000f0001', 't_s', 600,
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3310000, 'lng', 103.77500))));
    raise exception 'FAIL 4a: an id owned by another plan was accepted';
  exception
    when sqlstate '42501' then null;
  end;

  select plan_id into v_owner from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f0001';
  if v_owner <> '0b000000-0000-4000-8000-000000000b01' then
    raise exception 'FAIL 4b: the other plan''s frame now belongs to %', v_owner;
  end if;
  select count(*) into v_n from public.plan_frames
   where plan_id = '0b000000-0000-4000-8000-000000000b03' and t_s = 600;
  if v_n <> 0 then
    raise exception 'FAIL 4c: the refused write still left % frame(s) at +10:00', v_n;
  end if;
end $$;

-- ---------- 5. no id still means "mint one", and a taken time is still refused ----------
do $$
declare
  v_row public.plan_frames;
  v_n integer;
begin
  v_row := public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object('t_s', 900));
  if v_row.id is null then
    raise exception 'FAIL 5a: a create with no id came back without one';
  end if;
  if v_row.id = '0b000000-0000-4000-8000-0000000f0299' then
    raise exception 'FAIL 5b: the default minted the id of an existing frame';
  end if;

  begin
    perform public.frame_save('0b000000-0000-4000-8000-000000000b03', jsonb_build_object('t_s', 900));
    raise exception 'FAIL 5c: a second frame at +15:00 was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b03';
  if v_n <> 4 then
    raise exception 'FAIL 5d: the plan has % frames, expected 4 (two fixture + two added here)', v_n;
  end if;
end $$;

rollback;

select 'step 4: frame_save honours a free client id, updates on a retry, and refuses an id from another plan' as result;
