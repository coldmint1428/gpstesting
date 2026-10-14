-- Step 20 (merger Stage 1): a polygon bench per event, and zones the server can test positions against.
-- Run AFTER 019_bench_head.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- WHAT CHANGES
--   1. The bench belongs to an EVENT. public.layouts gets event_id: one bench per event, created the
--      first time someone opens the event's Zones tab. The bench that already exists (the one /polygon
--      has always shown) keeps event_id = null and stays as the DEMO bench, exactly as it is.
--   2. Who may do what follows the event's roles. Event bench: its members may look, its root and
--      planners may change it. Demo bench: any signed-in user, as before. (Until now ANY signed-in
--      account could edit the one bench -- review issue 16.) Every bench function takes the bench it
--      is about (p_layout); leaving it out means the demo bench, so an old page keeps working there.
--   3. public.zones: one row per AREA on an event bench, with a stable code (FORMATION_1), its kind
--      and its shape as PostGIS geography, indexed. Kept in step by triggers on layout_objects: an
--      area saved, renamed, reshaped or deleted on the bench changes its zone in the same transaction,
--      so there is no separate sync to forget. Floor plans are not zones.
--   4. Codes: every area on an event bench carries a `code` in its data. One typed by a planner is
--      kept (format A-Z 0-9 _, unique on the bench); otherwise one is made from the name once
--      (Formation 1 -> FORMATION_1, then _2, _3 ... if taken) and then kept through renames, because
--      the run sheet will refer to zones by code.
--   5. Helpers for the engines to come: zone_contains(), zone_distance_m(), event_zones().
--   6. groups get code, category, sector, headcount (edited in Stage 4).

create extension if not exists postgis with schema extensions;

-- ============================================================
-- 1. A bench per event
-- ============================================================
alter table public.layouts add column if not exists event_id uuid references public.events (id) on delete cascade;

-- A bench belongs to the event, not to whoever happened to open it first: deleting that person's
-- account must not take the event's zones with it (005 cascaded).
alter table public.layouts alter column created_by drop not null;
alter table public.layouts drop constraint if exists layouts_created_by_fkey;
alter table public.layouts
  add constraint layouts_created_by_fkey foreign key (created_by) references public.profiles (id) on delete set null;

-- One demo bench (no event) and one bench per event, instead of one bench in total.
drop index if exists public.layouts_single_row;
create unique index if not exists layouts_one_demo on public.layouts ((true)) where event_id is null;
create unique index if not exists layouts_one_per_event on public.layouts (event_id) where event_id is not null;

-- The demo bench: the one with no event.
create or replace function public.demo_layout()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select l.id from public.layouts l where l.event_id is null order by l.created_at limit 1;
$$;

-- The bench a call is about: the one named, or the demo bench when none is.
create or replace function public.bench_of(p_layout uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select coalesce(p_layout, public.demo_layout());
$$;

-- May I look at this bench? Demo: anyone signed in. Event bench: the event's members.
create or replace function public.bench_can_read(p_layout uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.layouts l
    where l.id = p_layout
      and (l.event_id is null or public.is_event_member(l.event_id))
  );
$$;

-- May I change it? Demo: anyone signed in. Event bench: the event's root and planners.
create or replace function public.bench_can_edit(p_layout uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.layouts l
    where l.id = p_layout
      and (l.event_id is null or public.has_event_role(l.event_id, array['root', 'planner']))
  );
$$;

-- ============================================================
-- 2. Reading follows the event (RLS). Writing already only happens through the functions below.
-- ============================================================
drop policy if exists "signed-in users see the bench" on public.layouts;
create policy "members see their event's bench" on public.layouts
  for select to authenticated using (public.bench_can_read(id));

drop policy if exists "planners see the bench shapes" on public.layout_objects;
create policy "members see their event's shapes" on public.layout_objects
  for select to authenticated using (public.bench_can_read(layout_id));

drop policy if exists "planners see the bench pictures" on public.layout_images;
create policy "members see their event's pictures" on public.layout_images
  for select to authenticated using (public.bench_can_read(layout_id));

drop policy if exists "planners see who is on the bench" on public.layout_presence;
create policy "members see who is on their event's bench" on public.layout_presence
  for select to authenticated using (public.bench_can_read(layout_id));
drop policy if exists "I announce myself" on public.layout_presence;
create policy "I announce myself" on public.layout_presence
  for insert to authenticated with check (user_id = auth.uid() and public.bench_can_read(layout_id));

-- ============================================================
-- 3. Zones
-- ============================================================
create table if not exists public.zones (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9_]{1,40}$'),
  name text not null check (char_length(name) between 1 and 50),
  kind text not null check (kind in ('zone', 'no_go', 'obstacle', 'stage', 'entrance')),
  shape extensions.geography(Polygon, 4326) not null,
  capacity integer check (capacity is null or capacity >= 0),
  -- The bench area this zone is a copy of (layout_objects.object_id). Null for a zone made another
  -- way later (a circle from an imported run sheet).
  source_area_id text unique,
  is_circle boolean not null default false,
  radius_m numeric check (radius_m is null or radius_m > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, code)
);
create index if not exists zones_shape_gix on public.zones using gist (shape);
create index if not exists zones_event_idx on public.zones (event_id);

