-- 026_live_show.sql -- merger Stage 6: the run sheet runs live.
--
-- While a session is live with a run sheet version (event_sessions.run_sheet_id, Stage 4), the show runs:
--   * every cue has a state for that session: pending -> running -> done (or skipped);
--   * show_rows() works out, for every cue, its planned and projected start and end and the delay, with the rules
--     below; the engine (show_tick, pg_cron every 2 s) and every screen use the same function, so they agree;
--   * root and planners press GO / Hold / Resume / +30 s / Skip; marshals see the show but cannot change it;
--   * every action and every alert is written to show_log (who, when, what), which pages show as toasts.
--
-- Rules (docs/merger-build-plan.md section 5):
--   * A cue never starts before its planned time, nor before the cue before it has ended: projected start =
--     max(planned, previous projected end). Delay = projected start - planned.
--   * A Flexible cue absorbs delay: it ends up to "can shorten by" early (by how late it started).
--   * An Anchor keeps its planned time. It is at risk when the cue before it is projected to end after it; when its
--     time comes it starts anyway, ending the cue still running and skipping cues that never got to run.
--   * Auto cues start by the clock. "Auto when ready" cues start when every group of their movements (deadline =
--     this cue's start) is inside its zone, else they wait and planners are told who is missing (GO anyway).
--     Manual cues wait for GO. A running cue ends at its length (+ any time added).
--   * Hold: nothing moves on to the next cue until Resume (the running cue keeps going; anchors still start).
--   * Arrived (the Stage 7 engine adds ETAs): at least "min ICs" (else every IC of the group that sent a reading in
--     the last 2 min, and at least 1) of the group's ICs have been inside the zone for "stay inside" seconds.
--
-- Times are the show's day in Singapore: cue 18:04:12 (+1 day) on show_state.show_date.

-- ============================================================
-- 1. Tables
-- ============================================================
create table public.show_state (
  session_id uuid primary key references public.event_sessions (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  run_sheet_id uuid references public.run_sheets (id) on delete set null,
  show_date date not null,                 -- the day the cue times are on (Singapore)
  opened_at timestamptz not null,          -- nothing starts before this (the session's start)
  held_since timestamptz,
  held_by uuid references auth.users (id) on delete set null,
  finished_at timestamptz,
  rev bigint not null default 1,
  updated_at timestamptz not null default now()
);

create table public.show_cues (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  cue_id uuid not null references public.cues (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'running', 'done', 'skipped')),
  started_at timestamptz,
  ended_at timestamptz,
  started_by uuid references auth.users (id) on delete set null,   -- null = by the clock
  ended_by uuid references auth.users (id) on delete set null,
  added_s integer not null default 0 check (added_s between -3600 and 3600),
  wait_kind text check (wait_kind in ('go', 'groups')),            -- why a due cue has not started
  waiting_since timestamptz,
  risk_alerted boolean not null default false,                     -- anchor at risk: told once
  note text,
  updated_at timestamptz not null default now(),
  primary key (session_id, cue_id)
);

create table public.show_log (
  id bigserial primary key,
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  cue_id uuid references public.cues (id) on delete set null,
  kind text not null check (kind in ('go', 'hold', 'resume', 'add_time', 'skip', 'end_now', 'auto_start', 'auto_end',
                                     'anchor_start', 'anchor_cut', 'waiting_go', 'waiting_groups', 'anchor_risk',
                                     'finished', 'switch')),
  message text not null,
  by_user uuid references auth.users (id) on delete set null,      -- null = the show clock
  at timestamptz not null default now()
);
create index show_log_session on public.show_log (session_id, id desc);

alter table public.show_state enable row level security;
alter table public.show_cues enable row level security;
alter table public.show_log enable row level security;
create policy "show: root, planners, marshals read" on public.show_state
  for select to authenticated using (public.has_event_role(event_id, array['root', 'planner', 'marshal']));
create policy "show cues: root, planners, marshals read" on public.show_cues
  for select to authenticated
  using (exists (select 1 from public.event_sessions s where s.id = session_id
                 and public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])));
create policy "show log: root, planners, marshals read" on public.show_log
  for select to authenticated
  using (exists (select 1 from public.event_sessions s where s.id = session_id
                 and public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])));
revoke all on table public.show_state, public.show_cues, public.show_log from anon, public;
grant select on table public.show_state, public.show_cues, public.show_log to authenticated;

alter table public.show_state replica identity full;
alter table public.show_cues replica identity full;
alter publication supabase_realtime add table public.show_state, public.show_cues, public.show_log;

-- ============================================================
-- 2. Helpers
-- ============================================================
-- The show clock. Tests set show.test_now (inside their own transaction) to step through time; nothing a page sends
-- can set it.
create or replace function public.show_now()
returns timestamptz
language sql volatile set search_path = ''
as $$
  select coalesce(nullif(current_setting('show.test_now', true), '')::timestamptz, clock_timestamp());
$$;

-- For the page's clock: server time, so every screen counts down to the same second
create or replace function public.server_now()
returns timestamptz
language sql volatile set search_path = ''
as $$ select clock_timestamp(); $$;

-- "18:04:12 (+1 day) on the show's day" -> the moment
create or replace function public.show_at(p_date date, p_day integer, p_time time)
returns timestamptz
language sql immutable set search_path = ''
as $$ select ((p_date + p_day) + p_time) at time zone 'Asia/Singapore'; $$;

