-- Step 5: the planner drawing bench at /polygon.
-- Run AFTER 004_tracking_passes.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- The bench is deliberately standalone: it is NOT tied to an event, and it touches none
-- of the tables from 001-004 (it only references public.profiles, which already exists).
--
-- Design, in one paragraph:
--   There is exactly ONE bench. It lives in public.layouts as a single row whose `data`
--   column holds the whole canvas as one JSON document: the map view, the floor plans
--   (placement + the image itself, base64) and every area's polygon points. There is no
--   polygons table and no Storage bucket, because the page always loads the entire bench
--   and commits it whole -- splitting it up would only cost joins and extra policies.
--   Exactly one person may edit it at a time. That is enforced by public.layout_claims:
--   the claim returns a TOKEN, and every save must present it. A save with a stale token
--   is REFUSED rather than obeyed, so an expired claim can never overwrite anyone's work.
--
-- Everything is checked HERE as well as in the page: the shape of the JSON (by a check
-- constraint and by the save function) and who may edit (by the claim token).

-- ============================================================
-- 1. Validators. Immutable, so they can back a check constraint and be called from the
--    functions -- one source of truth for what a valid layout looks like.
--    All of these are written so that a malformed value returns false instead of raising:
--    a check constraint treats NULL as "pass", so every branch must be explicit.
-- ============================================================

-- Singapore only: the OneMap basemap covers nothing else, and the reverse-geocode Edge
-- Function enforces the same box.
create function public.point_in_sg(p_point jsonb)
returns boolean
language plpgsql immutable set search_path = ''
as $$
declare
  v_lat numeric;
  v_lng numeric;
begin
  -- Note: `-> 0` on a scalar or an object yields SQL NULL, so none of this can raise.
  -- `is distinct from` (not `<>`) so a missing element returns false, not NULL.
  if jsonb_typeof(p_point) is distinct from 'array' then return false; end if;
  if jsonb_typeof(p_point -> 0) is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_point -> 1) is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_point -> 2) is not null then return false; end if; -- exactly two members

  -- numeric, not double precision: a huge JSON number would make the cast raise.
  v_lat := (p_point ->> 0)::numeric;
  v_lng := (p_point ->> 1)::numeric;

  return v_lat between 1.1 and 1.5 and v_lng between 103.5 and 104.2;
end;
$$;

-- One area: { id, name, kind, points: [[lat,lng], ...] }
create function public.area_ok(p_area jsonb)
returns boolean
language plpgsql immutable set search_path = ''
as $$
declare
  v_points jsonb;
  v_point jsonb;
begin
  if jsonb_typeof(p_area) is distinct from 'object' then return false; end if;

  if jsonb_typeof(p_area -> 'name') is distinct from 'string' then return false; end if;
  if char_length(p_area ->> 'name') not between 1 and 50 then return false; end if;

  -- `NULL not in (...)` is NULL, not true, so the missing case needs its own test.
  if (p_area ->> 'kind') is null
     or (p_area ->> 'kind') not in ('zone', 'no_go', 'obstacle', 'stage', 'entrance') then
    return false;
  end if;

  v_points := p_area -> 'points';
  if jsonb_typeof(v_points) is distinct from 'array' then return false; end if;
  if jsonb_array_length(v_points) not between 3 and 200 then return false; end if;

  for v_point in select * from jsonb_array_elements(v_points) loop
    if not public.point_in_sg(v_point) then return false; end if;
  end loop;

  return true;
end;
$$;

-- One floor plan: placement in geographic units, plus the image as a data URL.
-- Storing centre + size + angle (rather than two corners) is what lets it rotate rigidly.
create function public.floor_plan_ok(p_plan jsonb)
returns boolean
language plpgsql immutable set search_path = ''
as $$
declare
  v_w numeric;
  v_h numeric;
  v_opacity numeric;
begin
  if jsonb_typeof(p_plan) is distinct from 'object' then return false; end if;
  if not public.point_in_sg(p_plan -> 'centre') then return false; end if;

  if jsonb_typeof(p_plan -> 'widthM') is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_plan -> 'heightM') is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_plan -> 'angleDeg') is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_plan -> 'opacity') is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_plan -> 'visible') is distinct from 'boolean' then return false; end if;
  if jsonb_typeof(p_plan -> 'image') is distinct from 'string' then return false; end if;

  v_w := (p_plan ->> 'widthM')::numeric;
  v_h := (p_plan ->> 'heightM')::numeric;
  v_opacity := (p_plan ->> 'opacity')::numeric;

  if v_w <= 0 or v_w > 20000 then return false; end if;
  if v_h <= 0 or v_h > 20000 then return false; end if;
  if v_opacity < 0 or v_opacity > 1 then return false; end if;

  if (p_plan ->> 'image') not like 'data:image/%' then return false; end if;

  return true;
