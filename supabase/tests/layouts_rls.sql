-- ============================================================
-- Tests for 005_layouts.sql
--
-- Run in the Supabase SQL Editor (or with psql) AFTER the migration is applied.
-- Everything happens inside ONE transaction that ends in ROLLBACK, so nothing is left
-- behind -- the test users, the bench row and the claim all disappear.
--
-- Each check raises 'FAIL: ...' if it does not hold, which aborts the transaction and
-- names the check that broke. A clean run prints the success notice at the end.
--
-- Identity is switched with `set local request.jwt.claims`, which is what auth.uid()
-- reads. Only two roles are used: `authenticated` (for everything) and `anon` (to prove
-- the bench is not public). Owner-only steps use `reset role`.
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
-- 6. There are no insert/update policies -- a direct write is refused
-- ============================================================
do $$
declare
  v_blocked boolean := false;
begin
  begin
    insert into public.layout_claims (layout_id, user_id)
    values (current_setting('bench.id')::uuid, '11111111-1111-1111-1111-111111111111');
  exception when others then
    v_blocked := true;
  end;

  if not v_blocked then
    raise exception 'FAIL 6: a direct insert into layout_claims was allowed';
  end if;
end $$;

-- ============================================================
-- 7. A claims the bench and gets a token
-- ============================================================
do $$
declare
  v_granted boolean;
  v_token   uuid;
  v_held_by text;
begin
  select granted, token, held_by into v_granted, v_token, v_held_by from public.claim_bench();

  if not v_granted or v_token is null then
    raise exception 'FAIL 7: the first claim was refused (held_by=%)', v_held_by;
  end if;

  perform set_config('bench.token_a', v_token::text, true);
end $$;

-- ============================================================
-- 8. Renewing keeps MY token (so a heartbeat does not invalidate my own session)
-- ============================================================
do $$
declare
  v_token uuid;
begin
  select token into v_token from public.claim_bench();
  if v_token::text <> current_setting('bench.token_a') then
    raise exception 'FAIL 8: renewing changed my own token (% -> %)',
      current_setting('bench.token_a'), v_token;
  end if;
end $$;

-- ============================================================
-- 9. B is refused while A holds a live claim, and is told who holds it
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
declare
  v_granted boolean;
  v_token   uuid;
  v_held_by text;
begin
  select granted, token, held_by into v_granted, v_token, v_held_by from public.claim_bench();

  if v_granted then
    raise exception 'FAIL 9: two people claimed the bench at once';
  end if;
  if v_held_by is distinct from 'Bench Test A' then
    raise exception 'FAIL 9: held_by was %, expected Bench Test A', coalesce(v_held_by, '<null>');
  end if;
end $$;

-- ============================================================
-- 10. B cannot save with A's token
-- ============================================================
do $$
begin
  begin
    perform public.save_bench(
      current_setting('bench.token_a')::uuid,
      '{"polygons": []}'::jsonb
    );
    raise exception 'FAIL 10: a save with someone else''s token was accepted';
  exception
    when sqlstate 'PT409' then null; -- expected
  end;
end $$;

-- ============================================================
-- 11. After a claim goes silent for 5 minutes, someone else can take it over
-- ============================================================
reset role;
update public.layout_claims set expires_at = now() - interval '1 minute';
set local role authenticated;

do $$
declare
  v_granted boolean;
  v_token   uuid;
begin
  select granted, token into v_granted, v_token from public.claim_bench();

  if not v_granted or v_token is null then
    raise exception 'FAIL 11: an expired claim could not be taken over';
  end if;
  if v_token::text = current_setting('bench.token_a') then
    raise exception 'FAIL 11: the takeover reused the old token';
  end if;

  perform set_config('bench.token_b', v_token::text, true);
end $$;

-- ============================================================
-- 12. A's old token is now worthless -- the whole point of the token
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
begin
  begin
    perform public.save_bench(
      current_setting('bench.token_a')::uuid,
      '{"polygons": []}'::jsonb
    );
    raise exception 'FAIL 12: a stale token was obeyed';
  exception
    when sqlstate 'PT409' then null; -- expected
  end;
end $$;

-- ============================================================
-- 13. A is now refused as well, and told that B has it
-- ============================================================
do $$
declare
  v_granted boolean;
  v_held_by text;
