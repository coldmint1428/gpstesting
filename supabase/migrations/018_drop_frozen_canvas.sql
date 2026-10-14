-- Step 10: the frozen canvas goes, and the bench's home view moves out of it.
-- Run AFTER 017_object_rows.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- WHAT THIS REMOVES. 017 split the one-row canvas into a row per shape and left public.layouts.data
-- exactly as it was: 3.7 MB of document that nothing reads and nothing writes, kept only so that a
-- mistake in the split would be recoverable by hand. The split has since been checked against the real
-- bench -- 6 floor plans and 9 areas came back as 15 rows, all of them drawn, with the six plans' two
-- pictures stored once each instead of six times -- so that backup is dead weight now.
--
-- AND IT IS A PARTICULARLY AWKWARD KIND of dead weight: it lives in the bench's own row, so every read
-- of the bench detoasts 3.7 MB to get at the 200 bytes beside it.
--
-- THE HOME VIEW IS THE ONE THING STILL LIVING IN IT, so it is carried into a column of its own first.
-- 015 moved a planner's camera into public.layout_views and left the copy inside the document as the
-- view a planner who has never panned opens at; this is that value, kept, so nothing about where the
-- map opens changes.
--
-- THE DROP REFUSES TO HAPPEN IF IT WOULD LOSE A SHAPE, which is the whole reason this is a migration
-- and not a `drop column` typed into a console. If the document holds a shape with no row, then the rows
-- are NOT the whole bench, and throwing the document away would throw that shape away with it: better a
-- migration that stops with a sentence naming the shapes than a bench that quietly lost one.
--
-- RE-RUNNABLE, like the rest of them: every statement is `if exists` / `if not exists`, and a second run
-- finds nothing left to do. (017 is NOT re-runnable AFTER this, deliberately: it describes the split,
-- and the document it split is gone. Run these files in order, once.)
--
-- WHAT IT DROPS BESIDES THE COLUMN, and why: the four functions that only ever described that one
-- document -- layout_problem(), layout_data_ok(), floor_plan_ok() and layout_list(). None of them can be
-- reached any more: a shape is checked by shape_problem() as it is written (017) and by the table's own
-- constraints as it is stored, and nothing asks about a whole canvas, because there is no whole canvas.
-- A function called layout_data_ok() that nothing calls is a description of a rule that no longer
-- exists, so it goes rather than sitting there looking authoritative.

do $$
begin
  if to_regclass('public.layouts') is null or to_regclass('public.layout_objects') is null then
    raise exception 'Run 005_layouts.sql and 017_object_rows.sql before this migration';
  end if;
end $$;

-- ============================================================
-- 1. The home view, into a column of its own.
--
--    `execute` inside the guard, so the statement is only ever PARSED when the column it reads still
--    exists -- which is what makes this file safe to run a second time.
-- ============================================================
alter table public.layouts add column if not exists home jsonb;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'layouts' and column_name = 'data'
  ) then
    execute $copy$
      update public.layouts
      set home = data -> 'view'
      where home is null and jsonb_typeof(data -> 'view') = 'object'
    $copy$;
  end if;
end $$;

-- ============================================================
-- 2. The guard: every shape in the document has to have a row.
-- ============================================================
do $$
declare
  v_missing text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'layouts' and column_name = 'data'
  ) then
    return; -- already dropped: there is nothing left to check
  end if;

  select string_agg(s ->> 'id', ', ')
    into v_missing
  from public.layouts l,
       lateral jsonb_array_elements(
         case when jsonb_typeof(l.data -> 'floorPlans') = 'array'
              then l.data -> 'floorPlans' else '[]'::jsonb end
         || case when jsonb_typeof(l.data -> 'polygons') = 'array'
                 then l.data -> 'polygons' else '[]'::jsonb end
       ) s
  where not exists (
    select 1 from public.layout_objects o where o.object_id = s ->> 'id'
  );

  if v_missing is not null then
    raise exception 'Refusing to drop the frozen canvas: these shapes have no row (%s)', v_missing;
  end if;
end $$;

-- ============================================================
-- 3. The column, and the constraint that was about it.
--    The constraint is dropped by whatever name it has, the way 014 dropped 005's, so that no name of
--    a check constraint has to be remembered here.
-- ============================================================
do $$
declare
  v_constraint text;
begin
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

alter table public.layouts drop column if exists data;

-- ============================================================
-- 4. The four functions that described the document that has just gone. Dropped in dependency order:
--    layout_problem() and layout_data_ok() both call floor_plan_ok().
-- ============================================================
drop function if exists public.layout_problem(jsonb);
drop function if exists public.layout_data_ok(jsonb);
drop function if exists public.floor_plan_ok(jsonb);
drop function if exists public.layout_list(jsonb, text);

-- ============================================================
-- 5. open_bench() reads the home view from where it now lives. Same signature and the same reply, so
--    this is a `create or replace` rather than a drop and a rebuild -- and the page needs no change at
--    all: it has read `row.home` since 017.
-- ============================================================
create or replace function public.open_bench()
returns table (
  id uuid,
  rev bigint,
  bytes bigint,
  home jsonb,     -- where a planner who has never panned opens the map
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

  select l.id, l.rev, l.home
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

-- Next: nothing. The bench is rows, a write is a patch of one shape, and there is no longer a second
-- copy of the canvas anywhere in the schema.
