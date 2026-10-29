-- Step 2, checked at the database: a session runs a plan, and the two-engine rule that step 2 introduced.
--
--     node tools/sql.mjs --file dev/checks/step2-session-plan.sql
--
-- Step 24 (060) retired the run-sheet half of the rule and rewrote what this check can say. "A session runs a plan or a
-- run sheet, never both" is now "a session runs a plan or nothing": the start functions have no run-sheet parameter to
-- pass, so the old door is a function that does not exist. Step 25 (061) then deleted the engine and the column, so the
-- sections below are step 2's own proof (an unpublished plan is refused, publishing is the gate, renaming keeps the
-- status, the session records its plan and its clock), a tracking-only start that still works, and the absence of the
-- old engine -- asserted by name, table and column.
--
-- It runs as testuser1 (root + planner of the fixture event), through the same functions the buttons call, and
-- finishes by printing one row. Any assertion that is false raises, so a passing run is a run that printed a row.
--
-- The session it starts is carried between blocks in a transaction-local setting rather than a temp table: the
-- Management API is not committed to running a multi-statement script on one connection, and a check that depends on
-- that would fail in a way that looks like a bug in the thing being checked.
begin;

-- ---------- a clean bench ----------
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';
update public.plans set status = 'draft' where id = '0b000000-0000-4000-8000-000000000b01';
update public.plans set status = 'ready' where id = '0b000000-0000-4000-8000-000000000b02';

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 1. an unpublished plan cannot be run ----------
do $$
declare v_refused boolean := false;
begin
  begin
    perform public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b02');
  exception when others then
    v_refused := sqlerrm like '%not published%';
    if not v_refused then raise; end if;
  end;
  if not v_refused then
    raise exception 'FAIL 1: a draft plan was started without being published';
  end if;
end $$;

-- ---------- 2. publishing it is the gate, and it passes for the clean plan ----------
do $$
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b02', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b02'));
  if (select status from public.plans where id = '0b000000-0000-4000-8000-000000000b02') <> 'live' then
    raise exception 'FAIL 2: plan_publish did not make the plan live';
  end if;
end $$;

