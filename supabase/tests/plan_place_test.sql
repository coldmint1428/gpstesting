-- ============================================================
-- Tests for 082_frame_place.sql: a badge is written on its own, against a hold on it.
--
-- Run in the Supabase SQL Editor AFTER 082, or locally with `node tools/pgtest.mjs plan-place`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
--
-- WHY THIS RUNS AS THE CONNECTION USER, and how it drives identity: 082's doors are `security definer` and
-- decide who the caller is from auth.uid() -- the JWT claim, not the SQL role -- so the suite sets the claim
-- (`pg_temp.zz_as`) and stays the connection user. That is what lets it age a hold by hand to test the lapsed
-- and stolen cases, and read plan_positions to see what a refused call did NOT write. The last section switches
-- to the real `authenticated` role to check the grants the app actually has.
-- ============================================================
begin;

create function pg_temp.zz_refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

-- R root, P planner (Priya), Q planner (Daniel), M participant; O is in another event.
insert into auth.users (id, email, raw_user_meta_data) values
  ('82000000-0000-0000-0000-000000000001', 'pl2-r@example.test', '{"username":"pl2_r","display_name":"Rita Root"}'),
  ('82000000-0000-0000-0000-000000000002', 'pl2-p@example.test', '{"username":"pl2_p","display_name":"Priya Planner"}'),
  ('82000000-0000-0000-0000-000000000003', 'pl2-q@example.test', '{"username":"pl2_q","display_name":"Daniel Planner"}'),
  ('82000000-0000-0000-0000-000000000004', 'pl2-m@example.test', '{"username":"pl2_m","display_name":"Mira Member"}'),
  ('82000000-0000-0000-0000-000000000005', 'pl2-o@example.test', '{"username":"pl2_o","display_name":"Oscar Other"}');
insert into public.events (id, name, created_by) values
  ('82000000-0000-0000-0000-0000000000e1', 'Place test', '82000000-0000-0000-0000-000000000001'),
  ('82000000-0000-0000-0000-0000000000e2', 'Other event', '82000000-0000-0000-0000-000000000005');
insert into public.event_roles (event_id, user_id, role) values
  ('82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-000000000001', 'root'),
  ('82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-000000000002', 'planner'),
  ('82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-000000000003', 'planner'),
  ('82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-000000000004', 'participant'),
  ('82000000-0000-0000-0000-0000000000e2', '82000000-0000-0000-0000-000000000005', 'root');
insert into public.groups (id, event_id, name) values
  ('82000000-0000-0000-0000-0000000000a1', '82000000-0000-0000-0000-0000000000e1', 'Gate Crew'),
  ('82000000-0000-0000-0000-0000000000a2', '82000000-0000-0000-0000-0000000000e1', 'Stage'),
  ('82000000-0000-0000-0000-0000000000a3', '82000000-0000-0000-0000-0000000000e2', 'Elsewhere');

insert into public.plans (id, event_id, name, created_by) values
  ('82000000-0000-0000-0000-0000000000b1', '82000000-0000-0000-0000-0000000000e1', 'Show night',
   '82000000-0000-0000-0000-000000000001'),
  ('82000000-0000-0000-0000-0000000000b2', '82000000-0000-0000-0000-0000000000e1', 'Rehearsal',
   '82000000-0000-0000-0000-000000000001');
insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
  ('82000000-0000-0000-0000-0000000000f1', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', 60, '82000000-0000-0000-0000-000000000001'),
  ('82000000-0000-0000-0000-0000000000f2', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', 120, '82000000-0000-0000-0000-000000000001'),
  ('82000000-0000-0000-0000-0000000000f3', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', 180, '82000000-0000-0000-0000-000000000001'),
  -- a frame of the OTHER plan, for "that frame is not in this plan"
  ('82000000-0000-0000-0000-0000000000f9', '82000000-0000-0000-0000-0000000000b2',
   '82000000-0000-0000-0000-0000000000e1', 60, '82000000-0000-0000-0000-000000000001');
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('82000000-0000-0000-0000-0000000000f1', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('82000000-0000-0000-0000-0000000000f1', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-0000000000a2', 1.31, 103.81),
  ('82000000-0000-0000-0000-0000000000f2', '82000000-0000-0000-0000-0000000000b1',
   '82000000-0000-0000-0000-0000000000e1', '82000000-0000-0000-0000-0000000000a1', 1.30, 103.80);

do $t$
declare
  v_plan constant uuid := '82000000-0000-0000-0000-0000000000b1';
  v_f1 constant uuid := '82000000-0000-0000-0000-0000000000f1';
  v_f2 constant uuid := '82000000-0000-0000-0000-0000000000f2';
  v_f3 constant uuid := '82000000-0000-0000-0000-0000000000f3';
  v_f9 constant uuid := '82000000-0000-0000-0000-0000000000f9';
  v_a1 constant uuid := '82000000-0000-0000-0000-0000000000a1';
  v_a2 constant uuid := '82000000-0000-0000-0000-0000000000a2';
  v_a3 constant uuid := '82000000-0000-0000-0000-0000000000a3';
  v_p constant uuid := '82000000-0000-0000-0000-000000000002';
  v_q constant uuid := '82000000-0000-0000-0000-000000000003';
  v_m constant uuid := '82000000-0000-0000-0000-000000000004';
  v_o constant uuid := '82000000-0000-0000-0000-000000000005';
  -- three page-loads: Priya's tab, Daniel's tab, and Priya's OTHER tab
  v_s_p constant uuid := '82100000-0000-0000-0000-000000000001';
  v_s_q constant uuid := '82100000-0000-0000-0000-000000000002';
  v_s_p2 constant uuid := '82100000-0000-0000-0000-000000000003';
  v_one jsonb;
  v_two jsonb;
  v_three jsonb;
  v_msg text;
  v_lat float8;
  v_lng float8;
  v_state text;
  v_verify text;
  v_rev integer;
  v_new_rev integer;
  v_updated timestamptz;
  v_frame uuid;
  v_count integer;
  v_sig text;
begin
  -- The list 082's doors take: {frame, group, lat, lng, state?, verify?}.
  v_one := jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1, 'lat', 2.0, 'lng', 104.0));
  v_two := jsonb_build_array(
             jsonb_build_object('frame', v_f1, 'group', v_a1, 'lat', 3.0, 'lng', 105.0),
             jsonb_build_object('frame', v_f1, 'group', v_a2, 'lat', 3.1, 'lng', 105.1));
  v_three := jsonb_build_array(
             jsonb_build_object('frame', v_f1, 'group', v_a1, 'lat', 5.0, 'lng', 106.0),
             jsonb_build_object('frame', v_f1, 'group', v_a2, 'lat', 5.1, 'lng', 106.1),
             jsonb_build_object('frame', v_f2, 'group', v_a1, 'lat', 5.2, 'lng', 106.2));

  -- ---------- 1. Only a planner or the root may write anything ----------
  perform pg_temp.zz_as(v_m::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 1.0, 103.0)',
                                     v_plan, v_f1, v_a1, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1a: a participant was not refused (got %)', v_msg;
  end if;

  perform pg_temp.zz_as(v_o::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 1.0, 103.0)',
                                     v_plan, v_f1, v_a1, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1b: someone from another event was not refused (got %)', v_msg;
  end if;

  -- ---------- 2. A write with no hold on the badge is refused, and writes nothing ----------
  perform pg_temp.zz_as(v_p::text);
  update public.plans set updated_at = now() - interval '1 hour' where id = v_plan;
  v_updated := (select p.updated_at from public.plans p where p.id = v_plan);

  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 2.0, 104.0)',
                                     v_plan, v_f1, v_a1, v_s_p));
  if v_msg not like 'PT423|%stopped being yours%' then
    raise exception 'FAIL 2a: an unheld write was not refused as one (got %)', v_msg;
  end if;
  select p.lat, p.lng into v_lat, v_lng from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat <> 1.30 or v_lng <> 103.80 then
    raise exception 'FAIL 2b: a refused write moved the badge (%, %)', v_lat, v_lng;
  end if;
  if (select p.updated_at from public.plans p where p.id = v_plan) <> v_updated then
    raise exception 'FAIL 2c: a refused write touched the plan';
  end if;

  -- ---------- 3. Held, it writes exactly that cell ----------
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.plan_lock_cells(v_plan, v_one, v_s_p, false);
  perform public.frame_place_many(v_plan, v_one, v_s_p);

  select p.lat, p.lng into v_lat, v_lng from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat <> 2.0 or v_lng <> 104.0 then
    raise exception 'FAIL 3a: the badge did not move (%, %)', v_lat, v_lng;
  end if;
  -- the other badge on the frame, which the old payload carried back
  select p.lat, p.lng into v_lat, v_lng from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a2;
  if v_lat <> 1.31 or v_lng <> 103.81 then
    raise exception 'FAIL 3b: writing one badge moved another (%, %)', v_lat, v_lng;
  end if;
  select f.rev into v_new_rev from public.plan_frames f where f.id = v_f1;
  if v_new_rev <> v_rev then
    raise exception 'FAIL 3c: a badge move bumped the frame revision (% -> %)', v_rev, v_new_rev;
  end if;
  if (select p.updated_at from public.plans p where p.id = v_plan) <= v_updated then
    raise exception 'FAIL 3d: a badge move did not touch the plan';
  end if;

  -- ---------- 4. An omitted flag means "as it was" (046's rule, kept by the one writer) ----------
  perform public.frame_place(v_plan, v_f1, v_a1, v_s_p, 2.5, 104.5, 'off_site', 'manual');
  select p.state, p.verify into v_state, v_verify from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 4a: the flags were not written (%, %)', v_state, v_verify;
  end if;
  -- the drag sends a coordinate and nothing else
  perform public.frame_place(v_plan, v_f1, v_a1, v_s_p, 2.6, 104.6);
  select p.state, p.verify, p.lat into v_state, v_verify, v_lat
    from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_state <> 'off_site' or v_verify <> 'manual' or v_lat <> 2.6 then
    raise exception 'FAIL 4b: a drag put an off-site group back, or reset its trust (%, %, %)', v_state, v_verify, v_lat;
  end if;

  -- ---------- 5. A badge the frame only inherited gains a row, with the defaults ----------
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f2, 'group', v_a2)), v_s_p, false);
  perform public.frame_place(v_plan, v_f2, v_a2, v_s_p, 1.32, 103.82);
  select p.state, p.verify into v_state, v_verify from public.plan_positions p where p.frame_id = v_f2 and p.group_id = v_a2;
  if v_state <> 'on_site' or v_verify <> 'auto' then
    raise exception 'FAIL 5: a new row did not take the defaults (%, %)', v_state, v_verify;
  end if;

  -- ---------- 6. The words are named, and a place is checked ----------
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 2.0, 104.0, %L)',
                                     v_plan, v_f1, v_a1, v_s_p, 'nowhere'));
  if v_msg not like '22023|%either on site or off site%' then
    raise exception 'FAIL 6a: a bad state was not named (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 2.0, 104.0, null, %L)',
                                     v_plan, v_f1, v_a1, v_s_p, 'maybe'));
  if v_msg not like '22023|%automatically or by hand%' then
    raise exception 'FAIL 6b: a bad verify was not named (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, null, 104.0)',
                                     v_plan, v_f1, v_a1, v_s_p));
  if v_msg not like '22023|%needs a place on the map%' then
    raise exception 'FAIL 6c: a missing place was not named (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 120.0, 104.0)',
                                     v_plan, v_f1, v_a1, v_s_p));
  if v_msg not like '22023|%not a place on the map%' then
    raise exception 'FAIL 6d: an impossible latitude was not refused (got %)', v_msg;
  end if;

  -- ---------- 7. A frame of another plan, and a group of another event ----------
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 2.0, 104.0)',
                                     v_plan, v_f9, v_a1, v_s_p));
  if v_msg not like '42501|%not in this plan%' then
    raise exception 'FAIL 7a: another plan''s frame was accepted (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 2.0, 104.0)',
                                     v_plan, v_f1, v_a3, v_s_p));
  if v_msg not like '42501|%belongs to another event%' then
    raise exception 'FAIL 7b: another event''s group was accepted (got %)', v_msg;
  end if;

  -- ---------- 8. The list itself ----------
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)', v_plan, '[]', v_s_p));
  if v_msg not like '22023|%at least one badge%' then
    raise exception 'FAIL 8a: an empty list was accepted (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)',
                                     v_plan, jsonb_build_object('frame', v_f1), v_s_p));
  if v_msg not like '22023|%Name the badges as a list%' then
    raise exception 'FAIL 8b: an object was accepted as a list (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)',
                                     v_plan, jsonb_build_array(jsonb_build_object('frame', 'nope', 'group', v_a1,
                                                                                  'lat', 1.0, 'lng', 103.0)),
                                     v_s_p));
  if v_msg not like '22023|%not a badge on this board%' then
    raise exception 'FAIL 8c: a bad id was not named (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)',
                                     v_plan, jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1,
                                                                                  'lng', 103.0)),
                                     v_s_p));
  if v_msg not like '22023|%needs a place on the map%' then
    raise exception 'FAIL 8d: a list entry with no latitude was accepted (got %)', v_msg;
  end if;

  -- ---------- 9. A gesture is all or nothing ----------
  -- Priya holds Gate Crew; Daniel holds Stage. Her gesture names both.
  perform public.plan_release_all(v_s_p, v_plan);
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a2)), v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1)), v_s_p, false);

  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)', v_plan, v_two, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner% is editing Stage at +1:00%' then
    raise exception 'FAIL 9a: the refusal did not name the holder (got %)', v_msg;
  end if;
  select p.lat, p.lng into v_lat, v_lng from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat <> 2.6 or v_lng <> 104.6 then
    raise exception 'FAIL 9b: the first badge of a refused gesture was written (%, %)', v_lat, v_lng;
  end if;

  -- ---------- 10. My own other window is named as mine, not as somebody else ----------
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_release_all(v_s_p, v_plan);
  perform public.plan_lock_cells(v_plan, v_one, v_s_p2, false);
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)', v_plan, v_one, v_s_p));
  if v_msg not like 'PT423|%open in another of your windows (Gate Crew, +1:00)%' then
    raise exception 'FAIL 10: my own other window was not recognised (got %)', v_msg;
  end if;

  -- ---------- 11. A hold that lapsed is "try again", not a name ----------
  perform public.plan_release_all(v_s_p2, v_plan);
  perform public.plan_lock_cells(v_plan, v_one, v_s_p, false);
  update public.plan_cell_locks set last_seen = now() - interval '8 seconds' where session_id = v_s_p;
  v_msg := pg_temp.zz_refused(format('select public.frame_place_many(%L, %L::jsonb, %L)', v_plan, v_one, v_s_p));
  if v_msg not like 'PT423|%stopped being yours%' then
    raise exception 'FAIL 11: a lapsed hold was not told to try again (got %)', v_msg;
  end if;

  -- ---------- 12. A gesture that is all mine goes through, and takes all of it ----------
  perform public.plan_lock_cells(v_plan, v_three, v_s_p, true);
  select public.frame_place_many(v_plan, v_three, v_s_p) into v_count;
  if v_count <> 3 then
    raise exception 'FAIL 12a: the gesture reported % written, not 3', v_count;
  end if;
  select count(*) into v_count from public.plan_positions p
   where (p.frame_id, p.group_id) in ((v_f1, v_a1), (v_f1, v_a2), (v_f2, v_a1)) and p.lat in (5.0, 5.1, 5.2);
  if v_count <> 3 then
    raise exception 'FAIL 12b: % of the three cells were written', v_count;
  end if;

  -- ---------- 13. A frame that already exists refuses a payload ----------
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  v_msg := pg_temp.zz_refused(format(
    'select public.frame_save(%L, %L::jsonb)', v_plan,
    jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev,
                       'positions', jsonb_build_object(v_a1::text, jsonb_build_object('lat', 9.0, 'lng', 109.0)))));
  if v_msg not like '22023|%edited one at a time%' then
    raise exception 'FAIL 13a: a whole-map payload was accepted (got %)', v_msg;
  end if;
  select p.lat into v_lat from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat <> 5.0 then
    raise exception 'FAIL 13b: a refused whole-map payload wrote a position (%)', v_lat;
  end if;

  -- ---------- 14. A frame this call creates takes its first cells (the import path, 059) ----------
  v_frame := (select f.id from public.frame_save(v_plan, jsonb_build_object(
    't_s', 300,
    'note', 'Doors',
    'positions', jsonb_build_object(v_a1::text, jsonb_build_object('lat', 1.40, 'lng', 103.90),
                                    v_a2::text, jsonb_build_object('lat', 1.41, 'lng', 103.91,
                                                                   'state', 'off_site')))) f);
  if v_frame is null then
    raise exception 'FAIL 14a: creating a frame with its badges returned nothing';
  end if;
  select count(*) into v_count from public.plan_positions p where p.frame_id = v_frame;
  if v_count <> 2 then
    raise exception 'FAIL 14b: the new frame states % groups, not 2', v_count;
  end if;
  select p.state into v_state from public.plan_positions p where p.frame_id = v_frame and p.group_id = v_a2;
  if v_state <> 'off_site' then
    raise exception 'FAIL 14c: the new frame dropped a flag (%)', v_state;
  end if;

  -- ...and a create that names a group of another event leaves no frame behind
  v_msg := pg_temp.zz_refused(format(
    'select public.frame_save(%L, %L::jsonb)', v_plan,
    jsonb_build_object('t_s', 360,
                       'positions', jsonb_build_object(v_a3::text, jsonb_build_object('lat', 1.0, 'lng', 103.0)))));
  if v_msg not like '42501|%belongs to another event%' then
    raise exception 'FAIL 14d: a bad group in a new frame was accepted (got %)', v_msg;
  end if;
  if exists (select 1 from public.plan_frames f where f.plan_id = v_plan and f.t_s = 360) then
    raise exception 'FAIL 14e: a refused create left its frame behind';
  end if;

  -- ---------- 15. The moment: a note bumps the revision and leaves the badges alone ----------
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.frame_save(v_plan, jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev, 'note', 'Gates open'));
  select f.rev, f.note into v_new_rev, v_state from public.plan_frames f where f.id = v_f1;
  if v_new_rev <> v_rev + 1 or v_state <> 'Gates open' then
    raise exception 'FAIL 15a: the note was not written (rev %, note %)', v_new_rev, v_state;
  end if;
  select p.lat into v_lat from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat <> 5.0 then
    raise exception 'FAIL 15b: saving a note moved a badge (%)', v_lat;
  end if;

  -- ---------- 16. A session is checked against the moment, and no session is the old rev guard ----------
  perform public.plan_lock_frame(v_plan, v_f1, v_s_p, false);
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  v_msg := pg_temp.zz_refused(format(
    'select public.frame_save(%L, %L::jsonb, %L)', v_plan,
    jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev, 'note', 'Theirs'), v_s_p2));
  if v_msg not like 'PT423|%editing this moment%' then
    raise exception 'FAIL 16a: another session edited a held moment (got %)', v_msg;
  end if;
  -- my own session, which holds it, may
  perform public.frame_save(v_plan, jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev, 'note', 'Mine'), v_s_p);
  select f.note into v_state from public.plan_frames f where f.id = v_f1;
  if v_state <> 'Mine' then
    raise exception 'FAIL 16b: the holder could not save its own moment (note %)', v_state;
  end if;
  -- and without a session the rev check is the only guard, which is what every caller had before 082
  perform public.plan_release_all(v_s_p, v_plan);
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.frame_save(v_plan, jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev, 'note', 'Mine again'));
  select f.note into v_state from public.plan_frames f where f.id = v_f1;
  if v_state <> 'Mine again' then
    raise exception 'FAIL 16c: a sessionless save was refused (note %)', v_state;
  end if;
  -- ...and a stale rev is still PT409
  v_msg := pg_temp.zz_refused(format(
    'select public.frame_save(%L, %L::jsonb)', v_plan,
    jsonb_build_object('id', v_f1, 't_s', 60, 'rev', v_rev - 1, 'note', 'Stale')));
  if v_msg not like 'PT409|%changed this frame first%' then
    raise exception 'FAIL 16d: a stale revision was not refused (got %)', v_msg;
  end if;

  -- ---------- 17. Removing a badge, and only with a hold ----------
  v_msg := pg_temp.zz_refused(format('select public.frame_unplace(%L, %L, %L, %L)', v_plan, v_f2, v_a2, v_s_p2));
  if v_msg not like 'PT423|%stopped being yours%' then
    raise exception 'FAIL 17a: an unheld removal was accepted (got %)', v_msg;
  end if;
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f2, 'group', v_a2)), v_s_p, false);
  select public.frame_unplace(v_plan, v_f2, v_a2, v_s_p) into v_count;
  if v_count <> 1 then
    raise exception 'FAIL 17b: the removal reported % rows, not 1', v_count;
  end if;
  if exists (select 1 from public.plan_positions p where p.frame_id = v_f2 and p.group_id = v_a2) then
    raise exception 'FAIL 17c: the position is still there';
  end if;
  -- already gone: 0, not an error (undo walks a stored diff)
  select public.frame_unplace(v_plan, v_f2, v_a2, v_s_p) into v_count;
  if v_count <> 0 then
    raise exception 'FAIL 17d: taking away a row that is gone reported %', v_count;
  end if;

  -- ---------- 18. Removing a gesture's worth ----------
  perform public.plan_lock_cells(v_plan, v_three, v_s_p, true);
  select public.frame_unplace_many(v_plan, v_three, v_s_p) into v_count;
  if v_count <> 3 then
    raise exception 'FAIL 18a: the removal took away % rows, not 3', v_count;
  end if;
  select count(*) into v_count from public.plan_positions p
   where (p.frame_id, p.group_id) in ((v_f1, v_a1), (v_f1, v_a2), (v_f2, v_a1));
  if v_count <> 0 then
    raise exception 'FAIL 18b: % of the three cells survived', v_count;
  end if;

  -- ---------- 19. A frame somebody deleted cannot be written ----------
  delete from public.plan_frames f where f.id = v_f3;
  v_msg := pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 1.0, 103.0)',
                                     v_plan, v_f3, v_a1, v_s_p));
  if v_msg not like '42501|%not in this plan%' then
    raise exception 'FAIL 19: a deleted frame was written (got %)', v_msg;
  end if;

  -- ---------- 20. What the real roles may reach ----------
  if has_function_privilege('anon', 'public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text)',
                            'EXECUTE') then
    raise exception 'FAIL 20a: anon can place a badge';
  end if;
  if not has_function_privilege('authenticated',
        'public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text)', 'EXECUTE') then
    raise exception 'FAIL 20b: a signed-in planner cannot place a badge';
  end if;
  if has_function_privilege('authenticated', 'public.plan_place_cell(uuid, uuid, uuid, float8, float8, text, text)',
                            'EXECUTE') then
    raise exception 'FAIL 20c: the unguarded writer is callable by clients';
  end if;
  if has_function_privilege('authenticated', 'public.plan_require_cell_holds(uuid, jsonb, uuid)', 'EXECUTE') then
    raise exception 'FAIL 20d: the hold check is callable by clients';
  end if;
  if has_function_privilege('authenticated', 'public.plan_cell_points(jsonb)', 'EXECUTE') then
    raise exception 'FAIL 20e: the point parser is callable by clients';
  end if;
  -- a default argument makes a 3-argument frame_save, and the 2-argument one must be gone with it
  select count(*) into v_count from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_save' and p.pronargs = 2;
  if v_count <> 0 then
    raise exception 'FAIL 20f: frame_save(uuid, jsonb) still exists beside the 3-argument one';
  end if;
  select pg_get_function_result('public.frame_save(uuid, jsonb, uuid)'::regprocedure) into v_sig;
  if v_sig is distinct from 'plan_frames' then
    raise exception 'FAIL 20g: frame_save does not return the frame row (%)', v_sig;
  end if;
