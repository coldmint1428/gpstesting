-- 038_plan_frames.sql
--
-- The planning board, second attempt: a plan is a strip of frames, not a list of activity blocks.
--
-- WHY THIS REPLACES 037. 037 modelled the plan as activities with a start and a length, which is how a run
-- sheet thinks. The product is not a run sheet: it is closer to an animation timeline. A planner does not
-- say "this block runs from +10:00 to +20:00"; they say "at this moment, every group is HERE" and the app
-- works out the movement in between. Routes are never drawn -- a straight line joins neighbouring frames,
-- and a detailed path is just more frames, closer together. So the two things that matter are
--   when (a frame)  and  who is where (a position on that frame).
-- Nothing in src/ used the 037 tables, so this migration removes them rather than carrying two models.
--
-- T+0: every time here is seconds from the plan's zero point. No clock time is stored -- a rehearsal and
-- show night run the same plan at different times, and live editing is nothing but changing these numbers.
--
-- THE 25 m RULE. Neighbouring frames of one group may be no more than 25 m apart. It is the whole reason
-- routes do not need drawing: the app can always assume "they walked straight there, and not far". The check
-- lives in plan_check() here and in src/utils/planFrames.js on the client; both compare CONSECUTIVE STATED
-- positions, which is enough because carrying a position forward never changes a distance.
--
-- WHO MAY WRITE (same rule as src/utils/permissions.js): read = any member, write = root or planner.
-- The app never writes these tables directly: it calls the functions at the bottom, which check the role,
-- the revision (stale writes raise PT409) and the values.

-- ---------- retire the 037 activity model ----------
drop function if exists public.activity_list(uuid);
drop function if exists public.activity_save(uuid, jsonb);
drop function if exists public.activity_move(uuid, integer, integer, integer);
drop function if exists public.activity_delete(uuid, integer);
-- plan_list and plan_check change shape, so they are dropped and recreated rather than replaced.
drop function if exists public.plan_list(uuid);
drop function if exists public.plan_check(uuid);
drop table if exists public.activities;

-- ---------- plans: forking and publishing ----------
alter table public.plans
  add column if not exists fork_of uuid references public.plans (id) on delete set null,
  add column if not exists forked_at timestamptz,
  add column if not exists published_at timestamptz;

-- A plan can now also be the one that is running.
alter table public.plans drop constraint if exists plans_status_check;
alter table public.plans
  add constraint plans_status_check check (status in ('draft', 'ready', 'live', 'archived'));

-- One live plan per event. Publishing a fork therefore has to stand the old one down, which plan_publish does.
create unique index if not exists plans_one_live_idx on public.plans (event_id) where status = 'live';

-- ---------- plan_frames ----------
-- One moment in the run. Two frames may not share a time; that is what makes "paste this frame and drag it
-- 5 seconds later" a safe operation.
create table if not exists public.plan_frames (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans (id) on delete cascade,
  -- Denormalised so row-level security does not need a join per row.
  event_id uuid not null references public.events (id) on delete cascade,
  -- Seconds from T+0. 0 is the plan's zero point.
  t_s integer not null,
  note text,
  rev integer not null default 1,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),

  constraint plan_frames_t_range check (t_s >= 0 and t_s <= 86400 * 3),
  -- Deferred on purpose. Shifting a stretch of the bar by +5 minutes moves frames past each other on the way
  -- (the frame at +2:00 lands on the one at +7:00 before that one has moved), and only the end state has to
  -- be legal. The functions below still refuse a real collision with a readable message.
  constraint plan_frames_unique_time unique (plan_id, t_s) deferrable initially deferred
);

create index if not exists plan_frames_plan_idx on public.plan_frames (plan_id, t_s);

alter table public.plan_frames enable row level security;

drop policy if exists plan_frames_read on public.plan_frames;
create policy plan_frames_read on public.plan_frames for select to authenticated
  using (public.is_event_member(event_id));

drop policy if exists plan_frames_write on public.plan_frames;
create policy plan_frames_write on public.plan_frames for all to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']))
  with check (public.has_event_role(event_id, array['root', 'planner']));

