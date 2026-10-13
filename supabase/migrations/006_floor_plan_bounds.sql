-- Step 6: a floor plan has to fit inside Singapore, not just start there.
--
-- Run AFTER 005_layouts.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- The problem this closes:
--   public.floor_plan_ok() checked only the plan's CENTRE with point_in_sg(), and checked its
--   size separately against a 20 km sanity limit. Nothing joined the two, so a plan centred
--   just inside the box could extend kilometres outside it. point_in_sg() is what makes
--   "Singapore only" a real rule -- the OneMap basemap covers nothing else, the
--   reverse-geocode Edge Function enforces the same box, and every area point is checked
--   against it. A picture hanging outside means floor area where the map cannot name a place
--   and where a drawn area would be refused: the picture and the drawable surface disagree.
--
-- The rule now, and it is deliberately the simple one: ALL FOUR CORNERS must be inside the
-- box. A picture that is only partly on the map is not a picture of anything.
--
-- The corners are computed with the SAME trigonometry as cornersOf() in
-- src/utils/floorPlan.js -- rotate the plan's own frame into metres east/north, then convert
-- metres back to lat/lng. If one side changes, the other has to change with it.
--
-- ---------------------------------------------------------------------------
-- READ THIS BEFORE RUNNING THE MIGRATION
--
-- The CHECK constraint on public.layouts.data re-validates the WHOLE row on every write, so
-- this rule is retroactive: if the one saved bench already holds a plan that sticks outside
-- the box, then AFTER this migration every save is refused until that plan is removed -- and
-- removing it is itself a save, so the editor would be stuck.
--
-- Step 0 below is the audit for that, and it is the one part of this file you run ON YOUR OWN
-- and READ, before running anything else. If it returns no rows, apply the whole file. If it
-- returns a row, open the bench and either delete that floor plan or move it inwards first.
--
-- Step 4 also validates the existing row, so a bad bench stops the migration with nothing
-- half-applied -- step 0 exists so you find out before that, with the plan's name in hand.
-- ============================================================================


-- ============================================================================
-- 0. PRE-FLIGHT AUDIT -- run this block on its own and read the result.
--    Everything after it is the migration itself.
--
--    Lists every floor plan in the saved bench with a corner outside the box that
--    point_in_sg() enforces. No rows = safe to apply. Any rows = fix those plans first;
--    the names tell you which ones to open in the bench.
-- ============================================================================
--
-- with corner as (
--   select l.id,
--          p.plan ->> 'name' as plan_name,
--          (p.plan -> 'centre' ->> 0)::numeric as centre_lat,
--          (p.plan -> 'centre' ->> 1)::numeric as centre_lng,
--          (p.plan ->> 'widthM')::numeric as width_m,
--          (p.plan ->> 'heightM')::numeric as height_m,
--          coalesce((p.plan ->> 'angleDeg')::numeric, 0) as angle_deg
--   from public.layouts l
--   cross join lateral jsonb_array_elements(l.data -> 'floorPlans') as p(plan)
-- ),
-- corner_check as (
--   select plan_name,
--          centre_lat,
--          centre_lng,
--          width_m,
--          height_m,
--          -- Rotate each corner's offsets into east/north metres, then back to degrees.
--          -- Same trigonometry as floor_plan_in_sg() below and cornersOf() in floorPlan.js.
--          centre_lat + (
--            (-(s.sx * width_m  / 2) * sin(radians(angle_deg))
--             + (s.sy * height_m / 2) * cos(radians(angle_deg))) / 111320
--          ) as corner_lat,
--          centre_lng + (
--            ((s.sx * width_m  / 2) * cos(radians(angle_deg))
--             + (s.sy * height_m / 2) * sin(radians(angle_deg)))
--            / (111320 * cos(radians(centre_lat)))
--          ) as corner_lng
--   from corner
--   cross join (values (1, -1), (1, 1), (-1, 1), (-1, -1)) as s(sx, sy)
-- )
-- select plan_name,
--        round(width_m)  as width_m,
--        round(height_m) as height_m,
--        round(corner_lat::numeric, 5) as corner_lat,
--        round(corner_lng::numeric, 5) as corner_lng
-- from corner_check
-- where corner_lat not between 1.1 and 1.5
--    or corner_lng not between 103.5 and 104.2
-- order by plan_name;
-- ============================================================================