end;
$$;

-- The whole canvas: { view?, floorPlans?, polygons? }. Every part is optional, so an
-- older client that only sends `polygons` is still accepted.
create function public.layout_data_ok(p_data jsonb)
returns boolean
language plpgsql immutable set search_path = ''
as $$
declare
  v_item jsonb;
begin
  if jsonb_typeof(p_data) is distinct from 'object' then return false; end if;

  -- Where the map was looking when the planner last left it.
  if p_data -> 'view' is not null then
    if jsonb_typeof(p_data -> 'view') is distinct from 'object' then return false; end if;
    if jsonb_typeof(p_data -> 'view' -> 'lat') is distinct from 'number' then return false; end if;
    if jsonb_typeof(p_data -> 'view' -> 'lng') is distinct from 'number' then return false; end if;
    if jsonb_typeof(p_data -> 'view' -> 'zoom') is distinct from 'number' then return false; end if;
    if not public.point_in_sg(
             jsonb_build_array(p_data -> 'view' -> 'lat', p_data -> 'view' -> 'lng')
           ) then
      return false;
    end if;
    if (p_data -> 'view' ->> 'zoom')::numeric not between 0 and 25 then return false; end if;
  end if;

  if p_data -> 'floorPlans' is not null then
    if jsonb_typeof(p_data -> 'floorPlans') is distinct from 'array' then return false; end if;
    if jsonb_array_length(p_data -> 'floorPlans') > 20 then return false; end if;
    for v_item in select * from jsonb_array_elements(p_data -> 'floorPlans') loop
      if not public.floor_plan_ok(v_item) then return false; end if;
    end loop;
  end if;

  if p_data -> 'polygons' is not null then
    if jsonb_typeof(p_data -> 'polygons') is distinct from 'array' then return false; end if;
    if jsonb_array_length(p_data -> 'polygons') > 500 then return false; end if;
    for v_item in select * from jsonb_array_elements(p_data -> 'polygons') loop
      if not public.area_ok(v_item) then return false; end if;
    end loop;
  end if;

  return true;
end;
$$;

-- ============================================================
-- 2. Tables
-- ============================================================

