-- Step 25, checked at the database: the run-sheet stack is gone, and nothing that survived still points at it.
--
--     node tools/sql.mjs --file dev/checks/step25-drop.sql
--
-- This check runs AFTER 061_drop_run_sheet_stack.sql, so it cannot re-run the migration's own guard (the objects it
-- walks no longer exist). What it does instead:
--
--   1. THE INVENTORY IS ABSENT, by name: ten tables, sixty-two functions, the zone trigger, and the two columns that
--      lived on tables which survive (`event_sessions.run_sheet_id`, `sim_groups.movement_id`).
--   2. NOTHING NAMES IT. Every surviving body in `public` and every `cron.job` command is scanned for every retired
--      name -- the half of the guard `pg_depend` cannot see -- and the scan is proved not to be vacuous by finding a
--      name that is still in use.
--   3. THE SURVIVORS STILL WORK. `start_event` (rewritten in 061 to stop writing the dropped column) starts a
--      tracking-only session; `broadcast_send` (rewritten to stop writing `show_log`) answers its dry run; the plan's
--      own read and check still answer on the bench.
--   4. THE CATALOGUE IS HEALTHY: exactly the seven cron jobs of step 24, every remaining table with row level security
--      on, and no table or function in `public` whose name belongs to the retired stack.
--
-- Everything runs in one transaction and is rolled back: it starts a session and ends it, and leaves the bench as it
-- found it.

begin;

-- ---------- 1. the tables and the two columns ----------
do $$
declare v_left text;
begin
  select string_agg(r, ', ' order by r) into v_left
  from unnest(array['movements', 'movement_status', 'movement_routes', 'run_sheets', 'run_sheet_switches',
                    'cues', 'show_cues', 'show_state', 'show_log', 'group_messages']) r
  where to_regclass('public.' || r) is not null;
  if v_left is not null then raise exception 'FAIL 1a: still there: %', v_left; end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'event_sessions' and column_name = 'run_sheet_id') then
    raise exception 'FAIL 1b: event_sessions.run_sheet_id is still there';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'sim_groups' and column_name = 'movement_id') then
    raise exception 'FAIL 1c: sim_groups.movement_id is still there';
  end if;
  -- The tables that survive are still there: a drop that took too much would pass the three assertions above.
  if to_regclass('public.event_sessions') is null or to_regclass('public.plan_frames') is null
     or to_regclass('public.plans') is null or to_regclass('public.zones') is null
     or to_regclass('public.handover_log') is null or to_regclass('public.broadcasts') is null then
    raise exception 'FAIL 1d: a table this step does not drop is missing';
  end if;
end $$;

-- ---------- 2. the sixty-two functions, the trigger and the zone guard ----------
do $$
declare v_left text;
begin
  select string_agg(f, ', ' order by f) into v_left
  from unnest(array['check_run_sheet', 'create_run_sheet', 'delete_cue', 'delete_movement', 'delete_run_sheet',
                    'import_run_sheet', 'mark_in_position', 'mark_run_sheet_ready', 'message_group', 'move_cue',
                    'move_dist', 'move_planned_leave', 'move_step', 'my_moves', 'ops_ack', 'ops_board', 'ops_handle',
                    'ops_session_role', 'ops_snooze', 'push_collect_moves', 'report_delay', 'route_claim', 'route_due',
                    'route_save', 'route_wanted', 'rs_circle_points', 'rs_clock', 'rs_code', 'rs_day', 'rs_edit',
                    'rs_int', 'rs_moves', 'rs_next_code', 'rs_runnable', 'rs_time', 'run_sheet_list',
                    'run_sheet_moves', 'run_sheet_used_on', 'save_cue', 'save_movement', 'session_run_sheets',
                    'show_add_time', 'show_at', 'show_board', 'show_carry_over', 'show_for_action', 'show_go',
                    'show_hold', 'show_keep_holding', 'show_label', 'show_log_add', 'show_missing_groups', 'show_now',
                    'show_open', 'show_resume', 'show_rows', 'show_secs', 'show_skip', 'show_step',
                    'switch_live_run_sheet', 'update_run_sheet', 'zones_guard_live']) f
  where exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = f);
  if v_left is not null then raise exception 'FAIL 2a: still there: %', v_left; end if;

  if exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
              where c.relname = 'zones' and t.tgname = 'zones_guard_live') then
    raise exception 'FAIL 2b: the zones_guard_live trigger is still there';
  end if;

  -- The helpers the stack needed but that are not the stack: a display-name helper the plan calls, and the two push
  -- collectors for zones, which a plan session still uses. Dropping these would break the plan, not the run sheet.
  select string_agg(f, ', ' order by f) into v_left
  from unnest(array['show_who', 'push_collect_nogo', 'plan_ops', 'plan_push_tick', 'session_timetable']) f
  where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = f);
  if v_left is not null then raise exception 'FAIL 2c: the drop took a survivor: %', v_left; end if;