-- ============================================================================
-- 1. geometry helper.
--
--    ONE function, not two. An earlier version split the corner maths out into a
--    floor_plan_corners() helper, which failed at run time with
--    "42501: permission denied for function floor_plan_corners": the migration revokes
--    EXECUTE on the internals (that is what keeps them out of reach of the app), but these
--    functions are SECURITY INVOKER -- the default, and what lets latest_locations() honour
--    the caller's RLS -- so a revoked inner function cannot be called from one either.
--    Keeping the maths inside floor_plan_in_sg() removes the problem instead of granting a
--    privilege that was deliberately withheld.
--
--    Immutable, so it can back a check constraint.
-- ============================================================================
--
-- Are all four corners inside the box point_in_sg() enforces?
-- Null-safe on purpose: null/NaN input gives false or null, never an exception, because a
-- check constraint treats null as "pass" and a raise here would break every save.
create or replace function public.floor_plan_in_sg(
  p_centre jsonb,
  p_width_m numeric,
  p_height_m numeric,
  p_angle_deg numeric
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_corner jsonb;
  v_lat numeric;
  v_lng numeric;
  v_cos numeric;
begin
  if p_width_m is null or p_height_m is null or p_angle_deg is null then return null; end if;
  if p_width_m <= 0 or p_height_m <= 0 then return false; end if;

  -- Numeric, not double precision: a huge JSON number would make the cast raise.
  if jsonb_typeof(p_centre) is distinct from 'array' then return false; end if;
  if jsonb_typeof(p_centre -> 0) is distinct from 'number' then return false; end if;
  if jsonb_typeof(p_centre -> 1) is distinct from 'number' then return false; end if;

  -- Longitude shrinks by cos(latitude), and the plan's centre is the reference latitude --
  -- the same reference cornersOf() uses in src/utils/floorPlan.js. Over a venue the two
  -- differ by well under a metre, and agreeing with the picture the planner sees matters
  -- more than the last decimal place.
  v_cos := cos(radians((p_centre ->> 0)::numeric));

  -- The four corners, rotated about the centre: the sign pairs are the plan's own frame
  -- mapped through the same rotation as cornersOf(). Order does not matter -- every corner
  -- has to be inside -- which is why this needs no set-returning helper.
  for v_corner in
    select jsonb_build_array(
             (p_centre ->> 0)::numeric
               + (-(s.sx * p_width_m / 2) * sin(radians(p_angle_deg))
                  + (s.sy * p_height_m / 2) * cos(radians(p_angle_deg))) / 111320,
             (p_centre ->> 1)::numeric
               + ((s.sx * p_width_m / 2) * cos(radians(p_angle_deg))
                  + (s.sy * p_height_m / 2) * sin(radians(p_angle_deg))) / (111320 * v_cos)
           )
    from (values (1, -1), (1, 1), (-1, 1), (-1, -1)) as s(sx, sy)
  loop
    if not public.point_in_sg(v_corner) then return false; end if;
  end loop;

  -- Belt and braces: the corners above are computed from the centre, so a centre that is
  -- itself nonsense (outside the box, or non-finite) could still produce four corners that
  -- happen to look plausible.
  v_lat := (p_centre ->> 0)::numeric;
  v_lng := (p_centre ->> 1)::numeric;
  return v_lat between 1.1 and 1.5 and v_lng between 103.5 and 104.2;
end;
$$;


-- ============================================================================
-- 2. Replace floor_plan_ok().
--
--    It keeps its name and its boolean return, but must be dropped rather than replaced:
--    the CHECK constraint on public.layouts.data and public.layout_data_ok() both call it,
--    and Postgres cannot CREATE OR REPLACE a function that other objects depend on.
--
--    The constraint is dropped first and put back at the end with the SAME definition (data
--    still not null, still layout_data_ok(data)), so nothing about the table changes -- the
--    row and the column default are untouched.
-- ============================================================================
do $$
declare
  v_constraint text;
begin
  if to_regclass('public.layouts') is null then
    raise exception 'Run 005_layouts.sql before this migration';
  end if;

  -- Drop the constraint by whatever name 005's inline check was given, so the cascade below
  -- cannot take the constraint definition with it silently.
  for v_constraint in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public.layouts'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%layout_data_ok%'
  loop
    execute format('alter table public.layouts drop constraint %I', v_constraint);
  end loop;
end $$;

-- CASCADE takes public.layout_data_ok() with it: it calls floor_plan_ok(), and the constraint
-- that was just dropped was its only other caller. Step 4 below rebuilds both.
drop function if exists public.floor_plan_ok(jsonb) cascade;

-- The centre still has to be somewhere real; the corners are the new part.
create function public.floor_plan_ok(p_plan jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_w numeric;
  v_h numeric;
  v_angle numeric;
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
  v_angle := (p_plan ->> 'angleDeg')::numeric;
  v_opacity := (p_plan ->> 'opacity')::numeric;

  if v_w <= 0 or v_w > 20000 then return false; end if;
  if v_h <= 0 or v_h > 20000 then return false; end if;
  if v_opacity < 0 or v_opacity > 1 then return false; end if;

  -- NEW: the picture itself has to fit on the map, not just its centre point.
  if not public.floor_plan_in_sg(p_plan -> 'centre', v_w, v_h, v_angle) then return false; end if;

  if (p_plan ->> 'image') not like 'data:image/%' then return false; end if;

  return true;
end;
$$;


-- ============================================================================
-- 3. Public helper: WHY was a layout refused?
--
--    The check constraint and save_bench() can only answer true/false, which reaches the
--    planner as "The layout data is not valid" -- no help at all when the real problem is one
--    floor plan that sticks 40 m outside the edge. This returns a sentence instead, so the
--    page can say something the planner can act on.
-- ============================================================================
create or replace function public.layout_problem(p_data jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_plan jsonb;
  v_view jsonb;
  v_index int := 0;
begin
  if jsonb_typeof(p_data) is distinct from 'object' then
    return 'The saved canvas is not an object.';
  end if;

  -- view: the map centre has to be somewhere on the basemap (size is handled by Leaflet).
  v_view := p_data -> 'view';
  if v_view is not null and jsonb_typeof(v_view) = 'object' then
    if jsonb_typeof(v_view -> 'lat') is distinct from 'number'
       or jsonb_typeof(v_view -> 'lng') is distinct from 'number'
       or jsonb_typeof(v_view -> 'zoom') is distinct from 'number' then
      return 'The saved map view is incomplete.';
    end if;
    if not public.point_in_sg(jsonb_build_array(v_view -> 'lat', v_view -> 'lng')) then
      return 'The saved map view is outside Singapore.';
    end if;
  end if;

  if p_data -> 'floorPlans' is not null and jsonb_typeof(p_data -> 'floorPlans') = 'array' then
    for v_plan in select * from jsonb_array_elements(p_data -> 'floorPlans') loop
      v_index := v_index + 1;
      if not public.floor_plan_ok(v_plan) then
        -- Name it when it has one: "Floor plan 2" is far less useful than "Level 1".
        return coalesce(
          nullif(v_plan ->> 'name', ''),
          'Floor plan ' || v_index
        ) || ': this floor plan hangs outside the Singapore map, so its parts would sit where'
          || ' place names and drawn areas are not allowed. Move it inwards or make it smaller.';
      end if;
    end loop;
  end if;

  return null;
end;
$$;


-- ============================================================================
-- 4. Put the table's constraint back, exactly as 005 had it, and re-check the row.
--    This is where a bad existing bench is caught: if the one saved row breaks the new rule,
--    the whole migration fails here and NOTHING is left half-applied.
-- ============================================================================
alter table public.layouts
  add constraint layouts_data_ok_check check (public.layout_data_ok(data));

alter table public.layouts validate constraint layouts_data_ok_check;


-- ============================================================================
-- 5. Permissions -- same pattern as 002 and 005.
--    Drop and grant by explicit signature: the functions this migration replaced no longer
--    exist, so a blanket "all functions in schema public" would also hand the geometry
--    helpers to the app.
-- ============================================================================
revoke execute on function public.floor_plan_in_sg(jsonb, numeric, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.floor_plan_ok(jsonb) from public, anon, authenticated;
revoke execute on function public.layout_problem(jsonb) from public, anon;

grant execute on function public.floor_plan_ok(jsonb) to authenticated;
grant execute on function public.layout_problem(jsonb) to authenticated;

-- If an earlier version of this migration created the separate corner helper, drop it: it is
-- unreachable by design (EXECUTE was revoked) and nothing calls it any more.
drop function if exists public.floor_plan_corners(jsonb, numeric, numeric, numeric);
