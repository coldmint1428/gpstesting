-- Step 9: one row per shape, and the picture beside it.
-- Run AFTER 008_object_locks.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- RE-RUNNABLE, deliberately, the same rule as 007 and 008: every statement is `if not exists`,
-- `if exists` or `create or replace`, and the split of the old document is written so that applying
-- this file a second time can neither duplicate nor overwrite anything. Nothing here deletes data.
--
-- WHAT THIS REPLACES, AND WHY. 005 put the whole canvas in ONE jsonb column and 008 made saving it a
-- merge. The merge is what made a lock worth anything, and it worked -- but every change saved
-- EVERYTHING, and the bench has outgrown that. Measured on the real bench (tools/bench_harness.mjs,
-- round 3): 3.7 MB of a 4 MB cap, and a save of one moved dot took 19 to 34 SECONDS, because it
-- uploaded the whole canvas -- every floor plan picture in it, base64 -- to change one number. Two
-- other faults follow from the same shape, and neither can be fixed from inside it: the merge has to
-- GUESS what a planner meant (an object missing from their copy counts as a deletion only if they
-- hold its lock), and a shape somebody else creates or deletes cannot appear on your screen until
-- your next save, because a whole-document save has nothing to say about one shape.
--
-- SO THE CANVAS BECOMES ROWS:
--
--   public.layout_objects   one row per area and per floor plan: the shape's data, its own
--                           REVISION, and a reference to its picture.
--   public.layout_images    one row per PICTURE, keyed by the md5 of the image itself, so the same
--                           picture pasted twice is stored once and a plan that is only being moved
--                           uploads nothing at all.
--
-- AND THE SAVE BECOMES A PATCH. save_object() takes the fields a planner actually changed and lays
-- them over the STORED row, so a planner whose copy is behind -- a hidden tab, a screen that missed
-- an event -- cannot silently undo somebody else's rename: their patch is merged onto what the bench
-- has, the merged row comes back, and that is what their screen takes. The lock is still the
-- permission, exactly as 008 left it (save_object() writes nothing for a shape the caller does not
-- hold), and the merge that used to be the safety net is now simply the way every write happens.
--
-- THE OLD COLUMN IS KEPT, FROZEN. public.layouts.data still holds the canvas as it was the moment
-- this migration ran. Nothing reads it and nothing writes it any more; it is left exactly as it is
-- so that a mistake in the split below is recoverable by hand. The 4 MB cap is now measured over the
-- rows (layout_bytes() below), and `rev` on the same table is the bench's own revision counter: it
-- moves on every write, which is how a page that has been away asks "has anything changed?" with one
-- small query instead of downloading the whole canvas.
--
-- A PAGE THAT WAS ALREADY OPEN will still be running the old code. It cannot be allowed to write
-- (there is no document to write), so save_bench() is left in place as a door that refuses them in
-- words -- see section 6 -- rather than being dropped, which would answer a stale tab with "function
-- public.save_bench does not exist" and no way to understand it.

-- ============================================================
-- 0. What is already there.
-- ============================================================
do $$
begin
  if to_regclass('public.layouts') is null or to_regclass('public.layout_locks') is null then
    raise exception 'Run 005_layouts.sql and 008_object_locks.sql before this migration';
  end if;
end $$;

