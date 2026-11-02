-- ============================================================
-- Tests for 081_plan_locks.sql: who is editing which badge, and which moment.
--
-- Run in the Supabase SQL Editor AFTER 081, or locally with `node tools/pgtest.mjs plan-locks`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
--
-- WHY THIS RUNS AS THE CONNECTION USER. Every door in 081 is `security definer` and decides who the caller
-- is from auth.uid() -- the JWT claim, not the SQL role. So the suite drives the claim (`pg_temp.zz_as`) and
-- stays the connection user, which is what lets it age a lock by hand (`last_seen`) to test the steal and
-- expiry rules; a test that could not reach the table could only test the happy path of a clock. The last
-- section switches to the real `authenticated` role to check the two things that role can and cannot do.
-- ============================================================
begin;

create function pg_temp.zz_refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end $$;

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

-- R root, P planner (Priya), Q planner (Daniel), M participant; O is in another event.
insert into auth.users (id, email, raw_user_meta_data) values
  ('81000000-0000-0000-0000-000000000001', 'pl-r@example.test', '{"username":"pl_r","display_name":"Rita Root"}'),
  ('81000000-0000-0000-0000-000000000002', 'pl-p@example.test', '{"username":"pl_p","display_name":"Priya Planner"}'),
  ('81000000-0000-0000-0000-000000000003', 'pl-q@example.test', '{"username":"pl_q","display_name":"Daniel Planner"}'),
  ('81000000-0000-0000-0000-000000000004', 'pl-m@example.test', '{"username":"pl_m","display_name":"Mira Member"}'),
  ('81000000-0000-0000-0000-000000000005', 'pl-o@example.test', '{"username":"pl_o","display_name":"Oscar Other"}');
insert into public.events (id, name, created_by) values
  ('81000000-0000-0000-0000-0000000000e1', 'Plan lock test', '81000000-0000-0000-0000-000000000001'),
  ('81000000-0000-0000-0000-0000000000e2', 'Other event', '81000000-0000-0000-0000-000000000005');
insert into public.event_roles (event_id, user_id, role) values
  ('81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-000000000001', 'root'),
  ('81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-000000000002', 'planner'),
  ('81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-000000000003', 'planner'),
  ('81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-000000000004', 'participant'),
  ('81000000-0000-0000-0000-0000000000e2', '81000000-0000-0000-0000-000000000005', 'root');
insert into public.groups (id, event_id, name) values
  ('81000000-0000-0000-0000-0000000000a1', '81000000-0000-0000-0000-0000000000e1', 'Gate Crew'),
  ('81000000-0000-0000-0000-0000000000a2', '81000000-0000-0000-0000-0000000000e1', 'Stage'),
  ('81000000-0000-0000-0000-0000000000a3', '81000000-0000-0000-0000-0000000000e2', 'Elsewhere');

insert into public.plans (id, event_id, name, created_by) values
  ('81000000-0000-0000-0000-0000000000b1', '81000000-0000-0000-0000-0000000000e1', 'Show night',
   '81000000-0000-0000-0000-000000000001'),
  ('81000000-0000-0000-0000-0000000000b2', '81000000-0000-0000-0000-0000000000e1', 'Rehearsal',
   '81000000-0000-0000-0000-000000000001');