-- The bench. It never grows past one row -- see the unique index below.
create table public.layouts (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Polygon bench' check (char_length(name) between 1 and 80),
  created_by uuid not null references public.profiles (id) on delete cascade,
  -- The entire canvas. `not null default` so an INSERT that only sets created_by works.
  data jsonb not null default '{"view": null, "floorPlans": [], "polygons": []}'::jsonb
    check (public.layout_data_ok(data)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- A unique index on a constant means at most one row can ever exist, so "one bench" is
-- a rule the database holds rather than an assumption the code makes. It also makes
-- open_bench()'s INSERT ... ON CONFLICT DO NOTHING race-free.
create unique index layouts_single_row on public.layouts ((true));

-- Who is editing the bench right now. At most one row, because layout_id is the key.
create table public.layout_claims (
  layout_id uuid primary key references public.layouts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  token uuid not null default gen_random_uuid(), -- the "receipt": every save must show it
  expires_at timestamptz not null default now() + interval '5 minutes',
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 3. Row Level Security.
--    Select-only on layouts; no insert/update/delete policies, so every write has to go
--    through the functions below. layout_claims has NO policies at all: it is only ever
--    reached through a security definer function.
-- ============================================================
alter table public.layouts enable row level security;
alter table public.layout_claims enable row level security;

-- Every signed-in user can look at the bench. One bench, shared by everyone.
create policy "signed-in users see the bench" on public.layouts
  for select to authenticated using (true);

-- ============================================================
-- 4. Actions (called from the page with supabase.rpc).
--    None of these take an id: there is one bench, so the function finds it itself.
-- ============================================================

-- Open the bench: create it if it does not exist yet, and report who is editing it.
-- One call gives the page everything it needs to draw itself.
create function public.open_bench()
returns table (
  id uuid,
  data jsonb,
  updated_at timestamptz,
  held_by text,           -- display name of the other editor, or null
  claim_expires_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- Safe under concurrency: the singleton index makes the loser a no-op.
  insert into public.layouts (created_by) values (auth.uid()) on conflict do nothing;

  select l.id into v_id from public.layouts l order by l.created_at limit 1;

  return query
    select l.id,
           l.data,
           l.updated_at,
           case when c.expires_at > now() and c.user_id <> auth.uid()
                then p.display_name end,
           case when c.expires_at > now() then c.expires_at end
    from public.layouts l
    left join public.layout_claims c on c.layout_id = l.id
    left join public.profiles p on p.id = c.user_id
    where l.id = v_id;
end;
$$;

-- Ask to edit. One atomic statement decides the winner, so two browsers claiming in the
-- same millisecond cannot both succeed: Postgres serialises the conflict on layout_id.
create function public.claim_bench()
returns table (granted boolean, token uuid, held_by text, expires_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare
  v_layout uuid;
  v_token uuid;
  v_expires timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select l.id into v_layout from public.layouts l order by l.created_at limit 1;
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;

  insert into public.layout_claims (layout_id, user_id, token, expires_at, updated_at)
  values (v_layout, auth.uid(), gen_random_uuid(), now() + interval '5 minutes', now())
  on conflict (layout_id) do update
    set user_id = excluded.user_id,
        -- Renewing my own claim keeps my token; taking over someone else's mints a new
        -- one, which is what makes the previous holder's token worthless.
        token = case when layout_claims.user_id = excluded.user_id
                     then layout_claims.token
                     else excluded.token end,
        expires_at = excluded.expires_at,
        updated_at = now()
    -- The WHERE decides whether the conflict is resolved at all: a live claim held by
    -- somebody else matches no row, so nothing is returned and nothing is changed.
    where layout_claims.expires_at < now() or layout_claims.user_id = auth.uid()
  returning layout_claims.token, layout_claims.expires_at into v_token, v_expires;

  if v_token is not null then
    return query select true, v_token, null::text, v_expires;
    return;
  end if;

  -- Refused: somebody else is working. Tell the page who.
  return query
    select false, null::uuid, p.display_name, c.expires_at
    from public.layout_claims c
    join public.profiles p on p.id = c.user_id
    where c.layout_id = v_layout;
end;
$$;

-- I am done: let go of my own claim. Silence would also release it after 5 minutes.
create function public.release_bench(p_token uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  delete from public.layout_claims
  where user_id = auth.uid() and token = p_token;
end;
$$;

-- Save the canvas. The token is the whole point: a stale one is refused, never obeyed.
create function public.save_bench(p_token uuid, p_data jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_layout uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- My claim, with MY token, and still alive.
  select c.layout_id into v_layout
  from public.layout_claims c
  where c.user_id = auth.uid()
    and c.token = p_token
    and c.expires_at > now();

  if v_layout is null then
    -- PT409 -> HTTP 409, so the page can tell "you lost the claim" apart from any other
    -- error and go read-only instead of retrying.
    raise exception 'Your editing claim expired, or someone else took it over'
      using errcode = 'PT409';
  end if;

  -- Size cap lives here rather than in the check constraint: pg_column_size/octet_length
  -- are not immutable, so they cannot back a constraint.
  -- 54000 = program_limit_exceeded, so the page can tell "too big" apart from "invalid".
  if octet_length(p_data::text) > 4194304 then
    raise exception 'That layout is too large (4 MB maximum)' using errcode = '54000';
  end if;

  if not public.layout_data_ok(p_data) then
    raise exception 'The layout data is not valid' using errcode = '22023';
  end if;

  update public.layouts
  set data = p_data, updated_at = now()
  where id = v_layout;

  -- A save is also a sign of life, so it doubles as a heartbeat.
  update public.layout_claims
  set expires_at = now() + interval '5 minutes', updated_at = now()
  where layout_id = v_layout and token = p_token;
end;
$$;

-- ============================================================
-- 5. Permissions (same pattern as 002 section 6)
-- ============================================================
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- Internal only: the validators are reached through the check constraint and the
-- functions above, never from the app.
revoke execute on function public.point_in_sg(jsonb) from authenticated;
revoke execute on function public.area_ok(jsonb) from authenticated;
revoke execute on function public.floor_plan_ok(jsonb) from authenticated;
revoke execute on function public.layout_data_ok(jsonb) from authenticated;
