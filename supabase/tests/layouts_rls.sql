-- ============================================================
-- Tests for the bench schema: 005_layouts.sql, 006_floor_plan_bounds.sql,
-- 007_presence_and_views.sql and 008_object_locks.sql
--
-- Run in the Supabase SQL Editor (or with psql) AFTER those migrations are applied.
-- Everything happens inside ONE transaction that ends in ROLLBACK, so nothing is left
-- behind -- the test users, the bench row, the locks and the presence rows all disappear.
--
-- Each check raises 'FAIL: ...' if it does not hold, which aborts the transaction and
-- names the check that broke. A clean run prints the success notice at the end.
--
-- Identity is switched with `set local request.jwt.claims`, which is what auth.uid()
-- reads. Only two roles are used: `authenticated` (for everything) and `anon` (to prove
-- the bench is not public). Owner-only steps use `reset role`.
--
-- What is where: checks 1-5 are the bench row itself (005), 6 proves a direct write is
-- refused at the table, 7-14d are the OBJECT locks and the merging save that 008 replaced
-- the whole-bench claim with, 15-17g are the layout validators (005 and 006), 18-23b are
-- presence and views (007), and 24 is the cascade when the bench is deleted.
-- ============================================================

begin;

-- ============================================================
-- 0. Two test users. Inserting into auth.users fires the trigger from 002, which creates
--    the matching public.profiles row (username + display name).
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

-- From here on we act as a signed-in user: user A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- ============================================================
-- 1. open_bench() creates the bench when it is missing
-- ============================================================
do $$
declare
  v_rows int;
  v_id   uuid;
begin
  select count(*) into v_rows from public.open_bench();
  if v_rows <> 1 then
    raise exception 'FAIL 1: open_bench() returned % rows, expected 1', v_rows;
  end if;

  select id into v_id from public.open_bench();
  perform set_config('bench.id', v_id::text, true);
end $$;

-- ============================================================
-- 2. open_bench() is idempotent -- a second call returns the same row, not a new one
-- ============================================================
do $$
declare
  v_id uuid;
begin
  select id into v_id from public.open_bench();
  if v_id::text <> current_setting('bench.id') then
    raise exception 'FAIL 2: open_bench() returned a different bench (%)', v_id;
  end if;

  if (select count(*) from public.layouts) <> 1 then
    raise exception 'FAIL 2: there is more than one bench row';
  end if;
end $$;

-- ============================================================
-- 2b. Empty the canvas, as the owner, so that every check below is about the objects THIS FILE puts
--     there.
--
--     It has to be done by the owner rather than by a save, because a save now MERGES: an object
--     nobody in this test holds is kept whatever the caller sends. That is the safety property the
--     whole design rests on (see check 10), and it also means no save can ever clear a bench that
--     already has something on it -- the bench is shared with whatever is really stored in it, and
--     this file has to be able to reason about totals.
--
--     The document is written with NO `view` key rather than a null one: a JSON null is not a SQL
--     null, and 005's validator refuses `{"view": null}` (which is why 008 changes the table
--     default). Everything here is inside the transaction and rolled back at the end.
-- ============================================================
reset role;
update public.layouts set data = '{"floorPlans": [], "polygons": []}'::jsonb;
set local role authenticated;

-- ============================================================
-- 3. There is no insert policy on layouts -- a signed-in user cannot write directly
-- ============================================================
do $$
declare
  v_blocked boolean := false;
begin
  begin
    insert into public.layouts (created_by)
    values ('11111111-1111-1111-1111-111111111111');
  exception when others then
    v_blocked := true;
  end;

  if not v_blocked then
    raise exception 'FAIL 3: a direct insert into layouts was allowed';
  end if;
end $$;

-- ============================================================
-- 3b. The singleton index stops a second bench row even for the owner
--     (RLS would hide this from a signed-in user, so it is checked as the owner.)
-- ============================================================
reset role;
do $$
declare
  v_blocked boolean := false;
begin
  begin
    insert into public.layouts (created_by)
    values ('11111111-1111-1111-1111-111111111111');
  exception when unique_violation then
    v_blocked := true;
  end;

  if not v_blocked then
    raise exception 'FAIL 3b: a second bench row was created (singleton index missing)';
  end if;
end $$;
set local role authenticated;

-- ============================================================
-- 4. A signed-in user can read the bench
-- ============================================================
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.layouts;
  if v_rows <> 1 then
    raise exception 'FAIL 4: authenticated saw % bench rows, expected 1', v_rows;
  end if;
end $$;

-- ============================================================
-- 5. Anonymous visitors see nothing
-- ============================================================
set local role anon;
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.layouts;
  if v_rows <> 0 then
    raise exception 'FAIL 5: anon could read the bench (% rows)', v_rows;
  end if;
end $$;
set local role authenticated;

-- ============================================================
-- 6. A direct write to the lock table is refused -- and refused for a DIFFERENT reason
--    than 005's table was.
--
--    public.layout_claims (005) had RLS and no policies, so a direct write died as "new
--    row violates row-level security policy". public.layout_locks (008) goes one step
--    further and has NO GRANTS either -- the session id inside it IS the credential, so the
--    table is never published at all. The refusal is therefore a PERMISSION error, and that
--    is what this check names: the difference is the migration's "no grants at all" rule
--    being enforced, rather than merely intended.
-- ============================================================
do $$
declare
  v_blocked boolean := false;
  v_msg     text := '';