alter table public.zones enable row level security;
drop policy if exists "members see their event's zones" on public.zones;
create policy "members see their event's zones" on public.zones
  for select to authenticated using (public.is_event_member(event_id));
-- No insert / update / delete policies: zones are written by the triggers below only.
revoke all on table public.zones from anon, public;
grant select on table public.zones to authenticated;

-- The live map redraws the Zones layer when a zone changes.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'zones'
     ) then
    alter publication supabase_realtime add table public.zones;
  end if;
end $$;

-- Points as the bench stores them ([[lat, lng], ...], not closed) -> a closed PostGIS polygon.
-- PostGIS points are (lng, lat): the order is swapped here and only here.
create or replace function public.points_to_polygon(p_points jsonb)
returns extensions.geography
language sql immutable set search_path = ''
as $$
  with pts as (
    select ord, extensions.st_makepoint((p ->> 1)::float8, (p ->> 0)::float8) as pt
    from jsonb_array_elements(p_points) with ordinality as e(p, ord)
  )
  select extensions.st_setsrid(
           extensions.st_makepolygon(
             extensions.st_makeline(
               array(select pt from pts order by ord) || array(select pt from pts order by ord limit 1)
             )
           ), 4326
         )::extensions.geography;
$$;

-- "Formation 1" -> "FORMATION_1": upper case, anything else -> _, at most 40 characters.
create or replace function public.code_from_name(p_name text)
returns text
language sql immutable set search_path = ''
as $$
  select coalesce(
    nullif(left(trim(both '_' from regexp_replace(upper(coalesce(p_name, '')), '[^A-Z0-9]+', '_', 'g')), 40), ''),
    'ZONE'
  );
$$;

-- BEFORE a shape is stored on an EVENT bench: every area carries a code. A valid one already in its
-- data is kept (save_object refuses a duplicate before it gets here); a missing one is made from the
-- name once, made unique with _2, _3 ..., and then kept through renames.
create or replace function public.layout_area_code()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_code text;
  v_base text;
  v_n int := 1;
