-- 053_fork_cut.sql
--
-- Step 17 of the planning plan: a copy taken mid-walk must not teleport anybody.
--
-- THE PROBLEM. plan_fork copied the whole plan: every frame, past and future. So a planner who copied a running plan
-- to change what happens next got a copy in which the walk so far was editable -- and editing it, republishing and
-- switching the event across would put a group that is halfway through a five-minute walk somewhere the new plan
-- says they were, which is a place they never went. A plan is a forecast. The past is not a forecast any more.
--
-- THE RULE. A plan copied from a RUNNING plan remembers the instant it was taken: plans.fork_cut_s, the clock offset
-- the session had reached. The copy then contains
--
--   * one ANCHOR FRAME at the cut, holding each group's position as the walk has it at that instant -- interpolated
--     between the statements that bracket it, carried forward when the group is standing still or off site, and absent
--     for a group that has not appeared yet. That is what "no teleporting" means: the copy starts where the walk
--     already had them, not at the last stated dot and not at the next one;
--   * every LATER frame, unchanged, each naming the frame it was copied from in plan_frames.origin_frame_id;
--   * and NO FRAME AT OR BEFORE THE CUT. The past stays on the plan it happened on (which is still readable), and the
--     triggers below refuse any later attempt to write a frame back in before the cut.
--
-- A plan copied from a plan that is not running has no cut (fork_cut_s null) and is the same deep copy it always was.
-- A copy taken exactly at T+0 has no past yet either, so it also has no cut: there is nothing to freeze.
--
-- FINDING 8, HONOURED. origin_frame_id cannot be set inside the INSERT that copies the frames: the rows and their ids
-- do not exist yet. It is set in a second pass that pairs the two plans by their time, which is unique in both.
--
-- WHY A TRIGGER AND NOT A CHECK IN EVERY WRITE FUNCTION. frame_save, frame_move, frame_delete, frame_shift,
-- frames_fill and frame_hold can all land a frame at or before the cut, and plan_positions can be written straight to
-- the table by anyone the RLS write policy admits. Six copies of one rule is six chances to miss one (R8's lesson,
-- read the other way round); a row trigger on the two tables is one statement of it, and it also covers the direct
-- write the app never makes. plan_fork writes the anchor BEFORE it sets the cut, so the rule never needs a bypass.
--
-- THE ANCHOR IS FROZEN because it is the copy's starting fact: it cannot be moved, deleted or carried to another
-- plan, and its positions cannot change. Its NOTE can, because a label on the start is not a statement about where
-- anybody was. Everything after it is an ordinary plan.
--
-- AND THE HAND-OVER. Publishing the copy carries the running session across in the same transaction -- plan_id, the
-- revision, and the clock it started on, which is the same clock the copy inherits -- and records the anchor as
-- arrived at the cut for every group it anchors. Without that last part the copy's first row would read "late" the
-- instant it was published: the group is not late, it is where the plan already had it.

-- ---------- 1. the two columns ----------
alter table public.plan_frames
  add column if not exists origin_frame_id uuid references public.plan_frames (id) on delete set null;

create index if not exists plan_frames_origin_idx on public.plan_frames (origin_frame_id);

comment on column public.plan_frames.origin_frame_id is
  'For a frame a copy brought along: the frame it was copied from (053). Null for a frame that was drawn.';

alter table public.plans add column if not exists fork_cut_s integer;

alter table public.plans drop constraint if exists plans_fork_cut_range_check;
alter table public.plans
  add constraint plans_fork_cut_range_check check (fork_cut_s is null or (fork_cut_s >= 0 and fork_cut_s <= 86400 * 3));

comment on column public.plans.fork_cut_s is
  'The clock offset a copy was taken at: its first frame, and the last instant nothing may be written at or before '
  '(053). Null for a plan that was not copied from a running one.';

