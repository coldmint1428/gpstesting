-- 064_mark_owner.sql
--
-- Step 28 of the planning stage: the IC's own "we're here" press -- and the two rules that make a mark a person's.
--
-- WHY THIS FILE EXISTS AT ALL. `progress_mark` (050) has admitted the group's IC and its admin since the day it was
-- written, but until now the only client caller was the ops board, which is mounted only for root, planner and
-- marshal (`EventView.vue` mounts `PlanOps` when `seesWholeEvent`) -- exactly the three roles the function exempts.
-- So half of its role check had never been reached by anything: the door was real and no screen knocked on it. Step
-- 28 gives the group's IC a press on their own timetable ("We're here") for the moment the clock is on, which is the
-- first thing that needs the IC half to be true -- and the first time a second person marking stops being
-- hypothetical.
--
-- WHAT A SECOND PERSON MAY DO. Not replace it silently. When a row carries a person's mark, a different person's
-- call is refused with a sentence naming who marked it and when, unless the caller is the event's ops (root,
-- planner, marshal) -- correcting a mark is what ops are for. The person who made it may correct their own. An
-- automatic close is nobody's statement, so any hand may correct it: a phone's guess loses to a person who was
-- there.
--
-- WHY A FLAG AND NOT A NULL NAME. 050 made `marked_by` null mean "the tick did it", and the column is
-- `on delete set null`, so deleting a profile silently turns a hand-made mark into the tick's: the board says "the
-- phone was there" and (with this guard) the row would become freely overwritable. Null was already carrying three
-- meanings -- the tick, a deleted profile, and a repair that left it blank. `marked_auto` says which writer closed
-- the moment, so a person's mark stays a person's mark after their account is gone and the guard keeps protecting
-- it. The one-time backfill below is the truth for rows written before this file: until now only the tick left the
-- name null.
--
-- THE TWO SCREEN BUGS THE AUDIT FOUND, FIXED BESIDE THIS FILE. `PlanOps` (and the timetable beside it) clear
-- `errorMsg` on every successful read, and the ops board polls every five seconds -- so a refused write's sentence
-- was gone before anyone could read it. A write's error is sticky now until the next successful write or a dismiss.
-- The ops board also read "the phone was there" off `marked_by is null`, which is the deleted-profile bug above; it
-- reads `marked_auto` now, which is why `plan_ops` gains the column.
--
-- R2: `plan_ops`'s return type changes (one column appended), so it is DROP + CREATE + re-GRANT. `progress_mark` and
-- `plan_auto_close` keep their signatures, so they are `create or replace` and their grants stand (R4 restates the
-- new one anyway). R8: `progress_mark`'s body is 050's and `plan_auto_close`'s is 063's, each copied whole and
-- changed only where this header says. R1: `extensions.` is qualified where used.

-- ============================================================
-- 1. Which writer closed the moment
-- ============================================================
alter table public.plan_progress
  add column if not exists marked_auto boolean not null default false;

comment on column public.plan_progress.marked_auto is
  'True only when the tick closed the moment by itself (063''s rule). A person''s mark is false even if that '
  'person''s profile is later deleted, so "the phone was there" is a fact about the writer and not about a missing '
  'name (064).';