-- ---------- plan_positions ----------
-- Where one group is, at one frame. Absent means "unchanged since the last frame that mentions this group",
-- which is what makes moving a single marker a single-row write.
create table if not exists public.plan_positions (
  frame_id uuid not null references public.plan_frames (id) on delete cascade,
  plan_id uuid not null references public.plans (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  lat double precision not null,
  lng double precision not null,

  primary key (frame_id, group_id),
  constraint plan_positions_lat check (lat between -90 and 90),
  constraint plan_positions_lng check (lng between -180 and 180)
);

create index if not exists plan_positions_plan_idx on public.plan_positions (plan_id, group_id);
create index if not exists plan_positions_frame_idx on public.plan_positions (frame_id);

alter table public.plan_positions enable row level security;

drop policy if exists plan_positions_read on public.plan_positions;
create policy plan_positions_read on public.plan_positions for select to authenticated
  using (public.is_event_member(event_id));

drop policy if exists plan_positions_write on public.plan_positions;
create policy plan_positions_write on public.plan_positions for all to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']))
  with check (public.has_event_role(event_id, array['root', 'planner']));

-- ---------- scope guards ----------
-- A frame may not belong to a plan of a different event; a position may not point at another event's group.
create or replace function public.plan_frames_check_scope()
returns trigger
language plpgsql
as $body$
begin
  if not exists (select 1 from public.plans p where p.id = new.plan_id and p.event_id = new.event_id) then
    raise exception 'That plan belongs to another event.' using errcode = '42501';
  end if;
  return new;
end;
$body$;

drop trigger if exists plan_frames_check_scope on public.plan_frames;
create trigger plan_frames_check_scope
  before insert or update of plan_id, event_id on public.plan_frames
  for each row execute function public.plan_frames_check_scope();

create or replace function public.plan_positions_check_scope()
returns trigger
language plpgsql
as $body$
begin
  if not exists (select 1 from public.groups g where g.id = new.group_id and g.event_id = new.event_id) then
    raise exception 'That group belongs to another event.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.plan_frames f where f.id = new.frame_id and f.plan_id = new.plan_id and f.event_id = new.event_id
  ) then
    raise exception 'That frame belongs to another plan.' using errcode = '42501';
  end if;
  return new;
end;
$body$;

drop trigger if exists plan_positions_check_scope on public.plan_positions;
create trigger plan_positions_check_scope
  before insert or update of frame_id, plan_id, event_id, group_id on public.plan_positions
  for each row execute function public.plan_positions_check_scope();

-- seconds from T+0 -> '+h:mm:ss' / '+m:ss' (a plan has no clock of its own). Unchanged from 037.
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

-- ---------- functions: plans ----------

create or replace function public.plan_list(p_event uuid)
returns table (
  id uuid, name text, for_date date, t0_time time, status text,
  rev integer, updated_at timestamptz, fork_of uuid, published_at timestamptz,
  frame_count integer, first_t_s integer, last_t_s integer
)
language sql
stable
security invoker
set search_path = public
as $body$
  select p.id, p.name, p.for_date, p.t0_time, p.status, p.rev, p.updated_at, p.fork_of, p.published_at,
         coalesce(count(f.id), 0)::int,
         min(f.t_s),
         max(f.t_s)
  from public.plans p
  left join public.plan_frames f on f.plan_id = p.id
  where p.event_id = p_event
  group by p.id
  order by p.created_at desc;
$body$;

