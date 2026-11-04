-- 091: no distance rule and no speed rule. Run AFTER 090 (Supabase -> SQL Editor). Can be re-run.
--
-- WHY. A group may walk, ride a bus, take a boat or follow a float, so how far and how fast it moves between two
-- frames is the planner's call. The 25 m-per-frame-step budget (048/049) and the "faster than running" warning
-- (049/087) are gone, and so is Fill (frames_fill, 042/083), whose only job was to add frames to satisfy the budget.
--
-- WHAT IS LEFT. plan_check reports one thing: a walk whose straight line crosses a no-go area or an obstacle, as
-- severity 'error'. Publish (058) and the session start (051) still refuse a plan with any error row, so those gates
-- now mean "no walk through a closed area" and nothing else.
--
-- ONE BEHAVIOUR CHANGE TO KNOW. Before this, a hop over the budget was reported as too far and was never tested
-- against the zones (the zone test sat in the else branch). Now every hop is tested, so a long jump whose line
-- crosses a no-go area shows up as that crossing.
--
-- This is 087's plan_check with the two retired branches removed; the zone rule, its sentence and the grants are as
-- they were. The return columns are unchanged, so the board and every caller read it exactly as before.

create or replace function public.plan_check(p_plan uuid)
returns table (
  severity text, group_id uuid, from_frame uuid, from_s integer,
  to_frame uuid, to_s integer, metres integer, message text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $body$
declare
  v_event uuid;
  v_group uuid;
  v_frame uuid;
  v_s integer;
  v_lat float8;
  v_lng float8;
  v_prev_group uuid;
  v_prev_frame uuid;
  v_prev_s integer;
  v_prev_lat float8;
  v_prev_lng float8;
  v_dx float8;
  v_dy float8;
  v_m float8;
  v_dt integer;
  v_zones text;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;

  for v_group, v_frame, v_s, v_lat, v_lng in
    select p.group_id, f.id, f.t_s, p.lat, p.lng
      from public.plan_frames f
      join public.plan_positions p on p.frame_id = f.id
     where f.plan_id = p_plan
       and p.state = 'on_site'
     order by p.group_id, f.t_s
  loop
    if v_prev_group is not distinct from v_group and v_prev_frame is not null then
      v_dx := (v_lng - v_prev_lng) * 111320 * cos(radians((v_lat + v_prev_lat) / 2));
      v_dy := (v_lat - v_prev_lat) * 111320;
      v_m := sqrt(v_dx * v_dx + v_dy * v_dy);
      v_dt := v_s - v_prev_s;

      -- The line the walk claims, as a geography so the polygon test is the one the zones layer draws. A null
      -- answer means the line touches no zone (SELECT INTO with no rows assigns null, so this resets each pair).
      select string_agg(format('%s "%s"',
                               case z.kind when 'no_go' then 'the no-go area' else 'the obstacle' end,
                               z.name),
                        ' and ' order by z.name)
        into v_zones
        from public.zones z
       where z.event_id = v_event
         and z.kind in ('no_go', 'obstacle')
         and extensions.st_intersects(
               z.shape,
               extensions.st_setsrid(
                 extensions.st_makeline(
                   extensions.st_makepoint(v_prev_lng, v_prev_lat),
                   extensions.st_makepoint(v_lng, v_lat)),
                 4326)::extensions.geography);

      if v_zones is not null then
        severity := 'error';
        group_id := v_group;
        from_frame := v_prev_frame;
        from_s := v_prev_s;
        to_frame := v_frame;
        to_s := v_s;
        metres := round(v_m)::int;
        message := format('%s m in %s (from %s to %s) -- the straight line crosses %s',
                          round(v_m)::int,
                          public.plan_clock(v_dt),
                          public.plan_clock(v_prev_s),
                          public.plan_clock(v_s),
                          v_zones);
        return next;
      end if;
    end if;
    v_prev_group := v_group;
    v_prev_frame := v_frame;
    v_prev_s := v_s;
    v_prev_lat := v_lat;
    v_prev_lng := v_lng;
  end loop;
end;
$body$;

-- R4: `create or replace` keeps the old grants, but naming them here is what keeps a future re-create honest, and
-- the schema's default ACL hands every new function an EXECUTE to anon unless it is revoked from both.
revoke execute on function public.plan_check(uuid) from public, anon;
grant execute on function public.plan_check(uuid) to authenticated;

-- Fill is gone: nothing calls it, and the rule it served is gone.
drop function if exists public.frames_fill(uuid, uuid, uuid, uuid[], uuid);
drop function if exists public.frames_fill(uuid, uuid, uuid, uuid[]);