-- ============================================================
-- 1. A floor plan's PLACEMENT, checked without its picture.
--
--    006's floor_plan_ok() asks for the image as well, because the whole document carries it. A row
--    in layout_objects does NOT: the picture lives in layout_images and the row only points at it,
--    so the rule that a row has to satisfy is the placement, and the picture is checked separately
--    (by the foreign key's existence and by save_object() before it stores one).
--
--    Both are `create or replace` on existing signatures, so nothing that already calls
--    floor_plan_ok() -- the check constraint on public.layouts, and layout_problem() -- is disturbed.
-- ============================================================
create or replace function public.floor_plan_fields_ok(p_plan jsonb)
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

  v_w := (p_plan ->> 'widthM')::numeric;
  v_h := (p_plan ->> 'heightM')::numeric;
  v_angle := (p_plan ->> 'angleDeg')::numeric;
  v_opacity := (p_plan ->> 'opacity')::numeric;

  if v_w <= 0 or v_w > 20000 then return false; end if;
  if v_h <= 0 or v_h > 20000 then return false; end if;
  if v_opacity < 0 or v_opacity > 1 then return false; end if;

  -- The picture itself has to fit on the map, not just its centre point (006).
  return public.floor_plan_in_sg(p_plan -> 'centre', v_w, v_h, v_angle);
end;
$$;

-- floor_plan_ok() is now exactly "and it has a picture", which is what the whole-document path needs.
create or replace function public.floor_plan_ok(p_plan jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_plan -> 'image') = 'string'
     and (p_plan ->> 'image') like 'data:image/%'
     and public.floor_plan_fields_ok(p_plan);
$$;

-- ============================================================
-- 2. The two tables.
-- ============================================================

-- A picture, once. The key is the md5 of the data URL itself, and that is the whole deduplication
-- story: two floor plans made from the same file (a copy, a paste, a planner who uploads the same
-- level twice) share one row, and the bench's size counts the picture once. md5 is not a signature
-- and does not need to be: the worst a collision can do here is make two plans share a picture, and
-- the row can only be written by save_object() from an image it has already validated.
create table if not exists public.layout_images (
  layout_id uuid not null references public.layouts (id) on delete cascade,
  image_id text not null,
  data text not null,
  -- Who put it there, for the same reason the rest of the schema keeps that: it is knowable, so it
  -- is recorded. ON DELETE SET NULL rather than CASCADE -- a picture belongs to the bench, not to
  -- the planner who happened to upload it, and 005's cascade on layouts.created_by already means a
  -- deleted account takes the whole bench away.
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (layout_id, image_id),
  constraint layout_images_id_md5 check (image_id ~ '^[0-9a-f]{32}$'),
  constraint layout_images_is_a_data_url check (data like 'data:image/%')
);

-- A shape. `data` is the object EXACTLY as the canvas holds it -- id, name, kind, points / centre,
-- angle, size, opacity, visible -- but with no `image` member: the picture is the row in
-- layout_images that `image_id` points at, and the check below is what keeps it that way.
create table if not exists public.layout_objects (
  layout_id uuid not null references public.layouts (id) on delete cascade,
  object_id text not null,
  kind text not null,
  data jsonb not null,
  image_id text,
  -- The bench revision this row was last written at (see `rev` on public.layouts below). It is what
  -- a page orders what it has heard against -- "is this event newer than what I am showing?" -- and
  -- it is the reason a page can be told what changed without being sent everything.
  rev bigint not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references public.profiles (id) on delete set null,
  primary key (layout_id, object_id),
  constraint layout_objects_kind check (kind in ('plan', 'area')),
  constraint layout_objects_id_len check (char_length(object_id) between 1 and 200),
  -- A floor plan has a picture and an area does not, in both directions. Written as an equality of
  -- two booleans so that neither half can be forgotten.
  constraint layout_objects_image_matches_kind check ((kind = 'plan') = (image_id is not null)),
  constraint layout_objects_no_image_member check (not jsonb_exists(data, 'image')),
  -- The row carries the shape's id, because the canvas needs it and a patch could not otherwise be
  -- matched to anything.
  constraint layout_objects_data_has_id check (data ->> 'id' = object_id),
  -- The rules, held by the database rather than only by save_object(): a row that is on the bench is
  -- a row a planner could have drawn. save_object() checks the same things FIRST and refuses with a
  -- sentence (see shape_problem), so this is the backstop that a bug cannot get past.
  constraint layout_objects_area_ok check (kind <> 'area' or public.area_ok(data)),
  constraint layout_objects_plan_ok check (kind <> 'plan' or public.floor_plan_fields_ok(data)),
  -- The picture has to exist, and a picture in use cannot be swept away underneath the row.
  constraint layout_objects_image_fk foreign key (layout_id, image_id)
    references public.layout_images (layout_id, image_id)
);

-- ============================================================
-- 3. The bench's revision, and the bench's size.
-- ============================================================

-- One counter for the whole bench, moved by every write and stamped on the row it wrote. Two writers
-- cannot be given the same number (the update takes the row's lock), so it is a total order over
-- everything that has ever happened to the canvas -- and a page that has been away can compare its
-- own last number with this one and know in one small query whether it missed anything at all.
alter table public.layouts add column if not exists rev bigint not null default 0;

-- How big the bench is, in the same bytes the 4 MB cap was always counted in: the JSON text of every
-- shape, plus every picture (the image data URL is a string in the canvas exactly once per picture,
-- which is what makes the number recognisable against the old whole-document one).
--
-- A scan of a few hundred small rows and a handful of pictures, on a write, instead of a whole-column
-- write of 3.7 MB -- and it cannot drift, because it is derived rather than maintained.
create or replace function public.layout_bytes(p_layout uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
           select sum(octet_length(o.data::text))
           from public.layout_objects o
           where o.layout_id = p_layout
         ), 0)
       + coalesce((
           select sum(octet_length(i.data))
           from public.layout_images i
           where i.layout_id = p_layout
         ), 0);
$$;

-- ============================================================
-- 4. THE SPLIT. The one row in public.layouts becomes a row per shape, and every picture becomes a
--    row of its own -- the same picture once, so a bench that used one level twice gets smaller.
--
--    Written so that a second run of this file does nothing at all: every insert is
--    `on conflict do nothing`, keyed by (layout_id, object_id) or (layout_id, image_id), and the
--    revision is only set for a bench that has never been written to.
-- ============================================================
do $$
declare
  v_layout uuid;
  v_bad int;
  v_plans int := 0;
  v_areas int := 0;
  v_images int := 0;
begin
  select l.id into v_layout from public.layouts l order by l.created_at limit 1;

  -- No bench yet: there is nothing to split, and open_bench() makes the first one on demand.
  if v_layout is null then return; end if;

  -- TWO THINGS WOULD BE LOST BY A SPLIT, and both of them stop this migration here rather than
  -- leaving a shape behind on the frozen copy only:
  --
  --   * a shape with no id (or a blank one) cannot be given a row, and a shape with a duplicate id
  --     would silently share one;
  --   * a floor plan with no picture cannot be given an image row.
  --
  -- Neither is possible through save_bench(), which requires an id on everything it stores and a
  -- data URL on every plan -- so this is a guard against a hand-edited row, not a rule anybody has
  -- to meet. The counts are checked before anything is inserted.
  select count(*) into v_bad
  from public.layouts l,
       lateral jsonb_array_elements(
         public.layout_list(l.data, 'floorPlans') || public.layout_list(l.data, 'polygons')
       ) s
  where l.id = v_layout
    and (jsonb_typeof(s -> 'id') is distinct from 'string' or s ->> 'id' = '');

  if v_bad > 0 then
    raise exception 'Step 9 cannot split this bench: % shape(s) have no id', v_bad;
  end if;

  select count(*) into v_bad
  from (
    select s ->> 'id' as id
    from public.layouts l,
         lateral jsonb_array_elements(
           public.layout_list(l.data, 'floorPlans') || public.layout_list(l.data, 'polygons')
         ) s
    where l.id = v_layout
    group by 1
    having count(*) > 1
  ) d;

  if v_bad > 0 then
    raise exception 'Step 9 cannot split this bench: % shape id(s) are used more than once', v_bad;
  end if;

  select count(*) into v_bad
  from public.layouts l,
       lateral jsonb_array_elements(public.layout_list(l.data, 'floorPlans')) p
  where l.id = v_layout
    and jsonb_typeof(p -> 'image') is distinct from 'string';

  if v_bad > 0 then
    raise exception 'Step 9 cannot split this bench: % floor plan(s) have no picture', v_bad;
  end if;

  -- The pictures, one row per distinct image.
  insert into public.layout_images (layout_id, image_id, data)
  select v_layout, md5(p ->> 'image'), p ->> 'image'
  from public.layouts l,
       lateral jsonb_array_elements(public.layout_list(l.data, 'floorPlans')) p
  where l.id = v_layout
  on conflict (layout_id, image_id) do nothing;

  -- The floor plans. `- 'image'` is the split itself: the placement stays in the row and the picture
  -- moves to the row it now points at.
  insert into public.layout_objects (layout_id, object_id, kind, data, image_id, rev)
  select v_layout, p ->> 'id', 'plan', (p - 'image'), md5(p ->> 'image'), 1
  from public.layouts l,
       lateral jsonb_array_elements(public.layout_list(l.data, 'floorPlans')) p
  where l.id = v_layout
  on conflict (layout_id, object_id) do nothing;

  -- The areas, which have no picture.
  insert into public.layout_objects (layout_id, object_id, kind, data, image_id, rev)
  select v_layout, a ->> 'id', 'area', a, null, 1
  from public.layouts l,
       lateral jsonb_array_elements(public.layout_list(l.data, 'polygons')) a
  where l.id = v_layout
  on conflict (layout_id, object_id) do nothing;

  -- Revision 1 is "everything the split wrote". Only a bench that has never been written to gets it:
  -- a second run of this file (or a run after planners have worked) must not wind the counter back,
  -- because every open page compares its own number with this one.
  update public.layouts set rev = 1 where id = v_layout and rev = 0;

  select count(*) into v_plans from public.layout_objects o where o.layout_id = v_layout and o.kind = 'plan';
  select count(*) into v_areas from public.layout_objects o where o.layout_id = v_layout and o.kind = 'area';
  select count(*) into v_images from public.layout_images i where i.layout_id = v_layout;

  raise notice 'Step 9 split the bench: % floor plan(s), % area(s), % picture(s), % bytes',
    v_plans, v_areas, v_images, public.layout_bytes(v_layout);
end $$;

-- ============================================================
-- 5. Row Level Security, Realtime, and who may read.
--
--    READ-ONLY TO EVERY PLANNER, like public.layouts: there are no insert, update or delete policies
--    here at all, so every write has to go through the functions in section 6 -- which is where the
--    lock is asked for. A page reads these tables for two things: the canvas it draws (open_bench),
--    and a picture it has been told about but does not have yet (a shape somebody else just made).
-- ============================================================
alter table public.layout_objects enable row level security;
alter table public.layout_images enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'layout_objects'
      and policyname = 'planners see the bench shapes'
  ) then
    create policy "planners see the bench shapes" on public.layout_objects
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'layout_images'
      and policyname = 'planners see the bench pictures'
  ) then
    create policy "planners see the bench pictures" on public.layout_images
      for select to authenticated using (true);
  end if;
