-- Step 21 (merger Stage 2): who is inside which zone, one position per group, and No-Go alerts.
-- Run AFTER 020_event_zones.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- Every new location reading (phone upload or web sharer) now also updates, on the server, in the same
-- transaction:
--   * zone_presence   - which zones the IC is inside during the live session, and since when. Entering
--                       opens a row at the time of the first reading inside; leaving needs TWO readings in a
--                       row outside (GPS jitter at an edge must not flicker people in and out), and the row is
--                       closed at the time of the first of them. "Inside" allows for GPS accuracy at the
--                       edge: up to 15 m (min(accuracy, 15)).
--   * group_positions - one row per group per session: accuracy-weighted midpoint of the group's ICs (the
--                       same rule the live map uses: readings older than 2 min or worse than 100 m ignored),
--                       their average speed over the last ~60 s, and how many ICs are sharing.
--   * zone_alerts     - entering a No-Go zone raises ONE alert per entry (not one per reading), seen by the
--                       event's root / planners / marshals and by the IC who entered.
--
-- Two rules keep this safe:
--   1. A reading is ALWAYS stored, whatever happens here: the trigger catches its own errors (a warning in the
--      log), because losing an IC's location is worse than missing a presence update.
--   2. A late reading (queued during a dead zone and uploaded afterwards) never moves presence backwards: only
--      a person's newest reading updates presence and the group position.
--
-- Realtime: the three tables are published. zone_presence changes only on enter / blip / exit (the open row
-- is not touched on every reading), so it stays quiet; group_positions changes on every reading of the group.

-- ============================================================
-- 1. Tables
-- ============================================================
create table if not exists public.zone_presence (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  zone_id uuid not null references public.zones (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  group_id uuid references public.groups (id) on delete set null,
  entered_at timestamptz not null,
  last_inside_at timestamptz not null,
  outside_count int not null default 0,      -- readings in a row outside since the last one inside
  first_outside_at timestamptz,              -- the first of them (becomes exited_at)
  exited_at timestamptz                      -- null while inside
);
-- At most one OPEN stay per person per zone per session.
create unique index if not exists zone_presence_one_open
  on public.zone_presence (session_id, user_id, zone_id) where exited_at is null;
create index if not exists zone_presence_event_open on public.zone_presence (event_id) where exited_at is null;
create index if not exists zone_presence_zone on public.zone_presence (zone_id, entered_at);

create table if not exists public.group_positions (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  lat double precision,
  lng double precision,
  accuracy real,              -- the best accuracy among the ICs used
  speed_mps real,             -- average over the ICs that moved in the last ~60 s
  last_seen timestamptz,      -- newest reading of the group
  ics_sharing int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (session_id, group_id)
);
create index if not exists group_positions_event on public.group_positions (event_id);

create table if not exists public.zone_alerts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  zone_id uuid not null references public.zones (id) on delete cascade,
  presence_id uuid references public.zone_presence (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  group_id uuid references public.groups (id) on delete set null,
  kind text not null check (kind in ('no_go_entered')),
  at timestamptz not null,
  ack_by uuid references public.profiles (id) on delete set null,
  ack_at timestamptz
);
create unique index if not exists zone_alerts_one_per_entry on public.zone_alerts (presence_id) where presence_id is not null;
create index if not exists zone_alerts_event on public.zone_alerts (event_id, at desc);

-- ============================================================
-- 2. Who may read them (same rule as locations: ops roles see everything, others their own group)
-- ============================================================
alter table public.zone_presence enable row level security;
alter table public.group_positions enable row level security;
alter table public.zone_alerts enable row level security;

drop policy if exists "see presence by role" on public.zone_presence;
create policy "see presence by role" on public.zone_presence
  for select to authenticated using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal']) or group_id = public.my_group_id(event_id)
  );

drop policy if exists "see group positions by role" on public.group_positions;
create policy "see group positions by role" on public.group_positions
  for select to authenticated using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal']) or group_id = public.my_group_id(event_id)
  );

drop policy if exists "ops and the IC see alerts" on public.zone_alerts;
create policy "ops and the IC see alerts" on public.zone_alerts
  for select to authenticated using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal']) or user_id = auth.uid()
  );

revoke all on table public.zone_presence from anon, public;
revoke all on table public.group_positions from anon, public;
revoke all on table public.zone_alerts from anon, public;
grant select on table public.zone_presence to authenticated;
grant select on table public.group_positions to authenticated;
grant select on table public.zone_alerts to authenticated;

