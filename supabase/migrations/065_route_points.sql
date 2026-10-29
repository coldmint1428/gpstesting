-- 065_route_points.sql
--
-- Step 29 of the planning stage: a timetable row carries the moment's own POINT, so a follower's map can draw the
-- walk their group is meant to take.
--
-- WHY THIS FILE EXISTS. Step 16 gave every follower a timetable and step 26 made a row say WHERE in words ("7:40
-- Main Gate"). Neither can draw a line: a place is a name, and the walk is the points between them. The follower's
-- Map tab was still the placeholder, and the one read it has answers no coordinates -- so the screen had nothing to
-- join up even if it had a map. This file adds the two numbers and nothing else.
--
-- WHY ONE READ AND NOT TWO. The schedule already polls `session_timetable` every 30 s. The map reads the same call,
-- so the two screens share one answer, and "only your group" stays in the one place it is proved (040's scope inside
-- `session_status`, 052). A second read from the browser would be a second door for the scope to drift through, and
-- step 16's browser check exists because of what a second door once cost (finding 48).
--
-- WHAT A NULL POINT MEANS, and what it does not. The join below is 062's, unchanged, so `lat`/`lng` are null in
-- exactly the cases 062's `place` is null FOR WANT OF A POINT: a frame that only carries the group forward (no
-- `plan_positions` row of its own), and an off-site statement (`state = 'off_site'`, which is not a place on the
-- map). A ROUTE POINT IN OPEN GROUND IS NOT ONE OF THESE: it has a point and no place, because 062 judges a place by
-- the zone the point stands in. So the two travel together in one direction only -- a null point always has a null
-- place, and a place always has a point, but a point may stand in no zone at all. Carrying a route point's name as
-- null is 062's rule staying whole rather than acquiring an exception here.
--
-- R2: the return type changes (two columns appended), so this is DROP + CREATE + re-GRANT, not `create or replace`.
-- R8: the body is 062's (which is 057's, which is 052's with the deleted-plan guard), copied whole with only the two
-- columns and the comment changed. R4: the grants are named again because a fresh function inherits the schema
-- default. R1: `extensions.` is qualified where it is used (the place join is unchanged).

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
  place text,
  lat double precision,
  lng double precision
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
         z.name,
         pp.lat,
         pp.lng
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
  'session follows, the zone the moment''s drawn point stands in, and that point itself (null when the frame only '
  'carries the group or when the group is off site; a point in open ground has a point and no zone) — scoped to the '
  'caller (051, names 052, place 062, point 065); a session whose plan has been deleted answers no rows (057).';

revoke execute on function public.session_timetable(uuid, timestamptz) from public, anon;
grant execute on function public.session_timetable(uuid, timestamptz) to authenticated;