end $t$;

-- ---------- 21. The doors work from the real role, and the helpers are not reachable ----------
set local role authenticated;

do $t$
declare
  v_plan constant uuid := '82000000-0000-0000-0000-0000000000b1';
  v_f1 constant uuid := '82000000-0000-0000-0000-0000000000f1';
  v_a1 constant uuid := '82000000-0000-0000-0000-0000000000a1';
  v_p constant uuid := '82000000-0000-0000-0000-000000000002';
  v_s constant uuid := '82100000-0000-0000-0000-000000000004';
  v_lat float8;
begin
  perform pg_temp.zz_as(v_p::text);

  -- The earlier page-loads are done: put everything down so this section starts from a blank board.
  perform public.plan_release_all('82100000-0000-0000-0000-000000000001');
  perform public.plan_release_all('82100000-0000-0000-0000-000000000003');

  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1)), v_s, false);
  perform public.frame_place(v_plan, v_f1, v_a1, v_s, 1.50, 103.95);
  select p.lat into v_lat from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_lat is distinct from 1.50 then
    raise exception 'FAIL 21a: the board could not write through the door (%)', v_lat;
  end if;

  if pg_temp.zz_refused(format('select public.plan_place_cell(%L, %L, %L, 1.0, 103.0)',
                               v_plan, v_f1, v_a1)) = '' then
    raise exception 'FAIL 21b: a planner reached the unguarded writer';
  end if;

  -- a participant still cannot, through the same door
  perform pg_temp.zz_as('82000000-0000-0000-0000-000000000004'::text);
  if pg_temp.zz_refused(format('select public.frame_place(%L, %L, %L, %L, 1.0, 103.0)',
                               v_plan, v_f1, v_a1, v_s)) = '' then
    raise exception 'FAIL 21c: a participant placed a badge through the door';
  end if;
end $t$;

rollback;