create or replace function public.show_secs(p interval)
returns integer
language sql immutable set search_path = ''
as $$ select round(extract(epoch from p))::integer; $$;

-- The movements of a version, one row per group (categories expanded, exceptions applied), WITHOUT the role check:
-- for the engine (pg_cron runs as nobody). run_sheet_moves() below is the checked one the pages call.
create or replace function public.rs_moves(p_sheet uuid)
returns table (movement_id uuid, code text, group_id uuid, via_category text, is_exception boolean, zone_id uuid,
               deadline_kind text, cue_id uuid, fixed_time time, fixed_day_offset integer, early_s integer,
               min_ics integer, dwell_s integer, amber_s integer, travel_mode text, pace_mps numeric)
language sql stable security definer set search_path = ''
as $$
  select m.id, m.code, m.group_id, null::text, false, m.zone_id, m.deadline_kind, m.cue_id, m.fixed_time, m.fixed_day_offset,
         m.early_s, m.min_ics, m.dwell_s, m.amber_s, m.travel_mode, m.pace_mps
  from public.movements m
  where m.run_sheet_id = p_sheet and m.parent_id is null and m.group_id is not null
  union all
  select m.id, m.code, g.id, m.category, false, m.zone_id, m.deadline_kind, m.cue_id, m.fixed_time, m.fixed_day_offset,
         m.early_s, m.min_ics, m.dwell_s, m.amber_s, m.travel_mode, m.pace_mps
  from public.movements m
  join public.run_sheets r on r.id = m.run_sheet_id
  join public.groups g on g.event_id = r.event_id and lower(g.category) = lower(m.category)
  where m.run_sheet_id = p_sheet and m.parent_id is null and m.category is not null
    and not exists (select 1 from public.movements x where x.parent_id = m.id and x.group_id = g.id)
  union all
  select x.id, x.code, x.group_id, p.category, true, x.zone_id, x.deadline_kind, x.cue_id, x.fixed_time, x.fixed_day_offset,
         x.early_s, x.min_ics, x.dwell_s, x.amber_s, x.travel_mode, x.pace_mps
  from public.movements x
  join public.movements p on p.id = x.parent_id
  where x.run_sheet_id = p_sheet and x.parent_id is not null and not x.skip;
$$;

create or replace function public.run_sheet_moves(p_sheet uuid)
returns table (movement_id uuid, code text, group_id uuid, via_category text, is_exception boolean, zone_id uuid,
               deadline_kind text, cue_id uuid, fixed_time time, fixed_day_offset integer, early_s integer,
               min_ics integer, dwell_s integer, amber_s integer, travel_mode text, pace_mps numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.run_sheets r where r.id = p_sheet
                 and public.has_event_role(r.event_id, array['root', 'planner', 'marshal'])) then
    raise exception 'Only the root, planners and marshals can see the run sheet' using errcode = '42501';
  end if;
  return query select * from public.rs_moves(p_sheet);
end;
$$;

-- "Auto when ready": the groups of this cue's movements (must be there when it starts) that have NOT arrived.
-- Empty = everyone is there (or the cue has no movements).
create or replace function public.show_missing_groups(p_session uuid, p_sheet uuid, p_cue uuid, p_now timestamptz)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(g.name order by g.name), '{}')
  from public.rs_moves(p_sheet) e
  join public.groups g on g.id = e.group_id
  join public.event_sessions s on s.id = p_session
  where e.cue_id = p_cue and e.deadline_kind = 'cue_start'
    and not (
      e.zone_id is not null
      and (select count(*) from public.zone_presence zp
           join public.group_members gm on gm.user_id = zp.user_id and gm.group_id = e.group_id and gm.is_ic
           where zp.session_id = p_session and zp.zone_id = e.zone_id and zp.exited_at is null
             and zp.entered_at <= p_now - make_interval(secs => e.dwell_s))
          >= greatest(1, coalesce(e.min_ics,
               (select count(distinct l.user_id) from public.locations l
                join public.group_members gm on gm.user_id = l.user_id and gm.group_id = e.group_id and gm.is_ic
                where l.event_id = s.event_id and l.recorded_at > p_now - interval '2 minutes')))
    );
$$;