begin
  if new.kind <> 'area' then return new; end if;
  select l.event_id into v_event from public.layouts l where l.id = new.layout_id;
  if v_event is null then return new; end if; -- demo bench: no zones, no codes

  v_code := upper(nullif(trim(coalesce(new.data ->> 'code', '')), ''));
  if v_code is not null and v_code ~ '^[A-Z0-9_]{1,40}$' then
    new.data := jsonb_set(new.data, '{code}', to_jsonb(v_code));
    return new;
  end if;

  -- An update that lost its code (an old page's patch never removes it, but be sure): keep the old one.
  if tg_op = 'UPDATE' and (old.data ->> 'code') ~ '^[A-Z0-9_]{1,40}$' then
    new.data := jsonb_set(new.data, '{code}', to_jsonb(old.data ->> 'code'));
    return new;
  end if;

  v_base := public.code_from_name(new.data ->> 'name');
  v_code := v_base;
  while exists (
    select 1 from public.layout_objects o
    where o.layout_id = new.layout_id and o.kind = 'area' and o.object_id <> new.object_id
      and o.data ->> 'code' = v_code
  ) loop
    v_n := v_n + 1;
    v_code := left(v_base, 40 - char_length('_' || v_n)) || '_' || v_n;
  end loop;
  new.data := jsonb_set(new.data, '{code}', to_jsonb(v_code));
  return new;
end;
$$;

drop trigger if exists layout_area_code on public.layout_objects;
create trigger layout_area_code
  before insert or update on public.layout_objects
  for each row execute function public.layout_area_code();

-- AFTER a shape is stored or deleted: its zone follows, in the same transaction.
create or replace function public.layout_area_to_zone()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  if tg_op = 'DELETE' then
    if old.kind = 'area' then
      delete from public.zones z where z.source_area_id = old.object_id;
    end if;
    return old;
  end if;

  if new.kind <> 'area' then return new; end if;
  select l.event_id into v_event from public.layouts l where l.id = new.layout_id;
  if v_event is null then return new; end if;

  insert into public.zones (event_id, code, name, kind, shape, source_area_id, updated_at)
  values (
    v_event,
    new.data ->> 'code',
    new.data ->> 'name',
    new.data ->> 'kind',
    public.points_to_polygon(new.data -> 'points'),
    new.object_id,
    now()
  )
  on conflict (source_area_id) do update
    set code = excluded.code,
        name = excluded.name,
        kind = excluded.kind,
        shape = excluded.shape,
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists layout_area_to_zone on public.layout_objects;
create trigger layout_area_to_zone
  after insert or update or delete on public.layout_objects
  for each row execute function public.layout_area_to_zone();

-- ============================================================
-- 4. The bench's functions, now about one bench (p_layout; null = the demo bench)
-- ============================================================

-- Locks: the bench is remembered on the lock, and only someone who may edit the bench gets one.
drop function if exists public.lock_object(text, uuid);
drop function if exists public.take_over_object(text, uuid);
drop function if exists public.claim_object(text, uuid, boolean);

create or replace function public.claim_object(p_object text, p_session uuid, p_force boolean, p_layout uuid default null)
returns table (granted boolean, held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_layout uuid;
  v_object text := nullif(trim(coalesce(p_object, '')), '');
  v_expires timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if v_object is null or char_length(v_object) > 200 then
    raise exception 'That is not a shape on this bench' using errcode = '22023';
  end if;
  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  v_layout := public.bench_of(p_layout);
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;
  if not public.bench_can_edit(v_layout) then
    raise exception 'Only this event''s root and planners can change its zones' using errcode = 'PT403';
  end if;

  insert into public.layout_locks (object_id, layout_id, user_id, session_id)
  values (v_object, v_layout, auth.uid(), p_session)
  on conflict (object_id) do update
    set layout_id = excluded.layout_id,
        user_id = excluded.user_id,
        session_id = excluded.session_id,
        last_seen = now(),
        expires_at = now() + interval '45 seconds'
    where layout_locks.expires_at < now()
       or layout_locks.session_id = p_session
       or (p_force and (layout_locks.user_id = auth.uid()
                        or layout_locks.last_seen < now() - interval '90 seconds'))
  returning layout_locks.expires_at into v_expires;

  if v_expires is not null then
    return query select true, null::text, false, v_expires, 0;
    return;
  end if;

  return query
    select false, p.display_name, (c.user_id = auth.uid()), c.expires_at,
           greatest(0, extract(epoch from (now() - c.last_seen))::int)
    from (select 1) as one
    left join public.layout_locks c on c.object_id = v_object
    left join public.profiles p on p.id = c.user_id;
end;
$$;

create or replace function public.lock_object(p_object text, p_session uuid, p_layout uuid default null)
returns table (granted boolean, held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int)
language sql security definer set search_path = ''
as $$
  select * from public.claim_object(p_object, p_session, false, p_layout);
$$;

create or replace function public.take_over_object(p_object text, p_session uuid, p_layout uuid default null)
returns table (granted boolean, held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int)
language sql security definer set search_path = ''
as $$
  select * from public.claim_object(p_object, p_session, true, p_layout);
$$;

-- Write one shape (017), on the bench named, with the stored row (codes included) handed back.
drop function if exists public.save_object(text, jsonb, uuid);

create or replace function public.save_object(p_kind text, p_patch jsonb, p_session uuid, p_layout uuid default null)
returns table (
  ok boolean, rev bigint, bytes bigint, data jsonb, image_id text,
  held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int, problem text
)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_layout uuid;
  v_object text;
  v_here boolean;
  v_old_kind text;
  v_old_rev bigint;
  v_old_data jsonb;
  v_old_image text;
  v_new_image text;
  v_new_image_id text;
  v_data jsonb;
  v_full jsonb;
  v_problem text;
  v_rev bigint;
  v_bytes bigint;
  v_replaced boolean := false;
  v_code text;
  v_taken text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_session is null then
    raise exception 'This page has no session, so nothing can be saved' using errcode = 'PT409';
  end if;
  if p_kind is distinct from 'area' and p_kind is distinct from 'plan' then
    raise exception 'That is not a kind of shape this bench holds' using errcode = '22023';
  end if;
  if jsonb_typeof(p_patch) is distinct from 'object' then
    raise exception 'That is not a shape' using errcode = '22023';
  end if;

  v_object := nullif(trim(coalesce(p_patch ->> 'id', '')), '');
  if v_object is null or char_length(v_object) > 200 then
    raise exception 'Every shape needs an id' using errcode = '22023';
  end if;

  v_layout := public.bench_of(p_layout);
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;
  if not public.bench_can_edit(v_layout) then
    raise exception 'Only this event''s root and planners can change its zones' using errcode = 'PT403';
  end if;

  select o.kind, o.rev, o.data, o.image_id
    into v_old_kind, v_old_rev, v_old_data, v_old_image
  from public.layout_objects o
  where o.layout_id = v_layout and o.object_id = v_object
  for update;
  v_here := found;

  -- The lock is the permission, and it has to be a lock on THIS bench.
  if not exists (
    select 1 from public.layout_locks k
    where k.object_id = v_object and k.session_id = p_session and k.layout_id = v_layout
      and k.expires_at > now()
  ) then
    return query
      select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             p.display_name, (c.user_id = auth.uid()), c.expires_at,
             greatest(0, extract(epoch from (now() - c.last_seen))::int), null::text
      from (select 1) as one
      left join public.layout_locks c on c.object_id = v_object
      left join public.profiles p on p.id = c.user_id;
    return;
  end if;

  v_data := coalesce(v_old_data, '{}'::jsonb) || (p_patch - 'id' - 'image');
  v_data := jsonb_set(v_data, '{id}', to_jsonb(v_object));

  if v_here and v_old_kind is distinct from p_kind then
    return query
      select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             null::text, false, null::timestamptz, 0,
             'That shape is on the bench as something else. Reload the page.';
    return;
  end if;

  -- A code the planner typed: the right format, and not already another area's on this bench.
  if p_kind = 'area' and jsonb_typeof(p_patch -> 'code') = 'string' then
    v_code := upper(trim(p_patch ->> 'code'));
    if v_code !~ '^[A-Z0-9_]{1,40}$' then
      return query
        select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
               null::text, false, null::timestamptz, 0,
               'A zone code is 1 to 40 capital letters, digits or _ (for example FORMATION_1).';
      return;
    end if;
    select o.data ->> 'name' into v_taken
    from public.layout_objects o
    where o.layout_id = v_layout and o.kind = 'area' and o.object_id <> v_object
      and upper(o.data ->> 'code') = v_code
    limit 1;
    if v_taken is not null then
      return query
        select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
               null::text, false, null::timestamptz, 0,
               'The code ' || v_code || ' is already used by "' || v_taken || '".';
      return;
    end if;
    v_data := jsonb_set(v_data, '{code}', to_jsonb(v_code));
  end if;

  if p_kind = 'plan' then
    if jsonb_typeof(p_patch -> 'image') = 'string' then
      v_new_image := p_patch ->> 'image';
      v_new_image_id := md5(v_new_image);
      v_replaced := v_new_image_id is distinct from v_old_image;
    else
      v_new_image_id := v_old_image;
      if v_new_image_id is not null then
        select i.data into v_new_image
        from public.layout_images i
        where i.layout_id = v_layout and i.image_id = v_new_image_id;
      end if;
    end if;
  end if;

  v_full := case when p_kind = 'plan' then v_data || jsonb_build_object('image', v_new_image) else v_data end;
  v_problem := public.shape_problem(p_kind, v_full);
  if v_problem is not null then
    return query
      select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             null::text, false, null::timestamptz, 0, v_problem;
    return;
  end if;

  begin
    if v_new_image_id is not null and v_replaced then
      insert into public.layout_images (layout_id, image_id, data)
      values (v_layout, v_new_image_id, v_new_image)
      on conflict (layout_id, image_id) do nothing;
    end if;

    update public.layouts
    set rev = public.layouts.rev + 1, updated_at = now()
    where id = v_layout
    returning rev into v_rev;

    -- RETURNING the stored data: the code trigger may have added the area's code.
    insert into public.layout_objects (layout_id, object_id, kind, data, image_id, rev, updated_at, updated_by)
    values (v_layout, v_object, p_kind, v_data, v_new_image_id, v_rev, now(), auth.uid())
    on conflict (layout_id, object_id) do update
      set kind = excluded.kind,
          data = excluded.data,
          image_id = excluded.image_id,
          rev = excluded.rev,
          updated_at = excluded.updated_at,
          updated_by = excluded.updated_by
    returning layout_objects.data into v_data;

    select public.layout_bytes(v_layout) into v_bytes;
    if v_bytes > 4194304 then
      raise exception 'That is too much for one bench (4 MB maximum)' using errcode = '54000';
    end if;
  exception when sqlstate '54000' then
    v_bytes := public.layout_bytes(v_layout);
    return query
      select false, v_old_rev, v_bytes, v_old_data, v_old_image,
             null::text, false, null::timestamptz, 0,
             'That is too much for one bench (4 MB maximum). Remove or hide a floor plan first.';
    return;
  end;

  if v_replaced and v_old_image is not null then
    delete from public.layout_images i
    where i.layout_id = v_layout and i.image_id = v_old_image
      and not exists (
        select 1 from public.layout_objects o
        where o.layout_id = i.layout_id and o.image_id = i.image_id
      );
    select public.layout_bytes(v_layout) into v_bytes;
  end if;

  update public.layout_locks
  set last_seen = now(), expires_at = now() + interval '45 seconds'
  where session_id = p_session;

  return query
    select true, v_rev, v_bytes, v_data, v_new_image_id,
           null::text, false, null::timestamptz, 0, null::text;
end;
$$;

-- Delete one shape (017), on the bench named.
drop function if exists public.delete_object(text, uuid);

create or replace function public.delete_object(p_object text, p_session uuid, p_layout uuid default null)
returns table (
  ok boolean, rev bigint, bytes bigint, data jsonb, image_id text,
  held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int, problem text
)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_layout uuid;
  v_object text;
  v_here boolean;
  v_old_data jsonb;
  v_old_image text;
  v_rev bigint;
  v_bytes bigint;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_session is null then
    raise exception 'This page has no session, so nothing can be deleted' using errcode = 'PT409';
  end if;
  v_object := nullif(trim(coalesce(p_object, '')), '');
  if v_object is null or char_length(v_object) > 200 then
    raise exception 'That is not a shape on this bench' using errcode = '22023';
  end if;

  v_layout := public.bench_of(p_layout);
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;
  if not public.bench_can_edit(v_layout) then
    raise exception 'Only this event''s root and planners can change its zones' using errcode = 'PT403';
  end if;
  select l.rev into v_rev from public.layouts l where l.id = v_layout;

  select o.data, o.image_id into v_old_data, v_old_image
  from public.layout_objects o
  where o.layout_id = v_layout and o.object_id = v_object
  for update;
  v_here := found;

  if not exists (
    select 1 from public.layout_locks k
    where k.object_id = v_object and k.session_id = p_session and k.layout_id = v_layout
      and k.expires_at > now()
  ) then
    return query
      select false, v_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             p.display_name, (c.user_id = auth.uid()), c.expires_at,
             greatest(0, extract(epoch from (now() - c.last_seen))::int), null::text
      from (select 1) as one
      left join public.layout_locks c on c.object_id = v_object
      left join public.profiles p on p.id = c.user_id;
    return;
  end if;

  delete from public.layout_locks k where k.object_id = v_object;

  if not v_here then
    return query select true, v_rev, public.layout_bytes(v_layout),
                        null::jsonb, null::text, null::text, false, null::timestamptz, 0, null::text;
    return;
  end if;

  delete from public.layout_objects o where o.layout_id = v_layout and o.object_id = v_object;

  update public.layouts
  set rev = public.layouts.rev + 1, updated_at = now()
  where id = v_layout
  returning rev into v_rev;

  delete from public.layout_images i
  where i.layout_id = v_layout
    and not exists (
      select 1 from public.layout_objects o
      where o.layout_id = i.layout_id and o.image_id = i.image_id
    );

  select public.layout_bytes(v_layout) into v_bytes;

  update public.layout_locks
  set last_seen = now(), expires_at = now() + interval '45 seconds'
  where session_id = p_session;

  return query select true, v_rev, v_bytes,
                      null::jsonb, null::text, null::text, false, null::timestamptz, 0, null::text;
end;
$$;

-- Open a bench: the demo bench (no argument) or an event's (made on first use), with whether I may edit it.
drop function if exists public.open_bench();
drop function if exists public.open_bench(uuid);

create or replace function public.open_bench(p_event uuid default null)
returns table (id uuid, rev bigint, bytes bigint, home jsonb, shapes jsonb, images jsonb, event_id uuid, can_edit boolean)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_id uuid;
  v_rev bigint;
  v_home jsonb;
  v_shapes jsonb;
  v_images jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  if p_event is null then
    insert into public.layouts (created_by) values (auth.uid()) on conflict do nothing;
    select l.id, l.rev, l.home into v_id, v_rev, v_home
    from public.layouts l where l.event_id is null order by l.created_at limit 1;
  else
    if not public.is_event_member(p_event) then
      raise exception 'Only this event''s members can see its zones' using errcode = 'PT403';
    end if;
    insert into public.layouts (created_by, event_id, name)
    values (auth.uid(), p_event, 'Zones') on conflict do nothing;
    select l.id, l.rev, l.home into v_id, v_rev, v_home
    from public.layouts l where l.event_id = p_event;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.object_id, 'kind', o.kind, 'data', o.data, 'image_id', o.image_id, 'rev', o.rev
         ) order by o.kind, o.object_id), '[]'::jsonb)
    into v_shapes
  from public.layout_objects o where o.layout_id = v_id;

  select coalesce(jsonb_object_agg(i.image_id, i.data), '{}'::jsonb)
    into v_images
  from public.layout_images i where i.layout_id = v_id;

  return query select v_id, v_rev, public.layout_bytes(v_id), v_home, v_shapes, v_images,
                      p_event, public.bench_can_edit(v_id);
