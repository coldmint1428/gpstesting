-- 037_plans_activities.sql
--
-- The visual planning stage: a plan holds every group's activities on one shared T+0 grid.
--
-- WHY IT IS NOT A RUN SHEET. Run sheets (024) are the live engine's order: cues in wall-clock time, movements
-- as deadlines. They carry a whole show engine, IC pushes and playback. A plan is the thing a planner draws:
-- no clock at all, only offsets from T+0, so a rehearsal and show night can run the same plan at different
-- times. The two coexist; a plan is expected to be compiled into a run sheet later.
--
-- T+0: every duration here is seconds from the plan's zero point:
--   activities.start_s   when the activity begins, in seconds from T+0 (0 = the plan's start)
--   activities.length_s  how long it lasts, in seconds
--   plans.t0_time        the clock time T+0 maps to when previewing the plan (display only, never stored)
-- On show night the real mapping comes from the event session's start; that is not this table's business.
--
-- WHO MAY WRITE (same rule as the plan pages in src/utils/permissions.js):
--   read  : any member of the event
--   write : event role root or planner
--
-- The app never writes these tables directly: it calls the functions at the bottom, which check the role,
-- the locking revision and the values.

-- ---------- plans ----------
create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null,
  for_date date,
  -- The clock time T+0 maps to when this plan is previewed. Display only: a plan is stored in offsets.
  t0_time time not null default '18:00',
  status text not null default 'draft' check (status in ('draft', 'ready', 'archived')),
  rev integer not null default 1,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint plans_name_length check (char_length(name) between 1 and 80)
);

create index if not exists plans_event_idx on public.plans (event_id, created_at);

alter table public.plans enable row level security;

drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select to authenticated
  using (public.is_event_member(event_id));

drop policy if exists plans_write on public.plans;
create policy plans_write on public.plans for all to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']))
  with check (public.has_event_role(event_id, array['root', 'planner']));

-- ---------- activities ----------
create table if not exists public.activities (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans (id) on delete cascade,
  -- Denormalised so row-level security and the functions do not need a join to the plan.
  event_id uuid not null references public.events (id) on delete cascade,
  -- null = every group (a whole-event activity such as a briefing); otherwise one group's lane.
  group_id uuid references public.groups (id) on delete cascade,
  -- Where the group goes. null = stays where it is (a hold, a break).
  zone_id uuid references public.zones (id) on delete set null,
  kind text not null default 'move',
  label text not null,
  -- T+0 offsets in seconds. 0 is the plan's zero point; never a clock time.
  start_s integer not null,
  length_s integer not null,
  -- How this activity is confirmed live: 'auto' (an IC inside the destination zone long enough) or
  -- 'manual' (a marshal or group admin taps approve on the ground). Per-activity, so a plan can mix both.
  verify text not null default 'auto' check (verify in ('auto', 'manual')),
  notes text,
  rev integer not null default 1,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),

  constraint activities_start_range check (start_s >= 0 and start_s <= 86400 * 3),
  -- The product brief allows spans as short as 15 s; 5 is a floor that still catches a stray drag.
  constraint activities_length_range check (length_s >= 5 and length_s <= 86400 * 3),
  constraint activities_label_length check (char_length(label) between 1 and 80),
  constraint activities_kind check (
    kind in ('move', 'hold', 'assemble', 'perform', 'check-in', 'travel', 'briefing', 'break')
  )
);

create index if not exists activities_plan_idx on public.activities (plan_id, start_s);
create index if not exists activities_event_idx on public.activities (event_id);

alter table public.activities enable row level security;

drop policy if exists activities_read on public.activities;
create policy activities_read on public.activities for select to authenticated
  using (public.is_event_member(event_id));

drop policy if exists activities_write on public.activities;
create policy activities_write on public.activities for all to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']))
  with check (public.has_event_role(event_id, array['root', 'planner']));

-- An activity may not belong to a plan of a different event, nor point at another event's group or zone.
create or replace function public.activities_check_scope()
returns trigger
language plpgsql
as $body$
begin
  if not exists (select 1 from public.plans p where p.id = new.plan_id and p.event_id = new.event_id) then
    raise exception 'That plan belongs to another event.' using errcode = '42501';
  end if;
  if new.group_id is not null and not exists (
    select 1 from public.groups g where g.id = new.group_id and g.event_id = new.event_id
  ) then
    raise exception 'That group belongs to another event.' using errcode = '42501';
  end if;
  if new.zone_id is not null and not exists (
    select 1 from public.zones z where z.id = new.zone_id and z.event_id = new.event_id
  ) then
    raise exception 'That zone belongs to another event.' using errcode = '42501';
  end if;
  return new;
