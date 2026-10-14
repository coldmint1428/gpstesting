-- Step 22 (merger Stage 3): the simulator - 100+ virtual groups without 100 phones.
-- Run AFTER 021_zone_presence.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- ONLY IN SIMULATION EVENTS. An event is a simulation when events.is_simulation is true; it can only be
-- made that way (create_simulation_event), never switched on for a real event, and every page of it shows
-- a SIMULATION badge. Simulated people are profiles with is_simulated = true.
--
-- HOW IT WORKS
--   sim_setup()  makes N virtual groups ("SIM-001" ...), each with 1-3 virtual ICs. Every virtual IC is a real
--                (but fake) Supabase Auth account: profiles, group membership and every reading depend on one.
--                They can never sign in (no password, no identity) and are deleted by sim_reset().
--                Each group gets a BEHAVIOUR (sim_scripts) and a walk: from a random spot 200-600 m from one of
--                the event's zones to that zone (a No-Go zone for "wrong zone"), at 1.0-1.5 m/s.
--   sim_tick()   runs every 10 s (pg_cron), only for simulations that are running while their event is live.
--                It moves every group along its walk and inserts one reading per virtual IC, with GPS noise
--                (5-15 m) and a believable accuracy -- through the SAME locations table and Stage 2 trigger as a
--                real phone, so zone presence, group positions and No-Go alerts are exercised for real.
--   sim_start / sim_pause / sim_reset   the root's controls (Simulator tab).
--
-- Behaviours (sim_scripts): on_time, late_2min (leaves 2 min late), stops_halfway, loses_signal (silent for
-- 2.5 min partway, then resumes), wrong_zone (walks into a No-Go zone and stays).

-- ============================================================
-- 1. Flags
-- ============================================================
alter table public.events add column if not exists is_simulation boolean not null default false;
alter table public.profiles add column if not exists is_simulated boolean not null default false;

-- ============================================================
-- 2. Tables
-- ============================================================
create table if not exists public.sim_scripts (
  key text primary key,
  label text not null,
  description text not null,
  sort int not null default 0
);
insert into public.sim_scripts (key, label, description, sort) values
  ('on_time', 'On time', 'Walks to its zone at a normal pace and stays inside.', 1),
  ('late_2min', '2 min late', 'Leaves two minutes after the others, then walks normally.', 2),
  ('stops_halfway', 'Stops halfway', 'Stops moving halfway and never arrives.', 3),
  ('loses_signal', 'Loses signal', 'Goes silent for 2.5 minutes partway, then reappears further along.', 4),
  ('wrong_zone', 'Wrong zone', 'Walks into a No-Go zone and stays there.', 5)
on conflict (key) do update set label = excluded.label, description = excluded.description, sort = excluded.sort;