end;
$$;

-- Catch-up (019), for the bench named.
drop function if exists public.bench_head();

create or replace function public.bench_head(p_layout uuid default null)
returns table (rev bigint, bytes bigint, shapes jsonb)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_id uuid;
  v_rev bigint;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_id := public.bench_of(p_layout);
  if v_id is null or not public.bench_can_read(v_id) then
    return query select 0::bigint, 0::bigint, '{}'::jsonb;
    return;
  end if;
  select l.rev into v_rev from public.layouts l where l.id = v_id;
  return query
    select v_rev, public.layout_bytes(v_id),
           coalesce((select jsonb_object_agg(o.object_id, o.rev)
                     from public.layout_objects o where o.layout_id = v_id), '{}'::jsonb);
end;
$$;

-- ============================================================
-- 5. Helpers for the engines (Stage 2 on), and the live map's Zones layer
-- ============================================================

-- Is this point inside the zone (or within buffer_m metres of it)?  Null if I may not see the zone.
create or replace function public.zone_contains(p_zone uuid, p_lat double precision, p_lng double precision, p_buffer_m double precision default 0)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select extensions.st_dwithin(z.shape, extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
                               greatest(coalesce(p_buffer_m, 0), 0))
  from public.zones z
  where z.id = p_zone and public.is_event_member(z.event_id);