-- ---------- 2b. renaming a published plan keeps it published ----------
-- The board's rename sends {id, name, rev} and nothing else. plan_save used to default status to 'draft', so editing
-- the name of the plan everyone was following unpublished it silently.
do $$
declare v_before text; v_after text; v_rev integer;
begin
  select status, rev into v_before, v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b02';
  perform public.plan_save('0b000000-0000-4000-8000-000000000e01',
    jsonb_build_object('id', '0b000000-0000-4000-8000-000000000b02', 'name', 'Clean walk (renamed)', 'rev', v_rev));
  select status into v_after from public.plans where id = '0b000000-0000-4000-8000-000000000b02';
  if v_after <> v_before then
    raise exception 'FAIL 2b: renaming a % plan made it %', v_before, v_after;
  end if;
  perform public.plan_save('0b000000-0000-4000-8000-000000000e01',
    jsonb_build_object('id', '0b000000-0000-4000-8000-000000000b02', 'name', 'Clean walk',
                       'rev', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b02')));
end $$;

-- ---------- 3. the run-sheet door is gone ----------
-- Step 2's rule used to be enforced by a CHECK: a session with a plan AND a run sheet raised. Step 24 removed the
-- parameter, so the refusal is now at the door -- there is no three-argument start_event to call, and a run-sheet id
-- handed in as the plan is refused because it is not one of this event's plans.
do $$
declare v_refused boolean := false; v_refused_sched boolean := false;
begin
  if to_regprocedure('public.start_event(uuid,uuid,uuid)') is not null then
    raise exception 'FAIL 3a: the three-argument start_event still exists';
  end if;
  if to_regprocedure('public.start_event(uuid,uuid)') is null then
    raise exception 'FAIL 3b: start_event(event, plan) does not exist';
  end if;

  begin
    -- 7920a13c-... is a real run sheet of another event, which is exactly what an old client would still send.
    perform public.start_event('0b000000-0000-4000-8000-000000000e01', '7920a13c-6a46-47dc-bbf1-8e1f450c57dc');
  exception when others then
    v_refused := sqlerrm like '%not in this event%';
    if not v_refused then raise; end if;
  end;
  if not v_refused then
    raise exception 'FAIL 3c: a run sheet was accepted as a plan';
  end if;

  begin
    perform public.schedule_event_start('0b000000-0000-4000-8000-000000000e01', now() + interval '1 hour',
                                        '7920a13c-6a46-47dc-bbf1-8e1f450c57dc');
  exception when others then
    v_refused_sched := sqlerrm like '%not in this event%';
    if not v_refused_sched then raise; end if;
  end;
  if not v_refused_sched then
    raise exception 'FAIL 3d: the scheduler accepted a run sheet as a plan';
  end if;
  if exists (select 1 from public.event_sessions
              where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null) then
    raise exception 'FAIL 3e: a refused call left an open session behind';
  end if;
end $$;

-- ---------- 4. start on the plan, and the row says what it runs ----------
do $$
declare v_s uuid; v record;
begin
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b02');
  perform set_config('check.session', v_s::text, true);

  select es.plan_id, es.t0_at, es.plan_rev, p.rev as plan_now
    into v
  from public.event_sessions es join public.plans p on p.id = es.plan_id
  where es.id = v_s;

  if v.plan_id is null then raise exception 'FAIL 4a: the session does not say which plan it runs'; end if;
  if v.plan_rev <> v.plan_now then
    raise exception 'FAIL 4c: plan_rev is % but the plan is at %', v.plan_rev, v.plan_now;
  end if;
  -- 18:00 today, in Singapore: the plan's clock, which is 45 minutes before the session's own start.
  if v.t0_at <> (((current_date::timestamp + time '18:00') at time zone 'Asia/Singapore')) then
    raise exception 'FAIL 4d: t0_at is %, expected 18:00 today', v.t0_at;
  end if;
end $$;

-- ---------- 5. a tracking-only start is still a start, and there is no sheet to carry ----------
do $$
declare v_s uuid; v record;
begin
  -- check.session is left pointing at the plan session: section 6 asks about that one, not this tracking-only one.
  perform public.end_event('0b000000-0000-4000-8000-000000000e01');
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01');
  select es.plan_id, es.t0_at, es.plan_rev into v
    from public.event_sessions es where es.id = v_s;
  if v.plan_id is not null then raise exception 'FAIL 5a: a tracking-only start picked a plan by itself'; end if;
  if v.t0_at is not null then raise exception 'FAIL 5c: a session with no plan has a clock (t0_at = %)', v.t0_at; end if;
end $$;

reset role;

-- ---------- 6. the old engine is gone, not merely skipping plan sessions ----------
-- Step 2's positive control (the same ticks still drive a run-sheet session) cannot exist any more: step 25 deleted
-- the tables, the functions and the ticks. What replaces it is the absence, asserted by name -- the tables are not
-- there, the functions are not there, the column is not there, and no surviving body names any of them.
do $$
declare v_left text;
begin
  select string_agg(r, ', ') into v_left
  from unnest(array['movements','movement_status','movement_routes','run_sheets','run_sheet_switches','cues',
                    'show_cues','show_state','show_log','group_messages']) r
  where to_regclass('public.' || r) is not null;
  if v_left is not null then raise exception 'FAIL 6a: still there: %', v_left; end if;

  select string_agg(f, ', ') into v_left
  from unnest(array['show_tick','move_tick','sim_plan_movements','push_collect_moves','move_step','show_step',
                    'show_board','my_moves','ops_board','session_run_sheets','switch_live_run_sheet']) f
  where exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = f);
  if v_left is not null then raise exception 'FAIL 6b: still there: %', v_left; end if;

  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.prosrc ~ '\m(show_tick|move_tick|zz_walk_tick|sim_plan_movements|push_collect_moves|move_step|show_state)\M') then
    raise exception 'FAIL 6c: a function body still names a retired engine object';
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'event_sessions' and column_name = 'run_sheet_id') then
    raise exception 'FAIL 6d: event_sessions still has a run_sheet_id column';
  end if;
end $$;

-- ---------- tidy up: the bench goes back to "nothing has run" ----------
update public.event_sessions
   set ended_at = now(), end_reason = 'ended'
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';

commit;

select jsonb_build_object(
  'unpublished_refused', 'yes',
  'run_sheet_door', 'gone',
  'rename_kept_status', 'yes',
  'plan_session_started', 'yes',
  'tracking_only_start', 'yes, with no clock',
  'old_engine', 'deleted: 10 tables, 62 functions, the column',
  'left_open', (select count(*) from public.event_sessions where ended_at is null)
) as step2;