-- ============================================================
-- 3. The show of a session: made when it first runs, follows a version switch
-- ============================================================
-- Copies the state of cues that already ran into the version switched to (by cue code: a Duplicate keeps codes),
-- and skips its cues that sit before the point the show has reached.
create or replace function public.show_carry_over(p_session uuid, p_from uuid, p_to uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_reached integer;
begin
  insert into public.show_cues (session_id, cue_id)
  select p_session, c.id from public.cues c where c.run_sheet_id = p_to
  on conflict do nothing;
  if p_from is not null then
    update public.show_cues n
    set status = o.status, started_at = o.started_at, ended_at = o.ended_at, started_by = o.started_by,
        ended_by = o.ended_by, added_s = o.added_s, note = o.note, updated_at = now()
    from public.cues nc
    join public.cues oc on oc.run_sheet_id = p_from and oc.code = nc.code
    join public.show_cues o on o.session_id = p_session and o.cue_id = oc.id
    where n.session_id = p_session and n.cue_id = nc.id and nc.run_sheet_id = p_to and o.status <> 'pending';
  end if;
  select max(c.position) into v_reached
  from public.show_cues sc join public.cues c on c.id = sc.cue_id
  where sc.session_id = p_session and c.run_sheet_id = p_to and sc.status <> 'pending';
  if v_reached is not null then
    update public.show_cues sc
    set status = 'skipped', note = 'Not in the version that was running', updated_at = now()
    from public.cues c
    where c.id = sc.cue_id and sc.session_id = p_session and c.run_sheet_id = p_to
      and sc.status = 'pending' and c.position < v_reached;
  end if;
end;
$$;

-- The show of a live session (made the first time, locked FOR UPDATE: every change to a show goes through here, so
-- GO, Hold and the engine never act on the same show at once). Null when the session has no run sheet.
create or replace function public.show_open(p_session uuid)
returns public.show_state
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  st public.show_state;
  v_first public.cues;
  v_date date;
  v_p timestamptz;
  v_opened timestamptz;
begin
  select * into s from public.event_sessions where id = p_session;
  if not found or s.run_sheet_id is null then
    return null;
  end if;
  select * into st from public.show_state where session_id = p_session for update;
  if not found then
    -- The show's day: the session's day in Singapore, moved by a day if the first cue would be over 12 h away
    v_date := (s.starts_at at time zone 'Asia/Singapore')::date;
    select * into v_first from public.cues where run_sheet_id = s.run_sheet_id order by position limit 1;
    if v_first.id is not null then
      v_p := public.show_at(v_date, v_first.day_offset, v_first.start_time);
      if v_p < s.starts_at - interval '12 hours' then
        v_date := v_date + 1;
      elsif v_p > s.starts_at + interval '12 hours' then
        v_date := v_date - 1;
      end if;
    end if;
    -- A normal start counts from the session's start. A run sheet switched on during a session (from "no run
    -- sheet") counts from that switch: the record of switches says which, not how late the engine first looks (a
    -- late first look must catch up, not skip).
    v_opened := coalesce((select max(w.switched_at) from public.run_sheet_switches w
                          where w.session_id = p_session and w.from_sheet is null and w.to_sheet = s.run_sheet_id),
                         s.starts_at);
    insert into public.show_state (session_id, event_id, run_sheet_id, show_date, opened_at)
    values (p_session, s.event_id, s.run_sheet_id, v_date, v_opened)
    on conflict (session_id) do nothing;
    select * into st from public.show_state where session_id = p_session for update;
    perform public.show_carry_over(p_session, null, s.run_sheet_id);
    -- An anchor whose fixed time passed before the show opened cannot be kept: it is missed (the cues before it
    -- still run, late) rather than started late with everything before it skipped
    update public.show_cues sc
    set status = 'skipped', note = 'Missed: its fixed time ' || to_char(c.start_time, 'HH24:MI:SS') || ' passed before the show started',
        updated_at = now()
    from public.cues c
    where c.id = sc.cue_id and sc.session_id = p_session and c.run_sheet_id = s.run_sheet_id and sc.status = 'pending'
      and c.type = 'anchor' and public.show_at(v_date, c.day_offset, c.start_time) < v_opened;
    if v_opened > s.starts_at then
      update public.show_cues sc
      set status = 'skipped', note = 'Planned before the run sheet was switched on', updated_at = now()
      from public.cues c
      where c.id = sc.cue_id and sc.session_id = p_session and c.run_sheet_id = s.run_sheet_id and sc.status = 'pending'
        and public.show_at(v_date, c.day_offset, c.start_time) + make_interval(secs => c.length_s) <= v_opened;
    end if;
  elsif st.run_sheet_id is distinct from s.run_sheet_id then
    perform public.show_carry_over(p_session, st.run_sheet_id, s.run_sheet_id);
    update public.show_state
    set run_sheet_id = s.run_sheet_id, finished_at = null, rev = rev + 1, updated_at = now()
    where session_id = p_session
    returning * into st;
  end if;
  return st;
end;
$$;