create table if not exists public.sim_runs (
  event_id uuid primary key references public.events (id) on delete cascade,
  status text not null default 'ready' check (status in ('ready', 'running', 'paused')),
  started_at timestamptz,
  last_tick_at timestamptz,
  ticks int not null default 0,
  readings bigint not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.sim_groups (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  script text not null references public.sim_scripts (key),
  target_zone_id uuid references public.zones (id) on delete set null,
  start_lat double precision not null,
  start_lng double precision not null,
  end_lat double precision not null,
  end_lng double precision not null,
  path_m double precision not null,
  pace_mps double precision not null,
  depart_after_s int not null default 0,
  stop_at_m double precision,          -- stops_halfway: never goes further than this
  silent_from_s double precision,      -- loses_signal: no readings between these running times
  silent_to_s double precision,
  active_s double precision not null default 0,   -- seconds the simulation has been running for this group
  travelled_m double precision not null default 0
);
create index if not exists sim_groups_event on public.sim_groups (event_id);

-- The virtual ICs. Deleting a row deletes its Auth account (and with it the profile, memberships, presence).
create table if not exists public.sim_ics (
  user_id uuid primary key references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade
);
create index if not exists sim_ics_event on public.sim_ics (event_id);

create or replace function public.sim_ic_gone()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from auth.users u where u.id = old.user_id;
  return old;
end;
$$;
drop trigger if exists sim_ic_gone on public.sim_ics;
create trigger sim_ic_gone after delete on public.sim_ics for each row execute function public.sim_ic_gone();

alter table public.sim_scripts enable row level security;
alter table public.sim_runs enable row level security;
alter table public.sim_groups enable row level security;
alter table public.sim_ics enable row level security;

drop policy if exists "anyone signed in reads the presets" on public.sim_scripts;
create policy "anyone signed in reads the presets" on public.sim_scripts for select to authenticated using (true);
drop policy if exists "members see the simulation" on public.sim_runs;
create policy "members see the simulation" on public.sim_runs for select to authenticated using (public.is_event_member(event_id));
drop policy if exists "members see the simulated groups" on public.sim_groups;
create policy "members see the simulated groups" on public.sim_groups for select to authenticated using (public.is_event_member(event_id));
-- sim_ics: no policy (only the functions below touch it)

revoke all on table public.sim_scripts, public.sim_runs, public.sim_groups, public.sim_ics from anon, public;
grant select on table public.sim_scripts, public.sim_runs, public.sim_groups to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sim_runs') then
    alter publication supabase_realtime add table public.sim_runs;
  end if;
end $$;

-- ============================================================
-- 3. Making a simulation event
-- ============================================================
create or replace function public.create_simulation_event(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := public.create_event(p_name); -- the caller becomes its root, exactly like a real event
  update public.events set is_simulation = true where id = v_id;
  return v_id;
end;
$$;

-- Only the root of a SIMULATION event may run its simulator.
create or replace function public.sim_check(p_event uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.events e where e.id = p_event and e.is_simulation) then
    raise exception 'This is not a simulation event' using errcode = 'PT403';
  end if;
  if not public.has_event_role(p_event, array['root']) then
    raise exception 'Only the root of this simulation event can run the simulator' using errcode = 'PT403';
  end if;
end;
$$;

-- ============================================================
-- 4. Set up: N virtual groups with their ICs and walks
--    p_mix: percentages per behaviour, e.g. {"on_time":80,"late_2min":10,"loses_signal":5,"wrong_zone":5}
-- ============================================================
create or replace function public.sim_setup(p_event uuid, p_groups int, p_ics_min int default 2, p_ics_max int default 3, p_mix jsonb default '{"on_time":80,"late_2min":10,"stops_halfway":0,"loses_signal":5,"wrong_zone":5}')
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_short text := left(replace(p_event::text, '-', ''), 6);
  v_scripts text[] := '{}';
  v_key text;
  v_total numeric := 0;
  v_count int;
  v_i int;
  v_n int;
  v_group uuid;
  v_zone record;
  v_start extensions.geography;
  v_end extensions.geography;
  v_path double precision;
  v_pace double precision;
  v_script text;
  v_ics int;
  v_user uuid;
  v_next int;
  v_colours text[] := array['#0d6efd', '#d63384', '#198754', '#fd7e14', '#6f42c1', '#0dcaf0', '#b02a37', '#20c997', '#6610f2', '#ffc107'];
begin
  perform public.sim_check(p_event);
  if exists (select 1 from public.sim_runs r where r.event_id = p_event and r.status = 'running') then
    raise exception 'Pause the simulation before adding groups';
  end if;
  if p_groups is null or p_groups < 1 or p_groups > 150 then
    raise exception 'Between 1 and 150 groups at a time';
  end if;
  p_ics_min := greatest(1, least(coalesce(p_ics_min, 2), 3));
  p_ics_max := greatest(p_ics_min, least(coalesce(p_ics_max, 3), 3));
  if not exists (select 1 from public.zones z where z.event_id = p_event and z.kind <> 'no_go') then
    raise exception 'Draw at least one zone (not No-Go) in the Zones tab first: the virtual groups walk to the zones';
  end if;

  -- The behaviours, spread by the percentages (largest remainders last so the counts add up to N).
  for v_key in select key from public.sim_scripts order by sort loop
    v_total := v_total + greatest(coalesce((p_mix ->> v_key)::numeric, 0), 0);
  end loop;
  if v_total <= 0 then v_total := 1; p_mix := '{"on_time":1}'; end if;
  for v_key in select key from public.sim_scripts order by sort loop
    v_count := round(p_groups * greatest(coalesce((p_mix ->> v_key)::numeric, 0), 0) / v_total);
    for v_i in 1 .. v_count loop v_scripts := v_scripts || v_key; end loop;
  end loop;
  while coalesce(array_length(v_scripts, 1), 0) < p_groups loop v_scripts := v_scripts || 'on_time'::text; end loop;
  v_scripts := v_scripts[1:p_groups];

  select coalesce(max(substring(g.name from 'SIM-(\d+)')::int), 0) into v_next
  from public.groups g where g.event_id = p_event and g.name ~ '^SIM-\d+$';
  select count(*) into v_n from public.sim_ics s where s.event_id = p_event;

  for v_i in 1 .. p_groups loop
    v_script := v_scripts[v_i];

    -- Where it walks: a No-Go zone for "wrong zone" (if the event has one), otherwise any other zone.
    select z.id, extensions.st_centroid(z.shape::extensions.geometry)::extensions.geography as c into v_zone
    from public.zones z
    where z.event_id = p_event
      and (case when v_script = 'wrong_zone' and exists (select 1 from public.zones x where x.event_id = p_event and x.kind = 'no_go')
                then z.kind = 'no_go' else z.kind <> 'no_go' end)
    order by random() limit 1;

    v_end := v_zone.c;
    v_start := extensions.st_project(v_end, 200 + random() * 400, random() * 2 * pi());
    v_path := extensions.st_distance(v_start, v_end);
    v_pace := 1.0 + random() * 0.5;

    insert into public.groups (event_id, name, colour, category)
    values (p_event, 'SIM-' || lpad((v_next + v_i)::text, 3, '0'), v_colours[1 + ((v_next + v_i) % 10)], 'Simulated')
    returning id into v_group;

    insert into public.sim_groups (event_id, group_id, script, target_zone_id, start_lat, start_lng, end_lat, end_lng,
                                   path_m, pace_mps, depart_after_s, stop_at_m, silent_from_s, silent_to_s)
    values (p_event, v_group, v_script, v_zone.id,
            extensions.st_y(v_start::extensions.geometry), extensions.st_x(v_start::extensions.geometry),
            extensions.st_y(v_end::extensions.geometry), extensions.st_x(v_end::extensions.geometry),
            v_path, v_pace,
            case when v_script = 'late_2min' then 120 else 0 end,
            case when v_script = 'stops_halfway' then v_path * 0.5 end,
            case when v_script = 'loses_signal' then (v_path * 0.4) / v_pace end,
            case when v_script = 'loses_signal' then (v_path * 0.4) / v_pace + 150 end);

    v_ics := p_ics_min + floor(random() * (p_ics_max - p_ics_min + 1))::int;
    for v_count in 1 .. v_ics loop
      v_n := v_n + 1;
      v_user := gen_random_uuid();
      -- A fake Auth account: no password and no identity, so it can never sign in. handle_new_user makes
      -- its profile from the metadata.
      insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'sim-' || v_short || '-' || lpad(v_n::text, 4, '0') || '@simulation.invalid', '', now(),
              '{"provider":"simulation","providers":[]}'::jsonb,
              jsonb_build_object('username', 'sim_' || v_short || '_' || lpad(v_n::text, 4, '0'),
                                 'display_name', 'Sim IC ' || lpad(v_n::text, 4, '0')),
              now(), now());
      update public.profiles set is_simulated = true where id = v_user;
      insert into public.sim_ics (user_id, event_id, group_id) values (v_user, p_event, v_group);
      insert into public.event_roles (event_id, user_id, role) values (p_event, v_user, 'participant') on conflict do nothing;
      insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values (p_event, v_group, v_user, true, false);
    end loop;
  end loop;

  insert into public.sim_runs (event_id, status) values (p_event, 'ready')
  on conflict (event_id) do nothing;
  return p_groups;
end;
$$;

-- ============================================================
-- 5. Start, pause, reset
-- ============================================================
create or replace function public.sim_start(p_event uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.sim_check(p_event);
  if not exists (select 1 from public.sim_groups g where g.event_id = p_event) then
    raise exception 'Set up some virtual groups first';
  end if;
  -- The simulation only moves while the event is live: start it if it is not.
  if public.live_session_id(p_event) is null then
    perform public.start_event(p_event);
  end if;
  update public.sim_runs
  set status = 'running', started_at = coalesce(started_at, now()), last_tick_at = now()
  where event_id = p_event;
end;
$$;

create or replace function public.sim_pause(p_event uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.sim_check(p_event);
  update public.sim_runs set status = 'paused' where event_id = p_event;
end;
$$;

-- Everything simulated goes: readings, accounts (and with them memberships and presence), groups, the run.
create or replace function public.sim_reset(p_event uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_people int;
begin
  perform public.sim_check(p_event);
  select count(*) into v_people from public.sim_ics s where s.event_id = p_event;
  delete from public.locations l where l.event_id = p_event and l.user_id in (select s.user_id from public.sim_ics s where s.event_id = p_event);
  delete from public.sim_ics s where s.event_id = p_event; -- trigger deletes the Auth accounts
  delete from public.groups g where g.id in (select sg.group_id from public.sim_groups sg where sg.event_id = p_event);
  delete from public.sim_runs r where r.event_id = p_event;
  return v_people;
end;
$$;

-- ============================================================
-- 6. The tick (pg_cron, every 10 s)
-- ============================================================
create or replace function public.sim_tick()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_run record;
  v_dt double precision;
  v_inserted int;
  v_total int := 0;
begin
  for v_run in select r.* from public.sim_runs r where r.status = 'running' loop
    -- The event ended (End event, scheduled end): the simulation pauses with it.
    if public.live_session_id(v_run.event_id) is null then
      update public.sim_runs set status = 'paused' where event_id = v_run.event_id;
      continue;
    end if;

    v_dt := least(greatest(extract(epoch from (now() - coalesce(v_run.last_tick_at, now()))), 0), 30);

    update public.sim_groups g
    set active_s = g.active_s + v_dt,
        travelled_m = least(
          g.travelled_m + case when g.active_s + v_dt > g.depart_after_s then g.pace_mps * v_dt else 0 end,
          coalesce(g.stop_at_m, g.path_m))
    where g.event_id = v_run.event_id;

    insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
    select g.event_id, g.group_id, s.user_id,
           p.lat + n.r * cos(n.b) / 111320.0,
           p.lng + n.r * sin(n.b) / (111320.0 * cos(radians(p.lat))),
           round((5 + random() * 10)::numeric, 1)::real,
           'gps', now()
    from public.sim_groups g
    join public.sim_ics s on s.group_id = g.group_id
    cross join lateral (
      select g.start_lat + (g.end_lat - g.start_lat) * least(g.travelled_m / nullif(g.path_m, 0), 1) as lat,
             g.start_lng + (g.end_lng - g.start_lng) * least(g.travelled_m / nullif(g.path_m, 0), 1) as lng
    ) p
    cross join lateral (
      -- GPS noise: 5-15 m in a random direction (a few metres more while standing inside a zone is fine)
      select 5 + random() * 10 as r, random() * 2 * pi() as b
    ) n
    where g.event_id = v_run.event_id
      and not (g.silent_from_s is not null and g.active_s between g.silent_from_s and g.silent_to_s);
    get diagnostics v_inserted = row_count;

    update public.sim_runs
    set last_tick_at = now(), ticks = ticks + 1, readings = readings + v_inserted
    where event_id = v_run.event_id;
    v_total := v_total + v_inserted;
  end loop;
  return v_total;
end;
$$;

-- Every 10 seconds; does nothing at all when no simulation is running.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-sim-tick';
    perform cron.schedule('gps-sim-tick', '10 seconds', 'select public.sim_tick()');
  end if;
end $$;

-- ============================================================
-- 7. Permissions
-- ============================================================
revoke execute on function public.sim_ic_gone() from public, anon, authenticated;
revoke execute on function public.sim_check(uuid) from public, anon, authenticated;
revoke execute on function public.sim_tick() from public, anon, authenticated;
revoke execute on function public.create_simulation_event(text) from public, anon;
revoke execute on function public.sim_setup(uuid, int, int, int, jsonb) from public, anon;
revoke execute on function public.sim_start(uuid) from public, anon;
revoke execute on function public.sim_pause(uuid) from public, anon;
revoke execute on function public.sim_reset(uuid) from public, anon;
grant execute on function public.create_simulation_event(text) to authenticated;
grant execute on function public.sim_setup(uuid, int, int, int, jsonb) to authenticated;
grant execute on function public.sim_start(uuid) to authenticated;
grant execute on function public.sim_pause(uuid) to authenticated;
grant execute on function public.sim_reset(uuid) to authenticated;
