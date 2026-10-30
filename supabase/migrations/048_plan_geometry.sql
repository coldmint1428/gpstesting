-- 048 — the geometry rules: a walk that clips a no-go zone, and a pace nobody can run.
--
-- plan_check() has only ever measured distance between the moments a group says where it is. A distance cannot see
-- two things:
--
--   * the straight line between two neighbouring on-site positions can cross a no_go or obstacle zone while both
--     positions sit outside it -- "walk around the building" and "walk through the building" are the same 20 m;
--   * the implied pace can be beyond what a person on foot can do. The 25 m rule caps the step, not the sprint:
--     20 m between two frames a second apart is a legal distance and a nonsense plan.
--
-- One error per neighbouring pair, and the pair's most basic problem wins: more than 25 m first, then a zone, then
-- the pace. Publishing refuses any error, so both of these are a gate before a plan becomes everyone's timetable.
--
-- The zone is named inside `message` because the return type cannot gain a column -- R2 means DROP + re-create +
-- re-grant for that, and every caller (the board, both publish paths, two checks) would have to change with it. The
-- name in the sentence is what makes the error actionable: "crosses the no-go area "Stores (no-go)"" is a thing a
-- planner can walk around, and a bare "20 m" is not.
--
-- R1: PostGIS lives in `extensions`, so it is in search_path and every call is qualified. R8: this body is 046's
-- (the one that taught it to skip an off-site row), not 038's -- a replacement copied from the wrong file would
-- quietly resurrect the bug 046 fixed.
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
  -- A crowd walks at about 1.4 m/s. A hard sprint across a venue is about 6; above that the plan is asking for
  -- wheels, and a planner who meant "they are already there" should be writing two frames, not one impossible step.
  v_max_mps constant float8 := 6;
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

      if v_m > 25 then
        severity := 'error';
        group_id := v_group;
        from_frame := v_prev_frame;
        from_s := v_prev_s;
        to_frame := v_frame;
        to_s := v_s;
        metres := round(v_m)::int;
        message := format('%s m in %s (from %s to %s) -- the limit is 25 m',
                          round(v_m)::int,
                          public.plan_clock(v_dt),
                          public.plan_clock(v_prev_s),
                          public.plan_clock(v_s));
        return next;
      else
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
        elsif v_dt > 0 and v_m / v_dt > v_max_mps then
          severity := 'error';
          group_id := v_group;
          from_frame := v_prev_frame;
          from_s := v_prev_s;
          to_frame := v_frame;
          to_s := v_s;
          metres := round(v_m)::int;
          message := format('%s m in %s (from %s to %s) -- %s m/s is faster than running',
                            round(v_m)::int,
                            public.plan_clock(v_dt),
                            public.plan_clock(v_prev_s),
                            public.plan_clock(v_s),
                            round((v_m / v_dt)::numeric, 1));
          return next;
        end if;
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

-- ---------- publishing says which rule it refused for ----------
-- 038's body, with one change: the gate names the first problem instead of assuming every problem is a 25 m step.
-- It was a lie the moment a crossing or a sprint could refuse a publish. The problems are ordered by the moment
-- they happen (then by group, then by name) so the sentence is stable between two runs of the same plan.
create or replace function public.plan_publish(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_row public.plans;
  v_errors integer;
  v_first text;
  v_message text;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can publish a plan.' using errcode = '42501';
  end if;

  -- The 25 m rule is a warning while a plan is being drawn and a hard gate before anyone's timetable depends on
  -- it. Without this, "the limit" was only ever advice: the board coloured frames red and then let you publish.
  select count(*) into v_errors
    from public.plan_check(p_plan) c
   where c.severity = 'error';

  if v_errors > 0 then
    select c.message into v_first
      from public.plan_check(p_plan) c
     where c.severity = 'error'
     order by c.from_s, c.to_s, c.group_id
     limit 1;
    v_message := case
      when v_errors = 1 then format('This plan cannot be published yet: %s.', v_first)
      else format('This plan cannot be published yet (%s problems). The first is: %s.', v_errors, v_first)
    end;
    raise exception '%', v_message using errcode = '22023';
  end if;

  update public.plans
     set status = 'archived', updated_by = auth.uid(), updated_at = now()
   where event_id = v_event and status = 'live' and id <> p_plan;

  update public.plans
     set status = 'live', published_at = now(), rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_plan
  returning * into v_row;
  return v_row;
end;
$body$;

-- R4: `create or replace` keeps the old grants, but naming them here is what keeps a future re-create honest, and
-- the schema's default ACL hands every new function an EXECUTE to anon unless it is revoked from both.
revoke execute on function public.plan_check(uuid) from public, anon;
revoke execute on function public.plan_publish(uuid) from public, anon;
grant execute on function public.plan_check(uuid) to authenticated;
grant execute on function public.plan_publish(uuid) to authenticated;