end $$;

-- Only the shapes are published, never the pictures. Two reasons, and the second is the one that
-- matters: an event on this table is how a shape somebody else creates, moves or deletes arrives on your
-- screen without a save of your own (which the old whole-document bench could not do at all); and
-- publishing layout_images would put a 512 KB picture into every event that touched it.
--
-- REPLICA IDENTITY FULL, so that a deletion's notification carries the row that was deleted and not just
-- its key. A row here is a few hundred bytes -- the picture is somewhere else, which is the whole point
-- of the split -- so what this costs in the write-ahead log is nothing, and what it buys is a DELETE a
-- page can act on: which shape it was, and an old row for the RLS check to be made against.
alter table public.layout_objects replica identity full;

-- The subscription filters on layout_id, which is part of the primary key and therefore always present
-- in a deletion's payload -- a filter on any other column would silently drop every deletion.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'layout_objects'
     ) then
    alter publication supabase_realtime add table public.layout_objects;
  end if;
end $$;

revoke all on table public.layout_objects from anon, public;
revoke all on table public.layout_images from anon, public;
grant select on table public.layout_objects to authenticated;
grant select on table public.layout_images to authenticated;

-- ============================================================
-- 6. Writing and reading, one shape at a time.
-- ============================================================

-- Why a shape was refused, in a sentence a planner can act on, or NULL when there is nothing wrong
-- with it. This is 006's layout_problem() for ONE shape, and it exists because a per-shape write can
-- say which shape and what about it -- which the whole-document save never could: it could only
-- answer "The layout data is not valid" about a canvas with twenty things on it.
--
-- `p_shape` must have its `image` in it for a floor plan: the caller (save_object) reassembles it
-- from layout_images before asking, so this is always asked about a shape as the CANVAS has it.
create or replace function public.shape_problem(p_kind text, p_shape jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_points jsonb;
  v_point jsonb;
  v_name text;
  v_w numeric;
  v_h numeric;
  v_angle numeric;
  v_opacity numeric;
begin
  if jsonb_typeof(p_shape) is distinct from 'object' then
    return 'That is not a shape this bench can draw.';
  end if;

  if p_kind = 'area' then
    if jsonb_typeof(p_shape -> 'name') is distinct from 'string' then
      return 'Give the area a name.';
    end if;
    if char_length(p_shape ->> 'name') not between 1 and 50 then
      return 'An area name has to be between 1 and 50 characters.';
    end if;
    if (p_shape ->> 'kind') is null
       or (p_shape ->> 'kind') not in ('zone', 'no_go', 'obstacle', 'stage', 'entrance') then
      return 'That is not a kind of area this bench draws.';
    end if;

    v_points := p_shape -> 'points';
    if jsonb_typeof(v_points) is distinct from 'array' then
      return 'An area is a ring of points.';
    end if;
    if jsonb_array_length(v_points) not between 3 and 200 then
      return 'An area needs between 3 and 200 points (this one has '
        || jsonb_array_length(v_points) || ').';
    end if;

    for v_point in select * from jsonb_array_elements(v_points) loop
      if not public.point_in_sg(v_point) then
        return 'Every point of an area has to be inside Singapore.';
      end if;
    end loop;

    -- The rules above name everything area_ok() refuses, and this is the backstop that keeps the two
    -- from drifting apart: whatever a check constraint on the row would refuse is refused here too,
    -- with a sentence instead of a constraint violation.
    if not public.area_ok(p_shape) then
      return 'That area is not something this bench can store.';
    end if;
    return null;
  end if;

  if p_kind = 'plan' then
    if jsonb_typeof(p_shape -> 'image') is distinct from 'string'
       or (p_shape ->> 'image') not like 'data:image/%' then
      return 'A floor plan needs a picture.';
    end if;

    if jsonb_typeof(p_shape -> 'centre') is distinct from 'array' then
      return 'A floor plan needs a centre inside Singapore.';
    end if;
    if jsonb_typeof(p_shape -> 'widthM') is distinct from 'number'
       or jsonb_typeof(p_shape -> 'heightM') is distinct from 'number'
       or jsonb_typeof(p_shape -> 'angleDeg') is distinct from 'number'
       or jsonb_typeof(p_shape -> 'opacity') is distinct from 'number'
       or jsonb_typeof(p_shape -> 'visible') is distinct from 'boolean' then
      return 'That floor plan is incomplete: it needs a size, an angle, an opacity and a visibility.';
    end if;

    if not public.point_in_sg(p_shape -> 'centre') then
      return 'A floor plan has to be somewhere in Singapore.';
    end if;

    v_w := (p_shape ->> 'widthM')::numeric;
    v_h := (p_shape ->> 'heightM')::numeric;
    v_angle := (p_shape ->> 'angleDeg')::numeric;
    v_opacity := (p_shape ->> 'opacity')::numeric;

    if v_w <= 0 or v_w > 20000 or v_h <= 0 or v_h > 20000 then
      return 'A floor plan has to be between 0 and 20 km across.';
    end if;
    if v_opacity < 0 or v_opacity > 1 then
      return 'The opacity of a floor plan has to be between 0 and 1.';
    end if;

    if not public.floor_plan_in_sg(p_shape -> 'centre', v_w, v_h, v_angle) then
      -- Named when it has a name: "Floor plan 2" is far less useful than "Level 1".
      v_name := coalesce(nullif(p_shape ->> 'name', ''), 'This floor plan');
      return v_name || ': this floor plan hangs outside the Singapore map, so its parts would sit'
        || ' where place names and drawn areas are not allowed. Move it inwards or make it smaller.';
    end if;

    if not public.floor_plan_fields_ok(p_shape) then
      return 'That floor plan is not something this bench can store.';
    end if;
    return null;
  end if;

  return 'That is not a kind of shape this bench holds.';
end;
$$;

-- Write ONE shape. The planner sends the fields they changed; this lays them over what the bench has
-- and stores the result.
--
-- The reply is the same shape whether the write happened or was refused, which is what makes the
-- page's handling of it one thing rather than two: `ok` says whether the bench now holds what was
-- sent, `data` and `image_id` are what the bench DOES hold (so a refused page can put its own copy
-- back the way the bench sees it -- the snap-back), and `problem` is the sentence when the shape
-- itself was the reason.
create or replace function public.save_object(p_kind text, p_patch jsonb, p_session uuid)
returns table (
  ok boolean,
  rev bigint,
  bytes bigint,
  data jsonb,
  image_id text,
  held_by text,
  mine_elsewhere boolean,
  expires_at timestamptz,
  idle_seconds int,
  problem text
)
language plpgsql
security definer
set search_path = ''
as $$
-- The OUT parameters below are named after the columns the caller reads (`rev`, `bytes`, `data`), and
-- plpgsql refuses to guess between a variable and a column of the same name: without this, `RETURNING
-- rev` and `SET rev = ...` are errors rather than the column they obviously mean. Columns win here;
-- every local variable in these functions is `v_`-prefixed, so nothing else is affected.
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
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- A page with no session can hold nothing and therefore write nothing. This is the one hard
  -- refusal left (the same one 008 has), and it is an error rather than a refusal row because it
  -- means the page cannot work at all: there is nothing about a shape to say.
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

  select l.id into v_layout from public.layouts l order by l.created_at limit 1;
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;

  -- The stored row, locked for the length of this call: two writers of the same shape serialise here
  -- even before the lock below is consulted.
  select o.kind, o.rev, o.data, o.image_id
    into v_old_kind, v_old_rev, v_old_data, v_old_image
  from public.layout_objects o
  where o.layout_id = v_layout and o.object_id = v_object
  for update;

  v_here := found;

  -- THE LOCK IS THE PERMISSION, and this is the only place it is asked about a write. A page that
  -- holds nothing writes nothing, whatever it sends -- which is what makes everything else here safe
  -- to believe, and what makes a stale tab harmless. The refusal names the holder, exactly as
  -- claim_object() does, so the page has one sentence to show whichever way the refusal arrived.
  if not exists (
    select 1 from public.layout_locks k
    where k.object_id = v_object and k.session_id = p_session and k.expires_at > now()
  ) then
    return query
      select false,
             v_old_rev,
             public.layout_bytes(v_layout),
             v_old_data,
             v_old_image,
             p.display_name,
             (c.user_id = auth.uid()),
             c.expires_at,
             greatest(0, extract(epoch from (now() - c.last_seen))::int),
             null::text
      from (select 1) as one
      left join public.layout_locks c on c.object_id = v_object
      left join public.profiles p on p.id = c.user_id;
    return;
  end if;

  -- THE PATCH, LAID OVER WHAT THE BENCH HAS. A planner's copy can be behind -- a hidden tab, a screen
  -- that missed an event -- and this is what makes that harmless: what they changed is theirs, and
  -- every field they did not touch is the bench's. A shape being created is the same statement with
  -- nothing underneath it. The id is not negotiable: it is the row's name.
  v_data := coalesce(v_old_data, '{}'::jsonb) || (p_patch - 'id' - 'image');
  v_data := jsonb_set(v_data, '{id}', to_jsonb(v_object));

  -- A shape's kind is its row's business, never the caller's: an area does not become a floor plan,
  -- and a plan does not become an area. (Only reachable from a bug or an old page -- the page's mode
  -- string carries the kind it took the lock with -- so it is a refusal with a sentence.)
  if v_here and v_old_kind is distinct from p_kind then
    return query
      select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             null::text, false, null::timestamptz, 0,
             'That shape is on the bench as something else. Reload the page.';
    return;
  end if;

  -- THE PICTURE. Sent only when it is new or being replaced; when it is not sent the stored one is
  -- kept and the row's reference to it does not move, which is what makes moving a floor plan a
  -- write of a few hundred bytes instead of an upload of its picture.
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

  -- Checked before anything is written, so a refusal costs nothing and the bench is untouched. The
  -- shape is checked as the CANVAS holds it, which means with its picture in it.
  v_full := case when p_kind = 'plan'
                 then v_data || jsonb_build_object('image', v_new_image)
                 else v_data end;
  v_problem := public.shape_problem(p_kind, v_full);

  if v_problem is not null then
    return query
      select false, v_old_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             null::text, false, null::timestamptz, 0, v_problem;
    return;
  end if;

  -- The write itself, and the cap, in one block that can be undone: the size of the bench is only
  -- known AFTER the row is there (every other row is already stored), so the honest check is to
  -- write it, measure, and put it back if the answer is no. The 54000 raised below is caught by this
  -- block's own handler, which rolls the block back to where it started and answers with a sentence
  -- rather than a failure -- a planner who pasted one picture too many should be told why.
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

    insert into public.layout_objects (layout_id, object_id, kind, data, image_id, rev, updated_at, updated_by)
    values (v_layout, v_object, p_kind, v_data, v_new_image_id, v_rev, now(), auth.uid())
    on conflict (layout_id, object_id) do update
      set kind = excluded.kind,
          data = excluded.data,
          image_id = excluded.image_id,
          rev = excluded.rev,
          updated_at = excluded.updated_at,
          updated_by = excluded.updated_by;

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

  -- A picture this write replaced is dead weight unless another shape still points at it, and the
  -- bench's size is what the planner watches: leaving it behind would mean deleting a floor plan no
  -- longer made room for anything.
  if v_replaced and v_old_image is not null then
    delete from public.layout_images i
    where i.layout_id = v_layout and i.image_id = v_old_image
      and not exists (
        select 1 from public.layout_objects o
        where o.layout_id = i.layout_id and o.image_id = i.image_id
      );
    select public.layout_bytes(v_layout) into v_bytes;
  end if;

  -- A save is also a sign of life for everything this session is holding, the way it was for the
  -- claim in 005 and for the whole-document save in 008.
  update public.layout_locks
  set last_seen = now(), expires_at = now() + interval '45 seconds'
  where session_id = p_session;

  return query
    select true, v_rev, v_bytes, v_data, v_new_image_id,
           null::text, false, null::timestamptz, 0, null::text;
end;
$$;

-- Delete ONE shape, and let go of it. Only the holder may: the same rule the merge used to apply to
-- "an object missing from the caller's copy", now stated once instead of being inferred.
--
-- The reply is save_object()'s reply, column for column, so the page's handling of a refusal is one
-- thing rather than two -- and `data`/`image_id` are what the bench still holds, which is what a
-- refused deletion puts back on the planner's screen.
create or replace function public.delete_object(p_object text, p_session uuid)
returns table (
  ok boolean,
  rev bigint,
  bytes bigint,
  data jsonb,
  image_id text,
  held_by text,
  mine_elsewhere boolean,
  expires_at timestamptz,
  idle_seconds int,
  problem text
)
language plpgsql
security definer
set search_path = ''
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

  select l.id, l.rev into v_layout, v_rev from public.layouts l order by l.created_at limit 1;
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;

  select o.data, o.image_id into v_old_data, v_old_image
  from public.layout_objects o
  where o.layout_id = v_layout and o.object_id = v_object
  for update;

  v_here := found;

  if not exists (
    select 1 from public.layout_locks k
    where k.object_id = v_object and k.session_id = p_session and k.expires_at > now()
  ) then
    return query
      select false, v_rev, public.layout_bytes(v_layout), v_old_data, v_old_image,
             p.display_name,
             (c.user_id = auth.uid()),
             c.expires_at,
             greatest(0, extract(epoch from (now() - c.last_seen))::int),
             null::text
      from (select 1) as one
      left join public.layout_locks c on c.object_id = v_object
      left join public.profiles p on p.id = c.user_id;
    return;
  end if;

  -- The lock goes with the shape: there is nothing left to hold, and leaving the row behind would
  -- answer the next planner who wants that id with "somebody has it" for no reason at all. It goes in
  -- BOTH cases below -- including the one where the shape turned out to be gone already -- because the
  -- caller is the one holding it (checked above) and there is nothing here for them to hold.
  delete from public.layout_locks k where k.object_id = v_object;

  -- Already gone. The deletion is already true, and saying so is more useful than an error: a page
  -- that asked is about to take it off its own screen either way.
  if not v_here then
    return query select true, v_rev, public.layout_bytes(v_layout),
                        null::jsonb, null::text, null::text, false, null::timestamptz, 0, null::text;
    return;
  end if;

  delete from public.layout_objects o
  where o.layout_id = v_layout and o.object_id = v_object;

  update public.layouts
  set rev = public.layouts.rev + 1, updated_at = now()
  where id = v_layout
  returning rev into v_rev;

  -- A picture whose last shape has just gone is dead weight in the bench's size.
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

-- Open the bench: create it if it does not exist, and hand back EVERYTHING at once -- every shape,
-- every picture, and the bench's revision. One call, so the page has the whole canvas in the same
-- shape it will keep it in, and nothing has to be stitched together from two reads that could
-- disagree.
--
-- The shape of the reply changes, so this is dropped and rebuilt rather than replaced (create or
-- replace cannot change a return type).
drop function if exists public.open_bench();

create or replace function public.open_bench()
returns table (
  id uuid,
  rev bigint,
  bytes bigint,
  home jsonb,     -- the bench's HOME view: where a planner who has never panned opens the map
  shapes jsonb,   -- [{ id, kind, data, image_id, rev }, ...]
  images jsonb    -- { image_id: "data:image/...", ... }
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rev bigint;
  v_home jsonb;
  v_shapes jsonb;
  v_images jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- Safe under concurrency: the singleton index makes the loser a no-op.
  insert into public.layouts (created_by) values (auth.uid()) on conflict do nothing;

  -- `data -> 'view'` is the one thing still read out of the frozen document: 007 moved a planner's
  -- camera into public.layout_views and left the copy inside the canvas as the bench's home view, and
  -- that is what it still is. Reading it here costs a detoast of the old column on opening the bench
  -- and nothing on any write.
  select l.id, l.rev, l.data -> 'view'
    into v_id, v_rev, v_home
  from public.layouts l
  order by l.created_at
  limit 1;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id', o.object_id,
               'kind', o.kind,
               'data', o.data,
               'image_id', o.image_id,
               'rev', o.rev
             ) order by o.kind, o.object_id
           ), '[]'::jsonb)
    into v_shapes
  from public.layout_objects o
  where o.layout_id = v_id;

  select coalesce(jsonb_object_agg(i.image_id, i.data), '{}'::jsonb)
    into v_images
  from public.layout_images i
  where i.layout_id = v_id;

  return query select v_id, v_rev, public.layout_bytes(v_id), v_home, v_shapes, v_images;
