-- 039_session_plan.sql — a session runs a plan, or a run sheet, or neither. Never both.
--
-- Until now the live engine could only be given a run sheet (024's start_event took one argument), so a plan
-- could be drawn but not run: the only way to start anything was the Run sheet tab, and the plan board was a
-- drawing that nothing read. This migration gives a session the columns it needs to run a plan, and puts the
-- "never both" rule in the schema instead of in the heads of the callers.
--
-- What a plan session needs that a run-sheet session does not:
--
--   plan_id    which plan is running
--   t0_at      when that plan's clock reads T+0. NOT starts_at: the call can be at 18:00 and the doors at
--              18:45, and lateness is measured from the plan, not from when a planner pressed the button
--   plan_rev   the revision of the plan the session started on. Publishing again bumps it, which is how a
--              screen holding the old timetable can tell it is holding the old timetable
--
-- The old ticks are fenced off explicitly (`plan_id is null`) rather than relying on the fact that a plan
-- session happens to have no run sheet: the constraint is what keeps that true, and a tick that reads it by
-- accident is a tick that will read it wrongly the day the constraint is relaxed.
--
-- Also here: renaming a plan no longer resets its status. `plan_save` defaulted status to 'draft' whenever it
-- was not sent, so an edit to the name alone silently unpublished a published plan while everybody was
-- following it.

-- ---------- 1. the columns ----------

alter table public.event_sessions
  add column if not exists plan_id  uuid references public.plans(id) on delete set null,
  add column if not exists t0_at    timestamptz,
  add column if not exists plan_rev integer not null default 0;

-- R5, as a constraint: a session runs a plan or a run sheet, or neither.
alter table public.event_sessions drop constraint if exists event_sessions_one_engine;
alter table public.event_sessions
  add constraint event_sessions_one_engine check (plan_id is null or run_sheet_id is null);

comment on column public.event_sessions.t0_at is
  'When the plan''s clock read T+0. Null for a session that runs no plan (its clock starts at starts_at).';
comment on column public.event_sessions.plan_rev is
  'The plan revision this session started on; publishing again moves it on.';

create index if not exists event_sessions_plan_idx on public.event_sessions (plan_id) where plan_id is not null;

-- No backfill: no session has ever run a plan, so every existing row keeps plan_id null and its old meaning.

-- ---------- 2. when a plan's clock reads T+0 ----------

create or replace function public.plan_t0(p_plan uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $body$
  select ((coalesce(p.for_date, current_date)::timestamp + p.t0_time) at time zone 'Asia/Singapore')
  from public.plans p
  where p.id = p_plan;
$body$;

-- The one door that decides whether a session may run this plan: refused when both are given, refused when the
-- plan is not published. Returns the T+0 the session should carry.
create or replace function public.session_engine(p_event uuid, p_run_sheet uuid, p_plan uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_plan public.plans;
begin
  if p_run_sheet is not null and p_plan is not null then
    raise exception 'A session runs a plan or a run sheet, never both. Pick one.'
      using errcode = '22023';
  end if;
  if p_plan is null then
    return null;
  end if;
  select * into v_plan from public.plans where id = p_plan and event_id = p_event;
  if not found then
    raise exception 'That plan is not in this event.' using errcode = '42501';
  end if;
  if v_plan.status <> 'live' then
    raise exception '"%" is not published. Publish it before starting the event on it.', v_plan.name
      using errcode = '22023';
  end if;
  return public.plan_t0(p_plan);
end;
$body$;

-- ---------- 3. start and schedule take a plan as well as a run sheet ----------
-- Both parameters default to null: the existing callers send a run sheet and nothing else, and a call that
-- sends neither still means "tracking only". Dropped rather than replaced, because the argument list changes
-- (R2), and re-granted in this file (R4).

drop function if exists public.start_event(uuid, uuid);
create function public.start_event(p_event_id uuid, p_run_sheet uuid default null, p_plan uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
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
  v_t0 := public.session_engine(p_event_id, p_run_sheet, p_plan);
  select rev into v_rev from public.plans where id = p_plan;
  perform public.rs_runnable(p_event_id, p_run_sheet);

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live';
    end if;
    update public.event_sessions
       set starts_at = now(), started_by = auth.uid(),
           run_sheet_id = p_run_sheet, plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0)
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, run_sheet_id, plan_id, t0_at, plan_rev)
  values (p_event_id, now(), auth.uid(), p_run_sheet, p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

drop function if exists public.schedule_event_start(uuid, timestamptz, uuid);
create function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz,
                                            p_run_sheet uuid default null, p_plan uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
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
  v_t0 := public.session_engine(p_event_id, p_run_sheet, p_plan);
  select rev into v_rev from public.plans where id = p_plan;
  perform public.rs_runnable(p_event_id, p_run_sheet);

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions
       set starts_at = p_starts_at, started_by = auth.uid(),
           run_sheet_id = p_run_sheet, plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0),
           scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, run_sheet_id, plan_id, t0_at, plan_rev)
  values (p_event_id, p_starts_at, auth.uid(), p_run_sheet, p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$body$;

revoke execute on function public.start_event(uuid, uuid, uuid) from public, anon;
revoke execute on function public.schedule_event_start(uuid, timestamptz, uuid, uuid) from public, anon;
grant execute on function public.start_event(uuid, uuid, uuid) to authenticated;
grant execute on function public.schedule_event_start(uuid, timestamptz, uuid, uuid) to authenticated;

revoke execute on function public.plan_t0(uuid) from public, anon, authenticated;
revoke execute on function public.session_engine(uuid, uuid, uuid) from public, anon, authenticated;

-- ---------- 4. the old engine does not touch a plan session ----------
-- show_tick and move_tick walk every live session that has a run sheet. A plan session cannot have one
-- (event_sessions_one_engine), but the fence is written down here so that the rule does not depend on the
-- reader of this function knowing that.

create or replace function public.show_tick()
returns integer
language plpgsql security definer set search_path = ''
as $body$
declare
  s record;
  n integer := 0;
begin
  for s in
    select es.id from public.event_sessions es
    where es.ended_at is null and es.starts_at <= now() and es.run_sheet_id is not null
      and es.plan_id is null
      and (es.scheduled_end is null or es.scheduled_end > now())
  loop
    begin
      perform public.show_step(s.id, public.show_now());
      n := n + 1;
    exception when others then
      raise warning 'show_tick %: %', s.id, sqlerrm;
    end;
  end loop;
  return n;
end;
$body$;

create or replace function public.move_tick()
returns integer
language plpgsql security definer set search_path = ''
as $body$
declare
  s record;
  n integer := 0;
  queued integer := 0;
begin
  for s in
    select es.id, e.is_simulation from public.event_sessions es
    join public.show_state st on st.session_id = es.id
    join public.events e on e.id = es.event_id
    where es.ended_at is null and es.starts_at <= now() and es.run_sheet_id is not null
      and es.plan_id is null
      and (es.scheduled_end is null or es.scheduled_end > now())
  loop
    begin
      perform public.move_step(s.id, public.show_now());
      if not s.is_simulation then
        queued := queued + public.push_collect_moves(s.id, public.show_now());
      end if;
      n := n + 1;
    exception when others then
      raise warning 'move_tick %: %', s.id, sqlerrm;
    end;
  end loop;
  if queued > 0 then
    perform public.push_kick();
  end if;
  return n;
end;
$body$;

-- Switching the live run sheet is a run-sheet action; on a plan session it would try to set a column that the
-- "never both" constraint forbids, and answer with a constraint name instead of a sentence.
create or replace function public.switch_live_run_sheet(p_event uuid, p_sheet uuid)
returns void
language plpgsql security definer set search_path = ''
as $body$
declare
  v_session uuid;
  v_plan uuid;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the live run sheet' using errcode = '42501';
  end if;
  perform public.rs_runnable(p_event, p_sheet);
  select id, plan_id into v_session, v_plan from public.event_sessions
  where event_id = p_event and ended_at is null and starts_at <= now() for update;
  if v_session is null then
    raise exception 'The event is not live';
  end if;
  if v_plan is not null then
    raise exception 'This session runs a plan, not a run sheet.' using errcode = '22023';
  end if;
  update public.event_sessions set run_sheet_id = p_sheet where id = v_session;
end;
$body$;

-- ---------- 5. renaming a plan keeps its status ----------
-- The same function as 037, with one change: only the fields actually sent are written. A rename sends
-- {id, name, rev} and used to write status = 'draft', for_date = null and t0_time = '18:00' along with it.

create or replace function public.plan_save(p_event uuid, p_plan jsonb)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_id uuid := nullif(p_plan ->> 'id', '')::uuid;
  v_row public.plans;
  v_name text := btrim(coalesce(p_plan ->> 'name', ''));
  v_t0 time := coalesce(nullif(p_plan ->> 't0_time', '')::time, '18:00');
  v_status text := nullif(p_plan ->> 'status', '');
  v_rev integer := nullif(p_plan ->> 'rev', '')::int;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    raise exception 'Give the plan a name of 1 to 80 characters.' using errcode = '22023';
  end if;
  if v_status is not null and v_status not in ('draft', 'ready', 'archived') then
    raise exception 'Unknown plan status %.', v_status using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.plans (event_id, name, for_date, t0_time, status, created_by)
    values (p_event, v_name, nullif(p_plan ->> 'for_date', '')::date, v_t0, coalesce(v_status, 'draft'), auth.uid())
    returning * into v_row;
    return v_row;
  end if;

  select * into v_row from public.plans where id = v_id and event_id = p_event for update;
  if not found then
    raise exception 'That plan does not exist in this event.' using errcode = '42501';
  end if;
  if v_rev is not null and v_rev <> v_row.rev then
    raise exception 'Someone else saved this plan first. Reload it.' using errcode = 'PT409';
  end if;
  if v_row.status = 'archived' then
    raise exception 'An archived plan cannot be changed.' using errcode = '42501';
  end if;

  update public.plans
     set name = v_name,
         for_date = case when p_plan ? 'for_date' then nullif(p_plan ->> 'for_date', '')::date else v_row.for_date end,
         t0_time = case when p_plan ? 't0_time' then v_t0 else v_row.t0_time end,
         status = coalesce(v_status, v_row.status),
         rev = rev + 1,
         updated_by = auth.uid(),
         updated_at = now()
   where id = v_id
  returning * into v_row;
  return v_row;
end;
$body$;