end;
$body$;

drop trigger if exists activities_check_scope on public.activities;
create trigger activities_check_scope
  before insert or update of plan_id, event_id, group_id, zone_id on public.activities
  for each row execute function public.activities_check_scope();

-- ---------- functions: plans ----------

-- Every plan of an event, newest first (readable by any member).
create or replace function public.plan_list(p_event uuid)
returns table (
  id uuid, name text, for_date date, t0_time time, status text,
  rev integer, updated_at timestamptz,
  activity_count integer, first_start_s integer, last_end_s integer
)
language sql
stable
security invoker
set search_path = public
as $body$
  select p.id, p.name, p.for_date, p.t0_time, p.status, p.rev, p.updated_at,
         coalesce(count(a.id), 0)::int,
         min(a.start_s),
         max(a.start_s + a.length_s)
  from public.plans p
  left join public.activities a on a.plan_id = p.id
  where p.event_id = p_event
  group by p.id
  order by p.created_at desc;
$body$;

-- Create or update a plan. p_plan: { id?, name, for_date?, t0_time?, status? }
-- Update requires the current rev (stale writes raise PT409, which the app treats as "someone else saved first").
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
  v_status text := coalesce(nullif(p_plan ->> 'status', ''), 'draft');
  v_rev integer := nullif(p_plan ->> 'rev', '')::int;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    raise exception 'Give the plan a name of 1 to 80 characters.' using errcode = '22023';
  end if;
  if v_status not in ('draft', 'ready', 'archived') then
    raise exception 'Unknown plan status %.', v_status using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.plans (event_id, name, for_date, t0_time, status, created_by)
    values (p_event, v_name, nullif(p_plan ->> 'for_date', '')::date, v_t0, v_status, auth.uid())
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
         for_date = nullif(p_plan ->> 'for_date', '')::date,
         t0_time = v_t0,
         status = v_status,
         rev = rev + 1,
         updated_by = auth.uid(),
         updated_at = now()
   where id = v_id
  returning * into v_row;
  return v_row;
end;
$body$;

create or replace function public.plan_delete(p_plan uuid)
returns void
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can delete a plan.' using errcode = '42501';
  end if;
  delete from public.plans where id = p_plan;
end;
$body$;

-- ---------- functions: activities ----------

create or replace function public.activity_list(p_plan uuid)
returns table (
  id uuid, group_id uuid, zone_id uuid, kind text, label text,
  start_s integer, length_s integer, verify text, notes text, rev integer
)
language sql
stable
security invoker
set search_path = public
as $body$
  select a.id, a.group_id, a.zone_id, a.kind, a.label,
         a.start_s, a.length_s, a.verify, a.notes, a.rev
  from public.activities a
  where a.plan_id = p_plan
  order by a.start_s, a.created_at;
$body$;

-- Create or update one activity. p_activity: { id?, group_id?, zone_id?, kind, label, start_s, length_s, position?, notes?, rev? }
create or replace function public.activity_save(p_plan uuid, p_activity jsonb)
returns public.activities
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_id uuid := nullif(p_activity ->> 'id', '')::uuid;
  v_row public.activities;
  v_label text := btrim(coalesce(p_activity ->> 'label', ''));
  v_kind text := coalesce(nullif(p_activity ->> 'kind', ''), 'move');
  v_start integer := (p_activity ->> 'start_s')::int;
  v_length integer := (p_activity ->> 'length_s')::int;
  v_rev integer := nullif(p_activity ->> 'rev', '')::int;
  v_group uuid := nullif(p_activity ->> 'group_id', '')::uuid;
  v_zone uuid := nullif(p_activity ->> 'zone_id', '')::uuid;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if char_length(v_label) < 1 then
    raise exception 'Give the activity a name.' using errcode = '22023';
  end if;
  if v_start is null or v_start < 0 then
    raise exception 'An activity cannot start before T+0.' using errcode = '22023';
  end if;
  if v_length is null or v_length < 5 then
    raise exception 'An activity must last at least 5 seconds.' using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.activities (plan_id, event_id, group_id, zone_id, kind, label,
                                   start_s, length_s, verify, notes, created_by)
    values (p_plan, v_event, v_group, v_zone, v_kind, v_label,
            v_start, v_length, coalesce(nullif(p_activity ->> 'verify', ''), 'auto'),
            nullif(p_activity ->> 'notes', ''), auth.uid())
    returning * into v_row;
    return v_row;
  end if;

  select * into v_row from public.activities where id = v_id and plan_id = p_plan for update;
  if not found then
    raise exception 'That activity is not in this plan.' using errcode = '42501';
  end if;
  if v_rev is not null and v_rev <> v_row.rev then
    raise exception 'Someone else changed this activity first. Reload the plan.' using errcode = 'PT409';
  end if;

  update public.activities
     set group_id = v_group,
         zone_id = v_zone,
         kind = v_kind,
         label = v_label,
         start_s = v_start,
         length_s = v_length,
         verify = coalesce(nullif(p_activity ->> 'verify', ''), verify),
         notes = nullif(p_activity ->> 'notes', ''),
         rev = rev + 1,
         updated_by = auth.uid(),
         updated_at = now()
   where id = v_id
  returning * into v_row;
  return v_row;