end;
$$;

-- The door the OLD page comes through. It cannot be allowed to write (there is no document any
-- more), and dropping it would answer a tab that is still open with "function public.save_bench
-- does not exist", which says nothing to anybody. So it stays, with the same signature, and refuses
-- in words. Nothing else calls it.
create or replace function public.save_bench(p_data jsonb, p_session uuid)
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'This bench has been upgraded: reload the page to keep working'
    using errcode = 'PT410';
end;
$$;

-- ============================================================
-- 7. Permissions, the same pattern as 005, 007 and 008: internal by default, and only the four doors
--    the page uses are opened. (A function created by a later migration is granted to PUBLIC by
--    default, so every one of these revokes is load-bearing.)
-- ============================================================
revoke execute on function public.save_object(text, jsonb, uuid) from public, anon;
revoke execute on function public.delete_object(text, uuid) from public, anon;
revoke execute on function public.open_bench() from public, anon;
revoke execute on function public.save_bench(jsonb, uuid) from public, anon;
revoke execute on function public.layout_bytes(uuid) from public, anon, authenticated;
revoke execute on function public.shape_problem(text, jsonb) from public, anon, authenticated;
revoke execute on function public.floor_plan_fields_ok(jsonb) from public, anon, authenticated;
revoke execute on function public.floor_plan_ok(jsonb) from public, anon, authenticated;
revoke execute on function public.area_ok(jsonb) from public, anon, authenticated;
revoke execute on function public.point_in_sg(jsonb) from public, anon, authenticated;
revoke execute on function public.floor_plan_in_sg(jsonb, numeric, numeric, numeric) from public, anon, authenticated;

grant execute on function public.save_object(text, jsonb, uuid) to authenticated;
grant execute on function public.delete_object(text, uuid) to authenticated;
grant execute on function public.open_bench() to authenticated;
grant execute on function public.save_bench(jsonb, uuid) to authenticated;

-- Next: nothing. The canvas is rows, a write is a patch, and a shape somebody else changes arrives on
-- its own -- so the work that is left is in the page (drawing a row that arrives, and saying what
-- happened when a write is refused) rather than in the schema.
