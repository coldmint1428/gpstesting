-- 027_movements.sql -- merger Stage 7: the movements engine and the ops view at scale.
-- Applied on the project as 027 + 027b (message sender name) + 027c (speed per IC) + 027d (deadline = when the cue
-- was due) + 027e (smaller ops_board); this file holds the final state.
--
-- While a show runs (Stage 6), every movement of its run sheet (one row per group: categories expanded, exceptions
-- applied) gets a status for that session, worked out on the server every 5 s (pg_cron gps-move-tick):
--   * Deadline   = when the cue is due to start (moves with the show's delay, not while the cue waits for GO or for
--                  its groups; an anchor's never moves) or its end as projected, or the fixed time, minus "arrive
--                  early by".
--   * Arrived    = "min ICs" (else every IC of the group with a reading in the last 2 min, at least 1) have been inside
--                  the zone for "stay inside" seconds (Stage 2 zone presence). Before the deadline: arrived; after:
--                  arrived late (+m:ss). An IC with no signal never blocks.
--   * ETA        = per IC: now + distance still to go / speed + "stay inside"; the group's ETA is the k-th fastest IC
--                  (k = the number that must arrive). Distance: along the cached OneMap route (route-eta Edge Function)
--                  while the IC is within 50 m of it, else the straight line x 1.3 on foot / 1.4 by vehicle (x 1 in a
--                  simulation, whose virtual groups walk straight); the last 50 m straight to the zone's edge. Speed,
--                  per IC: the planned pace until that IC moves (gets 0.5 m/s closer over the last 50-90 s: a
--                  standing phone's GPS jitter stays below that), then blended towards its real progress (half and
--                  half after 30 s of the group moving, mostly real after 90 s).
--   * Status     = from spare = deadline - ETA (ETA rounded up to 5 s): on track (spare >= "amber below"), at risk
--                  (0 .. amber), late (< 0, shown +m:ss); no signal (not enough ICs heard in the last 2 min). A status
--                  only changes when two evaluations in a row agree; arriving and missing are told at once.
--   * Leave by   = deadline - "stay inside" - distance / planned pace (of the IC the group waits for), never after
--                  the planned "Must leave by"; kept once that IC moves.
--   * One movement per group at a time: the group's earliest unfinished one is active, its later ones wait. A movement
--     is missed when its cue has run without the group, or 10 min after its deadline; a skipped cue skips its movements.
-- The ops view reads ops_board() (root, planners, marshals); problems can be handled / acknowledged / snoozed; a group's
-- admins and ICs can be messaged; "Keep holding" is logged for an "Auto when ready" cue that waits for groups.
-- Simulation events: virtual groups with a movement follow the plan (they leave a minute before their leave-by time,
-- "2 min late" a minute after it), so a rehearsal can be run with the simulator.

-- ============================================================
-- 1. Tables
-- ============================================================
create table public.movement_status (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  movement_id uuid not null references public.movements (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  run_sheet_id uuid not null references public.run_sheets (id) on delete cascade,
  code text not null,
  state text not null default 'waiting' check (state in ('waiting', 'active', 'done')),
  status text not null default 'pending'
    check (status in ('pending', 'on_track', 'at_risk', 'late', 'no_signal', 'arrived', 'arrived_late', 'missed', 'skipped')),
  status_since timestamptz,
  cand_status text,                    -- a different status seen once: applied when the next evaluation agrees
  planned_deadline timestamptz,        -- without the show's delay
  deadline timestamptz,                -- projected
  eta timestamptz,
  spare_s integer,
  late_s integer,
  leave_by timestamptz,
  remaining_m real,
  speed_mps real,
  basis text check (basis in ('route', 'straight', 'inside')),
  moving_since timestamptz,
  ics_inside integer not null default 0,
  ics_required integer not null default 1,
  ics_sharing integer not null default 0,
  ics_no_signal integer not null default 0,
  arrived_at timestamptz,
  handled_by uuid references auth.users (id) on delete set null,
  handled_at timestamptz,
  acked_status text,                   -- acknowledged at this status: out of the queue until it gets worse
  acked_by uuid references auth.users (id) on delete set null,
  snoozed_until timestamptz,
  updated_at timestamptz not null default now(),
  primary key (session_id, movement_id, group_id)
);
create index movement_status_group on public.movement_status (session_id, group_id);

-- OneMap routes, one per movement and group, fetched by the route-eta Edge Function
create table public.movement_routes (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  movement_id uuid not null references public.movements (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  mode text not null check (mode in ('walk', 'drive')),
  from_point extensions.geography,
  to_point extensions.geography,
  path extensions.geography,           -- null: OneMap found no route (the straight line is used)
  distance_m real,
  duration_s real,
  fetched_at timestamptz,
  claimed_at timestamptz,              -- being fetched (another caller leaves it alone for a minute)
  error text,
  primary key (session_id, movement_id, group_id)
);

-- A message to a group's admins and ICs from the ops view ("Message group admin")
create table public.group_messages (
  id bigserial primary key,
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid references public.event_sessions (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  from_user uuid references auth.users (id) on delete set null,
  from_name text,                      -- who sent it, as shown to the group
  body text not null check (char_length(body) between 1 and 300),
  at timestamptz not null default now()
);
create index group_messages_group on public.group_messages (group_id, at desc);

-- A marshal's sector: the ops view opens filtered to it
alter table public.event_roles add column if not exists sector text check (sector is null or char_length(sector) between 1 and 50);

-- "Keep holding" on a waiting cue, and messages to groups, go in the show's log too
alter table public.show_log drop constraint if exists show_log_kind_check;
alter table public.show_log add constraint show_log_kind_check
  check (kind in ('go', 'hold', 'resume', 'add_time', 'skip', 'end_now', 'auto_start', 'auto_end', 'anchor_start', 'anchor_cut',
                  'waiting_go', 'waiting_groups', 'anchor_risk', 'finished', 'switch', 'keep_holding', 'message'));

-- The simulator's virtual groups can follow a movement (one leg at a time)
alter table public.sim_groups add column if not exists movement_id uuid references public.movements (id) on delete set null;

alter table public.movement_status enable row level security;
alter table public.movement_routes enable row level security;
alter table public.group_messages enable row level security;
-- Ops roles see every group; a group's own members see their group's movements (the IC phone, Stage 8)
create policy "movement status: ops and the group read" on public.movement_status
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']) or group_id = public.my_group_id(event_id));
-- movement_routes: no policy (ops_board hands out the routes it shows)
create policy "group messages: ops and the group read" on public.group_messages
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']) or group_id = public.my_group_id(event_id));
revoke all on table public.movement_status, public.movement_routes, public.group_messages from anon, public;
revoke all on table public.movement_routes from authenticated;
grant select on table public.movement_status, public.group_messages to authenticated;

-- Realtime: only the messages (a handful). Movement statuses change on every tick for groups on the move, so the ops
-- view reads ops_board() every few seconds instead of receiving every row change (Realtime quota, section 9).
alter publication supabase_realtime add table public.group_messages;

-- ============================================================
-- 2. Distance still to go
-- ============================================================
-- From a point to a zone: along the route while within 50 m of it, else the straight line x factor; the last 50 m (and
-- inside) straight.
create or replace function public.move_dist(p_zone extensions.geography, p_route extensions.geography, p_lat double precision,
                                            p_lng double precision, p_factor double precision, out remaining_m double precision,
                                            out basis text)
language plpgsql stable set search_path = ''
as $$
declare
  v_pt extensions.geography := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
  v_straight double precision;
  v_frac double precision;
begin
  v_straight := extensions.st_distance(p_zone, v_pt);
  if v_straight <= 0 then
    remaining_m := 0; basis := 'inside'; return;
  end if;
  if v_straight < 50 then
    remaining_m := v_straight; basis := 'straight'; return;
  end if;
  if p_route is not null and extensions.st_distance(p_route, v_pt) <= 50 then
    v_frac := extensions.st_linelocatepoint(p_route::extensions.geometry, v_pt::extensions.geometry);
    remaining_m := greatest(v_straight, extensions.st_length(p_route) * (1 - v_frac));
    basis := 'route';
    return;
  end if;
  remaining_m := v_straight * p_factor;
  basis := 'straight';
end;
$$;

-- The planned "Must leave by" ("C034 END" / "C034 START" / "18:20:00") -> the moment, projected like the cues
create or replace function public.move_planned_leave(p_text text, p_session uuid, p_date date, p_now timestamptz)
returns timestamptz
language plpgsql stable security definer set search_path = ''
as $$
declare
  m text[];
  r record;
begin
  if p_text is null then
    return null;
  end if;
  m := regexp_match(p_text, '^([A-Z0-9_-]{1,20}) (START|END)$');
  if m is not null then
    select x.* into r from public.show_rows(p_session, p_now) x where x.code = m[1];
    if not found or r.status = 'skipped' then
      return null;
    end if;
    return case when m[2] = 'START' then r.projected_start else r.projected_end end;
  end if;
  return public.show_at(p_date, 0, p_text::time);
end;
$$;

-- ============================================================
-- 3. The engine: every movement of one session's show, at a moment
-- ============================================================
create or replace function public.move_step(p_session uuid, p_now timestamptz)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  s public.event_sessions;
  v_sim boolean;
  r record;
  ic record;
  d record;
  d_old record;
  v_group uuid;
  v_active_found boolean := false;
  v_factor double precision;
  v_route extensions.geography;
  v_arr timestamptz[];          -- inside ICs: when they have stayed long enough
  v_eta timestamptz[];          -- every IC that counts for the ETA
  v_rem double precision[];     -- its distance still to go
  v_out_rem double precision[]; -- ICs on their way: distance still to go
  v_out_prog double precision[];-- ... how fast they get closer (null: no earlier reading yet)
  v_out_bas text[];             -- ... how the distance was measured
  v_spd double precision[];     -- every IC: speed used
  v_mov boolean[];              -- every IC: moving
  v_bas text[];                 -- every IC: basis
  v_mov_k boolean;
  v_sig integer;
  v_nosig integer;
  v_inside integer;
  v_k integer;
  v_moving boolean;
  v_moving_since timestamptz;
  v_speed double precision;
  v_w double precision;
  v_arrived timestamptz;
  v_eta_k timestamptz;
  v_rem_k double precision;
  v_basis text;
  v_raw text;
  v_status text;
  v_cand text;
  v_since timestamptz;
  v_spare integer;
  v_late integer;
  v_leave timestamptz;
  v_planned_leave timestamptz;
  v_state text;
  n integer := 0;
  i integer;
begin
  select * into st from public.show_state where session_id = p_session;
  if not found or st.run_sheet_id is null then
    return 0;
  end if;
  select * into s from public.event_sessions where id = p_session;
  select e.is_simulation into v_sim from public.events e where e.id = s.event_id;

  -- 1. One row per movement and group of the version running (new groups of a category join in). After a switch to
  --    another version, arrivals carry over by movement code and group, like the cues.
  insert into public.movement_status (session_id, movement_id, group_id, event_id, run_sheet_id, code)
  select p_session, m.movement_id, m.group_id, s.event_id, st.run_sheet_id, m.code
  from public.rs_moves(st.run_sheet_id) m
  on conflict do nothing;
  if exists (select 1 from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id) then
    update public.movement_status n
    set status = o.status, state = 'done', status_since = o.status_since, arrived_at = o.arrived_at, late_s = o.late_s,
        spare_s = o.spare_s, deadline = o.deadline, planned_deadline = o.planned_deadline, updated_at = now()
    from public.movement_status o
    where n.session_id = p_session and n.run_sheet_id = st.run_sheet_id and n.status = 'pending'
      and o.session_id = p_session and o.run_sheet_id <> st.run_sheet_id and o.code = n.code and o.group_id = n.group_id
      and o.status in ('arrived', 'arrived_late');
    delete from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id;
  end if;

  -- 2. Every row, by group and planned deadline: finished ones stay; a group's first unfinished one is active.
  for r in
    -- when each cue was due: its plan, or when the cue before it ended (a cue held for GO or for its groups does not
    -- give the groups more time; a cue started early by GO does take time away)
    with c as (
      select x.*, greatest(x.planned_start, st.opened_at,
                           max(coalesce(x.ended_at, x.projected_end)) over (order by x.pos rows between unbounded preceding and 1 preceding)) as due_calc
      from public.show_rows(p_session, p_now) x
    )
    select ms.*, mv.zone_id, mv.deadline_kind, mv.cue_id, mv.early_s, mv.min_ics, mv.dwell_s, mv.amber_s, mv.travel_mode,
           mv.pace_mps::double precision as pace, mv.leave_by as planned_leave_text, z.shape as zone_shape,
           c.status as cue_status,
           case mv.deadline_kind
             when 'fixed' then public.show_at(st.show_date, mv.fixed_day_offset, mv.fixed_time)
             when 'cue_start' then c.planned_start
             else c.planned_end end - make_interval(secs => mv.early_s) as p_deadline,
           case mv.deadline_kind
             when 'fixed' then public.show_at(st.show_date, mv.fixed_day_offset, mv.fixed_time)
             when 'cue_start' then case when c.type = 'anchor' then coalesce(c.started_at, c.due_at)
                                        when c.status in ('running', 'done') then least(c.started_at, c.due_calc)
                                        else c.due_at end
             else case when c.status = 'done' then c.ended_at else c.projected_end end end - make_interval(secs => mv.early_s) as x_deadline
    from public.movement_status ms
    join public.movements mv on mv.id = ms.movement_id
    left join public.zones z on z.id = mv.zone_id
    left join c on c.cue_id = mv.cue_id
    where ms.session_id = p_session
    order by ms.group_id, p_deadline nulls last, ms.code
  loop
    if v_group is distinct from r.group_id then
      v_group := r.group_id;
      v_active_found := false;
    end if;
    if r.status in ('arrived', 'arrived_late', 'missed', 'skipped') then
      continue;
    end if;

    -- A skipped cue skips its movements; a movement without a cue or zone (deleted since) cannot be followed
    if (r.deadline_kind <> 'fixed' and (r.cue_status is null or r.cue_status = 'skipped')) or r.zone_shape is null then
      update public.movement_status
      set status = 'skipped', state = 'done', status_since = p_now, cand_status = null, eta = null, spare_s = null, late_s = null,
          deadline = r.x_deadline, planned_deadline = r.p_deadline, updated_at = now()
      where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
      n := n + 1;
      continue;
    end if;

    if v_active_found then
      -- waits for the group's earlier movement: keep its deadline current, nothing else
      if (r.state, r.status, r.deadline, r.planned_deadline) is distinct from ('waiting', 'pending', r.x_deadline, r.p_deadline) then
        update public.movement_status
        set state = 'waiting', status = 'pending', cand_status = null, deadline = r.x_deadline, planned_deadline = r.p_deadline,
            eta = null, spare_s = null, late_s = null, leave_by = null, moving_since = null, updated_at = now()
        where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
        n := n + 1;
      end if;
      continue;
    end if;
    v_active_found := true;

    -- ---------- The group's active movement ----------
    v_factor := case when v_sim then 1.0 when r.travel_mode = 'vehicle' then 1.4 else 1.3 end;
    v_route := (select mr.path from public.movement_routes mr
                where mr.session_id = p_session and mr.movement_id = r.movement_id and mr.group_id = r.group_id);
    v_arr := '{}'; v_out_rem := '{}'; v_out_prog := '{}'; v_out_bas := '{}';
    v_sig := 0; v_nosig := 0; v_inside := 0;

    for ic in
      select gm.user_id, l.lat, l.lng, l.recorded_at, l.source,
             (select min(zp.entered_at) from public.zone_presence zp
              where zp.session_id = p_session and zp.user_id = gm.user_id and zp.zone_id = r.zone_id and zp.exited_at is null
                and zp.entered_at <= p_now) as inside_since
      from public.group_members gm
      left join lateral (
        select x.lat, x.lng, x.recorded_at, x.source from public.locations x
        where x.event_id = s.event_id and x.user_id = gm.user_id and x.recorded_at >= s.starts_at and x.recorded_at <= p_now
        order by x.recorded_at desc limit 1
      ) l on true
      where gm.group_id = r.group_id and gm.is_ic
    loop
      if ic.inside_since is not null then
        v_inside := v_inside + 1;
        v_arr := v_arr || (ic.inside_since + make_interval(secs => r.dwell_s));
      end if;
      if ic.recorded_at is null then
        continue;                                  -- has not shared in this session
      end if;
      if ic.source = 'stop' or ic.recorded_at <= p_now - interval '2 minutes' then
        v_nosig := v_nosig + 1;
        continue;
      end if;
      v_sig := v_sig + 1;
      if ic.inside_since is not null then
        continue;                                  -- counted in v_arr
      end if;
      d := public.move_dist(r.zone_shape, v_route, ic.lat, ic.lng, v_factor);
      v_out_rem := v_out_rem || d.remaining_m;
      v_out_bas := v_out_bas || d.basis;
      -- progress towards the zone: the same distance from this IC's earliest reading 50-90 s before
      select x.lat, x.lng, x.recorded_at into d_old from public.locations x
      where x.event_id = s.event_id and x.user_id = ic.user_id and x.source <> 'stop'
        and x.recorded_at between ic.recorded_at - interval '90 seconds' and ic.recorded_at - interval '50 seconds'
      order by x.recorded_at limit 1;
      v_out_prog := v_out_prog || case when found then
        ((public.move_dist(r.zone_shape, v_route, d_old.lat, d_old.lng, v_factor)).remaining_m - d.remaining_m)
          / greatest(extract(epoch from ic.recorded_at - d_old.recorded_at), 1) end;
    end loop;

    -- the group moves once one of its ICs does (0.5 m/s closer or more)
    v_moving := exists (select 1 from unnest(v_out_prog) p where p >= 0.5);
    v_moving_since := case when v_moving then coalesce(r.moving_since, p_now) end;
    v_w := case when v_moving then extract(epoch from p_now - v_moving_since) else 0 end;
    v_w := v_w / (v_w + 30);

    -- ETAs: inside ICs when they have stayed long enough; the others by distance / their speed (the planned pace until
    -- they move, then blended towards their real progress)
    v_eta := v_arr;
    v_rem := array_fill(0::double precision, array[cardinality(v_arr)]);
    v_spd := array_fill(null::double precision, array[cardinality(v_arr)]);
    v_mov := array_fill(false, array[cardinality(v_arr)]);
    v_bas := array_fill('inside'::text, array[cardinality(v_arr)]);
    for i in 1 .. coalesce(cardinality(v_out_rem), 0) loop
      v_speed := case when v_out_prog[i] >= 0.5 then (1 - v_w) * r.pace + v_w * v_out_prog[i] else r.pace end;
      v_eta := v_eta || (p_now + make_interval(secs => v_out_rem[i] / v_speed + r.dwell_s));
      v_rem := v_rem || v_out_rem[i];
      v_spd := v_spd || v_speed;
      v_mov := v_mov || coalesce(v_out_prog[i] >= 0.5, false);
      v_bas := v_bas || v_out_bas[i];
    end loop;

    v_k := greatest(1, coalesce(r.min_ics, v_sig));
    v_arrived := (select a from unnest(v_arr) a order by a offset v_k - 1 limit 1);
    if v_arrived > p_now then
      v_arrived := null;                           -- inside, still staying long enough
    end if;
    -- the group's ETA is the k-th IC's (the one the group waits for)
    v_eta_k := null; v_rem_k := null; v_speed := null; v_mov_k := false; v_basis := null;
    select e, rm, sp, mv, bs into v_eta_k, v_rem_k, v_speed, v_mov_k, v_basis
    from unnest(v_eta, v_rem, v_spd, v_mov, v_bas) as t(e, rm, sp, mv, bs) order by e offset v_k - 1 limit 1;
    if v_eta_k is not null then
      v_eta_k := to_timestamp(ceil(extract(epoch from v_eta_k) / 5) * 5);   -- rounded up to 5 s
    end if;

    v_spare := null; v_late := null;
    if v_arrived is not null then
      v_raw := case when v_arrived <= r.x_deadline then 'arrived' else 'arrived_late' end;
      v_spare := public.show_secs(r.x_deadline - v_arrived);
      v_late := case when v_raw = 'arrived_late' then -v_spare end;
    elsif (r.deadline_kind = 'cue_start' and r.cue_status = 'done') or p_now > r.x_deadline + interval '10 minutes' then
      v_raw := 'missed';
      v_late := public.show_secs(p_now - r.x_deadline);
    elsif v_eta_k is null then
      v_raw := 'no_signal';
      v_late := case when p_now > r.x_deadline then public.show_secs(p_now - r.x_deadline) end;
    else
      v_spare := public.show_secs(r.x_deadline - v_eta_k);
      v_raw := case when v_spare >= r.amber_s then 'on_track' when v_spare >= 0 then 'at_risk' else 'late' end;
      v_late := case when v_spare < 0 then -v_spare end;
    end if;

    -- two evaluations in a row must agree (arriving and missing are facts: at once; the first evaluation too)
    v_status := r.status; v_cand := null; v_since := r.status_since;
    if v_raw in ('arrived', 'arrived_late', 'missed') or r.status = 'pending' then
      v_status := v_raw;
    elsif v_raw <> r.status then
      if r.cand_status = v_raw then v_status := v_raw; else v_cand := v_raw; end if;
    end if;
    if v_status is distinct from r.status then
      v_since := p_now;
    end if;
    v_state := case when v_status in ('arrived', 'arrived_late', 'missed') then 'done' else 'active' end;

    -- leave by: worked out while the IC the group waits for has not left, kept once it moves
    if v_state = 'done' or v_inside >= v_k then
      v_leave := r.leave_by;
    elsif v_rem_k is not null and (not v_mov_k or r.leave_by is null) then
      v_leave := r.x_deadline - make_interval(secs => r.dwell_s + v_rem_k / r.pace);
      v_leave := to_timestamp(floor(extract(epoch from v_leave) / 5) * 5);
      v_planned_leave := public.move_planned_leave(r.planned_leave_text, p_session, st.show_date, p_now);
      if v_planned_leave < v_leave then
        v_leave := v_planned_leave;
      end if;
    else
      v_leave := coalesce(r.leave_by, public.move_planned_leave(r.planned_leave_text, p_session, st.show_date, p_now));
    end if;

    if (r.state, r.status, r.status_since, r.cand_status, r.deadline, r.planned_deadline, r.eta, r.spare_s, r.late_s, r.leave_by,
        r.remaining_m, r.speed_mps, r.basis, r.moving_since, r.ics_inside, r.ics_required, r.ics_sharing, r.ics_no_signal, r.arrived_at)
       is distinct from
       (v_state, v_status, v_since, v_cand, r.x_deadline, r.p_deadline,
        case when v_state = 'done' and v_status = 'missed' then null else v_eta_k end, v_spare, v_late, v_leave,
        round(v_rem_k)::real, round(coalesce(v_speed, r.pace)::numeric, 2)::real, v_basis, v_moving_since, v_inside, v_k, v_sig, v_nosig,
        case when v_status in ('arrived', 'arrived_late') then v_arrived end) then
      update public.movement_status
      set state = v_state, status = v_status, status_since = v_since, cand_status = v_cand, deadline = r.x_deadline,
          planned_deadline = r.p_deadline, eta = case when v_state = 'done' and v_status = 'missed' then null else v_eta_k end,
          spare_s = v_spare, late_s = v_late, leave_by = v_leave, remaining_m = round(v_rem_k)::real,
          speed_mps = round(coalesce(v_speed, r.pace)::numeric, 2)::real, basis = v_basis, moving_since = v_moving_since, ics_inside = v_inside,
          ics_required = v_k, ics_sharing = v_sig, ics_no_signal = v_nosig,
          arrived_at = case when v_status in ('arrived', 'arrived_late') then v_arrived end,
          -- a problem that is over needs no acknowledging or snoozing any more
          acked_status = case when v_status in ('on_track', 'arrived') then null else acked_status end,
          snoozed_until = case when v_status in ('on_track', 'arrived') then null else snoozed_until end,
          updated_at = now()
      where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
      n := n + 1;
    end if;
  end loop;

  if v_sim then
    perform public.sim_follow_plan(p_session, p_now);
  end if;
  return n;
end;
$$;

-- ============================================================
-- 4. Simulation events: virtual groups follow their movements
-- ============================================================
-- One leg at a time, from where the group stands to the middle of its active movement's zone, at the movement's
-- planned pace. They leave a minute before their leave-by time ("2 min late": a minute after it, two minutes after
-- the others). "Stops halfway" and "Loses signal" behave as before on every leg; "Wrong zone" keeps walking into the
-- No-Go zone. sim_tick() (022) moves them as before.
create or replace function public.sim_follow_plan(p_session uuid, p_now timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  g record;
  sg public.sim_groups;
  v_lat double precision;
  v_lng double precision;
  v_end extensions.geography;
  v_path double precision;
  v_depart double precision;
begin
  for g in
    select x.id, ms.movement_id as want, ms.leave_by, mv.pace_mps::double precision as plan_pace, z.shape
    from public.sim_groups x
    join public.event_sessions es on es.id = p_session and es.event_id = x.event_id
    join public.movement_status ms on ms.session_id = p_session and ms.group_id = x.group_id and ms.state = 'active'
    join public.movements mv on mv.id = ms.movement_id
    join public.zones z on z.id = mv.zone_id
    where x.script <> 'wrong_zone'
  loop
    select * into sg from public.sim_groups where id = g.id;
    if sg.movement_id is distinct from g.want then
      -- a new leg starts where the group stands
      v_lat := coalesce(sg.start_lat + (sg.end_lat - sg.start_lat) * least(sg.travelled_m / nullif(sg.path_m, 0), 1), sg.start_lat);
      v_lng := coalesce(sg.start_lng + (sg.end_lng - sg.start_lng) * least(sg.travelled_m / nullif(sg.path_m, 0), 1), sg.start_lng);
      v_end := extensions.st_centroid(g.shape::extensions.geometry)::extensions.geography;
      v_path := greatest(extensions.st_distance(v_end, extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography), 0.1);
      update public.sim_groups
      set movement_id = g.want, start_lat = v_lat, start_lng = v_lng,
          end_lat = extensions.st_y(v_end::extensions.geometry), end_lng = extensions.st_x(v_end::extensions.geometry),
          path_m = v_path, travelled_m = 0, pace_mps = g.plan_pace,
          depart_after_s = active_s + 100000,          -- waits for its leave-by time (below)
          stop_at_m = case when script = 'stops_halfway' then v_path * 0.5 end,
          silent_from_s = null, silent_to_s = null
      where id = g.id
      returning * into sg;
    end if;
    -- not left yet: the departure follows the leave-by time (which moves with the show's delay)
    if sg.travelled_m = 0 and g.leave_by is not null then
      v_depart := sg.active_s + greatest(0, extract(epoch from g.leave_by - p_now) - 60 + case when sg.script = 'late_2min' then 120 else 0 end);
      if sg.depart_after_s is null or abs(sg.depart_after_s - v_depart) > 2 then
        update public.sim_groups
        set depart_after_s = v_depart,
            silent_from_s = case when script = 'loses_signal' then v_depart + (path_m * 0.4) / pace_mps end,
            silent_to_s = case when script = 'loses_signal' then v_depart + (path_m * 0.4) / pace_mps + 150 end
        where id = g.id;
      end if;
    end if;
  end loop;
end;
$$;

-- Simulator panel: one movement per virtual group (to the zone it walks to) in a Draft version, due at a cue's start
create or replace function public.sim_plan_movements(p_event uuid, p_sheet uuid, p_cue uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  g record;
  n integer := 0;
begin
  perform public.sim_check(p_event);
  if not exists (select 1 from public.run_sheets r where r.id = p_sheet and r.event_id = p_event) then
    raise exception 'That run sheet version is not in this event';
  end if;
  if not exists (select 1 from public.cues c where c.id = p_cue and c.run_sheet_id = p_sheet) then
    raise exception 'Pick a cue of that version';
  end if;
  for g in
    select sg.group_id, sg.target_zone_id from public.sim_groups sg
    join public.zones z on z.id = sg.target_zone_id and z.kind <> 'no_go'
    where sg.event_id = p_event
      and not exists (select 1 from public.movements m where m.run_sheet_id = p_sheet and m.group_id = sg.group_id and m.parent_id is null)
    order by sg.group_id
  loop
    perform public.save_movement(p_sheet, jsonb_build_object('group_id', g.group_id, 'zone_id', g.target_zone_id,
                                 'deadline_kind', 'cue_start', 'cue_id', p_cue, 'dwell_s', 20, 'amber_s', 30));
    n := n + 1;
  end loop;
  if n = 0 then
    raise exception 'Every virtual group already has a movement in that version (or there are none yet: add groups first)';
  end if;
  return n;
end;
$$;

-- ============================================================
-- 5. The tick: every live show, every 5 s. One show failing never stops the others.
-- ============================================================
create or replace function public.move_tick()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  n integer := 0;
begin
  for s in
    select es.id from public.event_sessions es
    join public.show_state st on st.session_id = es.id
    where es.ended_at is null and es.starts_at <= now() and es.run_sheet_id is not null
      and (es.scheduled_end is null or es.scheduled_end > now())
  loop
    begin
      perform public.move_step(s.id, public.show_now());
      n := n + 1;
    exception when others then
      raise warning 'move_tick %: %', s.id, sqlerrm;
    end;
  end loop;
  return n;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-move-tick';
    perform cron.schedule('gps-move-tick', '5 seconds', 'select public.move_tick()');
  end if;
end $$;

-- ============================================================
-- 6. OneMap routes (Edge Function route-eta, called by pg_cron every 30 s with the push cron secret of 009)
-- ============================================================
-- Routes wanted now: active movements of groups on the map, outside their zone and over 80 m from it, in real events
-- (the simulator walks straight), with no route yet, a route over 2 min old, or a group more than 50 m off its route.
-- Destination: the arrival point's middle (the door) if set, else the zone's nearest edge.
create or replace function public.route_wanted(p_limit integer)
returns table (session_id uuid, movement_id uuid, group_id uuid, mode text, from_lat double precision, from_lng double precision,
               to_lat double precision, to_lng double precision)
language sql stable security definer set search_path = ''
as $$
  select ms.session_id, ms.movement_id, ms.group_id,
         case when mv.travel_mode = 'vehicle' then 'drive' else 'walk' end,
         gp.lat, gp.lng, extensions.st_y(w.dest), extensions.st_x(w.dest)
  from public.movement_status ms
  join public.movements mv on mv.id = ms.movement_id and mv.travel_mode in ('on_foot', 'vehicle')
  join public.zones z on z.id = mv.zone_id
  join public.events e on e.id = ms.event_id and not e.is_simulation
  join public.event_sessions es on es.id = ms.session_id and es.ended_at is null
  join public.group_positions gp on gp.session_id = ms.session_id and gp.group_id = ms.group_id
  left join public.movement_routes mr on mr.session_id = ms.session_id and mr.movement_id = ms.movement_id and mr.group_id = ms.group_id
  cross join lateral (
    select extensions.st_setsrid(extensions.st_makepoint(gp.lng, gp.lat), 4326)::extensions.geography as here
  ) h
  cross join lateral (
    select coalesce(
      (select extensions.st_centroid(az.shape::extensions.geometry) from public.zones az
       where az.event_id = ms.event_id and az.code = mv.arrival_point),
      extensions.st_closestpoint(z.shape::extensions.geometry, h.here::extensions.geometry)) as dest
  ) w
  where ms.state = 'active' and gp.lat is not null and gp.last_seen > now() - interval '2 minutes'
    and extensions.st_distance(z.shape, h.here) > 80
    and (mr.claimed_at is null or mr.claimed_at < now() - interval '1 minute')
    and (mr.fetched_at is null or mr.fetched_at < now() - interval '2 minutes'
         or (mr.path is not null and extensions.st_distance(mr.path, h.here) > 50))
  order by mr.fetched_at nulls first
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

-- Anything to fetch? (the cron job only calls the Edge Function when there is)
create or replace function public.route_due()
returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.route_wanted(1)); $$;

-- The Edge Function takes up to p_limit of them (marked as being fetched)
create or replace function public.route_claim(p_limit integer default 20)
returns table (session_id uuid, movement_id uuid, group_id uuid, mode text, from_lat double precision, from_lng double precision,
               to_lat double precision, to_lng double precision)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
  with want as (select * from public.route_wanted(p_limit)),
  claimed as (
    insert into public.movement_routes as t (session_id, movement_id, group_id, mode, claimed_at)
    select w.session_id, w.movement_id, w.group_id, w.mode, now() from want w
    on conflict (session_id, movement_id, group_id) do update set claimed_at = now(), mode = excluded.mode
    returning t.session_id, t.movement_id, t.group_id
  )
  select w.session_id, w.movement_id, w.group_id, w.mode, w.from_lat, w.from_lng, w.to_lat, w.to_lng
  from want w join claimed c on c.session_id = w.session_id and c.movement_id = w.movement_id and c.group_id = w.group_id;
end;
$$;

-- The Edge Function's answer: the route as [[lat, lng], ...] (or no points + an error: the straight line is used)
create or replace function public.route_save(p_session uuid, p_movement uuid, p_group uuid, p_points jsonb, p_distance_m real,
                                             p_duration_s real, p_from_lat double precision, p_from_lng double precision,
                                             p_to_lat double precision, p_to_lng double precision, p_error text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_path extensions.geography;
begin
  if p_points is not null and jsonb_typeof(p_points) = 'array' and jsonb_array_length(p_points) >= 2 then
    select extensions.st_makeline(array_agg(extensions.st_setsrid(extensions.st_makepoint((p ->> 1)::double precision,
                                                                                        (p ->> 0)::double precision), 4326) order by o))::extensions.geography
      into v_path
    from jsonb_array_elements(p_points) with ordinality as t(p, o);
  end if;
  update public.movement_routes
  set path = v_path, distance_m = p_distance_m, duration_s = p_duration_s,
      from_point = extensions.st_setsrid(extensions.st_makepoint(p_from_lng, p_from_lat), 4326)::extensions.geography,
      to_point = extensions.st_setsrid(extensions.st_makepoint(p_to_lng, p_to_lat), 4326)::extensions.geography,
      fetched_at = now(), claimed_at = null, error = left(p_error, 300)
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-route-eta';
    perform cron.schedule('gps-route-eta', '30 seconds', $job$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/route-eta',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
        body := '{}'::jsonb,
        timeout_milliseconds := 25000
      )
      where public.route_due() and exists (select 1 from vault.decrypted_secrets where name = 'project_url');
    $job$);
  end if;
end $$;

-- ============================================================
-- 7. What the ops view reads and presses
-- ============================================================
create or replace function public.ops_session_role(p_session uuid, p_roles text[])
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.event_sessions where id = p_session;
  if v_event is null or not public.has_event_role(v_event, p_roles) then
    raise exception 'Only the root, planners and marshals can see the groups'' movements' using errcode = '42501';
  end if;
  return v_event;
end;
$$;

-- Every movement of the session's show (root, planners, marshals). Read every few seconds by each ops screen, so it is
-- kept small: with p_since only the rows changed since then (10 s overlap: a tick that was still running when the last
-- read was made), empty fields left out, and a group's route sent only when it is new (route_at says which one).
create or replace function public.ops_board(p_session uuid, p_since timestamptz default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_event uuid := public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  v_since timestamptz := p_since - interval '10 seconds';
begin
  return jsonb_build_object(
    'server_now', public.show_now(),
    'as_of', now(),
    'full', p_since is null,
    'run_sheet_id', (select st.run_sheet_id from public.show_state st where st.session_id = p_session),
    'my_sector', (select er.sector from public.event_roles er where er.event_id = v_event and er.user_id = auth.uid() and er.role = 'marshal'),
    'rows', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'movement_id', ms.movement_id, 'group_id', ms.group_id, 'code', ms.code, 'zone_id', mv.zone_id, 'cue_id', mv.cue_id,
        'category', coalesce(mv.category, (select p.category from public.movements p where p.id = mv.parent_id)),
        'state', ms.state, 'status', ms.status, 'planned_deadline', ms.planned_deadline, 'deadline', ms.deadline,
        'spare_s', ms.spare_s, 'late_s', ms.late_s, 'leave_by', ms.leave_by, 'remaining_m', ms.remaining_m,
        'speed_mps', ms.speed_mps, 'basis', ms.basis, 'moving', case when ms.moving_since is not null then true end,
        'inside', nullif(ms.ics_inside, 0), 'required', ms.ics_required, 'sharing', ms.ics_sharing,
        'no_signal', nullif(ms.ics_no_signal, 0), 'arrived_at', ms.arrived_at,
        'handled_by', case when ms.handled_by is null then null else public.show_who(ms.handled_by) end,
        'handled_mine', case when ms.handled_by = auth.uid() then true end,
        'acked_status', ms.acked_status, 'snoozed_until', ms.snoozed_until,
        'route_at', case when w.problem then mr.fetched_at end,
        'route', case when w.problem and mr.path is not null and (p_since is null or mr.fetched_at > v_since)
                      then extensions.st_asgeojson(mr.path, 5)::jsonb end
      ))), '[]'::jsonb)
      from public.movement_status ms
      join public.movements mv on mv.id = ms.movement_id
      left join public.movement_routes mr on mr.session_id = ms.session_id and mr.movement_id = ms.movement_id and mr.group_id = ms.group_id
      cross join lateral (select ms.state = 'active' and ms.status in ('at_risk', 'late', 'no_signal') as problem) w
      where ms.session_id = p_session and (p_since is null or ms.updated_at > v_since)
    )
  );
end;
$$;

-- The queue buttons mark the row changed, so the next read of every ops screen picks them up
create or replace function public.ops_handle(p_session uuid, p_movement uuid, p_group uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  ms public.movement_status;
begin
  perform public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  select * into ms from public.movement_status where session_id = p_session and movement_id = p_movement and group_id = p_group for update;
  if not found then
    raise exception 'That movement is not in this show';
  end if;
  if ms.handled_by = auth.uid() then
    update public.movement_status set handled_by = null, handled_at = null, updated_at = now()
    where session_id = p_session and movement_id = p_movement and group_id = p_group;
    return 'released';
  end if;
  if ms.handled_by is not null then
    raise exception '% is already handling it (since %).', public.show_who(ms.handled_by),
      to_char(ms.handled_at at time zone 'Asia/Singapore', 'HH24:MI:SS') using errcode = 'PT409';
  end if;
  update public.movement_status set handled_by = auth.uid(), handled_at = now(), updated_at = now()
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
  return 'handling';
end;
$$;

create or replace function public.ops_ack(p_session uuid, p_movement uuid, p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  update public.movement_status set acked_status = status, acked_by = auth.uid(), updated_at = now()
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
  if not found then
    raise exception 'That movement is not in this show';
  end if;
end;
$$;

create or replace function public.ops_snooze(p_session uuid, p_movement uuid, p_group uuid, p_seconds integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  if p_seconds is null or p_seconds < 60 or p_seconds > 1800 then
    raise exception 'Snooze between 1 and 30 minutes';
  end if;
  update public.movement_status set snoozed_until = public.show_now() + make_interval(secs => p_seconds), updated_at = now()
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
  if not found then
    raise exception 'That movement is not in this show';
  end if;
end;
$$;

-- Message a group's admins and ICs (on the event page; a push when the app is closed comes with Stage 8)
create or replace function public.message_group(p_session uuid, p_group uuid, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid := public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  v_name text;
begin
  select g.name into v_name from public.groups g where g.id = p_group and g.event_id = v_event;
  if v_name is null then
    raise exception 'That group is not in this event';
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 300 then
    raise exception 'Write a message of 1 to 300 characters';
  end if;
  insert into public.group_messages (event_id, session_id, group_id, from_user, from_name, body)
  values (v_event, p_session, p_group, auth.uid(), public.show_who(auth.uid()), p_body);
  if exists (select 1 from public.show_state where session_id = p_session) then
    perform public.show_log_add(p_session, null, 'message', public.show_who(auth.uid()) || ' messaged ' || v_name || ': "' || p_body || '"',
      auth.uid(), public.show_now());
  end if;
end;
$$;

-- "Keep holding" an "Auto when ready" cue that waits for groups: every planner sees the decision
create or replace function public.show_keep_holding(p_session uuid, p_cue uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  r record;
begin
  st := public.show_for_action(p_session);
  select * into r from public.show_rows(p_session, public.show_now()) x where x.cue_id = p_cue;
  if not found or r.status <> 'pending' or r.wait_kind is distinct from 'groups' then
    raise exception 'That cue is not waiting for groups' using errcode = 'PT409';
  end if;
  perform public.show_log_add(p_session, p_cue, 'keep_holding', public.show_who(auth.uid()) || ' keeps ' ||
    public.show_label(r.code, r.title) || ' holding for its groups.', auth.uid(), public.show_now());
end;
$$;

-- A marshal's sector (root / planners, Members tab)
create or replace function public.set_marshal_sector(p_event uuid, p_user uuid, p_sector text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can set a marshal''s sector' using errcode = '42501';
  end if;
  p_sector := nullif(btrim(coalesce(p_sector, '')), '');
  if char_length(p_sector) > 50 then
    raise exception 'A sector name is at most 50 characters';
  end if;
  update public.event_roles set sector = p_sector where event_id = p_event and user_id = p_user and role = 'marshal';
  if not found then
    raise exception 'That person is not a marshal of this event';
  end if;
end;
$$;

-- ============================================================
-- 8. Permissions
-- ============================================================
revoke execute on function public.move_dist(extensions.geography, extensions.geography, double precision, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.move_planned_leave(text, uuid, date, timestamptz) from public, anon, authenticated;
revoke execute on function public.move_step(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.sim_follow_plan(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.move_tick() from public, anon, authenticated;
revoke execute on function public.route_wanted(integer) from public, anon, authenticated;
revoke execute on function public.route_due() from public, anon, authenticated;
revoke execute on function public.route_claim(integer) from public, anon, authenticated;
revoke execute on function public.route_save(uuid, uuid, uuid, jsonb, real, real, double precision, double precision, double precision, double precision, text) from public, anon, authenticated;
revoke execute on function public.ops_session_role(uuid, text[]) from public, anon, authenticated;
grant execute on function public.route_claim(integer) to service_role;
grant execute on function public.route_save(uuid, uuid, uuid, jsonb, real, real, double precision, double precision, double precision, double precision, text) to service_role;

revoke execute on function public.sim_plan_movements(uuid, uuid, uuid) from public, anon;
revoke execute on function public.ops_board(uuid, timestamptz) from public, anon;
revoke execute on function public.ops_handle(uuid, uuid, uuid) from public, anon;
revoke execute on function public.ops_ack(uuid, uuid, uuid) from public, anon;
revoke execute on function public.ops_snooze(uuid, uuid, uuid, integer) from public, anon;
revoke execute on function public.message_group(uuid, uuid, text) from public, anon;
revoke execute on function public.show_keep_holding(uuid, uuid) from public, anon;
revoke execute on function public.set_marshal_sector(uuid, uuid, text) from public, anon;
grant execute on function public.sim_plan_movements(uuid, uuid, uuid) to authenticated;
grant execute on function public.ops_board(uuid, timestamptz) to authenticated;
grant execute on function public.ops_handle(uuid, uuid, uuid) to authenticated;
grant execute on function public.ops_ack(uuid, uuid, uuid) to authenticated;
grant execute on function public.ops_snooze(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.message_group(uuid, uuid, text) to authenticated;
grant execute on function public.show_keep_holding(uuid, uuid) to authenticated;
grant execute on function public.set_marshal_sector(uuid, uuid, text) to authenticated;