end;
$body$;

-- Dragging on the board: only the two offsets change, so this stays cheap and does not race the other fields.
create or replace function public.activity_move(p_id uuid, p_start_s integer, p_length_s integer, p_rev integer)
returns public.activities
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_row public.activities;
begin
  select a.* into v_row
    from public.activities a
   where a.id = p_id
     for update;
  if not found then
    raise exception 'That activity does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_row.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_rev is not null and p_rev <> v_row.rev then
    raise exception 'Someone else changed this activity first. Reload the plan.' using errcode = 'PT409';
  end if;
  if p_start_s is null or p_start_s < 0 then
    raise exception 'An activity cannot start before T+0.' using errcode = '22023';
  end if;
  if p_length_s is null or p_length_s < 5 then
    raise exception 'An activity must last at least 5 seconds.' using errcode = '22023';
  end if;

  update public.activities
     set start_s = p_start_s,
         length_s = p_length_s,
         rev = rev + 1,
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_id
  returning * into v_row;
  return v_row;
end;
$body$;

create or replace function public.activity_delete(p_id uuid, p_rev integer)
returns void
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_row public.activities;
begin
  select * into v_row from public.activities where id = p_id for update;
  if not found then
    raise exception 'That activity does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_row.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_rev is not null and p_rev <> v_row.rev then
    raise exception 'Someone else changed this activity first. Reload the plan.' using errcode = 'PT409';
  end if;
  delete from public.activities where id = p_id;
end;
$body$;

-- seconds from T+0 -> '+h:mm:ss' / '+m:ss' (a plan has no clock of its own)
create or replace function public.plan_clock(p_s integer)
returns text
language sql
immutable
as $body$
  select case
           when p_s is null then null
           when p_s < 0 then '-' || public.plan_clock(-p_s)
           when p_s >= 3600 then format('+%s:%s:%s', p_s / 3600, lpad(((p_s % 3600) / 60)::text, 2, '0'), lpad((p_s % 60)::text, 2, '0'))
           else format('+%s:%s', p_s / 60, lpad((p_s % 60)::text, 2, '0'))
         end;
$body$;

-- ---------- checks the board shows before you publish ----------
--
-- Overlaps on one lane, and a move that leaves no time to walk. Deliberately simple: the 25 m/segment and
-- polygon rules need the zone geometry, and belong with the compiler, not here.
create or replace function public.plan_check(p_plan uuid)
returns table (severity text, activity_id uuid, message text)
language sql
stable
security invoker
set search_path = public
as $body$
  with ordered as (
    select a.id, a.group_id, a.label, a.kind, a.start_s, a.length_s,
           lag(a.start_s + a.length_s) over (partition by a.group_id order by a.start_s) as prev_end,
           lag(a.label) over (partition by a.group_id order by a.start_s) as prev_label
    from public.activities a
    where a.plan_id = p_plan
  )
  select 'error', id,
         format('"%s" starts at %s but "%s" runs until %s.',
                label, public.plan_clock(start_s), prev_label, public.plan_clock(prev_end))
  from ordered
  where prev_end is not null and start_s < prev_end;
$body$;

-- ---------- grants ----------
grant execute on function public.plan_list(uuid) to authenticated;
grant execute on function public.plan_save(uuid, jsonb) to authenticated;
grant execute on function public.plan_delete(uuid) to authenticated;
grant execute on function public.plan_check(uuid) to authenticated;
grant execute on function public.activity_list(uuid) to authenticated;
grant execute on function public.activity_save(uuid, jsonb) to authenticated;
grant execute on function public.activity_move(uuid, integer, integer, integer) to authenticated;
grant execute on function public.activity_delete(uuid, integer) to authenticated;
grant execute on function public.plan_clock(integer) to authenticated;

comment on table public.plans is 'A plan: one shared T+0 grid of activities for every group (037).';
comment on table public.activities is 'One group''s block on the plan board: start_s + length_s are T+0 offsets, never clock times (037).';
