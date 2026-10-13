-- ============================================================
-- Tests for the bench schema: 005_layouts.sql, 006_floor_plan_bounds.sql and
-- 007_presence_and_views.sql
--
-- Run in the Supabase SQL Editor (or with psql) AFTER those migrations are applied.
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
      current_setting('bench.token_a')::uuid,
      '{"floorPlans":[{"id":"p_out","name":"Level 9","centre":[1.3521,103.5143],"widthM":4000,"heightM":3000,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb
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
    current_setting('bench.token_a')::uuid,
    '{"floorPlans":[{"id":"p_ok","name":"Level 1","centre":[1.3521,103.8198],"widthM":2000,"heightM":1500,"angleDeg":45,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb
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
    current_setting('bench.token_a')::uuid,
    '{"floorPlans":[{"id":"p_noname","name":"","centre":[1.3521,103.8198],"widthM":100,"heightM":80,"angleDeg":0,"opacity":0.5,"visible":true,"image":"data:image/png;base64,iVBORw0KGgo="}]}'::jsonb
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
-- 24. Deleting the bench takes the claim, the presence rows and the views with it
--     (on delete cascade). Worth checking rather than assuming: a lock, a ghost or a camera
--     left behind by a bench that no longer exists would look authoritative for ever.
-- ============================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
do $$
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
end $$;

reset role;
delete from public.layouts;

do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.layout_claims;
  if v_rows <> 0 then
    raise exception 'FAIL 24: the claim row survived the bench (% rows)', v_rows;
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