begin
  select granted, held_by into v_granted, v_held_by from public.claim_bench();
  if v_granted then
    raise exception 'FAIL 13: A reclaimed a bench that B holds';
  end if;
  if v_held_by is distinct from 'Bench Test B' then
    raise exception 'FAIL 13: held_by was %, expected Bench Test B', coalesce(v_held_by, '<null>');
  end if;
end $$;

-- ============================================================
-- 14. Releasing frees the bench immediately, without waiting out the 5 minutes
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
do $$
begin
  perform public.release_bench(current_setting('bench.token_b')::uuid);
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
declare
  v_granted boolean;
  v_token   uuid;
begin
  select granted, token into v_granted, v_token from public.claim_bench();
  if not v_granted then
    raise exception 'FAIL 14: the bench was still locked after release_bench()';
  end if;
  perform set_config('bench.token_a', v_token::text, true);
end $$;

-- ============================================================
-- 15. Malformed layouts are refused
--     Each of these must be rejected BEFORE it reaches the table.
-- ============================================================
do $$
declare
  v_token uuid := current_setting('bench.token_a')::uuid;
  v_bad   jsonb;
  v_json  text;
  v_case  text;
begin
  -- A reusable "expect a rejection" pattern.
  foreach v_case in array array[
    'kind', 'two_points', 'outside_sg', 'bad_opacity', 'not_a_data_url', 'no_name',
    'empty_plan_name'
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
      when 'empty_plan_name' then
        '{"floorPlans":[{"name":"","centre":[1.35,103.82],"widthM":10,"heightM":10,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,AA"}]}'
      else -- 'no_name'
        '{"polygons":[{"name":"","kind":"zone","points":[[1.35,103.82],[1.36,103.83],[1.35,103.83]]}]}'
    end;
    v_bad := v_json::jsonb;

    begin
      perform public.save_bench(v_token, v_bad);
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
    perform public.save_bench(current_setting('bench.token_a')::uuid, v_big);
    raise exception 'FAIL 16: an oversized layout was accepted';
  exception
    when sqlstate '54000' then null; -- expected: too large
  end;
end $$;

-- ============================================================
-- 17. A valid layout is accepted and comes back unchanged
-- ============================================================
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
  perform public.save_bench(current_setting('bench.token_a')::uuid, v_good);

  select data into v_saved from public.layouts;

  if v_saved is distinct from v_good then
    raise exception 'FAIL 17: the saved layout does not match what was sent';
  end if;

  -- A save must also act as a heartbeat.
  if (select expires_at from public.layout_claims) < now() + interval '4 minutes' then
    raise exception 'FAIL 17: saving did not renew the claim';
  end if;
end $$;

-- ============================================================
-- 17b. A JSON null for an optional section means "not provided".
--      The table's own default is {"view": null, "floorPlans": [], "polygons": []}, and
--      `jsonb -> 'view'` gives a JSON null (not SQL NULL) when the key is present and
--      null -- so this used to fail its own check constraint. Keep this check.
-- ============================================================
do $$
begin
  perform public.save_bench(
    current_setting('bench.token_a')::uuid,
    '{"view": null, "floorPlans": null, "polygons": []}'::jsonb
  );
end $$;

-- ============================================================
-- 17c. A floor plan saved BEFORE names existed still passes. The name is optional on
--      purpose: the check constraint re-validates every save, so making it required would
--      turn one old row into a bench nobody can ever save again.
-- ============================================================
do $$
begin
  perform public.save_bench(
    current_setting('bench.token_a')::uuid,
    '{"floorPlans":[{"centre":[1.3521,103.8198],"widthM":120,"heightM":80,"angleDeg":0,"opacity":0.4,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb
  );
end $$;

-- ============================================================
-- 18. Deleting the bench takes its claim with it (on delete cascade)
-- ============================================================
reset role;
delete from public.layouts;

do $$
declare
  v_claims int;
begin
  select count(*) into v_claims from public.layout_claims;
  if v_claims <> 0 then
    raise exception 'FAIL 18: the claim row survived the bench (% rows)', v_claims;
  end if;
end $$;

-- Nothing is kept.
rollback;

do $$ begin
  raise notice 'All checks passed. Nothing was left behind.';
end $$;
