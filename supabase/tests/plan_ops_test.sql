-- ============================================================
-- Tests for 083_frame_ops_locks.sql: the rest of the board's writes, against the same rule.
--
-- Run in the Supabase SQL Editor AFTER 083, or locally with `node tools/pgtest.mjs plan-ops`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
--
-- WHY THIS RUNS AS THE CONNECTION USER, and how it drives identity: the doors are `security definer` and decide who
-- the caller is from auth.uid() -- the JWT claim, not the SQL role -- so the suite sets the claim (`pg_temp.zz_as`)
-- and stays the connection user. That is what lets it age a hold by hand (the 12 s lapse) and read the tables to see
-- what a refused call did NOT write. The last section switches to the real `authenticated` role to check the grants.
--
-- The rule under test, in one sentence: a door that would take away or overwrite something a live hold is guarding
-- refuses and names the holder; a door that only adds something that was not there may go ahead.
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
  ('83000000-0000-0000-0000-000000000001', 'pl3-r@example.test', '{"username":"pl3_r","display_name":"Rita Root"}'),
  ('83000000-0000-0000-0000-000000000002', 'pl3-p@example.test', '{"username":"pl3_p","display_name":"Priya Planner"}'),
  ('83000000-0000-0000-0000-000000000003', 'pl3-q@example.test', '{"username":"pl3_q","display_name":"Daniel Planner"}'),
  ('83000000-0000-0000-0000-000000000004', 'pl3-m@example.test', '{"username":"pl3_m","display_name":"Mira Member"}'),
  ('83000000-0000-0000-0000-000000000005', 'pl3-o@example.test', '{"username":"pl3_o","display_name":"Oscar Other"}');
insert into public.events (id, name, created_by) values
  ('83000000-0000-0000-0000-0000000000e1', 'Ops test', '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000e2', 'Other event', '83000000-0000-0000-0000-000000000005');
insert into public.event_roles (event_id, user_id, role) values
  ('83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-000000000001', 'root'),
  ('83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-000000000002', 'planner'),
  ('83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-000000000003', 'planner'),
  ('83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-000000000004', 'participant'),
  ('83000000-0000-0000-0000-0000000000e2', '83000000-0000-0000-0000-000000000005', 'root');
insert into public.groups (id, event_id, name) values
  ('83000000-0000-0000-0000-0000000000a1', '83000000-0000-0000-0000-0000000000e1', 'Gate Crew'),
  ('83000000-0000-0000-0000-0000000000a2', '83000000-0000-0000-0000-0000000000e1', 'Stage'),
  ('83000000-0000-0000-0000-0000000000a3', '83000000-0000-0000-0000-0000000000e2', 'Elsewhere');

insert into public.plans (id, event_id, name, created_by) values
  ('83000000-0000-0000-0000-0000000000b1', '83000000-0000-0000-0000-0000000000e1', 'Show night',
   '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000b2', '83000000-0000-0000-0000-0000000000e1', 'Rehearsal',
   '83000000-0000-0000-0000-000000000001');
insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
  ('83000000-0000-0000-0000-0000000000f1', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 60, '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000f2', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 120, '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000f3', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 180, '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000f4', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 240, '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000f5', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 300, '83000000-0000-0000-0000-000000000001'),
  -- the two ends of the gap the fill tests work on. 7180 m over 300 s is exactly one 24 m step per second, which is
  -- what 042 needs to be able to write the stretch at all (it refuses a step it cannot split that finely).
  ('83000000-0000-0000-0000-0000000000f6', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 360, '83000000-0000-0000-0000-000000000001'),
  ('83000000-0000-0000-0000-0000000000f7', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', 660, '83000000-0000-0000-0000-000000000001'),
  -- a frame of the OTHER plan, for the import and delete tests
  ('83000000-0000-0000-0000-0000000000f9', '83000000-0000-0000-0000-0000000000b2',
   '83000000-0000-0000-0000-0000000000e1', 60, '83000000-0000-0000-0000-000000000001');
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('83000000-0000-0000-0000-0000000000f1', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('83000000-0000-0000-0000-0000000000f1', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a2', 1.31, 103.81),
  ('83000000-0000-0000-0000-0000000000f2', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('83000000-0000-0000-0000-0000000000f4', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('83000000-0000-0000-0000-0000000000f6', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('83000000-0000-0000-0000-0000000000f7', '83000000-0000-0000-0000-0000000000b1',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.3645, 103.80),
  ('83000000-0000-0000-0000-0000000000f9', '83000000-0000-0000-0000-0000000000b2',
   '83000000-0000-0000-0000-0000000000e1', '83000000-0000-0000-0000-0000000000a1', 1.30, 103.80);

do $t$
declare
  v_plan constant uuid := '83000000-0000-0000-0000-0000000000b1';
  v_other constant uuid := '83000000-0000-0000-0000-0000000000b2';
  v_f1 constant uuid := '83000000-0000-0000-0000-0000000000f1';
  v_f2 constant uuid := '83000000-0000-0000-0000-0000000000f2';
  v_f3 constant uuid := '83000000-0000-0000-0000-0000000000f3';
  v_f4 constant uuid := '83000000-0000-0000-0000-0000000000f4';
  v_f5 constant uuid := '83000000-0000-0000-0000-0000000000f5';
  v_f6 constant uuid := '83000000-0000-0000-0000-0000000000f6';
  v_f7 constant uuid := '83000000-0000-0000-0000-0000000000f7';
  v_f9 constant uuid := '83000000-0000-0000-0000-0000000000f9';
  v_a1 constant uuid := '83000000-0000-0000-0000-0000000000a1';
  v_a2 constant uuid := '83000000-0000-0000-0000-0000000000a2';
  v_a3 constant uuid := '83000000-0000-0000-0000-0000000000a3';
  v_p constant uuid := '83000000-0000-0000-0000-000000000002';
  v_q constant uuid := '83000000-0000-0000-0000-000000000003';
  v_m constant uuid := '83000000-0000-0000-0000-000000000004';
  v_o constant uuid := '83000000-0000-0000-0000-000000000005';
  -- page-loads: Priya's tab, Daniel's tab, Priya's OTHER tab
  v_s_p constant uuid := '83100000-0000-0000-0000-000000000001';
  v_s_q constant uuid := '83100000-0000-0000-0000-000000000002';
  v_s_p2 constant uuid := '83100000-0000-0000-0000-000000000003';
  v_one jsonb;
  v_two jsonb;
  v_msg text;
  v_t integer;
  v_rev integer;
  v_n integer;
  v_n2 integer;
  v_updated timestamptz;
  v_sheet jsonb;
  v_result jsonb;
  v_cell1 constant text := '83100000-0000-0000-0000-0000000000c1';
begin
  -- The shapes the doors take.
  v_one := jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1));
  v_two := jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1),
                             jsonb_build_object('frame', v_f1, 'group', v_a2));

  -- ---------- 1. Only a planner or the root, on every new door ----------
  perform pg_temp.zz_as(v_m::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_delete(%L, null, %L)', v_f4, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1a: a participant deleted a moment (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.frame_shift(%L, 60, 60, null, %L)', v_plan, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1b: a participant pushed a stretch (got %)', v_msg;
  end if;
  v_msg := pg_temp.zz_refused(format('select public.plan_delete(%L, %L)', v_other, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1c: a participant deleted a plan (got %)', v_msg;
  end if;

  perform pg_temp.zz_as(v_o::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_move(%L, 90, null, %L)', v_f1, v_s_p));
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1d: somebody from another event retimed a frame (got %)', v_msg;
  end if;

  -- ---------- 2. A retime needs the moment: no hold, somebody else's hold, then mine ----------
  perform pg_temp.zz_as(v_p::text);
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  v_msg := pg_temp.zz_refused(format('select public.frame_move(%L, 90, %L, %L)', v_f1, v_rev, v_s_p));
  if v_msg not like 'PT423|%stopped being yours%' then
    raise exception 'FAIL 2a: an unheld retime was accepted (got %)', v_msg;
  end if;
  select f.t_s into v_t from public.plan_frames f where f.id = v_f1;
  if v_t <> 60 then
    raise exception 'FAIL 2b: a refused retime moved the frame (t_s %)', v_t;
  end if;

  -- Daniel's hand on the moment: named, with the place, and the sentence says what did not happen.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_frame(v_plan, v_f1, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_move(%L, 90, %L, %L)', v_f1, v_rev, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +1:00, so this moment cannot be moved yet.%' then
    raise exception 'FAIL 2c: another session''s moment was not named (got %)', v_msg;
  end if;

  -- ...mine, and the revision moves with the time.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_lock_frame(v_plan, v_f1, v_s_p, false);
  perform public.frame_move(v_f1, 90, v_rev, v_s_p);
  select f.t_s into v_t from public.plan_frames f where f.id = v_f1;
  if v_t <> 90 then
    raise exception 'FAIL 2d: the holder could not retime its own moment (t_s %)', v_t;
  end if;
  -- back where it was, with the revision this call just made
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.frame_move(v_f1, 60, v_rev, v_s_p);

  -- ...and a caller with no session is still judged by the revision alone (an internal caller, as in 082).
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.frame_move(v_f1, 65, v_rev);
  select f.t_s into v_t from public.plan_frames f where f.id = v_f1;
  if v_t <> 65 then
    raise exception 'FAIL 2e: a sessionless retime was refused (t_s %)', v_t;
  end if;
  select f.rev into v_rev from public.plan_frames f where f.id = v_f1;
  perform public.frame_move(v_f1, 60, v_rev);
  perform public.plan_release_all(v_s_p, v_plan);
  perform public.plan_release_all(v_s_q, v_plan);

  -- ---------- 3. Deleting a moment somebody's hand is in: refused, by name ----------
  perform pg_temp.zz_as(v_p::text);
  update public.plans set updated_at = now() - interval '1 hour' where id = v_plan;
  v_updated := (select p.updated_at from public.plans p where p.id = v_plan);

  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f4, 'group', v_a1)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_delete(%L, null, %L)', v_f4, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing Gate Crew at +4:00, so this moment cannot be deleted yet.%' then
    raise exception 'FAIL 3a: a moment with a dragged badge was deleted (got %)', v_msg;
  end if;
  if not exists (select 1 from public.plan_frames f where f.id = v_f4) then
    raise exception 'FAIL 3b: a refused delete took the frame away';
  end if;
  if (select p.updated_at from public.plans p where p.id = v_plan) <> v_updated then
    raise exception 'FAIL 3c: a refused delete touched the plan';
  end if;

  -- The moment retime counts too: the clock is being changed under the delete.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform public.plan_lock_frame(v_plan, v_f4, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_delete(%L, null, %L)', v_f4, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +4:00, so this moment cannot be deleted yet.%' then
    raise exception 'FAIL 3d: a moment being retimed was deleted (got %)', v_msg;
  end if;

  -- My own other window is not a colleague, and the sentence says so.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f4, 'group', v_a2)),
                                 v_s_p2, false);
  v_msg := pg_temp.zz_refused(format('select public.frame_delete(%L, null, %L)', v_f4, v_s_p));
  if v_msg not like 'PT423|%This badge is open in another of your windows (Stage, +4:00), so this moment cannot be deleted yet.%' then
    raise exception 'FAIL 3e: my own other window was named as somebody else (got %)', v_msg;
  end if;

  -- Free, it goes -- and the cascade takes the hold with it (081's foreign key is what made the refusal necessary).
  perform public.plan_release_all(v_s_p2, v_plan);
  perform public.frame_delete(v_f4, null, v_s_p);
  if exists (select 1 from public.plan_frames f where f.id = v_f4) then
    raise exception 'FAIL 3f: the delete did not delete';
  end if;
  if (select p.updated_at from public.plans p where p.id = v_plan) <= v_updated then
    raise exception 'FAIL 3g: the delete did not touch the plan';
  end if;

  -- ---------- 4. The lapse is the answer to "I need it gone now": a hold that can be stolen is not a hold ----------
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f5, 'group', v_a1)),
                                 v_s_q, false);
  update public.plan_cell_locks set last_seen = now() - interval '8 seconds' where session_id = v_s_q;
  perform pg_temp.zz_as(v_p::text);
  perform public.frame_delete(v_f5, null, v_s_p);
  if exists (select 1 from public.plan_frames f where f.id = v_f5) then
    raise exception 'FAIL 4a: a lapsed hold still blocked the delete';
  end if;

  -- ---------- 5. A push waits for a MOMENT, never for a badge ----------
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform public.plan_lock_frame(v_plan, v_f2, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select public.frame_shift(%L, 120, 300, 120, %L)', v_plan, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +2:00, so the stretch cannot be moved yet.%' then
    raise exception 'FAIL 5a: a stretch somebody is retiming was pushed (got %)', v_msg;
  end if;
  select f.t_s into v_t from public.plan_frames f where f.id = v_f2;
  if v_t <> 120 then
    raise exception 'FAIL 5b: a refused push moved a frame (t_s %)', v_t;
  end if;

  -- A badge hold is NOT a reason to refuse a push: 081 settled that a clock does not move a badge.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f2, 'group', v_a1)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  select public.frame_shift(v_plan, 120, 300, 120, v_s_p) into v_n;
  if v_n <> 1 then
    raise exception 'FAIL 5c: a push past a held badge reported % frames, not 1', v_n;
  end if;
  select f.t_s into v_t from public.plan_frames f where f.id = v_f2;
  if v_t <> 420 then
    raise exception 'FAIL 5d: the push did not move the frame (t_s %)', v_t;
  end if;
  -- and back
  perform public.frame_shift(v_plan, 420, -300, 420, v_s_p);
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);

  -- ---------- 6. Filling a gap waits for a moment in it ----------
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_frame(v_plan, v_f6, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select public.frames_fill(%L, %L, %L, %L::uuid[], %L)',
                                     v_plan, v_f6, v_f7, array[v_a1], v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +6:00, so this gap cannot be filled yet.%' then
    raise exception 'FAIL 6a: a gap with a retimed moment in it was filled (got %)', v_msg;
  end if;
  if exists (select 1 from public.plan_frames f where f.plan_id = v_plan and f.t_s > 360 and f.t_s < 660) then
    raise exception 'FAIL 6b: a refused fill left frames behind';
  end if;

  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  select count(*) into v_n from public.plan_frames f where f.plan_id = v_plan;
  select h.frames_added into v_n2 from public.frames_fill(v_plan, v_f6, v_f7, array[v_a1], v_s_p) h;
  if coalesce(v_n2, 0) < 1 then
    raise exception 'FAIL 6c: the fill added no frames (%)', v_n2;
  end if;
  if (select count(*) from public.plan_frames f where f.plan_id = v_plan) <= v_n then
    raise exception 'FAIL 6d: the fill wrote no frames to the plan';
  end if;

  -- ---------- 7. A hold is refused over somebody's badge, and not over a frame it invents ----------
  -- The target frame (+2:00) already stands, and Daniel has Stage there in his hand.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f2, 'group', v_a2)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select * from public.frame_hold(%L, %L, 60, %L::uuid[], %L)',
                                     v_plan, v_f1, array[v_a2], v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing Stage at +2:00, so this hold cannot be made yet.%' then
    raise exception 'FAIL 7a: a hold wrote over a dragged badge (got %)', v_msg;
  end if;
  if exists (select 1 from public.plan_positions p where p.frame_id = v_f2 and p.group_id = v_a2) then
    raise exception 'FAIL 7b: a refused hold wrote the row anyway';
  end if;

  -- Free, it writes exactly that group at the target.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  select h.positions_written into v_n from public.frame_hold(v_plan, v_f1, 60, array[v_a2], v_s_p) h;
  if v_n <> 1 then
    raise exception 'FAIL 7c: the hold wrote % rows, not 1', v_n;
  end if;

  -- A target frame that does not exist yet is invented: a row that did not exist a statement ago cannot be somebody's.
  select h.frames_added, h.positions_written into v_n, v_n2
    from public.frame_hold(v_plan, v_f7, 60, array[v_a1], v_s_p) h;
  if v_n <> 1 or v_n2 <> 1 then
    raise exception 'FAIL 7d: a hold on a new moment added % frames and wrote % rows', v_n, v_n2;
  end if;

  -- The target MOMENT is protected too: the frame's revision is bumped by a hold, which a retime would then call stale.
  update public.plan_positions set state = 'off_site' where frame_id = v_f1 and group_id = v_a2;
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_frame(v_plan, v_f2, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select * from public.frame_hold(%L, %L, 60, %L::uuid[], %L)',
                                     v_plan, v_f1, array[v_a2], v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +2:00, so this hold cannot be made yet.%' then
    raise exception 'FAIL 7e: a hold bumped a moment somebody was retiming (got %)', v_msg;
  end if;
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);

  -- ---------- 8. The confirmation grid: only the rows it would change are in anybody's way ----------
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_release_all(v_s_p, v_plan);
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select * from public.frame_set_verify(%L, %L::uuid[], %L::uuid[], %L, %L)',
                                     v_plan, array[v_f1], array[v_a1], 'manual', v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing Gate Crew at +1:00, so the confirmation cannot be changed yet.%' then
    raise exception 'FAIL 8a: a confirmation patched a badge in somebody''s hand (got %)', v_msg;
  end if;
  select p.verify into v_msg from public.plan_positions p where p.frame_id = v_f1 and p.group_id = v_a1;
  if v_msg <> 'auto' then
    raise exception 'FAIL 8b: a refused confirmation wrote the flag (%)', v_msg;
  end if;

  -- The same call with nothing to change is not in anybody's way: twice is once.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform pg_temp.zz_as(v_p::text);
  select h.positions_set into v_n
    from public.frame_set_verify(v_plan, array[v_f1], array[v_a1], 'manual', v_s_p) h;
  if v_n <> 1 then
    raise exception 'FAIL 8c: the confirmation set % rows, not 1', v_n;
  end if;
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f1, 'group', v_a1)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  select h.positions_set into v_n
    from public.frame_set_verify(v_plan, array[v_f1], array[v_a1], 'manual', v_s_p) h;
  if v_n <> 0 then
    raise exception 'FAIL 8d: setting a flag to what it already was wrote % rows', v_n;
  end if;

  -- ...and the moment guard applies even when no cell changes at all.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);
  perform public.plan_lock_frame(v_plan, v_f1, v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_msg := pg_temp.zz_refused(format('select * from public.frame_set_verify(%L, %L::uuid[], %L::uuid[], %L, %L)',
                                     v_plan, array[v_f1], array[v_a1], 'auto', v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing the moment at +1:00, so the confirmation cannot be changed yet.%' then
    raise exception 'FAIL 8e: a confirmation bumped a moment somebody was retiming (got %)', v_msg;
  end if;
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_plan);

  -- ---------- 9. Replacing a plan, and deleting one: refused while anybody is in it ----------
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_lock_cells(v_other, jsonb_build_array(jsonb_build_object('frame', v_f9, 'group', v_a1)),
                                 v_s_q, false);
  perform pg_temp.zz_as(v_p::text);
  v_sheet := jsonb_build_array(
    jsonb_build_object('t_s', 60, 'note', 'call',
                       'positions', jsonb_build_object(v_a1::text, jsonb_build_object('lat', 1.3, 'lng', 103.8))),
    jsonb_build_object('t_s', 120, 'note', 'doors',
                       'positions', jsonb_build_object(v_a1::text, jsonb_build_object('lat', 1.31, 'lng', 103.81))));
  v_msg := pg_temp.zz_refused(format('select public.plan_import(%L, %L::jsonb, %L)', v_other, v_sheet, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing Gate Crew at +1:00, so the plan cannot be replaced yet.%' then
    raise exception 'FAIL 9a: a sheet replaced a plan somebody was drawing on (got %)', v_msg;
  end if;
  if not exists (select 1 from public.plan_frames f where f.id = v_f9) then
    raise exception 'FAIL 9b: a refused import deleted the plan''s frames';
  end if;

  v_msg := pg_temp.zz_refused(format('select public.plan_delete(%L, %L)', v_other, v_s_p));
  if v_msg not like 'PT423|%Daniel Planner is editing Gate Crew at +1:00, so this plan cannot be deleted yet.%' then
    raise exception 'FAIL 9c: a plan somebody was drawing on was deleted (got %)', v_msg;
  end if;
  if not exists (select 1 from public.plans p where p.id = v_other) then
    raise exception 'FAIL 9d: a refused delete removed the plan';
  end if;

  -- Free: the import replaces every moment, and the delete takes the plan away.
  perform pg_temp.zz_as(v_q::text);
  perform public.plan_release_all(v_s_q, v_other);
  perform pg_temp.zz_as(v_p::text);
  select public.plan_import(v_other, v_sheet, v_s_p) into v_result;
  if (v_result ->> 'frames')::int <> 2 or (v_result ->> 'positions')::int <> 2 then
    raise exception 'FAIL 9e: the import wrote % frames and % positions', v_result ->> 'frames', v_result ->> 'positions';
  end if;
  perform public.plan_delete(v_other, v_s_p);
  if exists (select 1 from public.plans p where p.id = v_other) then
    raise exception 'FAIL 9f: the delete did not delete';
  end if;

  -- ---------- 10. One definition per door, and no leftover arity ----------
  -- (The grants are checked by has_function_privilege in section 11: a call from this user would be allowed whatever
  -- the ACL says, because this user owns the schema. The one door a real role reaches is section 12.)
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_move';
  if v_n <> 1 then
    raise exception 'FAIL 10e: frame_move has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'plan_delete';
  if v_n <> 1 then
    raise exception 'FAIL 10f: plan_delete has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'plan_import';
  if v_n <> 1 then
    raise exception 'FAIL 10g: plan_import has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_set_verify';
  if v_n <> 1 then
    raise exception 'FAIL 10h: frame_set_verify has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_hold';
  if v_n <> 1 then
    raise exception 'FAIL 10i: frame_hold has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frames_fill';
  if v_n <> 1 then
    raise exception 'FAIL 10j: frames_fill has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_shift';
  if v_n <> 1 then
    raise exception 'FAIL 10k: frame_shift has % definitions', v_n;
  end if;
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'frame_delete';
  if v_n <> 1 then
    raise exception 'FAIL 10l: frame_delete has % definitions', v_n;
  end if;
end $t$;

-- ---------- 11. What the real roles may reach ----------
do $t$
declare
  v_n integer;
  v_fn text;
begin
  foreach v_fn in array array[
    'frame_move(uuid, integer, integer, uuid)',
    'frame_delete(uuid, integer, uuid)',
    'frame_shift(uuid, integer, integer, integer, uuid)',
    'frames_fill(uuid, uuid, uuid, uuid[], uuid)',
    'frame_hold(uuid, uuid, integer, uuid[], uuid)',
    'frame_set_verify(uuid, uuid[], uuid[], text, uuid)',
    'plan_delete(uuid, uuid)',
    'plan_import(uuid, jsonb, uuid)'
  ] loop
    if has_function_privilege('anon', 'public.' || v_fn, 'EXECUTE') then
      raise exception 'FAIL 11a: anon can call %', v_fn;
    end if;
    if not has_function_privilege('authenticated', 'public.' || v_fn, 'EXECUTE') then
      raise exception 'FAIL 11b: a signed-in planner cannot call %', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'plan_raise_hold(text, text, text, integer, boolean, text, text)',
    'plan_refuse_holds(uuid, uuid[], uuid, text, text, text)',
    'plan_refuse_cells(uuid, jsonb, uuid, text, text)',
    'plan_require_moment_hold(uuid, uuid, uuid, text, text)'
  ] loop
    if has_function_privilege('authenticated', 'public.' || v_fn, 'EXECUTE') then
      raise exception 'FAIL 11c: a client can call %', v_fn;
    end if;
  end loop;
  perform 1;
end $t$;

-- ---------- 12. One door, from the real role ----------
set local role authenticated;

do $t$
declare
  v_plan constant uuid := '83000000-0000-0000-0000-0000000000b1';
  v_f3 constant uuid := '83000000-0000-0000-0000-0000000000f3';
  v_a1 constant uuid := '83000000-0000-0000-0000-0000000000a1';
  v_p constant uuid := '83000000-0000-0000-0000-000000000002';
  v_s constant uuid := '83100000-0000-0000-0000-000000000002';
  v_other constant uuid := '83100000-0000-0000-0000-000000000001';
begin
  perform pg_temp.zz_as(v_p::text);
  -- the earlier page-loads are done; this section starts from a board nobody is holding
  perform public.plan_release_all(v_other);
  perform public.plan_release_all('83100000-0000-0000-0000-000000000003');

  perform public.plan_lock_frame(v_plan, v_f3, v_s, false);
  perform public.frame_move(v_f3, 200, null, v_s);
  if (select f.t_s from public.plan_frames f where f.id = v_f3) <> 200 then
    raise exception 'FAIL 12a: the board could not retime through the door';
  end if;

  -- and a badge of my own other window, through the same role, still stops the delete
  perform public.plan_lock_cells(v_plan, jsonb_build_array(jsonb_build_object('frame', v_f3, 'group', v_a1)),
                                 v_other, false);
  if pg_temp.zz_refused(format('select public.frame_delete(%L, null, %L)', v_f3, v_s)) = '' then
    raise exception 'FAIL 12b: a moment holding a draggable badge was deleted';
  end if;
end $t$;

rollback;
