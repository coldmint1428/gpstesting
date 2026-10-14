-- Step 19: what the bench holds, without the pictures -- for a page catching up.
-- Run AFTER 018_drop_frozen_canvas.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- WHY. A page that was hidden or lost its socket used to ask "has the bench moved past MY highest
-- revision?" and only re-read when it had. That number cannot answer the question: a page that missed
-- somebody else's write at rev 12 and then made its own at rev 13 holds 13, compares equal, and keeps
-- the stale shape until a reload. And the re-read was open_bench(), which sends every picture again.
--
-- bench_head() answers it properly and cheaply: every shape's id and its own revision, the bench's
-- revision, and its size (layout_bytes, which a planner cannot call directly). The page compares shape
-- by shape, fetches only the rows that are newer than what it shows, and drops the ones that are gone.
-- A few hundred bytes, no pictures.
--
-- Read-only and additive: nothing existing is changed.
create or replace function public.bench_head()
returns table (
  rev bigint,
  bytes bigint,
  shapes jsonb -- { object_id: rev, ... }
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_id uuid;
  v_rev bigint;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select l.id, l.rev into v_id, v_rev from public.layouts l order by l.created_at limit 1;
  if v_id is null then
    return query select 0::bigint, 0::bigint, '{}'::jsonb;
    return;
  end if;

  return query
    select v_rev,
           public.layout_bytes(v_id),
           coalesce((
             select jsonb_object_agg(o.object_id, o.rev)
             from public.layout_objects o
             where o.layout_id = v_id
           ), '{}'::jsonb);
end;
$$;

revoke execute on function public.bench_head() from public, anon;
grant execute on function public.bench_head() to authenticated;