-- ============================================================
-- 4. Where every cue is: planned, projected, delay (the engine and the pages use this one function)
-- ============================================================
create or replace function public.show_rows(p_session uuid, p_now timestamptz)
returns table (cue_id uuid, pos integer, code text, title text, section text, type text, start_mode text,
               length_s integer, can_shorten_s integer, area text, status text,
               planned_start timestamptz, planned_end timestamptz, due_at timestamptz, projected_start timestamptz,
               projected_end timestamptz, natural_end timestamptz, delay_s integer, absorbed_s integer, added_s integer, risk_s integer,
               started_at timestamptz, ended_at timestamptz, started_by uuid, ended_by uuid,
               wait_kind text, waiting_since timestamptz, risk_alerted boolean, note text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  st public.show_state;
  r record;
  v_t timestamptz;          -- where the previous cue ends (projected)
  v_p timestamptz;
  v_due timestamptz;        -- when a pending cue should start (may be past: it is due)
  v_ps timestamptz;
  v_pe timestamptz;
  v_nat timestamptz;
  v_abs integer;
  v_risk integer;
begin
  select * into st from public.show_state where session_id = p_session;
  if not found then
    return;
  end if;
  v_t := st.opened_at;
  for r in
    select c.id, c.position, c.code, c.title, c.section, c.type, c.start_mode, c.length_s, c.can_shorten_s, c.area,
           c.start_time, c.day_offset, sc.status, sc.started_at, sc.ended_at, sc.started_by, sc.ended_by, sc.added_s,
           sc.wait_kind, sc.waiting_since, sc.risk_alerted, sc.note
    from public.cues c
    join public.show_cues sc on sc.cue_id = c.id and sc.session_id = p_session
    where c.run_sheet_id = st.run_sheet_id
    order by c.position
  loop
    v_p := public.show_at(st.show_date, r.day_offset, r.start_time);
    v_abs := 0;
    v_risk := 0;
    v_nat := null;
    v_due := null;
    if r.status = 'skipped' then
      v_ps := null;
      v_pe := null;
    elsif r.status = 'done' then
      v_ps := r.started_at;
      v_pe := r.ended_at;
      v_t := greatest(v_t, v_pe);
    elsif r.status = 'running' then
      v_ps := r.started_at;
      if r.type = 'flexible' then
        v_abs := least(r.can_shorten_s, greatest(0, public.show_secs(v_ps - v_p)));
      end if;
      v_nat := v_ps + make_interval(secs => greatest(0, r.length_s - v_abs + r.added_s));
      v_pe := greatest(v_nat, p_now); -- overdue (held, or the engine is about to end it)
      v_t := v_pe;
    else
      if r.type = 'anchor' then
        -- keeps its time; at risk when what comes before is projected to run past it
        v_risk := greatest(0, public.show_secs(v_t - v_p));
        v_due := greatest(v_p, st.opened_at);
        v_ps := v_due;
      else
        -- not before its plan, not before the cue before it ends; overdue (waiting for GO / groups / the engine) = now
        v_due := greatest(v_p, v_t);
        v_ps := greatest(v_due, p_now);
      end if;
      if r.type = 'flexible' then
        v_abs := least(r.can_shorten_s, greatest(0, public.show_secs(v_ps - v_p)));
      end if;
      v_pe := v_ps + make_interval(secs => greatest(0, r.length_s - v_abs + r.added_s));
      v_t := v_pe;
    end if;
    cue_id := r.id; pos := r.position; code := r.code; title := r.title; section := r.section; type := r.type;
    start_mode := r.start_mode; length_s := r.length_s; can_shorten_s := r.can_shorten_s; area := r.area;
    status := r.status; planned_start := v_p; planned_end := v_p + make_interval(secs => r.length_s);
    due_at := v_due; projected_start := v_ps; projected_end := v_pe; natural_end := v_nat;
    delay_s := case when v_ps is null then null else public.show_secs(v_ps - v_p) end;
    absorbed_s := v_abs; added_s := r.added_s; risk_s := v_risk;
    started_at := r.started_at; ended_at := r.ended_at; started_by := r.started_by; ended_by := r.ended_by;
    wait_kind := r.wait_kind; waiting_since := r.waiting_since; risk_alerted := r.risk_alerted; note := r.note;
    return next;
  end loop;
end;
$$;

-- ============================================================
-- 5. The engine: one step of one show (called with the show locked)
-- ============================================================
create or replace function public.show_log_add(p_session uuid, p_cue uuid, p_kind text, p_message text, p_by uuid, p_at timestamptz)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.show_log (session_id, cue_id, kind, message, by_user, at) values (p_session, p_cue, p_kind, p_message, p_by, p_at);
$$;

create or replace function public.show_label(p_code text, p_title text)
returns text
language sql immutable set search_path = ''
as $$ select p_code || ' "' || p_title || '"'; $$;

create or replace function public.show_step(p_session uuid, p_now timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  r record;
  run record;
  anc record;
  nxt record;
  v_i integer := 0;
  t_end timestamptz;
  t_anchor timestamptz;
  v_missing text[];
  v_start timestamptz;
begin
  st := public.show_open(p_session);
  if st.session_id is null or st.run_sheet_id is null then
    return;
  end if;

  -- One event at a time, the earliest first: a cue ending, an anchor's time, the next cue starting. When the engine
  -- catches up (a tick came late) everything still happens at the moment it should have.
  loop
    v_i := v_i + 1;
    exit when v_i > 1200; -- a safety stop (500 cues, two events each)
    select * into run from public.show_rows(p_session, p_now) x where x.status = 'running' order by x.pos limit 1;
    select * into anc from public.show_rows(p_session, p_now) x where x.status = 'pending' and x.type = 'anchor' order by x.pos limit 1;
    select * into nxt from public.show_rows(p_session, p_now) x where x.status = 'pending' order by x.pos limit 1;
    t_end := case when run.cue_id is not null and st.held_since is null and run.natural_end <= p_now then run.natural_end end;
    t_anchor := case when anc.cue_id is not null and anc.due_at <= p_now then anc.due_at end;

    -- 1. The running cue ends at its length (not while held), when that comes before an anchor's time
    if t_end is not null and (t_anchor is null or t_end <= t_anchor) then
      update public.show_cues set status = 'done', ended_at = t_end, updated_at = now()
      where session_id = p_session and cue_id = run.cue_id;
      perform public.show_log_add(p_session, run.cue_id, 'auto_end', public.show_label(run.code, run.title) || ' ended.', null, t_end);
      continue;
    end if;

    -- 2. A cue due before the anchor's time starts first (it is cut by the anchor later if it runs into it)
    if run.cue_id is null and st.held_since is null and nxt.cue_id is not null and nxt.type <> 'anchor'
       and nxt.due_at <= p_now and (t_anchor is null or nxt.due_at < t_anchor) then
      if nxt.start_mode = 'manual' then
        if nxt.wait_kind is null then
          update public.show_cues set wait_kind = 'go', waiting_since = nxt.due_at, updated_at = now()
          where session_id = p_session and cue_id = nxt.cue_id;
          perform public.show_log_add(p_session, nxt.cue_id, 'waiting_go',
            public.show_label(nxt.code, nxt.title) || ' is ready and waits for GO.', null, nxt.due_at);
        end if;
      else
        v_missing := case when nxt.start_mode = 'auto_ready'
                          then public.show_missing_groups(p_session, st.run_sheet_id, nxt.cue_id, p_now) else '{}' end;
        if cardinality(v_missing) = 0 then
          -- on time: at the moment it was due; after waiting for groups: now
          v_start := case when nxt.wait_kind is null then nxt.due_at else p_now end;
          update public.show_cues set status = 'running', started_at = v_start, started_by = null, wait_kind = null,
                 waiting_since = null, updated_at = now()
          where session_id = p_session and cue_id = nxt.cue_id;
          perform public.show_log_add(p_session, nxt.cue_id, 'auto_start', public.show_label(nxt.code, nxt.title) || ' started.', null, v_start);
          continue;
        elsif nxt.wait_kind is null then
          update public.show_cues set wait_kind = 'groups', waiting_since = nxt.due_at, updated_at = now()
          where session_id = p_session and cue_id = nxt.cue_id;
          perform public.show_log_add(p_session, nxt.cue_id, 'waiting_groups',
            public.show_label(nxt.code, nxt.title) || ' is holding: waiting for ' ||
            array_to_string(v_missing[1:5], ', ') ||
            case when cardinality(v_missing) > 5 then ' and ' || (cardinality(v_missing) - 5) || ' more' else '' end ||
            '. GO starts it anyway.', null, nxt.due_at);
        end if;
      end if;
    end if;

    -- 3. An anchor's time: it starts, whatever runs is cut, cues that never got to run are skipped (also when held)
    if t_anchor is not null then
      if run.cue_id is not null then
        update public.show_cues set status = 'done', ended_at = greatest(t_anchor, run.started_at), wait_kind = null, updated_at = now()
        where session_id = p_session and cue_id = run.cue_id;
        perform public.show_log_add(p_session, run.cue_id, 'anchor_cut',
          public.show_label(run.code, run.title) || ' was cut ' || public.show_secs(run.natural_end - t_anchor) ||
          ' s short: the anchor ' || public.show_label(anc.code, anc.title) || ' started on its time.', null, t_anchor);
      end if;
      for r in
        select x.cue_id, x.code, x.title from public.show_rows(p_session, p_now) x
        where x.status = 'pending' and x.pos < anc.pos
      loop
        update public.show_cues set status = 'skipped', note = 'Skipped: the anchor ' || anc.code || ' started first',
               wait_kind = null, waiting_since = null, updated_at = now()
        where session_id = p_session and cue_id = r.cue_id;
        perform public.show_log_add(p_session, r.cue_id, 'skip', public.show_label(r.code, r.title) ||
          ' was skipped: the anchor ' || public.show_label(anc.code, anc.title) || ' started first.', null, t_anchor);
      end loop;
      update public.show_cues set status = 'running', started_at = t_anchor, started_by = null, wait_kind = null,
             waiting_since = null, updated_at = now()
      where session_id = p_session and cue_id = anc.cue_id;
      perform public.show_log_add(p_session, anc.cue_id, 'anchor_start', public.show_label(anc.code, anc.title) || ' started on its time.', null, t_anchor);
      continue;
    end if;
    exit;
  end loop;

  -- 4. Anchors at risk: told once, again only after it was fine in between
  for r in select * from public.show_rows(p_session, p_now) x where x.status = 'pending' and x.type = 'anchor' loop
    if r.risk_s > 0 and not r.risk_alerted then
      update public.show_cues set risk_alerted = true, updated_at = now() where session_id = p_session and cue_id = r.cue_id;
      perform public.show_log_add(p_session, r.cue_id, 'anchor_risk',
        'Anchor ' || public.show_label(r.code, r.title) || ' at ' || to_char(r.planned_start at time zone 'Asia/Singapore', 'HH24:MI:SS') ||
        ' is at risk: the show is projected to run ' || r.risk_s || ' s into it.', null, p_now);
    elsif r.risk_s = 0 and r.risk_alerted then
      update public.show_cues set risk_alerted = false, updated_at = now() where session_id = p_session and cue_id = r.cue_id;
    end if;
  end loop;

  -- 5. Finished
  if st.finished_at is null and not exists (
       select 1 from public.show_cues sc join public.cues c on c.id = sc.cue_id
       where sc.session_id = p_session and c.run_sheet_id = st.run_sheet_id and sc.status in ('pending', 'running')) then
    update public.show_state set finished_at = p_now, rev = rev + 1, updated_at = now() where session_id = p_session;
    perform public.show_log_add(p_session, null, 'finished', 'The run sheet has finished.', null, p_now);
  end if;
end;
$$;

-- Every live session with a run sheet, every 2 s (pg_cron). One show failing never stops the others.
create or replace function public.show_tick()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  n integer := 0;
begin
  for s in
    select es.id from public.event_sessions es
    where es.ended_at is null and es.starts_at <= now() and es.run_sheet_id is not null
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
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-show-tick';
    perform cron.schedule('gps-show-tick', '2 seconds', 'select public.show_tick()');
  end if;
end $$;

-- ============================================================
-- 6. What root and planners press
-- ============================================================
-- The live show of a session, for a button: the role, the session is live, it has a run sheet. Locked.
create or replace function public.show_for_action(p_session uuid)
returns public.show_state
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  st public.show_state;
begin
  select * into s from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist';
  end if;
  if not public.has_event_role(s.event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can run the show' using errcode = '42501';
  end if;
  if s.ended_at is not null or s.starts_at > now() then
    raise exception 'The event is not live';
  end if;
  if s.run_sheet_id is null then
    raise exception 'This session runs without a run sheet';
  end if;
  -- catch up first, so a button acts on the show as it is now
  perform public.show_step(p_session, public.show_now());
  st := public.show_open(p_session);
  return st;
end;
$$;

create or replace function public.show_who(p_user uuid)
returns text
language sql stable security definer set search_path = ''
as $$ select coalesce((select display_name from public.profiles where id = p_user), 'someone'); $$;

-- GO: start the next cue now (ending the one running). Two planners at once: the second is told who was first.
create or replace function public.show_go(p_session uuid, p_cue uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  r record;
  nxt record;
  run record;
  v_now timestamptz;
begin
  st := public.show_for_action(p_session);
  v_now := public.show_now();
  select * into r from public.show_rows(p_session, v_now) x where x.cue_id = p_cue;
  if not found then
    raise exception 'That cue is not in the version this show runs';
  end if;
  if r.status = 'running' then
    raise exception '% is already running: started at % %.', public.show_label(r.code, r.title),
      to_char(r.started_at at time zone 'Asia/Singapore', 'HH24:MI:SS'),
      case when r.started_by is null then 'by the clock' else 'by ' || public.show_who(r.started_by) end
      using errcode = 'PT409';
  elsif r.status = 'done' then
    raise exception '% has already run.', public.show_label(r.code, r.title) using errcode = 'PT409';
  elsif r.status = 'skipped' then
    raise exception '% was skipped.', public.show_label(r.code, r.title) using errcode = 'PT409';
  end if;
  if r.type = 'anchor' then
    raise exception '% is an anchor: it starts by itself at %.', public.show_label(r.code, r.title),
      to_char(r.planned_start at time zone 'Asia/Singapore', 'HH24:MI:SS');
  end if;
  select * into nxt from public.show_rows(p_session, v_now) x where x.status = 'pending' order by x.pos limit 1;
  if nxt.cue_id is distinct from p_cue then
    if nxt.type = 'anchor' then
      raise exception 'The next cue is the anchor %: it starts by itself at %.', public.show_label(nxt.code, nxt.title),
        to_char(nxt.planned_start at time zone 'Asia/Singapore', 'HH24:MI:SS');
    end if;
    raise exception 'GO starts the next cue, %. Skip the cues before % first.', public.show_label(nxt.code, nxt.title), r.code;
  end if;
  for run in select * from public.show_rows(p_session, v_now) x where x.status = 'running' loop
    update public.show_cues set status = 'done', ended_at = v_now, ended_by = auth.uid(), updated_at = now()
    where session_id = p_session and cue_id = run.cue_id;
  end loop;
  update public.show_cues set status = 'running', started_at = v_now, started_by = auth.uid(), wait_kind = null,
         waiting_since = null, updated_at = now()
  where session_id = p_session and cue_id = p_cue;
  if st.held_since is not null then
    update public.show_state set held_since = null, held_by = null, rev = rev + 1, updated_at = now() where session_id = p_session;
  end if;
  perform public.show_log_add(p_session, p_cue, 'go', public.show_who(auth.uid()) || ' pressed GO: ' || public.show_label(r.code, r.title) ||
    case when r.delay_s > 0 then ' (' || r.delay_s || ' s late)' when r.delay_s < 0 then ' (' || -r.delay_s || ' s early)' else '' end || '.',
    auth.uid(), v_now);
  perform public.show_step(p_session, v_now);
end;
$$;

create or replace function public.show_hold(p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  v_now timestamptz;
begin
  st := public.show_for_action(p_session);
  v_now := public.show_now();
  if st.held_since is not null then
    raise exception 'The show is already held (by % since %).', public.show_who(st.held_by),
      to_char(st.held_since at time zone 'Asia/Singapore', 'HH24:MI:SS') using errcode = 'PT409';
  end if;
  if st.finished_at is not null then
    raise exception 'The run sheet has finished.';
  end if;
  update public.show_state set held_since = v_now, held_by = auth.uid(), rev = rev + 1, updated_at = now() where session_id = p_session;
  perform public.show_log_add(p_session, null, 'hold', public.show_who(auth.uid()) || ' held the show: the next cue waits for Resume.', auth.uid(), v_now);
end;
$$;

create or replace function public.show_resume(p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  run record;
  v_now timestamptz;
begin
  st := public.show_for_action(p_session);
  v_now := public.show_now();
  if st.held_since is null then
    raise exception 'The show is not held.' using errcode = 'PT409';
  end if;
  -- a cue that ran past its length while held ends now
  for run in select * from public.show_rows(p_session, v_now) x where x.status = 'running' and x.natural_end < v_now loop
    update public.show_cues set status = 'done', ended_at = v_now, updated_at = now() where session_id = p_session and cue_id = run.cue_id;
  end loop;
  update public.show_state set held_since = null, held_by = null, rev = rev + 1, updated_at = now() where session_id = p_session;
  perform public.show_log_add(p_session, null, 'resume', public.show_who(auth.uid()) || ' resumed the show (held ' ||
    public.show_secs(v_now - st.held_since) || ' s).', auth.uid(), v_now);
  perform public.show_step(p_session, v_now);
end;
$$;

-- +30 s (or any -600..600 s) on the running cue: everything after it moves, anchors excepted
create or replace function public.show_add_time(p_session uuid, p_seconds integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  run record;
  v_now timestamptz;
begin
  st := public.show_for_action(p_session);
  v_now := public.show_now();
  if p_seconds is null or p_seconds = 0 or p_seconds < -600 or p_seconds > 600 then
    raise exception 'Add between -10 and +10 minutes';
  end if;
  select * into run from public.show_rows(p_session, v_now) x where x.status = 'running' order by x.pos limit 1;
  if not found then
    raise exception 'No cue is running: time is added to the cue that is running.';
  end if;
  if run.added_s + p_seconds > 3600 or run.added_s + p_seconds < -run.length_s then
    raise exception 'That is too much for one cue.';
  end if;
  if p_seconds < 0 and run.natural_end + make_interval(secs => p_seconds) < v_now then
    raise exception 'It would have ended already: press GO for the next cue instead.';
  end if;
  update public.show_cues set added_s = added_s + p_seconds, updated_at = now() where session_id = p_session and cue_id = run.cue_id;
  perform public.show_log_add(p_session, run.cue_id, 'add_time', public.show_who(auth.uid()) || ' added ' ||
    case when p_seconds > 0 then '+' else '' end || p_seconds || ' s to ' || public.show_label(run.code, run.title) || '.', auth.uid(), v_now);
  perform public.show_step(p_session, v_now);
end;
$$;

-- Skip a cue that has not run; on the running cue: end it now
create or replace function public.show_skip(p_session uuid, p_cue uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  r record;
  v_now timestamptz;
begin
  st := public.show_for_action(p_session);
  v_now := public.show_now();
  select * into r from public.show_rows(p_session, v_now) x where x.cue_id = p_cue;
  if not found then
    raise exception 'That cue is not in the version this show runs';
  end if;
  if r.status = 'running' then
    update public.show_cues set status = 'done', ended_at = v_now, ended_by = auth.uid(), updated_at = now()
    where session_id = p_session and cue_id = p_cue;
    perform public.show_log_add(p_session, p_cue, 'end_now', public.show_who(auth.uid()) || ' ended ' || public.show_label(r.code, r.title) || ' early.', auth.uid(), v_now);
  elsif r.status = 'pending' then
    update public.show_cues set status = 'skipped', note = 'Skipped by ' || public.show_who(auth.uid()), wait_kind = null,
           waiting_since = null, ended_by = auth.uid(), updated_at = now()
    where session_id = p_session and cue_id = p_cue;
    perform public.show_log_add(p_session, p_cue, 'skip', public.show_who(auth.uid()) || ' skipped ' || public.show_label(r.code, r.title) || '.', auth.uid(), v_now);
  else
    raise exception '% has already %.', public.show_label(r.code, r.title), case when r.status = 'done' then 'run' else 'been skipped' end
      using errcode = 'PT409';
  end if;
  perform public.show_step(p_session, v_now);
end;
$$;

-- ============================================================
-- 7. What the pages read
-- ============================================================
-- The whole show of a session as one answer (root, planners, marshals): state, every cue, the last log lines.
create or replace function public.show_board(p_session uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  st public.show_state;
  v_now timestamptz := public.show_now();
  v_cues jsonb;
  v_next record;
  v_anchor record;
  v_delay integer;
  v_run record;
begin
  select * into s from public.event_sessions where id = p_session;
  if not found or not public.has_event_role(s.event_id, array['root', 'planner', 'marshal']) then
    raise exception 'Only the root, planners and marshals can see the show' using errcode = '42501';
  end if;
  select * into st from public.show_state where session_id = p_session;
  if s.run_sheet_id is null or not found then
    return jsonb_build_object('server_now', v_now, 'state', case when s.run_sheet_id is null then 'none' else 'starting' end);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'cue_id', x.cue_id, 'pos', x.pos, 'code', x.code, 'title', x.title, 'section', x.section, 'type', x.type,
           'start_mode', x.start_mode, 'length_s', x.length_s, 'can_shorten_s', x.can_shorten_s, 'area', x.area,
           'status', x.status, 'planned_start', x.planned_start, 'planned_end', x.planned_end,
           'due_at', x.due_at, 'projected_start', x.projected_start, 'projected_end', x.projected_end, 'natural_end', x.natural_end,
           'delay_s', x.delay_s, 'absorbed_s', x.absorbed_s, 'added_s', x.added_s, 'risk_s', x.risk_s,
           'started_at', x.started_at, 'ended_at', x.ended_at,
           'started_by', case when x.started_by is null then null else public.show_who(x.started_by) end,
           'ended_by', case when x.ended_by is null then null else public.show_who(x.ended_by) end,
           'wait_kind', x.wait_kind, 'waiting_since', x.waiting_since, 'note', x.note,
           'missing', case when x.wait_kind = 'groups' then to_jsonb(public.show_missing_groups(p_session, st.run_sheet_id, x.cue_id, v_now)) else null end
         ) order by x.pos), '[]'::jsonb)
    into v_cues
  from public.show_rows(p_session, v_now) x;
  select * into v_run from public.show_rows(p_session, v_now) x where x.status = 'running' order by x.pos limit 1;
  select * into v_next from public.show_rows(p_session, v_now) x where x.status = 'pending' order by x.pos limit 1;
  select * into v_anchor from public.show_rows(p_session, v_now) x where x.status = 'pending' and x.type = 'anchor' order by x.pos limit 1;
  -- How far behind: the next cue's projected start against its plan (the running cue's end when it is the last)
  v_delay := coalesce(v_next.delay_s, case when v_run.cue_id is not null then public.show_secs(v_run.projected_end - v_run.planned_end) end, 0);
  return jsonb_build_object(
    'server_now', v_now,
    'state', case when st.finished_at is not null then 'finished' when st.held_since is not null then 'held'
                  when v_run.cue_id is null and v_next.cue_id is not null and v_next.projected_start > v_now and v_next.wait_kind is null
                       and not exists (select 1 from public.show_cues sc where sc.session_id = p_session and sc.status in ('done', 'running'))
                  then 'before' else 'running' end,
    'run_sheet_id', st.run_sheet_id,
    'run_sheet_name', (select name from public.run_sheets where id = st.run_sheet_id),
    'show_date', st.show_date,
    'held_since', st.held_since,
    'held_by', case when st.held_by is null then null else public.show_who(st.held_by) end,
    'finished_at', st.finished_at,
    'delay_s', v_delay,
    'anchor', case when v_anchor.cue_id is null then null else jsonb_build_object('cue_id', v_anchor.cue_id, 'code', v_anchor.code,
                   'title', v_anchor.title, 'at', v_anchor.planned_start, 'risk_s', v_anchor.risk_s) end,
    'cues', v_cues,
    'log', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'message', l.message, 'at', l.at) order by l.id desc), '[]'::jsonb)
            from (select * from public.show_log where session_id = p_session order by id desc limit 30) l)
  );
end;
$$;

-- ============================================================
-- 8. Switching the live version (024) now carries the show over at once
-- ============================================================
create or replace function public.switch_live_run_sheet(p_event uuid, p_sheet uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session public.event_sessions;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the live run sheet' using errcode = '42501';
  end if;
  perform public.rs_runnable(p_event, p_sheet);
  select * into v_session from public.event_sessions
  where event_id = p_event and ended_at is null and starts_at <= now() for update;
  if not found then
    raise exception 'The event is not live';
  end if;
  if v_session.run_sheet_id is not distinct from p_sheet then
    raise exception 'The live show is already running that version';
  end if;
  insert into public.run_sheet_switches (session_id, from_sheet, to_sheet, switched_by)
  values (v_session.id, v_session.run_sheet_id, p_sheet, auth.uid());
  update public.event_sessions set run_sheet_id = p_sheet where id = v_session.id;
  if p_sheet is not null then
    perform public.show_open(v_session.id);
    perform public.show_log_add(v_session.id, null, 'switch', public.show_who(auth.uid()) || ' switched the live show to "' ||
      (select name from public.run_sheets where id = p_sheet) || '".', auth.uid(), public.show_now());
    perform public.show_step(v_session.id, public.show_now());
  end if;
end;
$$;

-- ============================================================
-- 9. Permissions
-- ============================================================
revoke execute on function public.show_now() from public, anon, authenticated;
revoke execute on function public.show_at(date, integer, time) from public, anon, authenticated;
revoke execute on function public.show_secs(interval) from public, anon, authenticated;
revoke execute on function public.rs_moves(uuid) from public, anon, authenticated;
revoke execute on function public.show_missing_groups(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.show_carry_over(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.show_open(uuid) from public, anon, authenticated;
revoke execute on function public.show_rows(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.show_log_add(uuid, uuid, text, text, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.show_label(text, text) from public, anon, authenticated;
revoke execute on function public.show_step(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.show_tick() from public, anon, authenticated;
revoke execute on function public.show_for_action(uuid) from public, anon, authenticated;
revoke execute on function public.show_who(uuid) from public, anon, authenticated;

revoke execute on function public.server_now() from public, anon;
revoke execute on function public.run_sheet_moves(uuid) from public, anon;
revoke execute on function public.show_go(uuid, uuid) from public, anon;
revoke execute on function public.show_hold(uuid) from public, anon;
revoke execute on function public.show_resume(uuid) from public, anon;
revoke execute on function public.show_add_time(uuid, integer) from public, anon;
revoke execute on function public.show_skip(uuid, uuid) from public, anon;
revoke execute on function public.show_board(uuid) from public, anon;
revoke execute on function public.switch_live_run_sheet(uuid, uuid) from public, anon;
grant execute on function public.server_now() to authenticated;
grant execute on function public.run_sheet_moves(uuid) to authenticated;
grant execute on function public.show_go(uuid, uuid) to authenticated;
grant execute on function public.show_hold(uuid) to authenticated;
grant execute on function public.show_resume(uuid) to authenticated;
grant execute on function public.show_add_time(uuid, integer) to authenticated;
grant execute on function public.show_skip(uuid, uuid) to authenticated;
grant execute on function public.show_board(uuid) to authenticated;
grant execute on function public.switch_live_run_sheet(uuid, uuid) to authenticated;