-- ---------- 2. where a group is at an instant ----------
-- The one statement of the walk's own arithmetic: the last statement at or before the instant, interpolated toward
-- the next one when both are on site. plan_fork anchors every group with it, and it is the honest answer to "where
-- were they when the copy was taken" for a check -- or for the ops board step 20 builds.
--
-- It returns nothing for an instant before the group's first statement: the group is not in the plan yet. An off-site
-- statement is not a place, so nothing is interpolated out of it or into it: the last statement stands (046's rule).
create or replace function public.plan_position_at(p_plan uuid, p_group uuid, p_t_s integer)
returns table (lat double precision, lng double precision, state text, verify text)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_prev_s integer;
  v_prev_lat double precision;
  v_prev_lng double precision;
  v_prev_state text;
  v_prev_verify text;
  v_next_s integer;
  v_next_lat double precision;
  v_next_lng double precision;
  v_next_state text;
  v_next_verify text;
  v_k double precision;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  -- The same read rule plan_positions has carried since 040: ops staff read every group, everybody else their own.
  if not (public.has_event_role(v_event, array['root', 'planner', 'marshal'])
          or p_group = public.my_group_id(v_event)) then
    raise exception 'You can read only your own group''s positions in this event.' using errcode = '42501';
  end if;

  select pf.t_s, pp.lat, pp.lng, pp.state, pp.verify
    into v_prev_s, v_prev_lat, v_prev_lng, v_prev_state, v_prev_verify
    from public.plan_positions pp
    join public.plan_frames pf on pf.id = pp.frame_id
   where pf.plan_id = p_plan and pp.group_id = p_group and pf.t_s <= p_t_s
   order by pf.t_s desc
   limit 1;
  if not found then
    return; -- not in the plan yet at that instant
  end if;

  select pf.t_s, pp.lat, pp.lng, pp.state, pp.verify
    into v_next_s, v_next_lat, v_next_lng, v_next_state, v_next_verify
    from public.plan_positions pp
    join public.plan_frames pf on pf.id = pp.frame_id
   where pf.plan_id = p_plan and pp.group_id = p_group and pf.t_s > p_t_s
   order by pf.t_s asc
   limit 1;

  if v_prev_state = 'off_site' or v_next_s is null or v_next_state = 'off_site' then
    lat := v_prev_lat;
    lng := v_prev_lng;
    state := v_prev_state;
    verify := v_prev_verify;
  else
    v_k := (p_t_s - v_prev_s)::double precision / (v_next_s - v_prev_s);
    lat := v_prev_lat + (v_next_lat - v_prev_lat) * v_k;
    lng := v_prev_lng + (v_next_lng - v_prev_lng) * v_k;
    state := 'on_site';
    -- Derived from two statements, so it needs confirming if either end does.
    verify := case when v_prev_verify = 'manual' or v_next_verify = 'manual' then 'manual' else 'auto' end;
  end if;
  return next;
end;
$body$;

comment on function public.plan_position_at(uuid, uuid, integer) is
  'Where a group is at an instant on the plan''s clock: the last statement at or before it, interpolated toward the '
  'next one when both are on site (053).';

-- ---------- 3. the cut is not editable ----------
-- One rule per table, raised as a sentence rather than as a constraint name. What is frozen is where the copy starts:
-- no frame may be created at or before the cut, none may be moved across it or out of it, the anchor cannot be
-- deleted or carried to another plan, and its positions cannot change. Its NOTE is still writable -- a label on the
-- start is not a statement about where anybody was, and refusing it would make the anchor the one frame on the board
-- whose note field always bounces. Note the deliberate hole: when the PLAN row is gone, the foreign keys are taking
-- its frames and positions with it, and there is no cut to protect.
create or replace function public.plan_frames_guard_cut()
returns trigger
language plpgsql
set search_path = ''
as $body$
declare
  v_cut integer;
begin
  select p.fork_cut_s into v_cut
    from public.plans p
   where p.id = case when tg_op = 'DELETE' then old.plan_id else new.plan_id end;
  if not found or v_cut is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if (tg_op = 'INSERT' and new.t_s <= v_cut)
     or (tg_op = 'UPDATE'
         and ((new.t_s is distinct from old.t_s and (old.t_s <= v_cut or new.t_s <= v_cut))
              or (old.t_s <= v_cut
                  and (new.plan_id is distinct from old.plan_id or new.event_id is distinct from old.event_id))))
     or (tg_op = 'DELETE' and old.t_s <= v_cut) then
    raise exception 'This copy starts at %: the walk before it stays on the plan it was copied from.',
      public.plan_clock(v_cut) using errcode = '22023';
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$body$;

drop trigger if exists plan_frames_guard_cut on public.plan_frames;
create trigger plan_frames_guard_cut
  before insert or update or delete on public.plan_frames
  for each row execute function public.plan_frames_guard_cut();

create or replace function public.plan_positions_guard_cut()
returns trigger
language plpgsql
set search_path = ''
as $body$
declare
  v_cut integer;
  v_t_s integer;
begin
  select f.t_s, p.fork_cut_s into v_t_s, v_cut
    from public.plan_frames f
    join public.plans p on p.id = f.plan_id
   where f.id = case when tg_op = 'DELETE' then old.frame_id else new.frame_id end;
  if not found or v_cut is null or v_t_s > v_cut then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  raise exception 'The start of this copy is fixed at %; its positions cannot be changed.', public.plan_clock(v_cut)
    using errcode = '22023';
end;
$body$;

drop trigger if exists plan_positions_guard_cut on public.plan_positions;
create trigger plan_positions_guard_cut
  before insert or update or delete on public.plan_positions
  for each row execute function public.plan_positions_guard_cut();

-- A cut is set once, by the copy that was taken at it, and never cleared or moved -- otherwise "the past cannot be
-- edited" would be one UPDATE away from being false.
create or replace function public.plans_guard_fork_cut()
returns trigger
language plpgsql
set search_path = ''
as $body$
begin
  if tg_op = 'UPDATE' and old.fork_cut_s is not null and new.fork_cut_s is distinct from old.fork_cut_s then
    raise exception 'This plan was copied at %; that start is part of it now.', public.plan_clock(old.fork_cut_s)
      using errcode = '22023';
  end if;
  -- A cut belongs to a copy. Checked when the plan is made and not when it is edited: deleting the plan a copy came
  -- from sets fork_of to null through the foreign key, and refusing that would make "delete the original" impossible
  -- for as long as a copy of it exists.
  if tg_op = 'INSERT' and new.fork_cut_s is not null and new.fork_of is null then
    raise exception 'Only a copy can have a cut: a plan with no original has nothing it was cut from.'
      using errcode = '22023';
  end if;
  return new;
end;
$body$;

drop trigger if exists plans_guard_fork_cut on public.plans;
create trigger plans_guard_fork_cut
  before insert or update of fork_cut_s, fork_of on public.plans
  for each row execute function public.plans_guard_fork_cut();

-- ---------- 4. the list carries the cut ----------
-- 038's list, with fork_cut_s at the end, because the board has to know where the copy starts to draw it and to say
-- so. Adding a column to a `returns table` changes the row type, so this is a drop and recreate (R2) and the grant is
-- repeated (R4).
drop function if exists public.plan_list(uuid);
create function public.plan_list(p_event uuid)
returns table (
  id uuid, name text, for_date date, t0_time time, status text,
  rev integer, updated_at timestamptz, fork_of uuid, published_at timestamptz,
  frame_count integer, first_t_s integer, last_t_s integer,
  fork_cut_s integer
)
language sql
stable
security invoker
set search_path = public
as $body$
  select p.id, p.name, p.for_date, p.t0_time, p.status, p.rev, p.updated_at, p.fork_of, p.published_at,
         coalesce(count(f.id), 0)::int,
         min(f.t_s),
         max(f.t_s),
         p.fork_cut_s
  from public.plans p
  left join public.plan_frames f on f.plan_id = p.id
  where p.event_id = p_event
  group by p.id
  order by p.created_at desc;
$body$;

comment on function public.plan_list(uuid) is
  'Every plan of an event, newest first, with its frame count, extent and the cut a copy was taken at (053).';

-- ---------- 5. the copy ----------
-- 046's body, plus the cut: frames after the cut (or all of them, when there is no cut), the origin links in a second
-- pass, and the anchor before the cut goes on.
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
  v_cut integer;
  v_anchor uuid;
  v_group uuid;
  v_point record;
begin
  select * into v_src from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_src.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can copy a plan.' using errcode = '42501';
  end if;

  -- ---------- where the running clock has got to ----------
  -- Only a session that has actually started has a past to protect, and only past T+0: a copy taken at the zero point
  -- still has its whole walk ahead of it, so it is an ordinary deep copy.
  select greatest(0, least(86400 * 3, floor(extract(epoch from now() - s.t0_at))::int))
    into v_cut
    from public.event_sessions s
   where s.event_id = v_src.event_id
     and s.plan_id = p_plan
     and s.ended_at is null
     and s.starts_at <= now()
     and s.t0_at is not null
   order by s.starts_at desc
   limit 1;
  if not found or v_cut <= 0 then
    v_cut := null;
  end if;

  v_name := left(v_src.name || ' (edited)', 80);

  insert into public.plans (event_id, name, for_date, t0_time, status, fork_of, forked_at, created_by)
  values (v_src.event_id, v_name, v_src.for_date, v_src.t0_time, 'draft', v_src.id, now(), auth.uid())
  returning * into v_row;

  -- ---------- the future, copied ----------
  with copied as (
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    select v_row.id, f.event_id, f.t_s, f.note, auth.uid()
    from public.plan_frames f
    where f.plan_id = p_plan
      and (v_cut is null or f.t_s > v_cut)
    returning id, t_s
  )
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
  select c.id, v_row.id, v_row.event_id, p.group_id, p.lat, p.lng, p.state, p.verify
  from copied c
  join public.plan_frames f_old on f_old.plan_id = p_plan and f_old.t_s = c.t_s
  join public.plan_positions p on p.frame_id = f_old.id;

  -- ---------- finding 8: the origin links, in a second pass ----------
  -- The INSERT above cannot name the frame it copied, because the new ids did not exist while it ran. Time is unique
  -- in a plan, so the two plans can be paired by it. The anchor is not a copy of anything and keeps a null origin.
  update public.plan_frames nf
     set origin_frame_id = src.id
    from public.plan_frames src
   where nf.plan_id = v_row.id
     and nf.origin_frame_id is null
     and (v_cut is null or nf.t_s > v_cut)
     and src.plan_id = p_plan
     and src.t_s = nf.t_s;

  -- ---------- the anchor: everyone where the walk already had them ----------
  if v_cut is not null then
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    values (v_row.id, v_row.event_id, v_cut, null, auth.uid())
    returning id into v_anchor;

    for v_group in
      select distinct pp.group_id
        from public.plan_positions pp
        join public.plan_frames pf on pf.id = pp.frame_id
       where pf.plan_id = p_plan
         and pf.t_s <= v_cut
       order by pp.group_id
    loop
      select * into v_point from public.plan_position_at(p_plan, v_group, v_cut);
      if found then
        insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
        values (v_anchor, v_row.id, v_row.event_id, v_group,
                v_point.lat, v_point.lng, v_point.state, v_point.verify);
      end if;
    end loop;

    -- The cut goes on last. Everything above is the copy; from here the triggers freeze what it starts from.
    update public.plans set fork_cut_s = v_cut where id = v_row.id returning * into v_row;
  end if;

  return v_row;
end;
$body$;

-- ---------- 6. publishing the copy carries the running event with it ----------
-- 051's body, plus the hand-over. Publishing a copy taken from the plan an open session is running moves that session
-- onto the copy in the same transaction (its clock does not move: the copy inherited the T+0), and records the anchor
-- as arrived at the cut for every group it anchors. A copy published with no session on its original, or published
-- again, carries nobody and rewrites no record -- a republish is not a second hand-over.
create or replace function public.plan_publish(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_row public.plans;
  v_errors integer;
  v_first text;
  v_message text;
  v_anchor uuid;
  v_session record;
  v_group uuid;
  v_cut_at timestamptz;
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
  select count(*) into v_errors
    from public.plan_check(p_plan) c
   where c.severity = 'error';

  if v_errors > 0 then
    select c.message into v_first
      from public.plan_check(p_plan) c
     where c.severity = 'error'
     order by c.from_s, c.to_s, c.group_id
     limit 1;
    v_message := case
      when v_errors = 1 then format('This plan cannot be published yet: %s.', v_first)
      else format('This plan cannot be published yet (%s problems). The first is: %s.', v_errors, v_first)
    end;
    raise exception '%', v_message using errcode = '22023';
  end if;

  update public.plans
     set status = 'archived', updated_by = auth.uid(), updated_at = now()
   where event_id = v_event and status = 'live' and id <> p_plan;

  update public.plans
     set status = 'live', published_at = now(), rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_plan
  returning * into v_row;

  -- The revision a running session follows. A session that has ended keeps the one it ran. This is what a screen
  -- holding the old timetable compares a fresh read against (step 15), and it is written here, not by a trigger,
  -- so the two bumps are one statement's worth of truth.
  update public.event_sessions
     set plan_rev = v_row.rev
   where plan_id = p_plan
     and ended_at is null;

  -- ---------- the hand-over ----------
  if v_row.fork_of is not null and v_row.fork_cut_s is not null then
    select f.id into v_anchor
      from public.plan_frames f
     where f.plan_id = v_row.id and f.t_s = v_row.fork_cut_s;

    for v_session in
      select s.id, s.t0_at
        from public.event_sessions s
       where s.plan_id = v_row.fork_of
         and s.event_id = v_row.event_id
         and s.ended_at is null
         and s.starts_at <= now()
         for update
    loop
      update public.event_sessions
         set plan_id = v_row.id, plan_rev = v_row.rev
       where id = v_session.id;

      v_cut_at := v_session.t0_at + make_interval(secs => v_row.fork_cut_s);
      if v_anchor is not null and v_session.t0_at is not null and v_cut_at <= now() then
        for v_group in
          select pp.group_id
            from public.plan_positions pp
           where pp.frame_id = v_anchor
             and pp.state <> 'off_site'
             and not exists (select 1 from public.plan_progress pg
                              where pg.session_id = v_session.id
                                and pg.frame_id = v_anchor
                                and pg.group_id = pp.group_id)
           order by pp.group_id
        loop
          perform public.progress_mark(v_session.id, v_anchor, v_group, 'arrived', v_cut_at);
        end loop;
      end if;
    end loop;
  end if;

  return v_row;
end;
$body$;

-- ---------- grants (R4) ----------
revoke execute on function public.plan_position_at(uuid, uuid, integer) from public, anon;
grant execute on function public.plan_position_at(uuid, uuid, integer) to authenticated;

-- Trigger functions: no client ever calls these; they fire with the table. Revoked all the same, so the plan surface
-- has one rule instead of an exception nobody remembers (040's habit).
revoke execute on function public.plan_frames_guard_cut() from public, anon;
revoke execute on function public.plan_positions_guard_cut() from public, anon;
revoke execute on function public.plans_guard_fork_cut() from public, anon;

-- plan_list was dropped to change its row type (R2), so its grant has to be put back (R4).
revoke execute on function public.plan_list(uuid) from public, anon;
grant execute on function public.plan_list(uuid) to authenticated;

-- `create or replace` keeps these two grants, but naming them is what keeps a future re-create honest.
revoke execute on function public.plan_fork(uuid) from public, anon;
revoke execute on function public.plan_publish(uuid) from public, anon;
grant execute on function public.plan_fork(uuid) to authenticated;
grant execute on function public.plan_publish(uuid) to authenticated;