-- The one-time truth for rows written before this file: until now the only writer that left `marked_by` null was the
-- tick (057's direct insert), so a null name on an existing row means an automatic close.
update public.plan_progress
   set marked_auto = true
 where marked_by is null
   and not marked_auto;

-- ============================================================
-- 2. The door: a mark belongs to the person who made it
-- ============================================================
-- 050's body (R8), with the guard between the T+0 check and the upsert and `marked_auto` written by the upsert. The
-- signature is unchanged, so `create or replace` and 050's grants stand; the comment below is extended.
create or replace function public.progress_mark(
  p_session uuid,
  p_frame uuid,
  p_group uuid,
  p_state text,
  p_at timestamptz default null
)
returns public.plan_progress
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_frame public.plan_frames;
  v_prev public.plan_progress;
  v_row public.plan_progress;
  v_name text;
  v_pos_state text;
  v_at timestamptz := coalesce(p_at, now());
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if v_session.plan_id is null or v_session.t0_at is null then
    raise exception 'That session is not running a plan.' using errcode = '22023';
  end if;

  if not (public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal'])
          or public.is_ic_of(v_session.event_id, p_group)
          or public.is_group_admin(p_group)) then
    raise exception 'Only the event''s ops, or the group''s IC or admin, can record an outcome.'
      using errcode = '42501';
  end if;

  -- The two words, named here so a typo comes back as a sentence rather than as plan_progress_state_check.
  if coalesce(p_state, '') not in ('arrived', 'missed') then
    raise exception 'A frame is recorded as arrived or missed, not %.', coalesce(p_state, 'nothing')
      using errcode = '22023';
  end if;

  select * into v_frame from public.plan_frames
   where id = p_frame and plan_id = v_session.plan_id and event_id = v_session.event_id;
  if not found then
    if exists (select 1 from public.plan_frames where id = p_frame) then
      raise exception 'That frame belongs to another plan.' using errcode = '42501';
    end if;
    raise exception 'That frame does not exist.' using errcode = '42501';
  end if;

  select g.name into v_name from public.groups g
   where g.id = p_group and g.event_id = v_session.event_id;
  if not found then
    raise exception 'That group is not in this event.' using errcode = '42501';
  end if;

  -- Where the group stands at that moment, by the same carry-forward the board draws with.
  select pp.state into v_pos_state
    from public.plan_positions pp
    join public.plan_frames pf on pf.id = pp.frame_id
   where pf.plan_id = v_session.plan_id
     and pp.group_id = p_group
     and pf.t_s <= v_frame.t_s
   order by pf.t_s desc
   limit 1;
  if not found then
    raise exception '% is not in the plan at %; there is nothing to record yet.',
      v_name, public.plan_clock(v_frame.t_s) using errcode = '22023';
  end if;
  if v_pos_state = 'off_site' then
    raise exception '% is off site at %; there is nothing to record.',
      v_name, public.plan_clock(v_frame.t_s) using errcode = '22023';
  end if;

  if v_at > now() then
    raise exception 'That moment has not happened yet.' using errcode = '22023';
  end if;
  if v_at < v_session.t0_at then
    raise exception 'That is before the plan started (T+0).' using errcode = '22023';
  end if;

  -- A MARK BELONGS TO THE PERSON WHO MADE IT. Another IC or admin is refused rather than silently replacing it; the
  -- sentence names who and when, so the caller knows who to ask. The event's ops may correct anything (that is what
  -- ops are for), the maker may correct their own, and an automatic close is nobody's statement, so a hand may
  -- correct it. `marked_auto` is the flag, not a missing name: a deleted profile must not turn a person's mark into
  -- the tick's (064).
  select * into v_prev
    from public.plan_progress
   where session_id = v_session.id
     and frame_id = v_frame.id
     and group_id = p_group;
  if found
     and not v_prev.marked_auto
     and v_prev.marked_by is distinct from auth.uid()
     and not public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal']) then
    raise exception '% recorded that moment already, at %. Ask the event''s ops to change it.',
      public.show_who(v_prev.marked_by), public.sg_hms(v_prev.marked_at)
      using errcode = '42501';
  end if;

  insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by, marked_auto)
  values (v_session.id, v_session.plan_id, v_session.event_id, v_frame.id, p_group, p_state, v_at, auth.uid(), false)
  on conflict (session_id, frame_id, group_id) do update
    set state = excluded.state,
        marked_at = excluded.marked_at,
        marked_by = excluded.marked_by,
        marked_auto = false
  returning * into v_row;

  return v_row;
end;
$body$;

comment on function public.progress_mark(uuid, uuid, uuid, text, timestamptz) is
  'Record one group''s outcome at one frame of a plan session; the only writer of plan_progress (050). A person''s '
  'mark may be replaced by the person who made it or by the event''s ops, not by another IC or admin, who are given a '
  'sentence naming the marker; an automatic close may be corrected by anybody allowed to mark (064).';

