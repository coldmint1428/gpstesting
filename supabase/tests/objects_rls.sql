-- ============================================================
-- Tests for the bench as ROWS: 017_object_rows.sql
--
-- Run in the Supabase SQL Editor (or with psql) AFTER 017 is applied -- and run locally, on a database
-- that starts empty, by `node tools/pgtest.mjs`. Everything happens inside ONE transaction that ends
-- in ROLLBACK, so nothing is left behind: the test users, the bench, the shapes, the pictures and the
-- locks all disappear. Each check raises 'FAIL n: ...', which aborts the transaction and names it.
--
-- The shape of this file is layouts_rls.sql's: `set local request.jwt.claims` is the identity (that is
-- what auth.uid() reads), `authenticated` is the role, and `reset role` is the owner -- which is how a
-- row is put into a state no page can reach, so that the page's handling of that state can be checked.
--
-- What is where: 1-2 the bench and its first shape, 3-4 who may write one and what a refused write
-- must hand back, 5 the patch that merges, 6-7 floor plans and their pictures, 8-9 the sentences a
-- refused shape is given, 10 the 4 MB cap and what a refused write leaves behind, 11-12 deletion,
-- 13-15 the doors (no session, no login, and the old save_bench), 16-17 what the TABLE refuses even
-- when the functions are bypassed, 18 two planners on two shapes at once.
-- ============================================================
begin;

-- ============================================================
-- 0. Two test users. Inserting into auth.users fires the trigger from 002, which creates the matching
--    public.profiles row -- and it is the profile's display name that a refusal names.
-- ============================================================
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'bench-a@example.test', '', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     '{"username":"bench_test_a","display_name":"Bench Test A"}'::jsonb, now(), now()),
    (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'bench-b@example.test', '', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     '{"username":"bench_test_b","display_name":"Bench Test B"}'::jsonb, now(), now());
end $$;

-- From here on we act as a signed-in user: A, in a tab whose session is SESS_A.
-- B is the other planner, in SESS_B. The two sessions are what makes "my other window" a case.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- ============================================================
-- 1. open_bench() makes the bench, and hands back a canvas that is empty -- revision 0, no bytes, no
--    shapes and no pictures.
-- ============================================================
do $$
declare
  v_id uuid; v_rev bigint; v_bytes bigint; v_shapes jsonb; v_images jsonb;
begin
  select id, rev, bytes, shapes, images
    into v_id, v_rev, v_bytes, v_shapes, v_images
  from public.open_bench();

  if v_id is null then raise exception 'FAIL 1: open_bench() returned no bench'; end if;
  if v_rev <> 0 then raise exception 'FAIL 1: a new bench starts at revision % (expected 0)', v_rev; end if;
  if v_bytes <> 0 then raise exception 'FAIL 1: a new bench is % bytes (expected 0)', v_bytes; end if;
  if v_shapes <> '[]'::jsonb then raise exception 'FAIL 1: a new bench has shapes: %', v_shapes; end if;
  if v_images <> '{}'::jsonb then raise exception 'FAIL 1: a new bench has pictures: %', v_images; end if;

  if (select count(*) from public.layouts) <> 1 then
    raise exception 'FAIL 1: there is more than one bench row';
  end if;

  perform set_config('bench.id', v_id::text, true);
end $$;

-- ============================================================
-- 1b. The bench still has a HOME view, and it still comes out of the document that used to hold the
--     whole canvas: 015 moved a planner's camera into public.layout_views and left the copy inside the
--     canvas as the view a planner who has never panned opens at. 018 moved that value into a column of
--     its own and dropped the document around it, so this is where it lives now.
-- ============================================================
reset role;
update public.layouts
set home = '{"lat": 1.3521, "lng": 103.8198, "zoom": 15}'::jsonb;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

do $$
declare
  v_home jsonb;