insert into public.plan_frames (id, plan_id, event_id, t_s, created_by) values
  ('81000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', 60, '81000000-0000-0000-0000-000000000001'),
  ('81000000-0000-0000-0000-0000000000f2', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', 120, '81000000-0000-0000-0000-000000000001'),
  ('81000000-0000-0000-0000-0000000000f3', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', 180, '81000000-0000-0000-0000-000000000001'),
  -- a frame of the OTHER plan, for "that frame is not in this plan"
  ('81000000-0000-0000-0000-0000000000f9', '81000000-0000-0000-0000-0000000000b2',
   '81000000-0000-0000-0000-0000000000e1', 60, '81000000-0000-0000-0000-000000000001');
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('81000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-0000000000a1', 1.30, 103.80),
  ('81000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-0000000000a2', 1.31, 103.81),
  ('81000000-0000-0000-0000-0000000000f2', '81000000-0000-0000-0000-0000000000b1',
   '81000000-0000-0000-0000-0000000000e1', '81000000-0000-0000-0000-0000000000a1', 1.30, 103.80);

do $t$
declare
  v_plan constant uuid := '81000000-0000-0000-0000-0000000000b1';
  v_plan2 constant uuid := '81000000-0000-0000-0000-0000000000b2';
  v_f1 constant uuid := '81000000-0000-0000-0000-0000000000f1';
  v_f2 constant uuid := '81000000-0000-0000-0000-0000000000f2';
  v_f3 constant uuid := '81000000-0000-0000-0000-0000000000f3';
  v_f9 constant uuid := '81000000-0000-0000-0000-0000000000f9';
  v_r constant uuid := '81000000-0000-0000-0000-000000000001';
  v_p constant uuid := '81000000-0000-0000-0000-000000000002';
  v_q constant uuid := '81000000-0000-0000-0000-000000000003';
  v_m constant uuid := '81000000-0000-0000-0000-000000000004';
  v_o constant uuid := '81000000-0000-0000-0000-000000000005';
  -- three page-loads: Priya's tab, Priya's OTHER tab, and Daniel's tab
  v_s_p constant uuid := '81100000-0000-0000-0000-000000000001';
  v_s_q constant uuid := '81100000-0000-0000-0000-000000000002';
  v_s_p2 constant uuid := '81100000-0000-0000-0000-000000000003';
  v_g1g1 jsonb;
  v_g1g2 jsonb;
  v_g2g1 jsonb;
  v_msg text;
  v_sig text;
  v_f uuid;
  v_g uuid;
  v_held boolean;
  v_t_s integer;
  v_name text;
  v_mine boolean;
  n integer;
begin
  v_g1g1 := jsonb_build_object('frame', v_f1, 'group', '81000000-0000-0000-0000-0000000000a1');
  v_g1g2 := jsonb_build_object('frame', v_f1, 'group', '81000000-0000-0000-0000-0000000000a2');
  v_g2g1 := jsonb_build_object('frame', v_f2, 'group', '81000000-0000-0000-0000-0000000000a1');

  -- ---------- 1. Only a planner or the root may take anything ----------
  perform pg_temp.zz_as(v_m::text);
  begin
    perform public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1a: a participant was not refused (got %)', v_msg;
  end if;

  perform pg_temp.zz_as(v_o::text);   -- root of another event
  begin
    perform public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like '42501|%Only the root user or a planner%' then
    raise exception 'FAIL 1b: someone from another event was not refused (got %)', v_msg;
  end if;

  -- ---------- 2. Priya takes a badge ----------
  perform pg_temp.zz_as(v_p::text);
  select c.frame_id, c.group_id into v_f, v_g
    from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p, false) c;
  if v_f is distinct from v_f1 or v_g is distinct from '81000000-0000-0000-0000-0000000000a1'::uuid then
    raise exception 'FAIL 2: the grab did not report the badge it took (%, %)', v_f, v_g;
  end if;

  -- ...and it is visible to anyone else editing the plan, with a name and no session id
  select h.group_name, h.t_s, h.mine, h.display_name into v_name, v_t_s, v_mine, v_msg
    from public.plan_lock_holders(v_plan) h
   where h.kind = 'badge' and h.frame_id = v_f1;
  if v_name is distinct from 'Gate Crew' or v_t_s is distinct from 60 or v_mine is distinct from true
     or v_msg is distinct from 'Priya Planner' then
    raise exception 'FAIL 3a: the holder list is wrong (%, %, %, %)', v_name, v_t_s, v_mine, v_msg;
  end if;
  select pg_get_function_result('public.plan_lock_holders(uuid)'::regprocedure) into v_sig;
  if position('session' in v_sig) > 0 then
    raise exception 'FAIL 3b: the holder list hands out session ids: %', v_sig;
  end if;
  if pg_get_function_result('public.plan_renew(uuid, jsonb, uuid[], uuid)'::regprocedure) like '%session%' then
    raise exception 'FAIL 3c: the heartbeat hands out session ids';
  end if;

  -- ---------- 3. Daniel cannot take it, and is told who has it ----------
  perform pg_temp.zz_as(v_q::text);
  begin
    perform public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_q, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like 'PT423|%Priya Planner%Gate Crew%+1:00%' then
    raise exception 'FAIL 4: the refusal did not name the holder and the place (got %)', v_msg;
  end if;

  -- ...but a different badge at the same moment is not in his way
  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g2), v_s_q, false);
  if n <> 1 then
    raise exception 'FAIL 5: two planners could not hold different badges of one frame';
  end if;

  -- ---------- 4. All-or-nothing: one taken badge refuses the whole gesture ----------
  begin
    perform public.plan_lock_cells(v_plan, jsonb_build_array(v_g2g1, v_g1g1), v_s_q, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like 'PT423|%Priya Planner%' then
    raise exception 'FAIL 6a: a gesture straddling a held badge was not refused (got %)', v_msg;
  end if;
  perform pg_temp.zz_as(v_r::text);
  select count(*) into n from public.plan_lock_holders(v_plan) h
   where h.user_id = v_q and h.t_s = 120;
  if n <> 0 then
    raise exception 'FAIL 6b: the refused gesture still took % badge(s) at +2:00', n;
  end if;

  -- ---------- 5. Nonsense is refused in words, not in cast errors ----------
  perform pg_temp.zz_as(v_q::text);
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, '"nope"', v_s_q)) not like '%Name the badges as a list%' then
    raise exception 'FAIL 7a: a non-list badge argument was not refused as such';
  end if;
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, '[{"frame":"not-a-uuid"}]', v_s_q)) not like '%not a badge%' then
    raise exception 'FAIL 7b: a malformed badge was not refused as such';
  end if;
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, '[]', v_s_q)) not like '%Name at least one badge%' then
    raise exception 'FAIL 7c: an empty grab was not refused';
  end if;
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, jsonb_build_array(jsonb_build_object('frame', v_f1, 'group',
         '81000000-0000-0000-0000-0000000000a3')), v_s_q)) not like '%belongs to another event%' then
    raise exception 'FAIL 7d: a group of another event was not refused';
  end if;
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, jsonb_build_array(jsonb_build_object('frame', v_f9, 'group',
         '81000000-0000-0000-0000-0000000000a1')), v_s_q)) not like '%frame is not in this plan%' then
    raise exception 'FAIL 7e: a frame of another plan was not refused';
  end if;

  -- ---------- 6. The heartbeat says which of my badges I still have ----------
  perform pg_temp.zz_as(v_p::text);
  select h.held into v_held from public.plan_renew(v_plan, jsonb_build_array(v_g1g1), array[]::uuid[], v_s_p) h;
  if v_held is distinct from true then
    raise exception 'FAIL 8a: the heartbeat lost a badge that was not taken';
  end if;
  select h.held into v_held from public.plan_renew(v_plan, jsonb_build_array(v_g2g1), array[]::uuid[], v_s_p) h;
  if v_held is distinct from false then
    raise exception 'FAIL 8b: the heartbeat claimed a badge Priya never took';
  end if;

  -- ---------- 7. My own other window is refused, and take-over is how past it ----------
  perform pg_temp.zz_as(v_p::text);
  begin
    perform public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p2, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like 'PT423|%another of your windows%' then
    raise exception 'FAIL 9a: a second tab of the same planner was not told why (got %)', v_msg;
  end if;

  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p2, true);
  if n <> 1 then
    raise exception 'FAIL 9b: take-over did not take my own other window''s badge';
  end if;
  select h.held into v_held from public.plan_renew(v_plan, jsonb_build_array(v_g1g1), array[]::uuid[], v_s_p) h;
  if v_held is distinct from false then
    raise exception 'FAIL 9c: the first tab still believes it holds the badge';
  end if;

  -- ...and the first tab takes it back, so that the rest of the suite has ONE unambiguous holder per badge
  perform public.plan_release_all(v_s_p2);
  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g1), v_s_p, false);
  if n <> 1 then
    raise exception 'FAIL 9d: the badge could not be taken back from my own other window';
  end if;

  -- ---------- 8. A quiet lock is stealable after 7 s, an expired one at once ----------
  -- (Daniel holds Stage at +1:00; age it by hand, then Priya takes it)
  update public.plan_cell_locks l set last_seen = now() - interval '8 seconds'
   where l.frame_id = v_f1 and l.group_id = '81000000-0000-0000-0000-0000000000a2';
  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g2), v_s_p, false);
  if n <> 1 then
    raise exception 'FAIL 10a: a lock quiet for 8 s could not be taken';
  end if;

  -- (now age Priya's: stale enough to be stealable is 7 s, but an EXPIRED row is refused on that arm too)
  update public.plan_cell_locks l
     set last_seen = now() - interval '1 second', expires_at = now() - interval '1 second'
   where l.frame_id = v_f1 and l.group_id = '81000000-0000-0000-0000-0000000000a2';
  perform pg_temp.zz_as(v_q::text);
  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g2), v_s_q, false);
  if n <> 1 then
    raise exception 'FAIL 10b: an expired lock could not be taken';
  end if;

  -- ---------- 9. A moment and the badges in it are separate resources ----------
  -- Priya is dragging Gate Crew at +1:00 and Daniel is dragging Stage there. Neither stops the other from
  -- retiming the moment: a retime and a badge drag write different rows, so nothing can be lost, and the
  -- first draft's refusal was dropped for exactly that reason.
  perform pg_temp.zz_as(v_p::text);
  select count(*) into n from public.plan_lock_frame(v_plan, v_f1, v_s_p, false);
  if n <> 1 then
    raise exception 'FAIL 11a: a badge being dragged elsewhere closed its moment';
  end if;

  -- ...but two planners still cannot retime the SAME moment, and the second is told whose it is.
  perform pg_temp.zz_as(v_q::text);
  begin
    perform public.plan_lock_frame(v_plan, v_f1, v_s_q, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like 'PT423|%Priya Planner%editing this moment%' then
    raise exception 'FAIL 11b: two planners retimed one moment (got %)', v_msg;
  end if;

  -- a second, empty moment can be taken, and then only by one
  perform pg_temp.zz_as(v_p::text);
  select count(*) into n from public.plan_lock_frame(v_plan, v_f2, v_s_p, false);
  if n <> 1 then
    raise exception 'FAIL 12a: a free moment could not be taken';
  end if;
  perform pg_temp.zz_as(v_q::text);
  begin
    perform public.plan_lock_frame(v_plan, v_f2, v_s_q, false);
    v_msg := '';
  exception when others then v_msg := sqlstate || '|' || sqlerrm;
  end;
  if v_msg not like 'PT423|%Priya Planner%' then
    raise exception 'FAIL 12b: a held moment was not refused by name (got %)', v_msg;
  end if;

  -- ---------- 10. Letting go ----------
  perform pg_temp.zz_as(v_r::text);
  select count(*) into n from public.plan_lock_holders(v_plan) h where h.kind = 'moment';
  if n <> 2 then
    raise exception 'FAIL 13a: the holder list shows % moment(s), not 2', n;
  end if;

  perform public.plan_unlock_frame(v_f2, v_s_p);
  select count(*) into n from public.plan_lock_holders(v_plan) h where h.kind = 'moment';
  if n <> 1 then
    raise exception 'FAIL 13b: unlocking a moment left % of them', n;
  end if;

  perform public.plan_unlock_cells(v_plan, jsonb_build_array(v_g1g2), v_s_q);
  select count(*) into n from public.plan_lock_holders(v_plan) h where h.kind = 'badge' and h.user_id = v_q;
  if n <> 0 then
    raise exception 'FAIL 13c: unlocking a badge left % of Daniel''s', n;
  end if;
  -- ...and the badge Daniel gave up is free again
  perform pg_temp.zz_as(v_p::text);
  select count(*) into n from public.plan_lock_cells(v_plan, jsonb_build_array(v_g1g2), v_s_p2, false);
  if n <> 1 then
    raise exception 'FAIL 13d: a released badge could not be taken';
  end if;

  -- everything a page holds, at once
  perform public.plan_release_all(v_s_p2);
  perform pg_temp.zz_as(v_r::text);
  select count(*) into n from public.plan_lock_holders(v_plan) h
   where h.frame_id = v_f1 and h.group_id = '81000000-0000-0000-0000-0000000000a2';
  if n <> 0 then
    raise exception 'FAIL 14: release-all left a badge behind';
  end if;

  -- ---------- 11. A deleted frame takes its locks with it ----------
  perform pg_temp.zz_as(v_p::text);
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', v_f3, 'group', '81000000-0000-0000-0000-0000000000a1')),
    v_s_p, false);
  perform public.plan_lock_frame(v_plan, v_f3, v_s_p, false);
  delete from public.plan_frames where id = v_f3;
  select count(*) into n from public.plan_cell_locks l where l.frame_id = v_f3;
  if n <> 0 then
    raise exception 'FAIL 15a: a deleted frame left % badge lock(s)', n;
  end if;
  select count(*) into n from public.plan_frame_locks l where l.frame_id = v_f3;
  if n <> 0 then
    raise exception 'FAIL 15b: a deleted frame left its moment lock';
  end if;

  -- ---------- 12. What the real roles may reach ----------
  if has_function_privilege('anon', 'public.plan_lock_cells(uuid, jsonb, uuid, boolean)', 'EXECUTE') then
    raise exception 'FAIL 16a: anon can take a badge';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_lock_cells(uuid, jsonb, uuid, boolean)', 'EXECUTE') then
    raise exception 'FAIL 16b: a signed-in planner cannot take a badge';
  end if;
  if has_function_privilege('authenticated', 'public.plan_require_editor(uuid)', 'EXECUTE') then
    raise exception 'FAIL 16c: the role check is callable by clients';
  end if;
  if has_function_privilege('authenticated', 'public.plan_cell_list(jsonb)', 'EXECUTE') then
    raise exception 'FAIL 16d: the badge parser is callable by clients';
  end if;