-- ============================================================
-- 3. The tick says which writer it is
-- ============================================================
-- 063's body (R8), with `marked_auto` true on the insert -- nothing else changes. Signature unchanged, so
-- `create or replace`; 057 revoked it from everybody and `plan_push_tick` calls it as its definer.
create or replace function public.plan_auto_close(p_session uuid default null, p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_n integer := 0;
  v_session record;
  v_moment record;
  v_point extensions.geography;
  v_entered timestamptz;
begin
  for v_session in
    select es.id, es.event_id, es.plan_id, es.t0_at
      from public.event_sessions es
     where es.plan_id is not null
       and es.t0_at is not null
       and es.ended_at is null
       and (p_session is null or es.id = p_session)
     order by es.id
  loop
    -- The group's CURRENT moment only: the last one the clock has reached. An earlier moment that was never marked is
    -- history -- a tick that was not there cannot claim the group was in a zone ten minutes ago -- and the next one has
    -- not happened. Same carry-forward the board draws with: a frame that does not state the group is not its moment.
    for v_moment in
      select distinct on (s.group_id)
             s.group_id, s.frame_id, s.t_s, s.lat, s.lng, s.state, s.verify,
             v_session.t0_at + make_interval(secs => s.t_s) as planned_at
        from (
          select pos.group_id, f.id as frame_id, f.t_s, pos.lat, pos.lng, pos.state, pos.verify
            from public.plan_positions pos
            join public.plan_frames f on f.id = pos.frame_id
           where f.plan_id = v_session.plan_id
        ) s
       where v_session.t0_at + make_interval(secs => s.t_s) <= p_at
       order by s.group_id, s.t_s desc
    loop
      continue when v_moment.state <> 'on_site' or v_moment.verify <> 'auto';

      -- Already said. `progress_mark`'s rule is one row per group per moment, so the tick must not make a second
      -- opinion of its own either.
      if exists (
        select 1 from public.plan_progress pr
         where pr.session_id = v_session.id
           and pr.frame_id = v_moment.frame_id
           and pr.group_id = v_moment.group_id
      ) then
        continue;
      end if;

      v_point := extensions.st_setsrid(extensions.st_makepoint(v_moment.lng, v_moment.lat), 4326)::extensions.geography;

      -- THE PLACE GATE (057's rule, 062's kinds). A route point is not somewhere to have arrived: the gate is what
      -- keeps "a phone passed within thirty metres of this corner" from being an arrival.
      if not exists (
        select 1
          from public.zones z
         where z.event_id = v_session.event_id
           and z.kind in ('zone', 'stage', 'entrance')
           and extensions.st_dwithin(z.shape, v_point, 0)
      ) then
        continue;
      end if;

      -- The earliest evidence that an IC of this group is at this moment: inside a zone that contains the drawn point
      -- (057's test, unchanged), or within that IC's own radius of the point. Null when nobody has said anything.
      select min(ev.evidence_at) into v_entered
        from public.group_members gm
        join lateral (
          select zp.entered_at as evidence_at
            from public.zone_presence zp
            join public.zones z on z.id = zp.zone_id and z.event_id = v_session.event_id
           where zp.user_id = gm.user_id
             and zp.session_id = v_session.id
             and zp.exited_at is null
             and extensions.st_dwithin(z.shape, v_point, 0)
          union all
          select l.recorded_at as evidence_at
            from public.locations l
           where l.event_id = v_session.event_id
             and l.user_id = gm.user_id
             and coalesce(l.source, 'gps') <> 'stop'
             and l.accuracy > 0
             and l.accuracy <= 100
             and l.recorded_at <= p_at
             and l.recorded_at > greatest(p_at - interval '2 minutes', v_session.t0_at)
             and extensions.st_dwithin(
                   extensions.st_setsrid(extensions.st_makepoint(l.lng, l.lat), 4326)::extensions.geography,
                   v_point,
                   gm.ic_tolerance_m + least(greatest(coalesce(l.accuracy, 0), 0), 15))
        ) ev on true
       where gm.event_id = v_session.event_id
         and gm.group_id = v_moment.group_id
         and gm.is_ic;
      if v_entered is null then
        continue;
      end if;

      insert into public.plan_progress
        (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by, marked_auto)
      values
        (v_session.id, v_session.plan_id, v_session.event_id, v_moment.frame_id, v_moment.group_id,
         'arrived', greatest(v_moment.planned_at, v_entered), null, true)
      on conflict (session_id, frame_id, group_id) do nothing;
      if found then
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;
  return v_n;
end;
$body$;

comment on function public.plan_auto_close(uuid, timestamptz) is
  'Close the current moment of every group whose position is auto and on site, when the moment''s drawn point stands '
  'in a zone a group can be sent to AND one of its ICs is either inside a zone containing the point or within that '
  'IC''s own arrival radius of it, with a reading no older than two minutes inside this session; marked_by null, '
  'marked_auto true, and marked_at the later of the plan and the first evidence (057, radius 063, writer 064).';

-- ============================================================
-- 4. The ops read says which writer closed it
-- ============================================================
-- 057's body (R8), with `marked_auto` appended to the columns and read off the row. DROP + CREATE because the return
-- type changes (R2); the grants are named again below (R4).
drop function if exists public.plan_ops(uuid, timestamptz);

create function public.plan_ops(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid,
  group_name text,
  frame_id uuid,
  t_s integer,
  planned_at timestamptz,
  note text,
  status text,
  next_t_s integer,
  next_at timestamptz,
  travel_s integer,
  plan_lat double precision,
  plan_lng double precision,
  plan_state text,
  plan_verify text,
  expected_lat double precision,
  expected_lng double precision,
  expected_state text,
  actual_lat double precision,
  actual_lng double precision,
  actual_accuracy real,
  actual_ics integer,
  actual_at timestamptz,
  off_m integer,
  marked_state text,
  marked_at timestamptz,
  marked_by uuid,
  marked_auto boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_at timestamptz := coalesce(p_at, now());
  v_clock integer;
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  -- The plan it WAS running has been deleted. The session keeps its t0_at and loses its plan_id (the foreign key nulls
  -- it), and for the second between that and the screen hearing about it a poll can still arrive. This answers nothing
  -- rather than refusing: there is no plan to draw, and a refusal put an HTTP 400 in a planner's console for a state
  -- that is about to be shown correctly ("running without a plan"). A session that never ran a plan has no t0_at and is
  -- still refused below.
  if v_session.plan_id is null and v_session.t0_at is not null then
    return;
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if v_session.plan_id is null or v_session.t0_at is null then
    raise exception 'That session is not running a plan.' using errcode = '22023';
  end if;

  v_clock := floor(extract(epoch from (v_at - v_session.t0_at)))::int;

  return query
  with visible as (
    select g.id as group_id, g.name as group_name
      from public.groups g
     where g.event_id = v_session.event_id
       and (public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal'])
            or g.id = public.my_group_id(v_session.event_id))
  ), stated as (
    select pos.group_id, f.id as frame_id, f.t_s, f.note, pos.lat, pos.lng, pos.state, pos.verify
      from public.plan_positions pos
      join public.plan_frames f on f.id = pos.frame_id
      join visible v on v.group_id = pos.group_id
     where f.plan_id = v_session.plan_id
  ), moments as (
    select s.group_id, s.frame_id, s.t_s, s.note, s.lat, s.lng, s.state, s.verify,
           lead(s.t_s) over (partition by s.group_id order by s.t_s) as next_t_s
      from stated s
  ), expected as (
    select m.group_id, e.lat, e.lng, e.state
      from (select distinct s.group_id from stated s) m
      cross join lateral public.plan_position_at(v_session.plan_id, m.group_id, v_clock) e
  ), ground as (
    select m.group_id, p.lat, p.lng, p.accuracy, p.ics, p.last_seen
      from (select distinct s.group_id from stated s) m
      cross join lateral public.group_position_at(v_session.event_id, m.group_id, v_at) p
  )
  select m.group_id,
         v.group_name,
         m.frame_id,
         m.t_s,
         v_session.t0_at + make_interval(secs => m.t_s),
         m.note,
         case
           when v_at < v_session.t0_at + make_interval(secs => m.t_s) then 'pending'
           when m.next_t_s is not null
                and v_at < v_session.t0_at + make_interval(secs => m.next_t_s) then 'active'
           else 'done'
         end,
         m.next_t_s,
         case when m.next_t_s is not null
              then v_session.t0_at + make_interval(secs => m.next_t_s) end,
         case when m.next_t_s is not null then m.next_t_s - m.t_s end,
         m.lat,
         m.lng,
         m.state,
         m.verify,
         e.lat,
         e.lng,
         e.state,
         p.lat,
         p.lng,
         p.accuracy,
         p.ics,
         p.last_seen,
         case when e.state = 'on_site' and p.lat is not null then
           round(extensions.st_distance(
             extensions.st_setsrid(extensions.st_makepoint(p.lng, p.lat), 4326)::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(e.lng, e.lat), 4326)::extensions.geography))::int
         end,
         pr.state,
         pr.marked_at,
         pr.marked_by,
         pr.marked_auto
    from moments m
    join visible v on v.group_id = m.group_id
    left join expected e on e.group_id = m.group_id
    left join ground p on p.group_id = m.group_id
    left join public.plan_progress pr
      on pr.session_id = v_session.id
     and pr.frame_id = m.frame_id
     and pr.group_id = m.group_id
   order by v.group_name, m.t_s;
end;
$body$;

comment on function public.plan_ops(uuid, timestamptz) is
  'The ops picture of a plan session: one row per group per moment with pending/active/done, the travel time the '
  'strip gives (to the group''s next moment), where its ICs are at p_at, and what has been recorded about the '
  'moment (marked_state / marked_at / marked_by, with marked_auto true when the tick did it); a session whose plan '
  'has been deleted answers no rows (056, marks and guard 057, writer 064).';

-- ============================================================
-- 5. Grants (R4) and the schema cache
-- ============================================================
-- progress_mark and plan_auto_close were re-created in place, so their grants stand; naming the new plan_ops is what
-- keeps a fresh function from inheriting the schema default.
revoke execute on function public.plan_ops(uuid, timestamptz) from public, anon;
grant execute on function public.plan_ops(uuid, timestamptz) to authenticated;

notify pgrst, 'reload schema';
