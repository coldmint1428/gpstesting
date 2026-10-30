-- 062_timetable_place.sql
--
-- Step 26 of the planning stage: a row of the timetable says WHERE the moment is.
--
-- THE MODEL THIS SERVES. A moment is a point. A point inside a zone is a place -- "be at Main Gate by 7:40" --
-- and a point outside every zone is a route point: it exists so the map can draw the walk, and nobody is judged on
-- it. Nothing is refused for sitting in open ground: a walk may cross the whole venue. This file only makes the
-- difference visible; it does not gate anything.
--
-- WHY A COLUMN AND NOT A SECOND READ. A follower reads "6:45 pm · doors" today and cannot tell where; the ops
-- board shows a point on a map, which is no use on a phone in a crowd. The zone a point stands in is one indexed
-- lookup per row, and the read is already polled every 30 s. The alternative -- a second read from the browser --
-- is exactly what step 16's browser check forbids (it asserts the schedule page makes no plan_positions request).
--
-- R2: the return type changes, so this is DROP + CREATE + re-GRANT, not `create or replace`. R8: the body is 057's,
-- which is 052's with the deleted-plan guard, and the only addition is the point join and its place. R4: the grants
-- are named again because a fresh function inherits the schema default.
--
-- WHICH ZONE, WHEN TWO COVER THE POINT. The rule 057 already uses for the same question, copied rather than
-- reinvented: a stage first, then an entrance, then any other, then the name, so two overlapping zones always
-- resolve the same way. No-go areas and obstacles are excluded: a moment is not somewhere to be merely because it
-- stands inside the cordon, and "be at Stores (no-go)" is not an instruction anyone can follow.
--
-- A FRAME THAT ONLY CARRIES A GROUP FORWARD HAS NO POINT, so it has no place, and null is the honest answer -- the
-- plan does not say "the group is somewhere" at that frame, it says the previous statement still stands. Carrying
-- the point forward would be a second copy of the walk that 051's carry-forward already owns.

drop function if exists public.session_timetable(uuid, timestamptz);

create function public.session_timetable(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid,
  group_name text,
  frame_id uuid,
  t_s integer,
  planned_at timestamptz,
  state text,
  lateness interval,
  marked_at timestamptz,
  marked_by uuid,
  note text,
  plan_name text,
  plan_rev integer,
  place text
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_plan uuid;
  v_rev integer;
  v_plan_name text;
  v_t0 timestamptz;
begin
  select s.event_id, s.plan_id, s.plan_rev, s.t0_at into v_event, v_plan, v_rev, v_t0
    from public.event_sessions s
   where s.id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;

  -- A plan that was deleted, not a session that never had one.
  if v_plan is null and v_t0 is not null then
    return;
  end if;

  -- A session with no plan has no name to show; session_status() refuses it below with its own sentence.
  select p.name into v_plan_name from public.plans p where p.id = v_plan;

  return query
  select st.group_id,
         g.name,
         st.frame_id,
         st.t_s,
         st.planned_at,
         st.state,
         st.lateness,
         st.marked_at,
         st.marked_by,
         f.note,
         v_plan_name,
         v_rev,
         z.name
    from public.session_status(p_session, p_at) st
    join public.groups g on g.id = st.group_id
    left join public.plan_frames f on f.id = st.frame_id
    -- The moment's own point. A carried frame has none; an off-site moment is not a place either.
    left join public.plan_positions pp
           on pp.frame_id = st.frame_id
          and pp.group_id = st.group_id
          and pp.state = 'on_site'
    left join lateral (
      -- The place the drawn point stands in, if it stands in one: stage first, then an entrance, then any other.
      select z2.name
        from public.zones z2
       where z2.event_id = v_event
         and z2.kind in ('zone', 'stage', 'entrance')
         and extensions.st_dwithin(
               z2.shape,
               extensions.st_setsrid(extensions.st_makepoint(pp.lng, pp.lat), 4326)::extensions.geography,
               0)
       order by case z2.kind when 'stage' then 0 when 'entrance' then 1 else 2 end, z2.name
       limit 1
    ) z on true
   order by st.t_s, g.name, st.group_id;
end;
$body$;

comment on function public.session_timetable(uuid, timestamptz) is
  'One read for a running timetable: a row per group per frame with the planned clock time (from t0_at), '
  'pending/late/arrived/missed/not_required, lateness, the frame''s note, the plan''s name, the revision the '
  'session follows, and the zone the moment''s drawn point stands in (null when it stands in none, when the frame '
  'only carries the group, or when the group is off site); scoped to the caller (051, names 052, place 062); a '
  'session whose plan has been deleted answers no rows (057).';

revoke execute on function public.session_timetable(uuid, timestamptz) from public, anon;
grant execute on function public.session_timetable(uuid, timestamptz) to authenticated;