$$;

-- How far the point is from the zone, in metres (0 when inside). Null if I may not see the zone.
create or replace function public.zone_distance_m(p_zone uuid, p_lat double precision, p_lng double precision)
returns double precision
language sql stable security definer set search_path = ''
as $$
  select extensions.st_distance(z.shape, extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography)
  from public.zones z
  where z.id = p_zone and public.is_event_member(z.event_id);
$$;

-- An event's zones as GeoJSON, for the live map.
create or replace function public.event_zones(p_event uuid)
returns table (id uuid, code text, name text, kind text, capacity integer, geojson jsonb)
language sql stable security definer set search_path = ''
as $$
  select z.id, z.code, z.name, z.kind, z.capacity, extensions.st_asgeojson(z.shape)::jsonb
  from public.zones z
  where z.event_id = p_event and public.is_event_member(p_event)
  order by z.kind, z.code;
$$;

-- ============================================================
-- 6. Groups get the columns the run sheet will use (edited from Stage 4)
-- ============================================================
alter table public.groups add column if not exists code text check (code is null or code ~ '^[A-Z0-9_]{1,40}$');
alter table public.groups add column if not exists category text check (category is null or char_length(category) between 1 and 50);
alter table public.groups add column if not exists sector text check (sector is null or char_length(sector) between 1 and 50);
alter table public.groups add column if not exists headcount integer check (headcount is null or headcount >= 0);
create unique index if not exists groups_event_code on public.groups (event_id, code) where code is not null;