begin
  begin
    insert into public.layout_locks (object_id, layout_id, user_id, session_id)
    values ('direct_write', current_setting('bench.id')::uuid,
            '11111111-1111-1111-1111-111111111111',
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  exception when others then
    v_blocked := true;
    v_msg := sqlerrm;
  end;

  if not v_blocked then
    raise exception 'FAIL 6: a direct insert into layout_locks was allowed';
  end if;
  -- Named, so this cannot pass by failing for some other reason.
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 6: the write was refused, but not for lack of a grant (%)', v_msg;
  end if;
end $$;

-- ============================================================
-- 7. A locks one OBJECT and is granted, with an expiry in the future.
--    008 replaced the whole-bench claim with a lock per object, held by a SESSION (one per
--    open tab): nothing is claimed as a whole any more, so there is no token to carry about.
-- ============================================================
do $$
declare
  v_granted boolean;
  v_held_by text;
  v_mine    boolean;
  v_expires timestamptz;
begin
  -- The sessions this section works with: A's tab, B's tab, and A's SECOND tab. The last of
  -- those is the bug 008 exists for -- same account, different editor.
  perform set_config('bench.session_a',  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  perform set_config('bench.session_b',  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
  perform set_config('bench.session_a2', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
  perform set_config('bench.session_c',  'dddddddd-dddd-dddd-dddd-dddddddddddd', true);

  select k.granted, k.held_by, k.mine_elsewhere, k.expires_at
  into v_granted, v_held_by, v_mine, v_expires
  from public.lock_object('a_lock_one', current_setting('bench.session_a')::uuid) as k;

  if not v_granted then
    raise exception 'FAIL 7: the first lock on an object was refused (held_by=%)',
      coalesce(v_held_by, '<null>');
  end if;
  if v_expires is null or v_expires <= now() then
    raise exception 'FAIL 7: the lock expires at %, which is not in the future', v_expires;
  end if;
  if v_held_by is not null then
    raise exception 'FAIL 7: a granted lock named a holder (%)', v_held_by;
  end if;
  if v_mine then
    raise exception 'FAIL 7: a granted lock was reported as mine elsewhere';
  end if;
end $$;

-- ============================================================
-- 8. Re-locking the SAME object with the SAME session is a heartbeat: granted again, still
--    exactly one holder, still THAT session, and the expiry moves out again.
-- ============================================================
reset role;
update public.layout_locks
set expires_at = now() + interval '1 second'
where object_id = 'a_lock_one';
set local role authenticated;

do $$
declare
  v_granted boolean;
  v_expires timestamptz;
begin
  select k.granted, k.expires_at into v_granted, v_expires
  from public.lock_object('a_lock_one', current_setting('bench.session_a')::uuid) as k;

  if not v_granted then
    raise exception 'FAIL 8: my own heartbeat was refused';
  end if;
  if v_expires is null or v_expires < now() + interval '30 seconds' then
    raise exception 'FAIL 8: the heartbeat did not move the expiry out (expires_at=%)', v_expires;
  end if;
end $$;

-- The lock table has no grants at all (008 section 2), so it is only ever read as the owner.
reset role;
do $$
declare
  v_rows    int;
  v_session uuid;
begin
  select count(*) into v_rows from public.layout_locks l where l.object_id = 'a_lock_one';
  if v_rows <> 1 then
    raise exception 'FAIL 8: % rows hold one object after a heartbeat, expected 1', v_rows;
  end if;

  select l.session_id into v_session from public.layout_locks l where l.object_id = 'a_lock_one';
  if v_session::text <> current_setting('bench.session_a') then
    raise exception 'FAIL 8: the heartbeat moved the lock to session %', v_session;
  end if;
end $$;
set local role authenticated;

-- ============================================================
-- 9. A DIFFERENT planner is refused on A's object and is told who holds it -- and can lock a
--    DIFFERENT object at the same time. That is the whole change: exclusion is per object, so
--    two planners work on one bench and neither locks the other out of the canvas, and both
--    saves are accepted.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_granted boolean;
  v_held_by text;
  v_mine    boolean;
begin
  select k.granted, k.held_by, k.mine_elsewhere into v_granted, v_held_by, v_mine
  from public.lock_object('a_lock_one', current_setting('bench.session_b')::uuid) as k;

  if v_granted then
    raise exception 'FAIL 9: two planners locked the same object';
  end if;
  if v_held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 9: held_by was %, expected Bench Test A', coalesce(v_held_by, '<null>');
  end if;
  if v_mine is distinct from false then
    raise exception 'FAIL 9: mine_elsewhere was % for another planner', v_mine;
  end if;

  select k.granted into v_granted
  from public.lock_object('a_lock_two', current_setting('bench.session_b')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 9: a second planner could not lock a different object';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_overruled text[];
begin
  v_overruled := public.save_bench(
    p_data => '{"polygons":[{"id":"a_lock_one","name":"Tree A","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}]}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );

  if v_overruled <> '{}'::text[] then
    raise exception 'FAIL 9: A''s own locked object was overruled (%)', v_overruled;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_overruled text[];
  v_polygons  jsonb;
begin
  v_overruled := public.save_bench(
    p_data => '{"polygons":[{"id":"a_lock_two","name":"Tree B","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}]}'::jsonb,
    p_session => current_setting('bench.session_b')::uuid
  );

  if v_overruled <> '{}'::text[] then
    raise exception 'FAIL 9: B''s own new object was overruled (%)', v_overruled;
  end if;

  -- Both saves landed, so the bench holds A's object and B's object at the same time. Counted BY ID
  -- rather than by the length of the array: the merge keeps objects nobody here holds (see check 10),
  -- so a total is not this check's business -- and the bench is shared with whatever is really on it.
  select l.data -> 'polygons' into v_polygons from public.layouts l;
  if (
    select count(*) from jsonb_array_elements(coalesce(v_polygons, '[]'::jsonb)) s
    where s ->> 'id' in ('a_lock_one', 'a_lock_two')
  ) <> 2 then
    raise exception 'FAIL 9: A''s and B''s objects are not both on the bench';
  end if;
end $$;

-- ============================================================
-- 10. The save MERGES, and that is what protects the other planner. B sends a whole document
--     in which A's locked object has been ALTERED (B does not hold that object's lock), plus
--     a brand new object of its own. The stored version of A's object survives and its id
--     comes back in the reply, so the page can say what happened and re-read; B's own object
--     is added in the same save.
-- ============================================================
do $$
declare
  v_overruled text[];
  v_polygons  jsonb;
  v_item      jsonb;
begin
  v_overruled := public.save_bench(
    p_data => '{"polygons":[
      {"id":"a_lock_two","name":"Tree B","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]},
      {"id":"a_lock_one","name":"B CHANGED THIS","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]},
      {"id":"a_lock_three","name":"Tree C","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}
    ]}'::jsonb,
    p_session => current_setting('bench.session_b')::uuid
  );

  if not ('a_lock_one' = any (v_overruled)) then
    raise exception 'FAIL 10: B overwrote an object B does not hold (overruled=%)', v_overruled;
  end if;

  select l.data -> 'polygons' into v_polygons from public.layouts l;

  select s into v_item from jsonb_array_elements(v_polygons) s where s ->> 'id' = 'a_lock_one';
  if v_item is null then
    raise exception 'FAIL 10: A''s object was dropped by B''s save';
  end if;
  if v_item ->> 'name' is distinct from 'Tree A' then
    raise exception 'FAIL 10: A''s object was overwritten (name=%)', v_item ->> 'name';
  end if;

  if (select count(*) from jsonb_array_elements(v_polygons) s where s ->> 'id' = 'a_lock_three') <> 1 then
    raise exception 'FAIL 10: B''s own new object was not added in the same save';
  end if;
end $$;

-- ============================================================
-- 11. A lock that has EXPIRED is free: anybody may take it, and the previous holder's save is
--     then overruled rather than obeyed -- the stored version of that object survives.
-- ============================================================
reset role;
update public.layout_locks
set expires_at = now() - interval '1 minute',
    last_seen  = now() - interval '5 minutes'
where object_id = 'a_lock_one';
set local role authenticated;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.lock_object('a_lock_one', current_setting('bench.session_b')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 11: an expired lock could not be taken';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_overruled text[];
  v_polygons  jsonb;
  v_name      text;
begin
  v_overruled := public.save_bench(
    p_data => '{"polygons":[{"id":"a_lock_one","name":"A CHANGED THIS","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}]}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );

  if not ('a_lock_one' = any (v_overruled)) then
    raise exception 'FAIL 11: a session whose lock was taken over still changed the object (%)',
      v_overruled;
  end if;

  select l.data -> 'polygons' into v_polygons from public.layouts l;
  select s ->> 'name' into v_name
  from jsonb_array_elements(v_polygons) s where s ->> 'id' = 'a_lock_one';
  if v_name is distinct from 'Tree A' then
    raise exception 'FAIL 11: the stored object changed to % after a take-over', v_name;
  end if;
end $$;

-- ============================================================
-- 12. The bug that motivated all of this: the SAME ACCOUNT in a SECOND SESSION is a second
--     editor, not a renewal. It is refused exactly like another planner, and it is told
--     mine_elsewhere = true -- so the page can say "you have it open in another tab" instead
--     of pretending this is somebody else.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.lock_object('a_lock_four', current_setting('bench.session_a')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 12: A could not lock an object of its own';
  end if;
end $$;

do $$
declare
  v_granted boolean;
  v_held_by text;
  v_mine    boolean;
begin
  -- Same `sub` as the block above: the same signed-in ACCOUNT, a different tab.
  select k.granted, k.held_by, k.mine_elsewhere into v_granted, v_held_by, v_mine
  from public.lock_object('a_lock_four', current_setting('bench.session_a2')::uuid) as k;

  if v_granted then
    raise exception 'FAIL 12: my own second tab was handed the object';
  end if;
  if v_held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 12: held_by was %, expected Bench Test A', coalesce(v_held_by, '<null>');
  end if;
  if v_mine is distinct from true then
    raise exception 'FAIL 12: mine_elsewhere was % for my own second tab', v_mine;
  end if;
end $$;

-- ============================================================
-- 13. take_over_object(): my OWN other window may repair "I left it open in another tab" at
--     once, while a DIFFERENT planner may not yank a lock that is still fresh -- and may, once
--     the holder has been quiet for 90 seconds. Note there is NO trigger on layout_locks, so
--     the owner can age last_seen directly (unlike presence, which check 22 has to disable a
--     trigger to age).
-- ============================================================
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.take_over_object('a_lock_four', current_setting('bench.session_a2')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 13: my own second window could not take over my lock';
  end if;
end $$;

do $$
declare
  v_granted boolean;
  v_mine    boolean;
begin
  -- The first window is now refused on the same object: the lock moved to the other tab.
  select k.granted, k.mine_elsewhere into v_granted, v_mine
  from public.lock_object('a_lock_four', current_setting('bench.session_a')::uuid) as k;
  if v_granted then
    raise exception 'FAIL 13: the old window kept the object after a take-over';
  end if;
  if v_mine is distinct from true then
    raise exception 'FAIL 13: mine_elsewhere was % when my own other window holds it', v_mine;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_granted boolean;
  v_idle    int;
begin
  select k.granted, k.idle_seconds into v_granted, v_idle
  from public.take_over_object('a_lock_four', current_setting('bench.session_b')::uuid) as k;

  if v_granted then
    raise exception 'FAIL 13: a different planner took over a lock that was still fresh';
  end if;
  if v_idle >= 90 then
    raise exception 'FAIL 13: the holder was reported as idle for % seconds', v_idle;
  end if;
end $$;

-- Age the holder's last_seen only: force is offered against a lock that has gone QUIET, so the
-- 45-second expiry must not be what lets this through.
reset role;
update public.layout_locks set last_seen = now() - interval '10 minutes'
where object_id = 'a_lock_four';
set local role authenticated;

do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.take_over_object('a_lock_four', current_setting('bench.session_b')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 13: a lock quiet for 10 minutes could not be taken over';
  end if;
end $$;

-- ============================================================
-- 14. unlock_object() frees ONE object at once; release_my_locks() frees everything a session
--     holds at once. Neither waits out the 45-second expiry.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.lock_object('a_lock_five', current_setting('bench.session_a')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 14: A could not lock an object to release';
  end if;
end $$;

do $$
declare
  v_granted boolean;
begin
  -- A's other window: refused while the first window holds it.
  select k.granted into v_granted
  from public.lock_object('a_lock_five', current_setting('bench.session_a2')::uuid) as k;
  if v_granted then
    raise exception 'FAIL 14: one object was handed to two sessions of one account';
  end if;
end $$;

do $$
begin
  perform public.unlock_object('a_lock_five', current_setting('bench.session_a')::uuid);
end $$;

do $$
declare
  v_granted boolean;
begin
  -- ...and now the other window gets it immediately.
  select k.granted into v_granted
  from public.lock_object('a_lock_five', current_setting('bench.session_a2')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 14: unlock_object() did not free the object';
  end if;

  select k.granted into v_granted
  from public.lock_object('a_lock_six', current_setting('bench.session_a2')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 14: the second window could not hold a second object';
  end if;

  -- Everything this session holds, at once.
  perform public.release_my_locks(current_setting('bench.session_a2')::uuid);
end $$;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.lock_object('a_lock_five', current_setting('bench.session_b')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 14: release_my_locks() left an object held';
  end if;

  select k.granted into v_granted
  from public.lock_object('a_lock_six', current_setting('bench.session_b')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 14: release_my_locks() left a second object held';
  end if;
end $$;

-- ============================================================
-- 14b. A page with no session cannot be taken at its word, and a session that simply holds
--      NOTHING may still save -- it just cannot change, or delete, what somebody else holds.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
begin
  begin
    perform public.save_bench(
      p_data => '{"polygons": []}'::jsonb,
      p_session => null
    );
    raise exception 'FAIL 14b: a save with no session was accepted';
  exception
    when sqlstate 'PT409' then null; -- expected: nothing can be held or saved without a session
  end;
end $$;

-- session_c below is a tab that has never locked anything at all.
do $$
declare
  v_overruled text[];
  v_polygons  jsonb;
  v_name      text;
begin
  v_overruled := public.save_bench(
    p_data => '{"polygons":[
      {"id":"a_lock_one","name":"STALE COPY","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]},
      {"id":"a_lock_seven","name":"New Object","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}
    ]}'::jsonb,
    p_session => current_setting('bench.session_c')::uuid
  );

  -- An object the bench has never seen is nobody else's, so even a lockless session may add it.
  if 'a_lock_seven' = any (v_overruled) then
    raise exception 'FAIL 14b: a brand new object was overruled (%)', v_overruled;
  end if;

  -- An object it does not hold keeps the STORED version, and is named in the reply.
  if not ('a_lock_one' = any (v_overruled)) then
    raise exception 'FAIL 14b: a session holding nothing overwrote an object it does not hold';
  end if;

  select l.data -> 'polygons' into v_polygons from public.layouts l;

  select s ->> 'name' into v_name
  from jsonb_array_elements(v_polygons) s where s ->> 'id' = 'a_lock_one';
  if v_name is distinct from 'Tree A' then
    raise exception 'FAIL 14b: the stored object changed to %', v_name;
  end if;

  -- Nor can it delete one: an object missing from its document is only dropped when that
  -- session holds the object's lock.
  if (select count(*) from jsonb_array_elements(v_polygons) s where s ->> 'id' = 'a_lock_two') <> 1 then
    raise exception 'FAIL 14b: a lockless session deleted an object it does not hold';
  end if;
end $$;

-- ============================================================
-- 14c. Anonymous visitors cannot reach ANY of it -- there is no grant to anon for any door --
--      and the machine underneath (claim_object) is not reachable by a signed-in planner
--      either, so "force" cannot be had without going through take_over_object()'s rules.
-- ============================================================
set local role anon;
do $$
declare
  v_msg text := '';
  v_n   int;
begin
  begin
    select count(*) into v_n
    from public.lock_object('a_lock_one', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached lock_object (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;

  v_msg := '';
  begin
    select count(*) into v_n
    from public.take_over_object('a_lock_one', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached take_over_object (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;

  v_msg := '';
  begin
    perform public.unlock_object('a_lock_one', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached unlock_object (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;

  v_msg := '';
  begin
    perform public.release_my_locks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached release_my_locks (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;

  v_msg := '';
  begin
    perform public.save_bench(
      p_data => '{"polygons": []}'::jsonb,
      p_session => 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    );
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached save_bench (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;

  v_msg := '';
  begin
    select count(*) into v_n from public.open_bench();
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: anon reached open_bench (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;
end $$;
set local role authenticated;

-- The internal machine, this time as a signed-in planner: 008 revokes it from authenticated
-- as well, so the only way to force a lock away is take_over_object().
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_msg text := '';
  v_n   int;
begin
  begin
    select count(*) into v_n
    from public.claim_object('a_lock_one', current_setting('bench.session_a')::uuid, true);
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg not like '%permission denied%' then
    raise exception 'FAIL 14c: a signed-in planner reached claim_object directly (%)',
      coalesce(nullif(v_msg, ''), 'it was allowed');
  end if;
end $$;

-- ============================================================
-- 14d. Setup between sections (no assertion). The lock checks above worked on objects of their
--      own, and a merge deliberately KEEPS objects it was not sent -- so anything they left in
--      the document would ride along in every later save and make those checks assert the
--      wrong thing. The rest of the file is about VALIDATION, not merging, so the owner clears
--      the locks and puts the canvas back to a clean document.
--
--      The document's `view` is seeded with a real HOME view on purpose: no save writes that
--      field any more (007 section 4 -- a planner's camera lives in public.layout_views), so
--      check 17 can only prove that a document comes back unchanged if the home view the save
--      preserves is already the one that check sends.
-- ============================================================
reset role;
delete from public.layout_locks;
update public.layouts
set data = '{
      "view": {"lat": 1.3521, "lng": 103.8198, "zoom": 16},
      "floorPlans": [],
      "polygons": []
    }'::jsonb,
    updated_at = now();
set local role authenticated;

-- ============================================================
-- 15. Malformed layouts are refused
--     Each of these must be rejected BEFORE it reaches the table -- and before the merge, so
--     the session needs to hold no lock at all for this check to mean anything.
-- ============================================================
do $$
declare
  v_session uuid := current_setting('bench.session_a')::uuid;
  v_bad   jsonb;
  v_json  text;
  v_case  text;
begin
  -- A reusable "expect a rejection" pattern.
  --
  -- Every case here fails area_ok() / floor_plan_ok() on a field they actually check. A
  -- floor plan's NAME is deliberately not one of them -- see check 17g, and the note on 17c.
  foreach v_case in array array[
    'kind', 'two_points', 'outside_sg', 'bad_opacity', 'not_a_data_url', 'no_name'
  ] loop
    v_json := case v_case
      when 'kind' then
        '{"polygons":[{"name":"A","kind":"swimming_pool","points":[[1.35,103.82],[1.36,103.83],[1.35,103.83]]}]}'
      when 'two_points' then
        '{"polygons":[{"name":"A","kind":"zone","points":[[1.35,103.82],[1.36,103.83]]}]}'
      when 'outside_sg' then
        '{"polygons":[{"name":"A","kind":"zone","points":[[1.35,103.82],[51.5,-0.12],[1.35,103.83]]}]}'
      when 'bad_opacity' then
        '{"floorPlans":[{"centre":[1.35,103.82],"widthM":10,"heightM":10,"angleDeg":0,"opacity":4,"visible":true,"image":"data:image/png;base64,AA"}]}'
      when 'not_a_data_url' then
        '{"floorPlans":[{"centre":[1.35,103.82],"widthM":10,"heightM":10,"angleDeg":0,"opacity":0.5,"visible":true,"image":"https://example.test/x.png"}]}'
      else -- 'no_name': an AREA must have a name (area_ok checks it; a floor plan's is optional)
        '{"polygons":[{"name":"","kind":"zone","points":[[1.35,103.82],[1.36,103.83],[1.35,103.83]]}]}'
    end;
    v_bad := v_json::jsonb;

    begin
      perform public.save_bench(p_data => v_bad, p_session => v_session);
      raise exception 'FAIL 15: a malformed layout (%) was accepted', v_case;
    exception
      when sqlstate '22023' then null; -- expected: invalid data
    end;
  end loop;
end $$;

-- ============================================================
-- 16. A payload over 4 MB is refused (the image lives in the row, so there has to be a cap)
-- ============================================================
do $$
declare
  v_big jsonb;
begin
  v_big := jsonb_build_object(
    'polygons', '[]'::jsonb,
    'floorPlans', jsonb_build_array(jsonb_build_object(
      'centre', jsonb_build_array(1.3521, 103.8198),
      'widthM', 10, 'heightM', 10, 'angleDeg', 0, 'opacity', 0.5, 'visible', true,
      'image', 'data:image/png;base64,' || repeat('A', 5000000)
    ))
  );

  begin
    perform public.save_bench(
      p_data => v_big,
      p_session => current_setting('bench.session_a')::uuid
    );
    raise exception 'FAIL 16: an oversized layout was accepted';
  exception
    when sqlstate '54000' then null; -- expected: too large
  end;
end $$;

-- ============================================================
-- 17. A valid layout is accepted and comes back unchanged, and the save doubles as a
--     heartbeat for everything the session is holding.
-- ============================================================
do $$
declare
  v_granted boolean;
begin
  select k.granted into v_granted
  from public.lock_object('p1', current_setting('bench.session_a')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 17: A could not lock the floor plan it is about to save';
  end if;
end $$;

-- Age that lock, so the save has something to renew.
reset role;
update public.layout_locks set expires_at = now() + interval '1 second' where object_id = 'p1';
set local role authenticated;

do $$
declare
  v_good jsonb := '{
    "view": {"lat": 1.3521, "lng": 103.8198, "zoom": 16},
    "floorPlans": [{
      "id": "p1", "name": "Level 1", "centre": [1.3521, 103.8198], "widthM": 120, "heightM": 80,
      "angleDeg": 37.5, "opacity": 0.4, "visible": true,
      "image": "data:image/png;base64,iVBORw0KGgo="
    }],
    "polygons": [{
      "id": "a1", "name": "Trees", "kind": "no_go",
      "points": [[1.3521, 103.8198], [1.3524, 103.8201], [1.3521, 103.8204]]
    }]
  }'::jsonb;
  v_saved jsonb;
begin
  perform public.save_bench(
    p_data => v_good,
    p_session => current_setting('bench.session_a')::uuid
  );

  select data into v_saved from public.layouts;

  -- Compared OBJECT BY OBJECT rather than as a whole document. The bench may legitimately hold
  -- objects this test never sent -- the merge keeps whatever the caller does not hold (see check
  -- 10) -- and what this check is about is what happened to the two objects that WERE sent. The
  -- view is left out entirely: 008 never takes the caller's view, because that field is the bench's
  -- home view now (007), so comparing it would only be testing that two unrelated things differ.
  if (select s from jsonb_array_elements(v_saved -> 'floorPlans') s where s ->> 'id' = 'p1')
     is distinct from
     (select s from jsonb_array_elements(v_good -> 'floorPlans') s where s ->> 'id' = 'p1') then
    raise exception 'FAIL 17: the saved floor plan does not match what was sent';
  end if;

  if (select s from jsonb_array_elements(v_saved -> 'polygons') s where s ->> 'id' = 'a1')
     is distinct from
     (select s from jsonb_array_elements(v_good -> 'polygons') s where s ->> 'id' = 'a1') then
    raise exception 'FAIL 17: the saved area does not match what was sent';
  end if;
end $$;

-- Read the lock table as the owner: it has no grants.
reset role;
do $$
declare
  v_expires timestamptz;
begin
  select l.expires_at into v_expires from public.layout_locks l where l.object_id = 'p1';
  if v_expires is null then
    raise exception 'FAIL 17: the session''s lock was gone after saving';
  end if;
  if v_expires < now() + interval '30 seconds' then
    raise exception 'FAIL 17: saving did not renew the lock (expires_at=%)', v_expires;
  end if;
end $$;
set local role authenticated;

-- ============================================================
-- 17b. A JSON null for an optional section means "not provided".
--      The table's own default is {"view": null, "floorPlans": [], "polygons": []}, and
--      `jsonb -> 'view'` gives a JSON null (not SQL NULL) when the key is present and
--      null -- so this used to fail its own check constraint. Keep this check.
-- ============================================================
do $$
begin
  perform public.save_bench(
    p_data => '{"view": null, "floorPlans": null, "polygons": []}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );
end $$;

-- ============================================================
-- 17c. A floor plan saved BEFORE names existed still passes. The name is optional on
--      purpose: the check constraint re-validates every save, so making it required would
--      turn one old row into a bench nobody can ever save again. (008 does require an ID on
--      every shape, because its merge matches objects by id -- so this plan, ancient as it
--      is, carries one.)
-- ============================================================
do $$
begin
  perform public.save_bench(
    p_data => '{"floorPlans":[{"id":"p_old","centre":[1.3521,103.8198],"widthM":120,"heightM":80,"angleDeg":0,"opacity":0.4,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );
end $$;

-- ============================================================
-- 17d. A floor plan whose CENTRE is inside Singapore but whose CORNERS are not is refused.
--      This is what 006_floor_plan_bounds.sql added: before it, only the centre was checked,
--      so a picture could hang kilometres off the edge of the basemap. The centre here is
--      ~1.5 km east of the 103.5 boundary while half the 4 km width is 2 km, so the west
--      corners fall outside.
-- ============================================================
do $$
begin
  begin
    perform public.save_bench(
      p_data => '{"floorPlans":[{"id":"p_out","name":"Level 9","centre":[1.3521,103.5143],"widthM":4000,"heightM":3000,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb,
      p_session => current_setting('bench.session_a')::uuid
    );
    raise exception 'FAIL 17d: a floor plan hanging outside Singapore was accepted';
  exception
    when sqlstate '22023' then null; -- expected: invalid data
  end;
end $$;

-- ============================================================
-- 17e. A large plan that DOES fit is still accepted, and it is accepted while ROTATED --
--      the corner maths has to rotate the offsets, not just add half the width.
-- ============================================================
do $$
begin
  perform public.save_bench(
    p_data => '{"floorPlans":[{"id":"p_ok","name":"Level 1","centre":[1.3521,103.8198],"widthM":2000,"heightM":1500,"angleDeg":45,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );
end $$;

-- ============================================================
-- 17f. layout_problem() explains the refusal, naming the plan, so the page can tell the
--      planner which floor plan to fix rather than "the layout data is not valid".
-- ============================================================
do $$
declare
  v_reason text;
begin
  v_reason := public.layout_problem(
    '{"floorPlans":[{"id":"p_out","name":"Level 9","centre":[1.3521,103.5143],"widthM":4000,"heightM":3000,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb
  );

  if v_reason is null then
    raise exception 'FAIL 17f: layout_problem() found no problem with an out-of-bounds plan';
  end if;
  if v_reason not like 'Level 9:%' then
    raise exception 'FAIL 17f: the reason did not name the plan (%)', v_reason;
  end if;

  -- A good layout has no problem to report.
  if public.layout_problem('{"polygons":[{"id":"a1","name":"Trees","kind":"zone","points":[[1.3521,103.8198],[1.3524,103.8201],[1.3521,103.8204]]}]}'::jsonb) is not null then
    raise exception 'FAIL 17f: layout_problem() reported a problem with a valid layout';
  end if;
end $$;

-- ============================================================
-- 17g. A floor plan with an EMPTY name is accepted, deliberately.
--
--      This is the closest call in the file and it is worth spelling out. A validator
--      naturally wants to require a non-empty name, and an earlier version of check 15
--      asserted exactly that for floor plans. It is wrong, for the same reason 17c gives:
--      the constraint re-validates the WHOLE document on every write, so the moment a name
--      is required, ONE plan without one makes the bench impossible to save ever again.
--      An AREA still needs a name (area_ok checks it, and check 15's 'no_name' case proves
--      it); a floor plan does not. The list falls back to "Floor plan 2" via planLabel().
-- ============================================================
do $$
begin
  perform public.save_bench(
    p_data => '{"floorPlans":[{"id":"p_noname","name":"","centre":[1.3521,103.8198],"widthM":100,"heightM":80,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb,
    p_session => current_setting('bench.session_a')::uuid
  );
end $$;

-- ============================================================
-- 18. Presence: I can announce myself, and the row tells the TRUTH about me rather than
--     whatever I sent.
--
--     The insert deliberately lies about both fields the trigger owns -- the name and the
--     clock -- so this proves they are overwritten rather than merely defaulted. A presence
--     row is what every other planner draws a name from, so a client that could set either
--     one could impersonate somebody else, or look busy while it was gone.
-- ============================================================
do $$
declare
  v_pid uuid := '33333333-3333-3333-3333-333333333333';
  v_row public.layout_presence;
begin
  insert into public.layout_presence (presence_id, layout_id, display_name, last_seen)
  values (v_pid, current_setting('bench.id')::uuid, 'Bench Test B', now() - interval '1 hour');

  select * into v_row from public.layout_presence where presence_id = v_pid;

  if v_row.user_id <> '11111111-1111-1111-1111-111111111111' then
    raise exception 'FAIL 18: the row was filed under %, not the session user', v_row.user_id;
  end if;
  if v_row.display_name <> 'Bench Test A' then
    raise exception 'FAIL 18: I announced myself as %', v_row.display_name;
  end if;
  if v_row.last_seen < now() - interval '1 minute' then
    raise exception 'FAIL 18: last_seen was left at the value I sent (%)', v_row.last_seen;
  end if;

  perform set_config('bench.presence_a', v_pid::text, true);
end $$;

-- ============================================================
-- 19. I cannot announce myself as somebody else
-- ============================================================
do $$
declare
  v_blocked boolean := false;
  v_msg text := '';
begin
  begin
    insert into public.layout_presence (presence_id, layout_id, user_id)
    values ('44444444-4444-4444-4444-444444444444', current_setting('bench.id')::uuid,
            '22222222-2222-2222-2222-222222222222');
  exception when others then
    v_blocked := true;
    v_msg := sqlerrm;
  end;

  if not v_blocked then
    raise exception 'FAIL 19: I announced myself as another planner';
  end if;
  -- Named, so this cannot pass by failing for some other reason.
  if v_msg not like '%row-level security%' then
    raise exception 'FAIL 19: the insert was refused, but not by RLS (%)', v_msg;
  end if;
end $$;

-- ============================================================
-- 20. I cannot touch somebody else's row -- and the ghost-sweeping policy does not quietly
--     turn a LIVE row into one I may delete. That second half is the point of the check: the
--     sweep exists so abandoned tabs do not haunt the bench for ever, and it would be a
--     disaster if it also let anyone clear a planner who is sitting right there.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_rows int;
  v_kept int;
begin
  update public.layout_presence set selected_object_id = '55555555-5555-5555-5555-555555555555'
  where presence_id = current_setting('bench.presence_a')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL 20: I changed somebody else''s presence row (% rows)', v_rows;
  end if;

  delete from public.layout_presence where presence_id = current_setting('bench.presence_a')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL 20: I deleted a live presence row that was not mine (% rows)', v_rows;
  end if;

  -- Reading it, on the other hand, is exactly what presence is for.
  select count(*) into v_kept from public.layout_presence
  where presence_id = current_setting('bench.presence_a')::uuid;
  if v_kept <> 1 then
    raise exception 'FAIL 20: another planner''s presence row was not visible to me';
  end if;
end $$;

-- ============================================================
-- 21. I can renew my own row -- and renewing still cannot rename me
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_row public.layout_presence;
begin
  update public.layout_presence
  set selected_object_id = '55555555-5555-5555-5555-555555555555', display_name = 'Not My Name'
  where presence_id = current_setting('bench.presence_a')::uuid;

  select * into v_row from public.layout_presence
  where presence_id = current_setting('bench.presence_a')::uuid;

  if v_row.selected_object_id <> '55555555-5555-5555-5555-555555555555' then
    raise exception 'FAIL 21: my own selection did not stick';
  end if;
  if v_row.display_name <> 'Bench Test A' then
    raise exception 'FAIL 21: an update renamed me to %', v_row.display_name;
  end if;
end $$;

-- ============================================================
-- 22. A ghost can be cleared by anyone, so an abandoned tab does not stay on the bench for
--     ever without a cron job to sweep it.
--
--     The trigger rewrites last_seen on every write -- which is the point of it (check 18) --
--     so the only way to build a ghost in a test is to stop the trigger, age the row, and
--     start it again. Worth noticing what that implies: the sweep can only ever see rows that
--     REAL TIME has aged, which is exactly what it is for.
-- ============================================================
reset role;
alter table public.layout_presence disable trigger layout_presence_truthful;
update public.layout_presence set last_seen = now() - interval '10 minutes'
where presence_id = current_setting('bench.presence_a')::uuid;
alter table public.layout_presence enable trigger layout_presence_truthful;
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

do $$
declare
  v_rows int;
begin
  delete from public.layout_presence where presence_id = current_setting('bench.presence_a')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'FAIL 22: a ghost was not clearable by another planner (% rows)', v_rows;
  end if;
end $$;

-- ============================================================
-- 23. My view is MINE: invisible to others rather than merely read-only, impossible to file
--     under somebody else's name, and held to the same Singapore rule 005 applies to the view
--     inside the canvas.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_rows int;
begin
  insert into public.layout_views (layout_id, lat, lng, zoom)
  values (current_setting('bench.id')::uuid, 1.3521, 103.8198, 18);

  select count(*) into v_rows from public.layout_views;
  if v_rows <> 1 then
    raise exception 'FAIL 23: I stored % view rows, expected 1', v_rows;
  end if;

  begin
    update public.layout_views set lat = 3.1; -- Kuala Lumpur is not on this basemap
    raise exception 'FAIL 23: a view outside Singapore was accepted';
  exception when check_violation then null; -- expected
  end;

  begin
    update public.layout_views set zoom = 40;
    raise exception 'FAIL 23: an impossible zoom was accepted';
  exception when check_violation then null; -- expected
  end;
end $$;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_rows int;
  v_blocked boolean := false;
begin
  select count(*) into v_rows from public.layout_views;
  if v_rows <> 0 then
    raise exception 'FAIL 23: I can see another planner''s camera (% rows)', v_rows;
  end if;

  begin
    insert into public.layout_views (layout_id, user_id, lat, lng, zoom)
    values (current_setting('bench.id')::uuid, '11111111-1111-1111-1111-111111111111',
            1.3521, 103.8198, 18);
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL 23: I stored a view under somebody else''s name';
  end if;

  update public.layout_views set zoom = 12;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL 23: I moved another planner''s camera (% rows)', v_rows;
  end if;
end $$;

-- ============================================================
-- 23b. Anonymous visitors cannot reach either table AT ALL -- and the way that is refused is
--      deliberately different from public.layouts. There, anon holds SELECT and RLS hides the
--      rows, so the answer is an empty result (check 5). Here the GRANT is gone as well, so
--      the answer is a permission error. Both are shut; this proves which kind of shut, which
--      is the part a future migration could accidentally change.
-- ============================================================
set local role anon;
do $$
declare
  v_blocked boolean := false;
begin
  begin
    perform count(*) from public.layout_presence;
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL 23b: anon could read presence';
  end if;

  v_blocked := false;
  begin
    perform count(*) from public.layout_views;
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL 23b: anon could read the views';
  end if;
end $$;
set local role authenticated;

-- ============================================================
-- 24. Deleting the bench takes the locks, the presence rows and the views with it (on delete
--     cascade). Worth checking rather than assuming: a lock, a ghost or a camera left behind
--     by a bench that no longer exists would look authoritative for ever.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_granted boolean;
begin
  insert into public.layout_presence (presence_id, layout_id)
  values ('66666666-6666-6666-6666-666666666666', current_setting('bench.id')::uuid);

  -- Check 23 already left a view row for me, so this is the ordinary "I panned again" write:
  -- an upsert on the pair that identifies it. Use the same shape the page uses, or this check
  -- would be testing a statement the app never issues.
  insert into public.layout_views (layout_id, lat, lng, zoom)
  values (current_setting('bench.id')::uuid, 1.3521, 103.8198, 19)
  on conflict (layout_id, user_id) do update
    set lat = excluded.lat, lng = excluded.lng, zoom = excluded.zoom;

  -- An object lock as well, so the count below cannot pass merely because nothing was held.
  -- The table has no grants, so the only way to make one is through the function.
  select k.granted into v_granted
  from public.lock_object('cascade_lock', current_setting('bench.session_a')::uuid) as k;
  if not v_granted then
    raise exception 'FAIL 24: A could not hold an object before the bench was deleted';
  end if;
end $$;

reset role;
delete from public.layouts;

do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.layout_locks;
  if v_rows <> 0 then
    raise exception 'FAIL 24: % lock rows survived the bench', v_rows;
  end if;

  select count(*) into v_rows from public.layout_presence;
  if v_rows <> 0 then
    raise exception 'FAIL 24: % presence rows survived the bench', v_rows;
  end if;

  select count(*) into v_rows from public.layout_views;
  if v_rows <> 0 then
    raise exception 'FAIL 24: % view rows survived the bench', v_rows;
  end if;
end $$;

-- Nothing is kept.
rollback;

do $$ begin
  raise notice 'All checks passed. Nothing was left behind.';
end $$;
