-- 057_plan_pushes.sql
--
-- Step 21 of the planning plan: pushes and ETAs computed from the strip, an auto-verified moment that closes itself,
-- and a hand-back log that says who is holding the board.
--
-- WHAT WAS THERE, AND WHY IT CANNOT SERVE A PLAN. Two 5 s / 30 s cron jobs watched the run-sheet engine: `gps-push-send`
-- collected No-Go pushes and told the Edge Function to send whatever was queued, and `gps-route-eta` asked OneMap for a
-- route per movement so 027 could turn metres into an ETA. Both read `movement_status` / `movements`, which belong to
-- the engine step 25 drops. A plan session has no movements: it has frames on a clock and positions a planner drew. So
-- the two jobs are replaced, and they are replaced rather than kept side by side because a tick that no longer has a
-- caller is the thing step 24 exists to hunt down (and step 24 has to be able to assert "the old names are gone").
--
-- The swap is in ONE transaction and the new jobs are scheduled BEFORE the old ones go: a moment's worth of No-Go
-- pushes is not lost between the two statements. What is genuinely lost for a while is the route refresh for run-sheet
-- sessions -- `plan_eta_tick` answers ETAs from the plan, not from OneMap, and a run-sheet movement keeps whatever
-- route it last fetched until step 24/25 retire that engine. That is a real cost, paid deliberately: the plan path is
-- what this build is for, and `dev/checks/step21-push-handover.sql` keeps the No-Go duty alive inside the new tick so
-- nothing goes dark while both engines still run.
--
-- WHAT AN ETA IS WHEN NOBODY FETCHED A ROUTE. The plan's next moment is a point, the group's phones give a point, and
-- `group_positions.speed_mps` is how fast the group has actually been walking over the last minute. So the forecast is
-- straight-line metres / that speed, announced as "at your pace you arrive 7:14 pm, 2:30 after the plan". Three
-- deliberate limits, named rather than discovered later:
--   * STRAIGHT LINE, not a route. 048 made the same choice for the 25 m rule, and for the same reason: a route needs an
--     external service and a plan may be read before anybody fetched one. It UNDER-estimates a walk, so the ETA is
--     optimistic -- a group told "you will make it" may not.
--   * A PACE FLOOR OF 0.5 m/s and a default of 1.3 m/s when the group has not moved yet. A group standing still has
--     speed 0, and dividing by it would announce that a group waiting to be called is infinitely late. The floor is a
--     walking pace nobody exceeds downwards; the default is an ordinary walk when there is no measurement at all.
--   * NO FIX, NO ETA. With no reading in the last two minutes `group_position_at` answers null and this function says
--     nothing: a forecast invented from the last place a phone was seen an hour ago is worse than silence.
--
-- WHAT "auto" NOW MEANS. 046 gave a position `verify` = 'auto' (trusted as drawn) or 'manual' (somebody has to confirm
-- it), and until this file nothing read it: it was a flag a planner could set and a board could colour. Here 'auto'
-- becomes a rule. A moment whose position is auto, is on site, is the group's CURRENT moment (the clock has reached it
-- and not the next one), and whose drawn point lies inside an event zone, closes itself the moment one of that group's
-- ICs is inside that same zone: a `plan_progress` row with 'arrived', marked_by null (nobody said it -- the tick did),
-- and marked_at the later of the planned time and the IC's entry, so a tick that runs late still records when the group
-- was actually there. "manual" is not a suggestion: the row is left for a person to tap, and nothing here touches it.
--
-- WHY "INSIDE ITS ZONE" AND NOT "WITHIN N METRES". The plan has no notion of a destination area -- 046 deliberately
-- ruled named states out -- so the only real area a drawn point can be "at" is the zone a planner put it in. That is
-- also the honest test of the drawing: a badge dropped inside the stage polygon is a statement about the stage, and a
-- badge dropped in an empty field has no area to be inside, so it can never close automatically (it waits for a tap).
-- The zone test is `st_dwithin(shape, point, 0)`, exactly 020's containment, and the IC test is membership
-- (`group_members.is_ic`) rather than the reading's own group id: a phone says which group it is walking with, but
-- who an IC is is a fact about the event, not about the last reading.
--
-- THE LOG IS A RECORD, NOT A DOOR. `handover_log` gets RLS, a read policy for the event's members and NO write policy
-- (R3): the only writer is `handover_take()`, a security-definer function that checks the caller is this event's ops.
-- `from_user` is not the caller's business to say -- it is read off the previous row, so a hand-back chain needs no
-- client bookkeeping and cannot be forged by a caller with the right role. The revision the board was showing is
-- copied onto the row (the session's `plan_rev`), because "who had it and what were they looking at" is the question
-- a hand-back answers, and step 18's versions are what the number names.
--
-- AND ONE THING THE REGRESSION RUN CAUGHT. Deleting the live plan nulls `event_sessions.plan_id` while leaving `t0_at`
-- behind, so for the second between the delete and the tab hearing about it a poll can still arrive at a plan read. Both
-- reads (`plan_ops`, and 051/052's `session_timetable`) now answer NOTHING for that session instead of refusing: there
-- is no plan to draw, the screen is about to say "running without a plan" (the schedule already has that sentence), and
-- the refusal put an HTTP 400 in a planner's console during step 19's deletion test. A session that never ran a plan has
-- no `t0_at` and is still refused, which is what steps 15 and 20 assert.
--
-- R2: `plan_ops` gains three columns, so it is DROPped and re-created and re-GRANTed (a `create or replace` cannot
-- change its shape); the body is 056's, verbatim except for the marks and the guard (R8 -- copied from the latest
-- definition). R4 everywhere: new functions are revoked from public and anon (the schema default hands them to anon),
-- the four internal ones are refused to authenticated too, and the two the client calls are granted to authenticated.

-- ============================================================
-- 1. The plan's three push kinds, on top of the ones that exist
-- ============================================================
-- 029's constraint, with the plan's three added. A CHECK is dropped and re-added because it cannot be altered in place,
-- and every existing kind is re-stated because dropping the constraint drops them -- from the DATABASE, not from the
-- files. The live constraint carries a tenth kind, 'sos', that no migration in this repository writes (eight rows of
-- the queue hold it), so a list copied from 029 would have re-added a constraint the existing rows violate; the first
-- attempt at this migration was refused for exactly that, which is the failure the check exists for. The database is the
-- inventory: 'sos' is carried forward here and the missing migration is somebody's to write.
alter table public.push_queue drop constraint if exists push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check
  check (kind in ('get_ready', 'leave_now', 'late', 'message', 'nogo', 'next', 'hold', 'resume', 'change', 'sos',
                  'plan_due', 'plan_leave', 'plan_late'));

-- ============================================================
-- 2. A moment that closes itself
-- ============================================================
-- Returns how many moments it closed. p_session null means every live plan session (the tick); a named session is what
-- a check stands on.
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

      -- One IC of this group, inside a zone that contains the drawn point, right now. The earliest such entry is the
      -- one the arrival is dated from.
      select min(zp.entered_at) into v_entered
        from public.zone_presence zp
        join public.zones z on z.id = zp.zone_id and z.event_id = v_session.event_id
        join public.group_members gm on gm.event_id = v_session.event_id
                                    and gm.group_id = v_moment.group_id
                                    and gm.user_id = zp.user_id
                                    and gm.is_ic
       where zp.session_id = v_session.id
         and zp.exited_at is null
         and extensions.st_dwithin(
               z.shape,
               extensions.st_setsrid(extensions.st_makepoint(v_moment.lng, v_moment.lat), 4326)::extensions.geography,
               0);
      if v_entered is null then
        continue;
      end if;

      insert into public.plan_progress
        (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
      values
        (v_session.id, v_session.plan_id, v_session.event_id, v_moment.frame_id, v_moment.group_id,
         'arrived', greatest(v_moment.planned_at, v_entered), null)
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
  'Close the current moment of every group whose position is auto and on site, when one of its ICs is inside a zone '
  'containing the drawn point; marked_by null and marked_at the later of the plan and the IC''s entry (057).';

-- ============================================================
-- 3. The "now" push: one nudge per moment, to the group's ICs and admins
-- ============================================================
-- p_session null means every live plan session. Returns how many pushes were queued (a second call in the same moment
-- queues none: push_queue.dedup is unique on kind:session:frame:group:person).
create or replace function public.plan_collect_pushes(p_session uuid default null, p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_n integer;
begin
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select gm.user_id, s.event_id, s.id, 'plan_due',
         'plan_due:' || s.id || ':' || m.frame_id || ':' || m.group_id || ':' || gm.user_id,
         'Now: ' || coalesce(nullif(btrim(m.note), ''), public.plan_clock(m.t_s)),
         g.name || ' is due at ' || public.plan_clock(m.t_s) || ' (' || public.sg_hms(m.planned_at) || ')' ||
           coalesce(' · ' || z.name, '') ||
           case when m.state = 'on_site' then '. Tap arrived when you are there.' else ' · off site.' end,
         jsonb_build_object('kind', 'plan_due', 'eventId', s.event_id, 'sessionId', s.id,
                            'frameId', m.frame_id, 'groupId', m.group_id,
                            'tag', 'plan-' || m.frame_id || '-' || m.group_id)
    from public.event_sessions s
    join public.events e on e.id = s.event_id and not e.is_simulation
    join public.groups g on g.event_id = s.event_id
    join public.group_members gm on gm.group_id = g.id and (gm.is_ic or gm.is_admin)
    cross join lateral (
      -- The group's current moment: the last one the clock has reached.
      select pos.group_id, f.id as frame_id, f.t_s, f.note, pos.lat, pos.lng, pos.state,
             s.t0_at + make_interval(secs => f.t_s) as planned_at
        from public.plan_positions pos
        join public.plan_frames f on f.id = pos.frame_id
       where f.plan_id = s.plan_id
         and pos.group_id = g.id
         and s.t0_at + make_interval(secs => f.t_s) <= p_at
       order by f.t_s desc
       limit 1
    ) m
    left join lateral (
      -- The zone the drawn point stands in, if it stands in one: stage first, then an entrance, then any other.
      select z2.name
        from public.zones z2
       where z2.event_id = s.event_id
         and extensions.st_dwithin(
               z2.shape,
               extensions.st_setsrid(extensions.st_makepoint(m.lng, m.lat), 4326)::extensions.geography,
               0)
       order by case z2.kind when 'stage' then 0 when 'entrance' then 1 else 2 end, z2.name
       limit 1
    ) z on true
   where s.plan_id is not null
     and s.t0_at is not null
     and s.ended_at is null
     and (p_session is null or s.id = p_session)
     -- A nudge at the moment, not a backlog: a tick that has been down for an hour must not tell six groups they are
     -- due now, all at once, about moments that passed.
     and p_at < m.planned_at + interval '1 minute'
     and not exists (
       select 1 from public.plan_progress pr
        where pr.session_id = s.id
          and pr.frame_id = m.frame_id
          and pr.group_id = m.group_id)
  on conflict (dedup) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$body$;

comment on function public.plan_collect_pushes(uuid, timestamptz) is
  'Queue one "now" push per group per moment to its ICs and admins, for moments at most a minute old and not yet '
  'recorded; dedup makes a second tick in the same moment queue nothing (057).';

-- ============================================================
-- 4. The heartbeat: close, nudge, No-Go, send
-- ============================================================
-- The replacement for `gps-push-send`'s command line. It keeps the No-Go collection and the kick, because those were
-- never about run sheets: a No-Go entry is an IC walking into a forbidden area in ANY live session, and a push queued by
-- a message or by 028 still has to leave the server.
create or replace function public.plan_push_tick(p_session uuid default null, p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_n integer := 0;
begin
  -- Closing first, nudging second: a group that is already there does not need to be told it is due.
  perform public.plan_auto_close(p_session, p_at);
  v_n := public.plan_collect_pushes(p_session, p_at);
  -- The old job's other two duties, kept: a No-Go entry is an IC in a forbidden area in any live session, and a push
  -- queued by a message or by 028 still has to leave the server. push_kick() decides whether there is anything to send.
  perform public.push_collect_nogo();
  perform public.push_kick();
  return v_n;
end;
$body$;

comment on function public.plan_push_tick(uuid, timestamptz) is
  'The 5 s heartbeat: close auto moments, queue the "now" pushes, collect No-Go pushes and ask the sender to send '
  '(057). Replaces the gps-push-send job.';

-- ============================================================
-- 5. The forecast: leave-by, and late
-- ============================================================
-- Straight-line metres from where the group's phones say it is to the point of its next moment, divided by the speed
-- those phones have shown. Two pushes, each once per moment and person:
--
--   plan_leave  it is time to set off (60 s before the leave-by time the walk implies), when there is more than 25 m
--               to go -- a group standing at the door is not told to leave
--   plan_late   at that pace the arrival is more than a minute after the plan
--
-- No fix means no forecast. No speed means an ordinary walk (1.3 m/s), never a division by a stationary zero.
create or replace function public.plan_eta_tick(p_session uuid default null, p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_n integer;
begin
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  with live as (
    select s.id, s.event_id, s.plan_id, s.t0_at
      from public.event_sessions s
      join public.events e on e.id = s.event_id and not e.is_simulation
     where s.plan_id is not null
       and s.t0_at is not null
       and s.ended_at is null
       and (p_session is null or s.id = p_session)
  ), nexts as (
    -- The group's NEXT moment still ahead, per group.
    select l.id as session_id, l.event_id,
           g.id as group_id, g.name as group_name,
           nm.frame_id, nm.t_s, nm.lat, nm.lng,
           l.t0_at + make_interval(secs => nm.t_s) as planned_at
      from live l
      join public.groups g on g.event_id = l.event_id
      cross join lateral (
        select pos.frame_id, f.t_s, pos.lat, pos.lng
          from public.plan_positions pos
          join public.plan_frames f on f.id = pos.frame_id
         where f.plan_id = l.plan_id
           and pos.group_id = g.id
           and pos.state = 'on_site'
           and l.t0_at + make_interval(secs => f.t_s) > p_at
         order by f.t_s
         limit 1
      ) nm
  ), ground as (
    select n.session_id, n.group_id, p.lat, p.lng
      from (select distinct session_id, event_id, group_id from nexts) n
      cross join lateral public.group_position_at(n.event_id, n.group_id, p_at) p
  ), walked as (
    select n.session_id, n.event_id, n.group_id, n.group_name, n.frame_id, n.t_s, n.planned_at,
           n.lat, n.lng,
           gp.speed_mps,
           extensions.st_distance(
             extensions.st_setsrid(extensions.st_makepoint(gr.lng, gr.lat), 4326)::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(n.lng, n.lat), 4326)::extensions.geography) as metres
      from nexts n
      join ground gr on gr.session_id = n.session_id and gr.group_id = n.group_id
      left join public.group_positions gp on gp.session_id = n.session_id and gp.group_id = n.group_id
     where gr.lat is not null
  ), forecast as (
    select w.*,
           (w.metres / greatest(coalesce(w.speed_mps, 1.3), 0.5)) as walk_s
      from walked w
  )
  select gm.user_id, f.event_id, f.session_id, k.kind,
         k.kind || ':' || f.session_id || ':' || f.frame_id || ':' || f.group_id || ':' || gm.user_id,
         case k.kind
           when 'plan_leave' then 'Leave now for ' || coalesce(z.name, 'your next moment')
           else 'Running behind for ' || coalesce(z.name, 'your next moment')
         end,
         case k.kind
           when 'plan_leave' then
             round(f.metres)::int || ' m · about ' || greatest(1, round(f.walk_s)::int) || ' s at your pace. Be there by ' ||
             public.sg_hms(f.planned_at) || '.'
           else
             'At your pace you arrive ' || public.sg_hms(p_at + make_interval(secs => f.walk_s)) || ', ' ||
             public.push_mmss(extract(epoch from (p_at + make_interval(secs => f.walk_s) - f.planned_at))::int) ||
             ' after the plan (' || coalesce(z.name, public.plan_clock(f.t_s)) || ' at ' ||
             public.sg_hms(f.planned_at) || ').'
         end,
         jsonb_build_object('kind', k.kind, 'eventId', f.event_id, 'sessionId', f.session_id,
                            'frameId', f.frame_id, 'groupId', f.group_id,
                            'tag', 'plan-' || f.frame_id || '-' || f.group_id)
    from forecast f
    join public.group_members gm on gm.group_id = f.group_id and (gm.is_ic or gm.is_admin)
    cross join lateral (
      values
        ('plan_leave', f.metres > 25
                       and p_at >= f.planned_at - make_interval(secs => f.walk_s) - interval '60 seconds'
                       and p_at < f.planned_at),
        ('plan_late', p_at + make_interval(secs => f.walk_s) > f.planned_at + interval '60 seconds')
    ) as k(kind, due)
    left join lateral (
      select z2.name
        from public.zones z2
       where z2.event_id = f.event_id
         and extensions.st_dwithin(
               z2.shape,
               extensions.st_setsrid(extensions.st_makepoint(f.lng, f.lat), 4326)::extensions.geography,
               0)
       order by case z2.kind when 'stage' then 0 when 'entrance' then 1 else 2 end, z2.name
       limit 1
    ) z on true
   where k.due
  on conflict (dedup) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$body$;

comment on function public.plan_eta_tick(uuid, timestamptz) is
  'Queue "leave now" and "running behind" pushes per group per next moment, from straight-line metres and the '
  'group''s own speed (0.5 m/s floor, 1.3 m/s default, no fix means no forecast) (057).';

-- ============================================================
-- 6. The hand-back log
-- ============================================================
-- One row per hand-back: who took the board, who had it before, when, and the revision the board was showing. The
-- columns are `handed_at` / `from_user` rather than `at` / `by` because 050 learned the hard way that both are keywords
-- PostgreSQL will not read off a PL/pgSQL record.
create table if not exists public.handover_log (
  id uuid primary key default gen_random_uuid(),
  -- Denormalised for the read policy, exactly as 037/038/050 do it: no join per row to decide about a row.
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  -- Nullable: a run-sheet session has no plan (both engines exist until step 25).
  plan_id uuid references public.plans (id) on delete set null,
  -- The revision the board was showing. Copied, not joined: a hand-back is about what was on the screen.
  plan_rev integer,
  -- Who had it before. Read off the previous row, never sent by the client.
  from_user uuid references public.profiles (id) on delete set null,
  to_user uuid not null references public.profiles (id) on delete cascade,
  note text,
  -- WALL-CLOCK time, not now(): `now()` is frozen for the whole transaction, so two hand-backs recorded in one
  -- transaction (a check, a replay, a bulk import) would carry the same instant and the chain would have no order.
  -- clock_timestamp() advances, which is what "when" means here.
  handed_at timestamptz not null default clock_timestamp(),

  constraint handover_log_note_length check (note is null or char_length(note) <= 300)
);

create index if not exists handover_log_session_idx on public.handover_log (session_id, handed_at desc);

comment on table public.handover_log is
  'Who took the board, from whom, when, and the plan revision they were looking at (057, step 21).';
comment on column public.handover_log.plan_rev is
  'The session''s plan revision at the hand-back: what the person taking over was actually looking at (057).';

alter table public.handover_log enable row level security;

drop policy if exists handover_log_read on public.handover_log;
create policy handover_log_read on public.handover_log for select to authenticated
  using (public.is_event_member(event_id));

-- R3: a read policy, no write policy at all, and no write grant. handover_take() is the only writer.
revoke all on table public.handover_log from anon, authenticated, public;
grant select on table public.handover_log to authenticated;

-- ---------- taking the board ----------
create or replace function public.handover_take(p_session uuid, p_note text default null)
returns public.handover_log
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_from uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_row public.handover_log;
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal']) then
    raise exception 'Only the event''s ops can take the board.' using errcode = '42501';
  end if;
  if v_session.ended_at is not null then
    raise exception 'That show has ended, so there is no board to take.' using errcode = '22023';
  end if;
  if v_session.starts_at > now() then
    raise exception 'That show has not started yet, so there is no board to take.' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 300 then
    raise exception 'Keep the hand-back note under 300 characters.' using errcode = '22023';
  end if;

  -- The previous holder, from the log itself: a chain the client cannot rewrite.
  select h.to_user into v_from
    from public.handover_log h
   where h.session_id = v_session.id
   order by h.handed_at desc, h.id desc
   limit 1;

  insert into public.handover_log (event_id, session_id, plan_id, plan_rev, from_user, to_user, note, handed_at)
  values (v_session.event_id, v_session.id, v_session.plan_id, v_session.plan_rev, v_from, auth.uid(), v_note,
          clock_timestamp())
  returning * into v_row;

  return v_row;
end;
$body$;

comment on function public.handover_take(uuid, text) is
  'Record that the caller (the event''s ops) has taken the board: who had it is read off the previous row, and the '
  'session''s plan revision is copied onto it (057).';

-- ---------- reading it, with names ----------
create or replace function public.handover_log_list(p_session uuid)
returns table (
  id uuid, handed_at timestamptz, from_user uuid, to_user uuid,
  from_name text, to_name text, note text, plan_rev integer
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
begin
  select s.event_id into v_event from public.event_sessions s where s.id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_event) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;

  return query
  select h.id, h.handed_at, h.from_user, h.to_user,
         -- A name, but only when there IS a previous holder: the first hand-back of a show has from_user null, and a
         -- coalesce that reached for 'someone' regardless made the screen say "handed from someone" on the first row.
         case when h.from_user is not null
              then coalesce(nullif(btrim(pf.display_name), ''), pf.username, 'someone') end,
         case when h.to_user is not null
              then coalesce(nullif(btrim(pt.display_name), ''), pt.username, 'someone') end,
         h.note, h.plan_rev
    from public.handover_log h
    left join public.profiles pf on pf.id = h.from_user
    left join public.profiles pt on pt.id = h.to_user
   where h.session_id = p_session
   order by h.handed_at desc, h.id desc;
end;
$body$;

comment on function public.handover_log_list(uuid) is
  'The hand-back chain of one session, newest first, with names: the board''s "with whom since when" (057).';

-- ============================================================
-- 7. The ops read gains the marks
-- ============================================================
-- 056's body, verbatim, plus three columns, a left join to plan_progress, and the deleted-plan guard: a row now says
-- whether that moment has been recorded, when, and whether a person said it (marked_by) or the tick did (marked_by null,
-- state set).
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
  marked_by uuid
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
         pr.marked_by
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
  'moment (marked_state / marked_at / marked_by, null marked_by meaning the tick did it); a session whose plan has '
  'been deleted answers no rows (056, marks and guard 057).';

-- ============================================================
-- 8. Jobs: new before old, one transaction
-- ============================================================
-- `cron.schedule` writes to pg_cron's own tables inside this migration's transaction, so the swap is atomic: either both
-- new jobs exist and both old ones are gone, or nothing changed. The new pair is scheduled BEFORE the old pair is
-- unscheduled so there is no instant with neither.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-plan-push';
    perform cron.schedule('gps-plan-push', '5 seconds', 'select public.plan_push_tick()');
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-plan-eta';
    perform cron.schedule('gps-plan-eta', '30 seconds', 'select public.plan_eta_tick()');
    -- Now that the plan's heartbeat is in place, the two run-sheet jobs go (steps 24/25 finish that retirement).
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-push-send';
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-route-eta';
  end if;
end $$;

-- ============================================================
-- 9. Grants (R4)
-- ============================================================
revoke execute on function public.plan_auto_close(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.plan_collect_pushes(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.plan_push_tick(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.plan_eta_tick(uuid, timestamptz) from public, anon, authenticated;

revoke execute on function public.handover_take(uuid, text) from public, anon;
grant execute on function public.handover_take(uuid, text) to authenticated;
revoke execute on function public.handover_log_list(uuid) from public, anon;
grant execute on function public.handover_log_list(uuid) to authenticated;

revoke execute on function public.plan_ops(uuid, timestamptz) from public, anon;
grant execute on function public.plan_ops(uuid, timestamptz) to authenticated;

-- ============================================================
-- 10. The timetable read answers nothing for a session whose plan was deleted
-- ============================================================
-- The same guard as plan_ops', for the same reason, on the other screen that polls a plan: deleting the live plan nulls
-- event_sessions.plan_id, and until the session channel reaches the tab a poll still asks 051/052 for a timetable. 052
-- delegates its refusal to session_status(), which raises (correctly) for a session that is not running a plan -- so the
-- poll answered HTTP 400 and Chrome logged it, which step 21's regression run caught in step 19's check as a console
-- error on a planner's page. A session that never ran a plan still has t0_at null and is still refused (step 15's check
-- 6a/6b); a session whose plan is gone has its t0_at and answers zero rows, which is exactly what the schedule's own
-- empty state ("This event is running without a plan") is written for.
--
-- R8: the body is 052's, with the guard in front and the columns unchanged (so `create or replace` keeps the shape);
-- R4 names the grants again so a future re-create cannot quietly open it.
create or replace function public.session_timetable(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid,
  group_name text,
  frame_id uuid,
  t_s integer,
  planned_at timestamptz,
  state text,
  lateness interval,
  marked_at timestamptz,
  marked_by uuid,
  note text,
  plan_name text,
  plan_rev integer
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_plan uuid;
  v_rev integer;
  v_plan_name text;
  v_t0 timestamptz;
begin
  select s.event_id, s.plan_id, s.plan_rev, s.t0_at into v_event, v_plan, v_rev, v_t0
    from public.event_sessions s
   where s.id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;

  -- A plan that was deleted, not a session that never had one.
  if v_plan is null and v_t0 is not null then
    return;
  end if;

  -- A session with no plan has no name to show; session_status() refuses it below with its own sentence.
  select p.name into v_plan_name from public.plans p where p.id = v_plan;

  return query
  select st.group_id,
         g.name,
         st.frame_id,
         st.t_s,
         st.planned_at,
         st.state,
         st.lateness,
         st.marked_at,
         st.marked_by,
         f.note,
         v_plan_name,
         v_rev
    from public.session_status(p_session, p_at) st
    join public.groups g on g.id = st.group_id
    left join public.plan_frames f on f.id = st.frame_id
   order by st.t_s, g.name, st.group_id;
end;
$body$;

comment on function public.session_timetable(uuid, timestamptz) is
  'One read for a running timetable: a row per group per frame with the planned clock time (from t0_at), '
  'pending/late/arrived/missed/not_required, lateness, the frame''s note, the plan''s name, and the revision the '
  'session follows; scoped to the caller (051, names 052); a session whose plan has been deleted answers no rows '
  '(057).';

revoke execute on function public.session_timetable(uuid, timestamptz) from public, anon;
grant execute on function public.session_timetable(uuid, timestamptz) to authenticated;