do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then return; end if;
  foreach t in array array['zone_presence', 'group_positions', 'zone_alerts'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ============================================================
-- 3. One group's position, from its ICs' newest readings
-- ============================================================
create or replace function public.refresh_group_position(p_session uuid, p_event uuid, p_group uuid, p_at timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_group is null then return; end if;

  with latest as (
    select distinct on (l.user_id) l.user_id, l.lat, l.lng, l.accuracy, l.source, l.recorded_at
    from public.locations l
    where l.event_id = p_event and l.group_id = p_group
      and l.recorded_at > p_at - interval '2 minutes'
    order by l.user_id, l.recorded_at desc
  ),
  sharing as (
    select * from latest where source <> 'stop'
  ),
  usable as (
    select *, 1.0 / (accuracy * accuracy) as w from sharing where accuracy > 0 and accuracy <= 100
  ),
  speeds as (
    -- each sharing IC: distance from its reading ~60 s earlier (30-90 s back) to now, per second
    select extensions.st_distance(
             extensions.st_setsrid(extensions.st_makepoint(s.lng, s.lat), 4326)::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(e.lng, e.lat), 4326)::extensions.geography
           ) / greatest(extract(epoch from (s.recorded_at - e.recorded_at)), 1) as mps
    from sharing s
    cross join lateral (
      select l.lat, l.lng, l.recorded_at
      from public.locations l
      where l.event_id = p_event and l.user_id = s.user_id and l.source <> 'stop'
        and l.recorded_at between s.recorded_at - interval '90 seconds' and s.recorded_at - interval '30 seconds'
      order by l.recorded_at desc
      limit 1
    ) e
  )
  insert into public.group_positions (session_id, group_id, event_id, lat, lng, accuracy, speed_mps, last_seen, ics_sharing, updated_at)
  select p_session, p_group, p_event,
         (select sum(lat * w) / nullif(sum(w), 0) from usable),
         (select sum(lng * w) / nullif(sum(w), 0) from usable),
         (select min(accuracy) from usable),
         (select avg(mps) from speeds),
         (select max(recorded_at) from latest),
         (select count(*) from sharing),
         now()
  on conflict (session_id, group_id) do update
    set lat = excluded.lat, lng = excluded.lng, accuracy = excluded.accuracy, speed_mps = excluded.speed_mps,
        last_seen = excluded.last_seen, ics_sharing = excluded.ics_sharing, updated_at = now();
end;
$$;

-- ============================================================
-- 4. The trigger on every new reading
-- ============================================================
create or replace function public.locations_zone_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_point extensions.geography;
  v_buffer double precision;
  v_inside uuid[];
  v_zone record;
  v_presence uuid;
begin
  begin
    -- The session this reading belongs to (a queued reading uploaded late still has its own time).
    select s.id into v_session
    from public.event_sessions s
    where s.event_id = new.event_id and s.starts_at <= new.recorded_at
      and (s.ended_at is null or s.ended_at >= new.recorded_at)
    order by s.starts_at desc
    limit 1;
    if v_session is null then return null; end if;

    -- A newer reading of this person is already in: this one is late and must not move anything back.
    if exists (
      select 1 from public.locations l
      where l.event_id = new.event_id and l.user_id = new.user_id and l.recorded_at > new.recorded_at
    ) then
      return null;
    end if;

    -- Stopped sharing: every open stay ends here.
    if new.source = 'stop' then
      update public.zone_presence p
      set exited_at = coalesce(p.first_outside_at, new.recorded_at)
      where p.session_id = v_session and p.user_id = new.user_id and p.exited_at is null;
      perform public.refresh_group_position(v_session, new.event_id, new.group_id, new.recorded_at);
      return null;
    end if;

    v_point := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;
    v_buffer := least(greatest(coalesce(new.accuracy, 0), 0), 15);

    select coalesce(array_agg(z.id), '{}') into v_inside
    from public.zones z
    where z.event_id = new.event_id and extensions.st_dwithin(z.shape, v_point, v_buffer);

    -- Inside: keep the open stay (resetting a blip outside), or open one -- and a No-Go entry is an alert.
    for v_zone in select z.id, z.kind from public.zones z where z.id = any (v_inside) loop
      select p.id into v_presence
      from public.zone_presence p
      where p.session_id = v_session and p.user_id = new.user_id and p.zone_id = v_zone.id and p.exited_at is null;

      if v_presence is not null then
        update public.zone_presence p
        set outside_count = 0, first_outside_at = null, last_inside_at = new.recorded_at
        where p.id = v_presence and p.outside_count > 0;
      else
        insert into public.zone_presence (event_id, session_id, zone_id, user_id, group_id, entered_at, last_inside_at)
        values (new.event_id, v_session, v_zone.id, new.user_id, new.group_id, new.recorded_at, new.recorded_at)
        on conflict do nothing
        returning id into v_presence;

        if v_presence is not null and v_zone.kind = 'no_go' then
          insert into public.zone_alerts (event_id, session_id, zone_id, presence_id, user_id, group_id, kind, at)
          values (new.event_id, v_session, v_zone.id, v_presence, new.user_id, new.group_id, 'no_go_entered', new.recorded_at)
          on conflict do nothing;
        end if;
      end if;
    end loop;

    -- Outside every other zone this person was in: one reading outside is a blip, two in a row is leaving.
    update public.zone_presence p
    set outside_count = p.outside_count + 1,
        first_outside_at = coalesce(p.first_outside_at, new.recorded_at),
        exited_at = case when p.outside_count + 1 >= 2 then coalesce(p.first_outside_at, new.recorded_at) end
    where p.session_id = v_session and p.user_id = new.user_id and p.exited_at is null
      and not (p.zone_id = any (v_inside));

    perform public.refresh_group_position(v_session, new.event_id, new.group_id, new.recorded_at);
  exception when others then
    -- Never lose a reading over this: say so in the database log and carry on.
    raise warning 'locations_zone_update skipped for reading at % (user %): %', new.recorded_at, new.user_id, sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists locations_zone_update on public.locations;
create trigger locations_zone_update
  after insert on public.locations
  for each row execute function public.locations_zone_update();

-- ============================================================
-- 5. Acknowledge an alert (root / planners / marshals)
-- ============================================================
create or replace function public.ack_zone_alert(p_alert uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select a.event_id into v_event from public.zone_alerts a where a.id = p_alert;
  if v_event is null or not public.has_event_role(v_event, array['root', 'planner', 'marshal']) then
    raise exception 'Only this event''s root, planners and marshals can acknowledge alerts' using errcode = 'PT403';
  end if;
  update public.zone_alerts set ack_by = auth.uid(), ack_at = now() where id = p_alert and ack_at is null;
end;
$$;

-- ============================================================
-- 6. Permissions
-- ============================================================
revoke execute on function public.refresh_group_position(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.locations_zone_update() from public, anon, authenticated;
revoke execute on function public.ack_zone_alert(uuid) from public, anon;
grant execute on function public.ack_zone_alert(uuid) to authenticated;