-- A copy of a plan, for editing the future while the event is already running. Deep copy: frames and
-- positions, so the fork can be cut loose without touching the plan people are currently following.
create or replace function public.plan_fork(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_src public.plans;
  v_row public.plans;
  v_name text;
begin
  select * into v_src from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_src.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can copy a plan.' using errcode = '42501';
  end if;

  v_name := left(v_src.name || ' (edited)', 80);

  insert into public.plans (event_id, name, for_date, t0_time, status, fork_of, forked_at, created_by)
  values (v_src.event_id, v_name, v_src.for_date, v_src.t0_time, 'draft', v_src.id, now(), auth.uid())
  returning * into v_row;

  with copied as (
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    select v_row.id, f.event_id, f.t_s, f.note, auth.uid()
    from public.plan_frames f
    where f.plan_id = p_plan
    returning id, t_s
  )
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
  select c.id, v_row.id, v_row.event_id, p.group_id, p.lat, p.lng
  from copied c
  join public.plan_frames f_old on f_old.plan_id = p_plan and f_old.t_s = c.t_s
  join public.plan_positions p on p.frame_id = f_old.id;

  return v_row;
end;
$body$;

-- Make this plan the one that is running. Any other live plan of the event is stood down first, because
-- everyone follows exactly one timetable.
create or replace function public.plan_publish(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_row public.plans;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can publish a plan.' using errcode = '42501';
  end if;

  -- The 25 m rule is a warning while a plan is being drawn and a hard gate before anyone's timetable depends on
  -- it. Without this, "the limit" was only ever advice: the board coloured frames red and then let you publish.
  if exists (select 1 from public.plan_check(p_plan) c where c.severity = 'error') then
    raise exception 'This plan still has frames more than 25 m apart. Fix the flagged stretches, then publish.'
      using errcode = '22023';
  end if;

  update public.plans
     set status = 'archived', updated_by = auth.uid(), updated_at = now()
   where event_id = v_event and status = 'live' and id <> p_plan;

  update public.plans
     set status = 'live', published_at = now(), rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_plan
  returning * into v_row;
  return v_row;
end;
$body$;

-- ---------- functions: frames ----------

-- Every frame of a plan, oldest first, each with its positions as { "<group id>": {lat, lng} }.
create or replace function public.plan_frames_list(p_plan uuid)
returns table (id uuid, t_s integer, note text, rev integer, positions jsonb)
language sql
stable
security invoker
set search_path = public
as $body$
  select f.id, f.t_s, f.note, f.rev,
         coalesce(
           jsonb_object_agg(p.group_id::text, jsonb_build_object('lat', p.lat, 'lng', p.lng))
             filter (where p.group_id is not null),
           '{}'::jsonb)
  from public.plan_frames f
  left join public.plan_positions p on p.frame_id = f.id
  where f.plan_id = p_plan
  group by f.id, f.t_s, f.note, f.rev
  order by f.t_s;
$body$;

-- Create or update one frame. p_frame: { id?, t_s, note?, rev?, positions?: { "<group id>": {lat, lng} } }
-- `positions` is replaced wholesale when present and left alone when absent, so moving a frame in time does
-- not rewrite where everybody stands.
create or replace function public.frame_save(p_plan uuid, p_frame jsonb)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_id uuid := nullif(p_frame ->> 'id', '')::uuid;
  v_row public.plan_frames;
  v_t integer := (p_frame ->> 't_s')::int;
  v_rev integer := nullif(p_frame ->> 'rev', '')::int;
  v_group_text text;
  v_point jsonb;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if v_t is null or v_t < 0 then
    raise exception 'A frame cannot sit before T+0.' using errcode = '22023';
  end if;

  if v_id is null then
    if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t) then
      raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
        using errcode = '22023';
    end if;
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    values (p_plan, v_event, v_t, nullif(p_frame ->> 'note', ''), auth.uid())
    returning * into v_row;
  else
    select * into v_row from public.plan_frames where id = v_id and plan_id = p_plan for update;
    if not found then
      raise exception 'That frame is not in this plan.' using errcode = '42501';
    end if;
    if v_rev is not null and v_rev <> v_row.rev then
      raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
    end if;
    if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t and f.id <> v_id) then
      raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
        using errcode = '22023';
    end if;
    update public.plan_frames
       set t_s = v_t,
           note = case when p_frame ? 'note' then nullif(p_frame ->> 'note', '') else note end,
           rev = rev + 1,
           updated_by = auth.uid(),
           updated_at = now()
     where id = v_id
    returning * into v_row;
  end if;

  if p_frame ? 'positions' then
    -- Drop the groups this frame no longer mentions ...
    delete from public.plan_positions pp
     where pp.frame_id = v_row.id
       and not (coalesce(p_frame -> 'positions', '{}'::jsonb) ? pp.group_id::text);

    -- ... then write the ones it does.
    for v_group_text, v_point in
      select key, value from jsonb_each(coalesce(p_frame -> 'positions', '{}'::jsonb))
    loop
      if not exists (select 1 from public.groups g where g.id = v_group_text::uuid and g.event_id = v_event) then
        raise exception 'That group belongs to another event.' using errcode = '42501';
      end if;
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
      values (v_row.id, p_plan, v_event, v_group_text::uuid,
              (v_point ->> 'lat')::float8, (v_point ->> 'lng')::float8)
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng;
    end loop;
  end if;

  update public.plans set updated_at = now() where id = p_plan;
  return v_row;
end;
$body$;

-- Dragging a frame along the time bar: only t_s changes.
create or replace function public.frame_move(p_id uuid, p_t_s integer, p_rev integer)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_row public.plan_frames;
begin
  select * into v_row from public.plan_frames where id = p_id for update;
  if not found then
    raise exception 'That frame does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_row.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_rev is not null and p_rev <> v_row.rev then
    raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
  end if;
  if p_t_s is null or p_t_s < 0 then
    raise exception 'A frame cannot sit before T+0.' using errcode = '22023';
  end if;
  if exists (select 1 from public.plan_frames f where f.plan_id = v_row.plan_id and f.t_s = p_t_s and f.id <> p_id) then
    raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(p_t_s)
      using errcode = '22023';
  end if;
  update public.plan_frames
     set t_s = p_t_s, rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_id
  returning * into v_row;
  update public.plans set updated_at = now() where id = v_row.plan_id;
  return v_row;
end;
$body$;

create or replace function public.frame_delete(p_id uuid, p_rev integer)
returns void
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_row public.plan_frames;
begin
  select * into v_row from public.plan_frames where id = p_id for update;
  if not found then
    raise exception 'That frame does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_row.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_rev is not null and p_rev <> v_row.rev then
    raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
  end if;
  delete from public.plan_frames where id = p_id;
  update public.plans set updated_at = now() where id = v_row.plan_id;
end;
$body$;

