-- 061_drop_run_sheet_stack.sql
--
-- Step 25 of the planning plan: delete the run-sheet stack. Step 24 closed the last doors into it -- a session can no
-- longer run a run sheet, three of its cron jobs are gone and the simulator walks the strip -- so nothing in the
-- product can reach any of this any more. This file takes it out of the database and proves, before it does, that
-- nothing left behind still points at it.
--
-- THE INVENTORY, FROM THE CATALOGUE AND NOT FROM THE LEDGER. The plan's earlier list was partly wrong, and the way it
-- was wrong is the reason this file begins with a query rather than a list. What actually exists: ten tables
-- (`movements`, `movement_status`, `movement_routes`, `run_sheets`, `run_sheet_switches`, `cues`, `show_cues`,
-- `show_state`, `show_log`, `group_messages`), sixty-two functions (the run-sheet CRUD, its `rs_*` helpers, the whole
-- show/GO engine, the ops board, the member's `my_moves`, the route planner and the three helpers that only they
-- used), one column on a table that SURVIVES (`event_sessions.run_sheet_id`) and one more on a table that survives
-- (`sim_groups.movement_id`), and one trigger (`zones_guard_live`). `session_run_sheets` is a FUNCTION, not a table as
-- the first list said; `show_cues` was missing from that list; and `ic_moves` and `delays` never existed at all. The
-- list below was printed by the catalogue, and the pool of what it leaves behind was checked by scanning every
-- surviving body for every name in it.
--
-- WHY A GUARD AND NOT JUST `DROP TABLE`. Postgres records in `pg_depend` what a view, a trigger, a column default, a
-- foreign key and a function's return type depend on -- and NOT what a plpgsql body reads. Writing
-- `drop table public.movements` against a function that still selects from it SUCCEEDS: the table goes, the function
-- stays, and the failure arrives on the next push tick, in production, as "relation does not exist". So this file
-- proves four things before it drops anything, and any one of them aborts the whole transaction, which is the only
-- way to make "abort rather than half-apply" true:
--
--   1. Every object in the inventory is really there. A stale list run against another database must fail, not
--      quietly do nothing.
--   2. `pg_depend` has no dependent of an inventory object that is outside the inventory. The walk is transitive
--      because a function's return type is two hops from its table (function -> type -> table), and it treats "an
--      object hanging off a table this file drops" (an index, a constraint) as part of the plan rather than as a
--      finding.
--   3. No surviving function body names an inventory object, and no `cron.job` command does. This is the half
--      `pg_depend` cannot see, and it is the half that would actually break in production.
--   4. The inventory is not empty: seventy-five objects were vouched for. A guard that inspects nothing passes.
--
-- The same walk runs again at the end, as a post-check, and says every object in the inventory is gone -- by oid, so
-- there is no second list to keep in step. It also asserts the cron inventory is still exactly seven jobs (step 24's
-- seven) and that every table this file leaves behind has row level security on.
--
-- NO `CASCADE`, ANYWHERE. `drop table ... cascade` would drop the view, the column default and the constraint it found
-- and report success -- the very outcome the guard exists to prevent. Every drop below names its object and fails
-- loudly if something it did not know about is in the way.
--
-- THREE FUNCTIONS ARE REWRITTEN, NOT DROPPED, because they survive and mentioned what is leaving:
--   * `start_event` and `schedule_event_start` set `run_sheet_id = null` on a session they re-use. With the column
--     gone the line goes; nothing else changes, and their signatures and grants stay (create or replace, R2 does not
--     apply because nothing about them changes but a line).
--   * `broadcast_send` (032) wrote a `show_log` line when a show was running. A plan session has no show and a
--     tracking-only session never had one, so the branch goes and the message is the push and the banner it always
--     was. Its `show_state` probe goes with it.
-- Those three are `create or replace`, so the grants of 032 and 060 are untouched.
--
-- WHAT IS REPLACED BY NOTHING, AND WHY THAT IS HONEST. `message_group` (the ops board's note to one group) wrote into
-- `show_state`/`show_log` and is deleted with them, so `group_messages` -- which nothing else ever wrote -- goes too,
-- and the member's "message from the planners" banner with it: a message with no sender is not a feature. The plan's
-- own `plan_broadcast` (058) is the replacement and has been since step 22. `my_moves`/`NextMoveCard` (a member's
-- next move, read from `movements`) is replaced by the timetable (`session_timetable`, 051) which was built for
-- exactly that screen in step 16. The ops board (`ops_board`, `OpsQueue`, `OpsDecision`, `OpsSummary`, and the map's
-- clusters) is replaced by `plan_ops`/`PlanOps` in step 20. `switch_live_run_sheet` and the Run sheet tab are
-- replaced by "publish the plan" (054/057).
--
-- WHAT SURVIVES THAT LOOKS LIKE IT BELONGS HERE. `show_who(uuid)` is a display-name helper the plan's broadcast and
-- publish call; it never touched the show. `zones`, `zone_alerts`, `zone_presence`, `handover_log` and every `plan_*`
-- object stay. So do the GPS recording playback (`playback_list`, `location_history`, `delete_recording`) and the
-- event-wide broadcast (032) -- neither is the run-sheet engine.
--
-- ONE THING THIS FILE STOPS GUARDING. `zones_guard_live` refused to delete a zone that a live movement pointed at.
-- A plan's positions are lat/lng, not zone rows, so a plan no longer pins a zone to anything; the trigger's only
-- remaining effect would be to refuse a deletion with no reason, so it goes. The loss is real and is recorded as a
-- debt: a planner can now delete a zone while the event is live, and its alerts and presence rows go with it (both
-- `on delete cascade`). A live-event guard for zones is a product decision to make, not a show leftover to keep.
--
-- WHAT THIS FILE CANNOT DELETE. The client modules (`RunSheetPanel`, `RunSheetImport`, `MovementEditor`, `ShowBar`,
-- `ShowPanel`, `CueChips`, `OpsQueue`, `OpsDecision`, `OpsSummary`, `NextMoveCard`, `runSheetFile.js`, `useRunSheets`,
-- `useShow`, `useOps`, `useMyMoves`, `useGroupMessages`, `opsStatus`), the `route-eta` Edge Function that was the only
-- caller of `route_claim`/`route_save`, the two run-sheet test tools, the six legacy PGlite suites that test the
-- dropped functions, and the Run sheet tab itself went in the same change, in the repository.
--
-- R1 (`extensions.` qualified -- nothing here needs it), R4 (nothing new is granted; the three replacements keep the
-- grants their signatures already had). `notify pgrst, 'reload schema'` is at the end: PostgREST caches tables and
-- signatures, and without it the dropped endpoints answer for a while yet and the rewritten ones answer from a cache
-- with the old column.

-- ============================================================
-- 1. The three survivors that mentioned what is leaving
-- ============================================================
-- The two start functions: the same bodies as 060, without `run_sheet_id = null` (the column is dropped in section 3).
create or replace function public.start_event(p_event_id uuid, p_plan uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $body$
declare
  open_session public.event_sessions;
  new_id uuid;
  v_t0 timestamptz;
  v_rev integer;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can start the event' using errcode = '42501';
  end if;
  v_t0 := public.session_engine(p_event_id, p_plan);
  select rev into v_rev from public.plans where id = p_plan;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live';
    end if;
    update public.event_sessions
       set starts_at = now(), started_by = auth.uid(), plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0)
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, plan_id, t0_at, plan_rev)
  values (p_event_id, now(), auth.uid(), p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

create or replace function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz, p_plan uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $body$
declare
  open_session public.event_sessions;
  new_id uuid;
  v_t0 timestamptz;
  v_rev integer;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can schedule the event' using errcode = '42501';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Pick a start time in the future';
  end if;
  if p_starts_at > now() + interval '1 year' then
    raise exception 'Pick a start time within the next year';
  end if;
  v_t0 := public.session_engine(p_event_id, p_plan);
  select rev into v_rev from public.plans where id = p_plan;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions
       set starts_at = p_starts_at, started_by = auth.uid(), plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0),
           scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, plan_id, t0_at, plan_rev)
  values (p_event_id, p_starts_at, auth.uid(), p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

comment on function public.start_event(uuid, uuid) is
  'Starts the event now, on a published plan or on nothing (step 24). The session no longer has a run sheet (step 25).';
comment on function public.schedule_event_start(uuid, timestamptz, uuid) is
  'Schedules the start on a published plan, or on nothing (step 24). The session no longer has a run sheet (step 25).';

-- The event-wide message (032): the same body, without the `show_log` line it used to write when a show was running.
create or replace function public.broadcast_send(
  p_event uuid, p_audience text, p_value text, p_body text,
  p_urgent boolean default false, p_dry boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_me uuid := auth.uid();
  v_from text := public.show_who(auth.uid());
  v_session uuid;
  v_id bigint;
  v_count integer;
  v_sim boolean;
  v_label text;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root and planners can message everyone' using errcode = '42501';
  end if;
  if p_audience not in ('everyone', 'groups', 'ics', 'staff', 'sector', 'category') then
    raise exception 'Pick who gets the message';
  end if;
  p_value := nullif(btrim(coalesce(p_value, '')), '');
  if p_audience in ('sector', 'category') and p_value is null then
    raise exception 'Pick the %', p_audience;
  end if;
  if p_audience not in ('sector', 'category') then
    p_value := null;
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 300 then
    raise exception 'Write a message of 1 to 300 characters';
  end if;
  select count(*) into v_count from public.broadcast_audience(p_event, p_audience, p_value, v_me);
  if p_dry then
    return jsonb_build_object('recipients', v_count);
  end if;
  if v_count = 0 then
    raise exception 'Nobody would get this message: no one in the event matches "%"', coalesce(p_value, p_audience);
  end if;
  select s.id into v_session from public.event_sessions s
  where s.event_id = p_event and s.ended_at is null and s.starts_at <= now()
  order by s.starts_at desc limit 1;
  insert into public.broadcasts (event_id, session_id, audience, audience_value, body, urgent, from_user, from_name)
  values (p_event, v_session, p_audience, p_value, p_body, coalesce(p_urgent, false), v_me, v_from)
  returning id into v_id;
  insert into public.broadcast_recipients (broadcast_id, user_id)
  select v_id, a.user_id from public.broadcast_audience(p_event, p_audience, p_value, v_me) a;
  v_label := case p_audience
    when 'everyone' then 'everyone'
    when 'groups' then 'every group'
    when 'ics' then 'all ICs and group admins'
    when 'staff' then 'the planners and marshals'
    when 'sector' then 'sector ' || p_value
    else 'every ' || p_value || ' group' end;
  select e.is_simulation into v_sim from public.events e where e.id = p_event;
  if not coalesce(v_sim, false) then
    insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
    select r.user_id, p_event, v_session, 'message', 'broadcast:' || v_id || ':' || r.user_id,
           case when p_urgent then 'URGENT · ' else '' end || 'Message from ' || v_from || ' to ' || v_label, p_body,
           jsonb_build_object('kind', 'message', 'eventId', p_event, 'broadcastId', v_id, 'tag', 'broadcast-' || v_id)
    from public.broadcast_recipients r
    where r.broadcast_id = v_id
    on conflict (dedup) do nothing;
  end if;
  perform public.push_kick();
  return jsonb_build_object('id', v_id, 'recipients', v_count);
end;
$body$;

-- ============================================================
-- 2. The inventory, and the guard that proves nothing outside it depends on it
-- ============================================================
-- `if exists` on the three scratch objects, so that a second run in the same session fails on the INVENTORY -- which
-- says what is missing -- rather than on a temporary table that is still lying about.
drop table if exists pg_temp._target;
create temporary table _target (
  classid oid not null,
  objid   oid not null,
  name    text not null, -- the bare identifier, for the body scan
  label   text not null,
  primary key (classid, objid)
) on commit drop;

-- How to name what pg_depend found, in words a person can act on.
create or replace function pg_temp.what(p_classid oid, p_objid oid) returns text
language sql stable as $f$
  select case p_classid
    when 'pg_class'::regclass then
      (select case relkind when 'r' then 'table ' when 'v' then 'view ' when 'm' then 'materialized view '
                           when 'i' then 'index ' when 'S' then 'sequence ' else 'relation ' end || relname
         from pg_class where oid = p_objid)
    when 'pg_proc'::regclass then
      (select 'function ' || proname || '(' || pg_get_function_identity_arguments(oid) || ')'
         from pg_proc where oid = p_objid)
    when 'pg_constraint'::regclass then 'constraint ' || (select conname from pg_constraint where oid = p_objid)
    when 'pg_policy'::regclass then
      'policy ' || (select polname || ' on ' || polrelid::regclass::text from pg_policy where oid = p_objid)
    when 'pg_trigger'::regclass then
      'trigger ' || (select tgname || ' on ' || tgrelid::regclass::text from pg_trigger where oid = p_objid)
    when 'pg_rewrite'::regclass then 'view ' || (select ev_class::regclass::text from pg_rewrite where oid = p_objid)
    when 'pg_attrdef'::regclass then
      'column default on ' || (select adrelid::regclass::text from pg_attrdef where oid = p_objid)
    when 'pg_type'::regclass then 'type ' || (select typname from pg_type where oid = p_objid)
    else p_classid::regclass::text || ' ' || p_objid::text
  end
$f$;

-- The relation an object hangs off. A constraint that belongs to a table this file drops is part of the plan, not a
-- finding: the walk uses this to tell the two apart.
create or replace function pg_temp.owner_of(p_classid oid, p_objid oid) returns oid
language sql stable as $f$
  select case p_classid
    when 'pg_constraint'::regclass then (select conrelid from pg_constraint where oid = p_objid)
    when 'pg_policy'::regclass then (select polrelid from pg_policy where oid = p_objid)
    when 'pg_trigger'::regclass then (select tgrelid from pg_trigger where oid = p_objid)
    when 'pg_rewrite'::regclass then (select ev_class from pg_rewrite where oid = p_objid)
    when 'pg_attrdef'::regclass then (select adrelid from pg_attrdef where oid = p_objid)
    when 'pg_class'::regclass then coalesce((select indrelid from pg_index where indexrelid = p_objid), p_objid)
    when 'pg_type'::regclass then (select typrelid from pg_type where oid = p_objid)
  end
$f$;

do $fill$
declare
  v_rel text[] := array[
    'movements', 'movement_status', 'movement_routes', 'run_sheets', 'run_sheet_switches',
    'cues', 'show_cues', 'show_state', 'show_log', 'group_messages'];
  v_fn text[] := array[
    -- the run sheet and its cues and movements
    'create_run_sheet', 'update_run_sheet', 'delete_run_sheet', 'run_sheet_list', 'run_sheet_moves',
    'run_sheet_used_on', 'mark_run_sheet_ready', 'check_run_sheet', 'import_run_sheet', 'switch_live_run_sheet',
    'session_run_sheets', 'save_cue', 'delete_cue', 'move_cue', 'save_movement', 'delete_movement',
    -- the helpers only they used
    'rs_edit', 'rs_moves', 'rs_runnable', 'rs_clock', 'rs_code', 'rs_day', 'rs_int', 'rs_next_code', 'rs_time',
    'rs_circle_points',
    -- the show / GO engine
    'show_board', 'show_go', 'show_hold', 'show_resume', 'show_skip', 'show_add_time', 'show_open', 'show_rows',
    'show_for_action', 'show_log_add', 'show_carry_over', 'show_keep_holding', 'show_missing_groups', 'show_step',
    'show_at', 'show_secs', 'show_label', 'show_now',
    -- the ops board
    'ops_board', 'ops_ack', 'ops_handle', 'ops_snooze', 'ops_session_role',
    -- a member's next move, the ops note to a group, the movement clock and the route planner
    'my_moves', 'mark_in_position', 'report_delay', 'message_group', 'move_step', 'move_planned_leave',
    'push_collect_moves', 'route_claim', 'route_wanted', 'route_save', 'route_due', 'move_dist',
    -- the zone guard that only the show needed
    'zones_guard_live'];
  v_missing text;
begin
  select string_agg(r, ', ') into v_missing from unnest(v_rel) r where to_regclass('public.' || r) is null;
  if v_missing is not null then
    raise exception 'DROP INVENTORY: no such table in public: %. This file must be written against the catalogue it '
      'runs on.', v_missing;
  end if;
  insert into _target
  select 'pg_class'::regclass, to_regclass('public.' || r)::oid, r, 'table ' || r from unnest(v_rel) r;

  select string_agg(f, ', ') into v_missing
  from unnest(v_fn) f
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then
    raise exception 'DROP INVENTORY: no such function in public: %', v_missing;
  end if;
  insert into _target
  select 'pg_proc'::regclass, p.oid, p.proname,
         'function ' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = any(v_fn);

  -- The two dependents that are part of the plan rather than findings: a column this file drops carries its foreign
  -- key with it, and the zone trigger is dropped in section 3.
  insert into _target
  select 'pg_trigger'::regclass, t.oid, t.tgname, 'trigger ' || t.tgname || ' on zones'
  from pg_trigger t
  where t.tgrelid = 'public.zones'::regclass and t.tgname = 'zones_guard_live';

  insert into _target
  select 'pg_constraint'::regclass, c.oid, c.conname, 'constraint ' || c.conname || ' on ' || c.conrelid::regclass::text
  from pg_constraint c
  where c.conname in ('event_sessions_run_sheet_id_fkey', 'sim_groups_movement_id_fkey');
end
$fill$;

do $guard$
declare
  v_bad text;
  v_rx text;
  v_count integer;
begin
  select count(*) into v_count from _target;
  if v_count <> 75 then
    raise exception 'DROP INVENTORY: expected 75 objects (10 tables, 62 functions, 1 trigger, 2 foreign keys), found '
      '%. A guard that inspects nothing passes.', v_count;
  end if;

  -- 2b. Nothing outside the inventory depends on anything inside it. The walk is (i, a) first -- indexes,
  -- constraints, row types, sequences, toast: the parts of a table -- and then one step along (n) edges, which is
  -- where a foreign key from another table, a view, a trigger on another table, a column default or a function's
  -- return type shows up.
  with recursive inside as (
    select classid, objid from _target
    union
    select d.classid, d.objid
    from pg_depend d
    join inside i on i.classid = d.refclassid and i.objid = d.refobjid
    where d.deptype in ('i', 'a')
  ),
  outside as (
    select distinct d.classid, d.objid
    from pg_depend d
    join inside i on i.classid = d.refclassid and i.objid = d.refobjid
    where d.deptype = 'n'
  )
  select string_agg(distinct pg_temp.what(o.classid, o.objid), E'\n  ') into v_bad
  from outside o
  where not exists (select 1 from _target t where t.classid = o.classid and t.objid = o.objid)
    and coalesce(pg_temp.owner_of(o.classid, o.objid), 0::oid)
        not in (select objid from _target where classid = 'pg_class'::regclass);
  if v_bad is not null then
    raise exception E'NOTHING WAS DROPPED. These objects depend on something this file removes and are not part of '
      'the plan:\n  %\nTake them out of the way first, or add them to the inventory with a reason.', v_bad;
  end if;

  -- 3. What pg_depend cannot see: the bodies. A plpgsql function that still selects from `movements` looks clean to
  -- the walk above and breaks on its next call.
  select '\m(' || string_agg(name, '|' order by name) || ')\M' into v_rx from _target;
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosrc ~ v_rx
    and not exists (select 1 from _target t where t.classid = 'pg_proc'::regclass and t.objid = p.oid);
  if v_bad is not null then
    raise exception E'NOTHING WAS DROPPED. These function bodies still name something this file removes:\n  %',
      v_bad;
  end if;

  select string_agg(jobname, ', ' order by jobname) into v_bad from cron.job where command ~ v_rx;
  if v_bad is not null then
    raise exception 'NOTHING WAS DROPPED. These cron jobs still run a function this file removes: %. Unschedule them '
      'in the file that drops their function, not in one that leaves the job pointing at nothing.', v_bad;
  end if;
end
$guard$;

-- ============================================================
-- 3. The trigger and the two columns that survive their tables
-- ============================================================
-- Dropped before its function, because a trigger is a dependent of the function it calls.
drop trigger zones_guard_live on public.zones;

-- The foreign key goes with the column, but naming it is the honest order: the column is what the product used.
alter table public.event_sessions drop column run_sheet_id;

-- `sim_groups.movement_id` was the last column in the schema pointing at `movements`. The simulator follows the
-- plan's moments now (060) and never read it.
alter table public.sim_groups drop column movement_id;

-- ============================================================
-- 4. The engine
-- ============================================================
drop function public.zones_guard_live();
drop function public.check_run_sheet(uuid);
drop function public.create_run_sheet(uuid, text, date, uuid);
drop function public.delete_cue(uuid);
drop function public.delete_movement(uuid);
drop function public.delete_run_sheet(uuid);
drop function public.import_run_sheet(uuid, jsonb);
drop function public.mark_in_position(uuid, uuid, uuid, boolean);
drop function public.mark_run_sheet_ready(uuid);
drop function public.message_group(uuid, uuid, text);
drop function public.move_cue(uuid, integer);
drop function public.move_dist(geography, geography, double precision, double precision, double precision);
drop function public.move_planned_leave(text, uuid, date, timestamptz);
drop function public.move_step(uuid, timestamptz);
drop function public.my_moves(uuid);
drop function public.ops_ack(uuid, uuid, uuid);
drop function public.ops_board(uuid, timestamptz);
drop function public.ops_handle(uuid, uuid, uuid);
drop function public.ops_session_role(uuid, text[]);
drop function public.ops_snooze(uuid, uuid, uuid, integer);
drop function public.push_collect_moves(uuid, timestamptz);
drop function public.report_delay(uuid, uuid, uuid, text);
drop function public.route_claim(integer);
drop function public.route_due();
drop function public.route_save(uuid, uuid, uuid, jsonb, real, real, double precision, double precision,
  double precision, double precision, text);
drop function public.route_wanted(integer);
drop function public.rs_circle_points(double precision, double precision, double precision);
drop function public.rs_clock(integer);
drop function public.rs_code(text);
drop function public.rs_day(timestamptz);
drop function public.rs_edit(uuid);
drop function public.rs_int(jsonb, text, integer, integer, integer, text);
drop function public.rs_moves(uuid);
drop function public.rs_next_code(uuid, text);
drop function public.rs_runnable(uuid, uuid);
drop function public.rs_time(text, text);
drop function public.run_sheet_list(uuid);
drop function public.run_sheet_moves(uuid);
drop function public.run_sheet_used_on(uuid);
drop function public.save_cue(uuid, jsonb);
drop function public.save_movement(uuid, jsonb);
drop function public.session_run_sheets(uuid);
drop function public.show_add_time(uuid, integer);
drop function public.show_at(date, integer, time);
drop function public.show_board(uuid);
drop function public.show_carry_over(uuid, uuid, uuid);
drop function public.show_for_action(uuid);
drop function public.show_go(uuid, uuid);
drop function public.show_hold(uuid);
drop function public.show_keep_holding(uuid, uuid);
drop function public.show_label(text, text);
drop function public.show_log_add(uuid, uuid, text, text, uuid, timestamptz);
drop function public.show_missing_groups(uuid, uuid, uuid, timestamptz);
drop function public.show_now();
drop function public.show_open(uuid);
drop function public.show_resume(uuid);
drop function public.show_rows(uuid, timestamptz);
drop function public.show_secs(interval);
drop function public.show_skip(uuid, uuid);
drop function public.show_step(uuid, timestamptz);
drop function public.switch_live_run_sheet(uuid, uuid);
drop function public.update_run_sheet(uuid, text, date);

-- ============================================================
-- 5. The tables
-- ============================================================
-- One statement, because they point at each other: listing them together means Postgres removes the web of foreign
-- keys with the tables instead of refusing the first one that is still referenced by a sibling.
drop table public.movements, public.movement_status, public.movement_routes, public.run_sheets,
  public.run_sheet_switches, public.cues, public.show_cues, public.show_state, public.show_log, public.group_messages;

-- ============================================================
-- 6. The post-check: by oid, so there is no second list
-- ============================================================
do $post$
declare
  v_left text;
  v_count integer;
begin
  select string_agg(pg_temp.what(t.classid, t.objid), E'\n  ') into v_left
  from _target t
  where (t.classid = 'pg_class'::regclass and exists (select 1 from pg_class where oid = t.objid))
     or (t.classid = 'pg_proc'::regclass and exists (select 1 from pg_proc where oid = t.objid))
     or (t.classid = 'pg_constraint'::regclass and exists (select 1 from pg_constraint where oid = t.objid))
     or (t.classid = 'pg_trigger'::regclass and exists (select 1 from pg_trigger where oid = t.objid));
  if v_left is not null then
    raise exception E'STILL THERE after the drops:\n  %', v_left;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'event_sessions' and column_name = 'run_sheet_id') then
    raise exception 'STILL THERE: event_sessions.run_sheet_id';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'sim_groups' and column_name = 'movement_id') then
    raise exception 'STILL THERE: sim_groups.movement_id';
  end if;

  -- The seven jobs of step 24, by name: this file unschedules nothing, and a job that vanished here would have been
  -- dropped as a side effect of something -- which is exactly what the guard exists to prevent.
  select count(*) into v_count from cron.job;
  if v_count <> 7 then
    raise exception 'The cron inventory changed: % jobs remain, expected the seven of step 24', v_count;
  end if;
  select string_agg(jobname, ', ' order by jobname) into v_left from cron.job;
  if v_left <> 'gps-auto-close-sessions, gps-cleanup-expired-locations, gps-end-scheduled-sessions, gps-plan-eta, '
             'gps-plan-push, gps-push-reminders, gps-sim-tick' then
    raise exception 'The cron inventory changed: %', v_left;
  end if;

  -- Every table this file leaves behind is protected by RLS. Dropping ten tables is a good moment to find out that
  -- one of the remaining ones never had a policy.
  select string_agg(c.relname, ', ' order by c.relname) into v_left
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_left is not null then
    raise exception 'A surviving table has row level security off: %', v_left;
  end if;

  -- And the plan's own path still answers: the read the boards open with.
  perform 1 from public.plan_frames limit 1;
  perform 1 from public.event_sessions limit 1;
end
$post$;

-- PostgREST caches tables and signatures: without this the dropped endpoints keep answering and the rewritten start
-- functions keep being called with the old cache's shape.
notify pgrst, 'reload schema';