-- ============================================================
-- 7. Permissions: internal by default, the page's doors opened one by one
-- ============================================================
revoke execute on function public.demo_layout() from public, anon, authenticated;
revoke execute on function public.bench_of(uuid) from public, anon, authenticated;
revoke execute on function public.bench_can_edit(uuid) from public, anon, authenticated;
revoke execute on function public.bench_can_read(uuid) from public, anon;
grant execute on function public.bench_can_read(uuid) to authenticated; -- used by the RLS policies above
revoke execute on function public.points_to_polygon(jsonb) from public, anon, authenticated;
revoke execute on function public.code_from_name(text) from public, anon, authenticated;
revoke execute on function public.layout_area_code() from public, anon, authenticated;
revoke execute on function public.layout_area_to_zone() from public, anon, authenticated;
revoke execute on function public.claim_object(text, uuid, boolean, uuid) from public, anon, authenticated;

revoke execute on function public.lock_object(text, uuid, uuid) from public, anon;
revoke execute on function public.take_over_object(text, uuid, uuid) from public, anon;
revoke execute on function public.save_object(text, jsonb, uuid, uuid) from public, anon;
revoke execute on function public.delete_object(text, uuid, uuid) from public, anon;
revoke execute on function public.open_bench(uuid) from public, anon;
revoke execute on function public.bench_head(uuid) from public, anon;
revoke execute on function public.zone_contains(uuid, double precision, double precision, double precision) from public, anon;
revoke execute on function public.zone_distance_m(uuid, double precision, double precision) from public, anon;
revoke execute on function public.event_zones(uuid) from public, anon;

grant execute on function public.lock_object(text, uuid, uuid) to authenticated;
grant execute on function public.take_over_object(text, uuid, uuid) to authenticated;
grant execute on function public.save_object(text, jsonb, uuid, uuid) to authenticated;
grant execute on function public.delete_object(text, uuid, uuid) to authenticated;
grant execute on function public.open_bench(uuid) to authenticated;
grant execute on function public.bench_head(uuid) to authenticated;
grant execute on function public.zone_contains(uuid, double precision, double precision, double precision) to authenticated;
grant execute on function public.zone_distance_m(uuid, double precision, double precision) to authenticated;
grant execute on function public.event_zones(uuid) to authenticated;