-- "Select a stretch of the bar and push it back": every frame at or after p_from_s moves by p_delta_s.
-- Everything later travels with it, so the shape of the plan is kept and only its timing changes. This is
-- the operation a planner reaches for when a group is late, and it is why live editing does not need a
-- separate state machine: it is a time shift on the plan everyone is already following.
create or replace function public.frame_shift(p_plan uuid, p_from_s integer, p_delta_s integer)
returns integer
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_count integer;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_delta_s is null or p_delta_s = 0 then
    return 0;
  end if;

  if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s >= p_from_s and f.t_s + p_delta_s < 0) then
    raise exception 'That would push a frame before T+0.' using errcode = '22023';
  end if;

  -- Moving later can never land on a frame that stays put; moving earlier can, and that is worth saying plainly
  -- rather than letting a unique violation surface from the middle of the update.
  if exists (
    select 1
      from public.plan_frames f
      join public.plan_frames g
        on g.plan_id = f.plan_id and g.t_s = f.t_s + p_delta_s
     where f.plan_id = p_plan and f.t_s >= p_from_s and g.t_s < p_from_s
  ) then
    raise exception 'Those frames would land on a frame that is staying put. Shift the whole stretch instead.'
      using errcode = '22023';
  end if;

  update public.plan_frames
     set t_s = t_s + p_delta_s, rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where plan_id = p_plan and t_s >= p_from_s;

  get diagnostics v_count = row_count;
  update public.plans set updated_at = now() where id = p_plan;
  return v_count;
end;
$body$;

-- ---------- the 25 m rule ----------
-- Every pair of consecutive stated positions of one group must be within 25 m. Carrying a position forward
-- never adds a distance, so comparing stated positions is the same as comparing every frame -- and it is
-- what makes one dragged marker light up the whole broken chain rather than only its neighbours.
create or replace function public.plan_check(p_plan uuid)
returns table (
  severity text, group_id uuid, from_frame uuid, from_s integer,
  to_frame uuid, to_s integer, metres integer, message text
)
language plpgsql
stable
security invoker
set search_path = public
as $body$
declare
  v_group uuid;
  v_frame uuid;
  v_s integer;
  v_lat float8;
  v_lng float8;
  v_prev_group uuid;
  v_prev_frame uuid;
  v_prev_s integer;
  v_prev_lat float8;
  v_prev_lng float8;
  v_dx float8;
  v_dy float8;
  v_m float8;
begin
  for v_group, v_frame, v_s, v_lat, v_lng in
    select p.group_id, f.id, f.t_s, p.lat, p.lng
      from public.plan_frames f
      join public.plan_positions p on p.frame_id = f.id
     where f.plan_id = p_plan
     order by p.group_id, f.t_s
  loop
    if v_prev_group is not distinct from v_group and v_prev_frame is not null then
      v_dx := (v_lng - v_prev_lng) * 111320 * cos(radians((v_lat + v_prev_lat) / 2));
      v_dy := (v_lat - v_prev_lat) * 111320;
      v_m := sqrt(v_dx * v_dx + v_dy * v_dy);
      if v_m > 25 then
        severity := 'error';
        group_id := v_group;
        from_frame := v_prev_frame;
        from_s := v_prev_s;
        to_frame := v_frame;
        to_s := v_s;
        metres := round(v_m)::int;
        message := format('%s m in %s (from %s to %s) -- the limit is 25 m',
                          round(v_m)::int,
                          public.plan_clock(v_s - v_prev_s),
                          public.plan_clock(v_prev_s),
                          public.plan_clock(v_s));
        return next;
      end if;
    end if;
    v_prev_group := v_group;
    v_prev_frame := v_frame;
    v_prev_s := v_s;
    v_prev_lat := v_lat;
    v_prev_lng := v_lng;
  end loop;
end;
$body$;

-- ---------- grants ----------
grant execute on function public.plan_list(uuid) to authenticated;
grant execute on function public.plan_fork(uuid) to authenticated;
grant execute on function public.plan_publish(uuid) to authenticated;
grant execute on function public.plan_frames_list(uuid) to authenticated;
grant execute on function public.frame_save(uuid, jsonb) to authenticated;
grant execute on function public.frame_move(uuid, integer, integer) to authenticated;
grant execute on function public.frame_delete(uuid, integer) to authenticated;
grant execute on function public.frame_shift(uuid, integer, integer) to authenticated;
grant execute on function public.plan_check(uuid) to authenticated;
grant execute on function public.plan_clock(integer) to authenticated;

comment on table public.plans is 'A plan: a strip of frames on one shared T+0 grid, for every group (038).';
comment on table public.plan_frames is 'One moment in a plan. t_s is seconds from T+0, never a clock time (038).';
comment on table public.plan_positions is 'Where one group stands at one frame. Omitted = unchanged since the last frame that said (038).';