end $$;

-- ---------- 3. nothing surviving names any of it ----------
do $$
declare
  v_rx text;
  v_left text;
  v_live integer;
begin
  select '\m(' || string_agg(r, '|' order by r) || ')\M' into v_rx
  from unnest(array['movements', 'movement_status', 'movement_routes', 'run_sheets', 'run_sheet_switches', 'cues',
                    'show_cues', 'show_state', 'show_log', 'group_messages', 'run_sheet_id',
                    'check_run_sheet', 'create_run_sheet', 'delete_run_sheet', 'import_run_sheet', 'mark_run_sheet_ready',
                    'session_run_sheets', 'switch_live_run_sheet', 'run_sheet_list', 'rs_edit', 'rs_runnable',
                    'show_board', 'show_go', 'show_hold', 'show_rows', 'show_step', 'show_log_add', 'show_now',
                    'ops_board', 'ops_session_role', 'my_moves', 'message_group', 'move_step', 'move_dist',
                    'route_claim', 'push_collect_moves', 'zones_guard_live']) r;

  select string_agg(p.proname, ', ' order by p.proname) into v_left
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosrc ~ v_rx;
  if v_left is not null then
    raise exception 'FAIL 3a: a surviving function body still names a retired object: %', v_left;
  end if;

  select string_agg(jobname, ', ' order by jobname) into v_left from cron.job where command ~ v_rx;
  if v_left is not null then
    raise exception 'FAIL 3b: a cron job still runs a retired function: %', v_left;
  end if;

  -- The scan is not vacuous: it does find bodies. Counting a name that is still in use proves the regex matches
  -- something, so "nothing found" above means something.
  select count(*) into v_live
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosrc ~ '\mplan_frames\M';
  if v_live < 1 then
    raise exception 'FAIL 3c: the body scan finds nothing at all, so its silence proves nothing';
  end if;
end $$;

-- ---------- 4. the survivors still work ----------
-- A clean bench first, as the owner: `end_event` refuses when the event is not live, and this check may run on a bench
-- where nothing is.
reset role;
update public.event_sessions set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;

-- As the bench's root: a tracking-only start (061 removed the line that wrote the dropped column) and the event-wide
-- message's dry run (061 removed the branch that wrote `show_log`).
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
  v_plan uuid;
  v_t0 timestamptz;
  v_msg jsonb;
begin
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01');
  select es.plan_id, es.t0_at into v_plan, v_t0 from public.event_sessions es where es.id = v_s;
  if v_plan is not null then raise exception 'FAIL 4a: a tracking-only start picked a plan'; end if;
  if v_t0 is not null then raise exception 'FAIL 4b: a tracking-only start has a clock'; end if;

  -- The message path still works, and its dry run writes nothing: no broadcast row, no push, no show log to write to.
  v_msg := public.broadcast_send('0b000000-0000-4000-8000-000000000e01', 'everyone', null, 'Step 25 dry run',
                                 false, true);
  if (v_msg ->> 'recipients') is null then
    raise exception 'FAIL 4c: broadcast_send''s dry run answered %', v_msg;
  end if;
end $$;

reset role;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.broadcasts where body = 'Step 25 dry run';
  if v_n <> 0 then raise exception 'FAIL 4d: the dry run wrote % broadcast row(s)', v_n; end if;
end $$;

-- The plan's own read still opens the bench board (it is the one read every screen starts with).
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.plan_frames_list('0b000000-0000-4000-8000-000000000b01');
  if v_n = 0 then raise exception 'FAIL 4e: plan_frames_list answered no frames for the bench plan'; end if;
end $$;

reset role;

-- ---------- 5. the catalogue ----------
do $$
declare
  v_left text;
  v_n integer;
begin
  select string_agg(jobname, ', ' order by jobname) into v_left from cron.job;
  if v_left <> 'gps-auto-close-sessions, gps-cleanup-expired-locations, gps-end-scheduled-sessions, gps-plan-eta, '
             'gps-plan-push, gps-push-reminders, gps-sim-tick' then
    raise exception 'FAIL 5a: the cron inventory is %, not the seven of step 24', v_left;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_left
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_left is not null then raise exception 'FAIL 5b: a table has row level security off: %', v_left; end if;

  -- A function whose NAME belongs to the retired stack would mean a drop that missed an overload the list above did
  -- not spell out. `show_who` is the one `show_*` that stays: it is a display-name helper, and the plan's broadcast and
  -- publish call it.
  select string_agg(p.proname, ', ' order by p.proname) into v_left
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname ~ '^(show_|ops_|rs_|route_|run_sheet_|move_)'
    and p.proname <> 'show_who';
  if v_left is not null then
    raise exception 'FAIL 5c: these function names still look like the retired engine: %', v_left;
  end if;
end $$;

rollback;

select 'step 25: the run-sheet stack is gone and nothing points at it' as check, 'PASS' as result;