end $t$;

-- ---------- 13. The tables are not reachable, and the doors are ----------
set local role authenticated;

do $t$
declare
  v_plan constant uuid := '81000000-0000-0000-0000-0000000000b1';
  v_p constant uuid := '81000000-0000-0000-0000-000000000002';
  v_s constant uuid := '81100000-0000-0000-0000-000000000004';
  n integer;
begin
  perform pg_temp.zz_as(v_p::text);

  -- Priya's earlier page-load still holds Gate Crew; let it go, so that this section starts from a blank board.
  perform public.plan_release_all('81100000-0000-0000-0000-000000000001');

  if pg_temp.zz_refused('select 1 from public.plan_cell_locks') = '' then
    raise exception 'FAIL 17a: a planner can read the badge locks';
  end if;
  if pg_temp.zz_refused('select 1 from public.plan_frame_locks') = '' then
    raise exception 'FAIL 17b: a planner can read the moment locks';
  end if;

  -- ...but the door still works from the real role, because it is security definer
  perform public.plan_lock_cells(v_plan,
    jsonb_build_array(jsonb_build_object('frame', '81000000-0000-0000-0000-0000000000f1',
                                        'group', '81000000-0000-0000-0000-0000000000a1')), v_s, false);
  select count(*) into n from public.plan_lock_holders(v_plan) h where h.mine;
  if n <> 1 then
    raise exception 'FAIL 18: the board could not see its own badge through the door (% rows)', n;
  end if;

  -- a participant still cannot, through the same door
  perform pg_temp.zz_as('81000000-0000-0000-0000-000000000004'::text);
  if pg_temp.zz_refused(format('select * from public.plan_lock_cells(%L, %L::jsonb, %L, false)',
       v_plan, jsonb_build_array(jsonb_build_object('frame', '81000000-0000-0000-0000-0000000000f1',
                                                   'group', '81000000-0000-0000-0000-0000000000a1')),
       v_s)) = '' then
    raise exception 'FAIL 19: a participant took a badge through the door';
  end if;
end $t$;

rollback;