begin
  select home into v_home from public.open_bench();
  if v_home is null or (v_home ->> 'zoom')::numeric <> 15 then
    raise exception 'FAIL 1b: the bench handed back the home view as %', coalesce(v_home::text, 'nothing');
  end if;
end $$;

-- ============================================================
-- 2. A shape is written by the planner who holds its lock -- and by nobody else.
--    The whole area goes in one patch, because the bench has never seen it.
-- ============================================================
do $$
declare
  r record;
begin
  select * into r from public.lock_object('area-1', '33333333-3333-3333-3333-333333333333');
  if not r.granted then
    raise exception 'FAIL 2: a lock on a shape nobody has was refused';
  end if;

  select * into r from public.save_object(
    'area',
    jsonb_build_object(
      'id', 'area-1',
      'name', 'Stage',
      'kind', 'stage',
      'points', jsonb_build_array(
        jsonb_build_array(1.3000, 103.8000),
        jsonb_build_array(1.3002, 103.8002),
        jsonb_build_array(1.3001, 103.8004)
      )
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if not r.ok then
    raise exception 'FAIL 2: the holder of the lock was refused: %', coalesce(r.problem, 'no reason given');
  end if;
  if r.rev <> 1 then
    raise exception 'FAIL 2: the write was stamped revision % (expected 1)', r.rev;
  end if;
  if r.bytes <= 0 then
    raise exception 'FAIL 2: the bench is % bytes after a shape was written', r.bytes;
  end if;
  if r.data ->> 'name' <> 'Stage' then
    raise exception 'FAIL 2: the reply is not what was stored: %', r.data;
  end if;
  if r.image_id is not null then
    raise exception 'FAIL 2: an area came back with a picture (%)', r.image_id;
  end if;
  if (select count(*) from public.layout_objects where object_id = 'area-1') <> 1 then
    raise exception 'FAIL 2: the shape is not on the bench';
  end if;
end $$;

-- ============================================================
-- 3. A planner with no lock writes nothing, is told who has it, and is handed the shape as the bench
--    holds it -- which is what their screen puts back (the snap-back).
--
--    This is the property the old merge used to provide by guessing, now stated once: the lock is the
--    permission, and a refusal is a report rather than silence.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

do $$
declare
  r record;
begin
  select * into r from public.save_object(
    'area',
    jsonb_build_object('id', 'area-1', 'name', 'Taken'),
    '44444444-4444-4444-4444-444444444444'
  );

  if r.ok then raise exception 'FAIL 3: a planner with no lock was allowed to write'; end if;
  if r.held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 3: the refusal named % (expected Bench Test A)', coalesce(r.held_by, 'nobody');
  end if;
  if r.mine_elsewhere then
    raise exception 'FAIL 3: somebody else''s lock was reported as another window of mine';
  end if;
  if r.data ->> 'name' <> 'Stage' then
    raise exception 'FAIL 3: the refusal did not hand back the stored shape: %', r.data;
  end if;
  if (select data ->> 'name' from public.layout_objects where object_id = 'area-1') <> 'Stage' then
    raise exception 'FAIL 3: the refused write was stored anyway';
  end if;
end $$;

-- ============================================================
-- 4. A WRITE IS A PATCH. The row is given a name by hand -- as if another planner had renamed it and
--    this page had missed the event -- and then the holder writes only the points. The name they never
--    mentioned has to survive, because a page whose copy is behind must not be able to undo work it
--    cannot see. (Under 016 the same write carried the whole object, and the whole object won.)
-- ============================================================
reset role;
update public.layout_objects
set data = jsonb_set(data, '{name}', '"Renamed by somebody else"')
where object_id = 'area-1';
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

do $$
declare
  r record;
begin
  select * into r from public.save_object(
    'area',
    jsonb_build_object(
      'id', 'area-1',
      'points', jsonb_build_array(
        jsonb_build_array(1.3010, 103.8010),
        jsonb_build_array(1.3012, 103.8012),
        jsonb_build_array(1.3011, 103.8014)
      )
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if not r.ok then
    raise exception 'FAIL 4: the holder was refused: %', coalesce(r.problem, 'no reason given');
  end if;
  if r.data ->> 'name' <> 'Renamed by somebody else' then
    raise exception 'FAIL 4: a patch undid a field it never mentioned: %', r.data;
  end if;
  if (r.data -> 'points' -> 0 ->> 0)::numeric <> 1.3010 then
    raise exception 'FAIL 4: the patch itself was not stored: %', r.data;
  end if;
end $$;

-- ============================================================
-- 5. A floor plan brings its picture with it, and the picture is stored ONCE however many plans are
--    made from it -- which is what makes a copy or a second upload of one level cost nothing.
-- ============================================================
do $$
declare
  r record;
  v_images int;
begin
  perform public.lock_object('plan-1', '33333333-3333-3333-3333-333333333333');
  select * into r from public.save_object(
    'plan',
    jsonb_build_object(
      'id', 'plan-1', 'name', 'Level 1',
      'centre', jsonb_build_array(1.3000, 103.8000),
      'angleDeg', 0, 'widthM', 100, 'heightM', 50, 'opacity', 0.5, 'visible', true,
      'image', 'data:image/png;base64,AAAA'
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if not r.ok then
    raise exception 'FAIL 5: a floor plan was refused: %', coalesce(r.problem, 'no reason given');
  end if;
  if r.image_id is distinct from md5('data:image/png;base64,AAAA') then
    raise exception 'FAIL 5: the plan was stored against picture %', coalesce(r.image_id, 'nothing');
  end if;
  if jsonb_exists(r.data, 'image') then
    raise exception 'FAIL 5: the reply still carries the picture itself';
  end if;

  -- The same picture again, as a second plan: one row, not two.
  perform public.lock_object('plan-2', '33333333-3333-3333-3333-333333333333');
  select * into r from public.save_object(
    'plan',
    jsonb_build_object(
      'id', 'plan-2', 'name', 'Level 2',
      'centre', jsonb_build_array(1.3010, 103.8010),
      'angleDeg', 0, 'widthM', 100, 'heightM', 50, 'opacity', 0.5, 'visible', true,
      'image', 'data:image/png;base64,AAAA'
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if not r.ok then raise exception 'FAIL 5: the second plan was refused: %', coalesce(r.problem, ''); end if;

  select count(*) into v_images from public.layout_images;
  if v_images <> 1 then
    raise exception 'FAIL 5: one picture used twice was stored % times', v_images;
  end if;
end $$;

-- ============================================================
-- 6. Moving a floor plan sends no picture, and does not touch the one it has: this is the write that
--    used to upload the whole canvas, and it is now a few hundred bytes that leave the picture alone.
-- ============================================================
do $$
declare
  r record;
  v_before bigint;
  v_image text;
begin
  select image_id into v_image from public.layout_objects where object_id = 'plan-1';
  select bytes into v_before from public.open_bench();

  select * into r from public.save_object(
    'plan',
    jsonb_build_object(
      'id', 'plan-1',
      'centre', jsonb_build_array(1.3020, 103.8020),
      'angleDeg', 30
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if not r.ok then raise exception 'FAIL 6: moving a floor plan was refused: %', coalesce(r.problem, ''); end if;
  if r.image_id is distinct from v_image then
    raise exception 'FAIL 6: the move changed which picture the plan points at';
  end if;
  if r.data ->> 'name' <> 'Level 1' then
    raise exception 'FAIL 6: the move lost the name: %', r.data;
  end if;
  if (r.data -> 'centre' ->> 0)::numeric <> 1.3020 then
    raise exception 'FAIL 6: the move was not stored: %', r.data;
  end if;
  if r.bytes <= v_before then
    raise exception 'FAIL 6: the size did not move with the shape (% then %)', v_before, r.bytes;
  end if;
end $$;

-- ============================================================
-- 7. A floor plan dragged off the Singapore map is refused, and the sentence says so -- about THAT
--    plan, which the whole-document save could never do ("The layout data is not valid", about
--    everything at once).
-- ============================================================
do $$
declare
  r record;
begin
  select * into r from public.save_object(
    'plan',
    jsonb_build_object('id', 'plan-1', 'centre', jsonb_build_array(1.9000, 103.8000)),
    '33333333-3333-3333-3333-333333333333'
  );

  if r.ok then raise exception 'FAIL 7: a floor plan was allowed outside Singapore'; end if;
  if r.problem is null or r.problem not like '%Singapore%' then
    raise exception 'FAIL 7: the refusal said: %', coalesce(r.problem, 'nothing');
  end if;
  if (select (data -> 'centre' ->> 0)::numeric from public.layout_objects where object_id = 'plan-1') <> 1.3020 then
    raise exception 'FAIL 7: the refused move moved the plan';
  end if;
end $$;

-- ============================================================
-- 8. An area with two points is refused, and the sentence counts them.
-- ============================================================
do $$
declare
  r record;
begin
  select * into r from public.save_object(
    'area',
    jsonb_build_object(
      'id', 'area-1',
      'points', jsonb_build_array(
        jsonb_build_array(1.3000, 103.8000),
        jsonb_build_array(1.3002, 103.8002)
      )
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if r.ok then raise exception 'FAIL 8: a two-point area was stored'; end if;
  if r.problem is null or r.problem not like '%3 and 200%' then
    raise exception 'FAIL 8: the refusal said: %', coalesce(r.problem, 'nothing');
  end if;
end $$;

-- ============================================================
-- 9. THE CAP, and what a refused write leaves behind: nothing at all.
--
--    4 MB is still the rule (it is the number the ring on the page shows), and a write that would pass
--    it is rolled back whole -- no row, no picture, no revision, no bytes. A planner who pasted one
--    picture too many is told why instead of being handed a failure, which is what the block inside
--    save_object() is for.
-- ============================================================
do $$
declare
  r record;
  v_bytes bigint;
  v_rev bigint;
  v_images int;
  v_objects int;
begin
  select bytes, rev into v_bytes, v_rev from public.open_bench();
  select count(*) into v_images from public.layout_images;
  select count(*) into v_objects from public.layout_objects;

  perform public.lock_object('plan-big', '33333333-3333-3333-3333-333333333333');
  select * into r from public.save_object(
    'plan',
    jsonb_build_object(
      'id', 'plan-big', 'name', 'Huge',
      'centre', jsonb_build_array(1.3000, 103.8000),
      'angleDeg', 0, 'widthM', 100, 'heightM', 50, 'opacity', 0.5, 'visible', true,
      'image', 'data:image/png;base64,' || repeat('A', 4200000)
    ),
    '33333333-3333-3333-3333-333333333333'
  );

  if r.ok then raise exception 'FAIL 9: a canvas over 4 MB was stored'; end if;
  if r.problem is null or r.problem not like '%too much for one bench%' then
    raise exception 'FAIL 9: the refusal said: %', coalesce(r.problem, 'nothing');
  end if;
  if (select count(*) from public.layout_images) <> v_images then
    raise exception 'FAIL 9: the refused write left a picture behind';
  end if;
  if (select count(*) from public.layout_objects) <> v_objects then
    raise exception 'FAIL 9: the refused write left a shape behind';
  end if;
  if (select bytes from public.open_bench()) <> v_bytes then
    raise exception 'FAIL 9: the refused write moved the size';
  end if;
  if (select rev from public.layouts) <> v_rev then
    raise exception 'FAIL 9: the refused write moved the revision';
  end if;
end $$;

-- ============================================================
-- 10. Deleting. Only the holder may, the lock goes with the shape, and a picture that no shape points
--     at any more goes too -- which is what keeps "delete a floor plan to make room" true.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

do $$
declare
  r record;
begin
  -- B is a planner, and B does not hold plan-2.
  select * into r from public.delete_object('plan-2', '44444444-4444-4444-4444-444444444444');
  if r.ok then raise exception 'FAIL 10: a planner with no lock was allowed to delete a shape'; end if;
  if r.held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 10: the refusal named %', coalesce(r.held_by, 'nobody');
  end if;
  if (select count(*) from public.layout_objects where object_id = 'plan-2') <> 1 then
    raise exception 'FAIL 10: the refusal deleted it anyway';
  end if;
  -- And the refusal hands back what the bench holds, which is what a refused deletion puts back on
  -- the planner's screen.
  if r.data ->> 'name' <> 'Level 2' then
    raise exception 'FAIL 10: the refusal did not hand back the shape: %', coalesce(r.data::text, 'nothing');
  end if;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

do $$
declare
  r record;
  v_bytes bigint;
begin
  select bytes into v_bytes from public.open_bench();

  -- plan-1 and plan-2 share one picture, so deleting one of them must keep it.
  perform public.lock_object('plan-2', '33333333-3333-3333-3333-333333333333');
  select * into r from public.delete_object('plan-2', '33333333-3333-3333-3333-333333333333');
  if not r.ok then raise exception 'FAIL 10b: the holder could not delete: %', coalesce(r.problem, ''); end if;
  if (select count(*) from public.layout_objects where object_id = 'plan-2') <> 0 then
    raise exception 'FAIL 10b: the shape is still on the bench';
  end if;
  if (select count(*) from public.layout_images) <> 1 then
    raise exception 'FAIL 10b: deleting one of two plans sharing a picture deleted the picture';
  end if;
  if r.bytes >= v_bytes then
    raise exception 'FAIL 10b: the size did not come down (% then %)', v_bytes, r.bytes;
  end if;
  -- (That the lock went with the shape is checked in 10d, from the other planner's side: a lock row
  -- that outlived its shape would refuse them for the next 45 seconds. layout_locks is not readable
  -- from here on purpose -- see 016 -- so the check is about what it does, not what it holds.)

  -- The last plan pointing at the picture takes it with it.
  perform public.lock_object('plan-1', '33333333-3333-3333-3333-333333333333');
  select * into r from public.delete_object('plan-1', '33333333-3333-3333-3333-333333333333');
  if not r.ok then raise exception 'FAIL 10c: the holder could not delete: %', coalesce(r.problem, ''); end if;
  if (select count(*) from public.layout_images) <> 0 then
    raise exception 'FAIL 10c: the picture of the last plan pointing at it was left behind';
  end if;
  if r.bytes <> (select bytes from public.open_bench()) then
    raise exception 'FAIL 10c: the size in the reply is not the bench''s size';
  end if;
end $$;

-- ============================================================
-- 11. Deleting a shape that is not there is not an error. This is a retry -- the page took the lock,
--     the delete went through, the reply was lost -- and the state it leaves is the state that was
--     wanted: the shape is not on the bench. (Without a lock it is refused like any other write; that
--     is check 10.)
-- ============================================================
do $$
declare
  r record;
  v_bytes bigint;
begin
  select bytes into v_bytes from public.open_bench();
  perform public.lock_object('plan-2', '33333333-3333-3333-3333-333333333333');

  select * into r from public.delete_object('plan-2', '33333333-3333-3333-3333-333333333333');
  if not r.ok then
    raise exception 'FAIL 11: re-deleting a shape that is already gone was refused: %', coalesce(r.problem, '');
  end if;
  if (select count(*) from public.layout_objects where object_id = 'plan-2') <> 0 then
    raise exception 'FAIL 11: a shape came back';
  end if;
  if r.bytes <> v_bytes then
    raise exception 'FAIL 11: deleting nothing moved the size (% then %)', v_bytes, r.bytes;
  end if;
end $$;

-- ============================================================
-- 11b. ...and the lock went with the shape. B may take that id at once, which can only be true if the
--      delete took the lock row with it: there is nothing left to hold.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

do $$
declare
  v_lock record;
begin
  select * into v_lock from public.lock_object('plan-2', '44444444-4444-4444-4444-444444444444');
  if not v_lock.granted then
    raise exception 'FAIL 11b: the lock outlived the shape it was on';
  end if;
  perform public.unlock_object('plan-2', '44444444-4444-4444-4444-444444444444');
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- ============================================================
-- 12. The doors. A page with no session cannot write anything (that is the one hard refusal left), and
--     the old save_bench() answers a stale tab in words rather than with "does not exist".
-- ============================================================
do $$
declare
  v_raised boolean := false;
  v_message text;
begin
  begin
    perform public.save_object('area', jsonb_build_object('id', 'area-1', 'name', 'No session'), null);
  exception when others then
    v_raised := true;
    v_message := sqlerrm;
  end;

  if not v_raised then raise exception 'FAIL 12: a page with no session was allowed to write'; end if;
  if v_message not like '%no session%' then
    raise exception 'FAIL 12: the refusal said: %', v_message;
  end if;
end $$;

do $$
declare
  v_raised boolean := false;
  v_message text;
begin
  begin
    perform public.save_bench('{"polygons": []}'::jsonb, '33333333-3333-3333-3333-333333333333');
  exception when others then
    v_raised := true;
    v_message := sqlerrm;
  end;

  if not v_raised then raise exception 'FAIL 12b: the old save_bench() was allowed to run'; end if;
  if v_message not like '%upgraded%' then
    raise exception 'FAIL 12b: the old door said: %', v_message;
  end if;
end $$;

-- Not signed in at all -- no claims, so auth.uid() is null.
set local request.jwt.claims = '{}';
do $$
declare
  v_raised boolean := false;
  v_message text;
begin
  begin
    perform public.open_bench();
  exception when others then
    v_raised := true;
    v_message := sqlerrm;
  end;

  if not v_raised then raise exception 'FAIL 12c: an anonymous request was allowed to open the bench'; end if;
  if v_message not like '%Not signed in%' then
    raise exception 'FAIL 12c: the refusal said: %', v_message;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- ============================================================
-- 13. Anonymous users reach nothing: neither the shapes nor the pictures.
-- ============================================================
set local role anon;
do $$
declare
  v_blocked boolean := false;
begin
  begin
    perform count(*) from public.layout_objects;
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 13: anon can read the bench shapes'; end if;

  v_blocked := false;
  begin
    perform count(*) from public.layout_images;
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 13: anon can read the bench pictures'; end if;
end $$;

-- ============================================================
-- 14. A signed-in planner cannot write the tables directly: there is no insert policy at all, so every
--     write has to come through save_object(), which is where the lock is asked for.
-- ============================================================
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
begin
  begin
    insert into public.layout_objects (layout_id, object_id, kind, data, rev)
    values (current_setting('bench.id')::uuid, 'direct-1', 'area',
            '{"id":"direct-1","name":"Direct","kind":"zone","points":[[1.3,103.8],[1.3002,103.8002],[1.3001,103.8004]]}'::jsonb,
            99);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 14: a signed-in planner wrote a shape row directly'; end if;

  v_blocked := false;
  begin
    insert into public.layout_images (layout_id, image_id, data)
    values (current_setting('bench.id')::uuid, md5('x'), 'data:image/png;base64,AAAA');
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 14: a signed-in planner wrote a picture row directly'; end if;
end $$;

-- ============================================================
-- 15. The TABLE holds the rules too, for anyone who gets past the functions (a migration, a console, a
--     future bug): a two-point area, a plan with no picture, a picture under a plan's id, and a row
--     whose `data` disagrees with the id it is filed under.
-- ============================================================
reset role;
do $$
declare
  v_blocked boolean := false;
  v_layout uuid;
begin
  select id into v_layout from public.layouts order by created_at limit 1;

  begin
    insert into public.layout_objects (layout_id, object_id, kind, data, rev)
    values (v_layout, 'direct-1', 'area',
            '{"id":"direct-1","name":"Direct","kind":"zone","points":[[1.3,103.8],[1.3002,103.8002]]}'::jsonb, 99);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 15: the table stored a two-point area'; end if;

  v_blocked := false;
  begin
    insert into public.layout_objects (layout_id, object_id, kind, data, rev)
    values (v_layout, 'direct-plan', 'plan',
            '{"id":"direct-plan","name":"No picture","centre":[1.3,103.8],"angleDeg":0,"widthM":100,"heightM":50,"opacity":0.5,"visible":true}'::jsonb,
            99);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 15: the table stored a floor plan with no picture'; end if;

  v_blocked := false;
  begin
    insert into public.layout_objects (layout_id, object_id, kind, data, rev)
    values (v_layout, 'direct-2', 'area',
            '{"id":"somebody-else","name":"Mismatch","kind":"zone","points":[[1.3,103.8],[1.3002,103.8002],[1.3001,103.8004]]}'::jsonb,
            99);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 15: the table accepted a shape whose id is not its own'; end if;

  -- And the one that would quietly break the canvas: a picture smuggled back into a row.
  v_blocked := false;
  begin
    insert into public.layout_objects (layout_id, object_id, kind, data, rev)
    values (v_layout, 'direct-3', 'area',
            '{"id":"direct-3","name":"With picture","kind":"zone","image":"data:image/png;base64,AAAA","points":[[1.3,103.8],[1.3002,103.8002],[1.3001,103.8004]]}'::jsonb,
            99);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'FAIL 15: the table accepted a shape row carrying a picture'; end if;
end $$;

-- ============================================================
-- 16. Two planners, two shapes, at the same time -- which is the whole point of a lock per shape, and
--     what the one-claim-for-the-bench model of 005 could not do at all.
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

do $$
declare
  r record;
  v_lock record;
  v_refused record;
begin
  -- A is still holding area-1 (nothing in this file released it), and B takes area-2 alongside.
  select * into v_lock from public.lock_object('area-2', '44444444-4444-4444-4444-444444444444');
  if not v_lock.granted then
    raise exception 'FAIL 16: a second planner could not take a second shape while the first was held';
  end if;

  -- ...while the shape A is holding stays A's: the exclusion is per shape, and it is still exclusion.
  select * into v_refused from public.lock_object('area-1', '44444444-4444-4444-4444-444444444444');
  if v_refused.granted then
    raise exception 'FAIL 16: a second planner took a shape the first one is holding';
  end if;
  if v_refused.held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 16: the refusal named %', coalesce(v_refused.held_by, 'nobody');
  end if;

  select * into r from public.save_object(
    'area',
    jsonb_build_object(
      'id', 'area-2', 'name', 'No go', 'kind', 'no_go',
      'points', jsonb_build_array(
        jsonb_build_array(1.3100, 103.8100),
        jsonb_build_array(1.3102, 103.8102),
        jsonb_build_array(1.3101, 103.8104)
      )
    ),
    '44444444-4444-4444-4444-444444444444'
  );

  if not r.ok then raise exception 'FAIL 16: the second planner was refused: %', coalesce(r.problem, ''); end if;
  if (select count(*) from public.layout_objects where kind = 'area') <> 2 then
    raise exception 'FAIL 16: the two areas are not both on the bench';
  end if;
end $$;

do $$
begin
  raise notice 'All 017 checks passed: the canvas is rows, a write is a patch, and the lock is the permission.';
end $$;

rollback;
