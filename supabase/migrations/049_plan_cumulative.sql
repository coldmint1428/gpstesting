-- 049 — the 25 m rule is a budget per frame step, not a flat 25 m between statements.
--
-- The decision this stage was built on: impossibility is cumulative. A group may cover 25 m in one frame step, so a
-- walk that spans three frames may be 75 m and one that spans ten may be 250 m. 048 (and 038 before it) compared
-- every pair of neighbouring *statements* against a flat 25 m, which quietly made a sparse plan impossible: a group
-- stated at T+0 and again at +10:00 across nine untouched frames is allowed to have walked 250 m, and the gate called
-- 200 m a violation.
--
-- Step 12 fixed the same rule on the board, which now counts frame steps from `resolveTracks`' ordinal index. This
-- file makes the gate count the same thing — the position of each frame among the plan's frames, by time — so the two
-- sides agree on which walks are impossible as well as on which pair of frames they belong to. Without it the board
-- would be more forgiving than the gate, and a planner would be told "fine" until Publish refused.
--
-- The sentence follows: one step still says "the limit is 25 m" (every check that reads it keeps reading it), and a
-- longer walk says how many steps it had and what they allow.
--
-- R1: PostGIS lives in `extensions`, so it is in search_path and every call is qualified. R8: this body is 048's, not
-- 038's or 046's — a replacement copied from the wrong file would resurrect the off-site bug 046 fixed or lose the
-- zone and pace rules 048 added.
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
  -- The budget, in metres per frame step. Stated once here so the sentence and the test cannot drift apart.
  v_step_m constant int := 25;
  v_event uuid;
  v_group uuid;
  v_frame uuid;
  v_s integer;
  v_idx integer;
  v_lat float8;
  v_lng float8;
  v_prev_group uuid;
  v_prev_frame uuid;
  v_prev_s integer;
  v_prev_idx integer;
  v_prev_lat float8;
  v_prev_lng float8;
  v_steps integer;
  v_budget integer;
  v_dx float8;
  v_dy float8;
  v_m float8;
  v_dt integer;
  v_zones text;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;

  -- `idx` is the frame's ordinal in the plan, which is the number of steps a walk between two frames had. It cannot be
  -- derived from seconds: two frames a step apart can be an hour apart, and one step is one 25 m of walking either way.
  for v_group, v_frame, v_s, v_lat, v_lng, v_idx in
    with ord as (
      select f.id, (row_number() over (order by f.t_s))::int as idx
        from public.plan_frames f
       where f.plan_id = p_plan
    )
    select p.group_id, f.id, f.t_s, p.lat, p.lng, o.idx
      from public.plan_frames f
      join public.plan_positions p on p.frame_id = f.id
      join ord o on o.id = f.id
     where f.plan_id = p_plan
       and p.state = 'on_site'
     order by p.group_id, f.t_s
  loop
    if v_prev_group is not distinct from v_group and v_prev_frame is not null then
      v_steps := v_idx - v_prev_idx;
      if v_steps < 1 then v_steps := 1; end if;
      v_budget := v_step_m * v_steps;

      v_dx := (v_lng - v_prev_lng) * 111320 * cos(radians((v_lat + v_prev_lat) / 2));
      v_dy := (v_lat - v_prev_lat) * 111320;
      v_m := sqrt(v_dx * v_dx + v_dy * v_dy);
      v_dt := v_s - v_prev_s;

      if v_m > v_budget then
        severity := 'error';
        group_id := v_group;
        from_frame := v_prev_frame;
        from_s := v_prev_s;
        to_frame := v_frame;
        to_s := v_s;
        metres := round(v_m)::int;
        message := case
          when v_steps = 1 then
            format('%s m in %s (from %s to %s) -- the limit is %s m',
                   round(v_m)::int, public.plan_clock(v_dt),
                   public.plan_clock(v_prev_s), public.plan_clock(v_s), v_step_m)
          else
            format('%s m in %s (from %s to %s) -- %s steps, so the limit is %s m',
                   round(v_m)::int, public.plan_clock(v_dt),
                   public.plan_clock(v_prev_s), public.plan_clock(v_s), v_steps, v_budget)
        end;
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
    v_prev_idx := v_idx;
    v_prev_lat := v_lat;
    v_prev_lng := v_lng;
  end loop;
end;
$body$;

-- R4: `create or replace` keeps the old grants, but naming them here is what keeps a future re-create honest, and
-- the schema's default ACL hands every new function an EXECUTE to anon unless it is revoked from both.
revoke execute on function public.plan_check(uuid) from public, anon;
grant execute on function public.plan_check(uuid) to authenticated;
