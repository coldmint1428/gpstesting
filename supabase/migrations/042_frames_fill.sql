-- 042_frames_fill.sql
--
-- "That stretch is impossible -- space it out for me", in one call.
--
-- WHY A FUNCTION AND NOT A LOOP OF SAVES. Spacing a 200 m jump into 25 m steps is eight frames. Eight frame_save
-- calls would each reload the plan, and the second would be written against a rev the first had already bumped --
-- so seven of them would come back PT409 and the planner would be left with a half-filled strip, red in the middle.
-- One call is also the only way to promise the thing the planner actually asked for: when it returns, no step in
-- that stretch is over the limit. The client does not decide any of this; it names the two ends and the groups.
--
-- THE RULE IT KEEPS. Every position it writes lies on the straight line between the two ends, at the fraction of
-- the elapsed time it took to get there. Steps are sized to 24 m rather than exactly 25 m: the limit is exact and a
-- coordinate rounded to seven decimal places can turn an exactly-25 m hop into 25.0004, which plan_check then
-- reports as a violation (the first version of the bench hit precisely that). 24 m is inside the limit with room
-- for the rounding, and it is the same number the fixture uses.
--
-- THE AWKWARD PART: TIMES ARE SHARED, DISTANCES ARE NOT. Two groups crossing the same stretch need different
-- numbers of steps -- one crosses 200 m, the other 60 m. A frame belongs to the whole plan, one per time, so the
-- function takes the UNION of the times each group needs and writes every filled group at every one of them. A
-- group then has more samples than it needs, never fewer, and more samples on the same straight line can only
-- shorten a step. That is why the union is safe, and why the client cannot merge these times correctly on its own
-- without re-implementing this: `subdivide()` in src/utils/planFrames.js is per group.
--
-- WHAT IT WILL NOT TOUCH.
--   * A group is filled only if it stands at both ends and has said nothing in between. That is checked before a
--     single row is written, so the call can never overwrite a position a planner placed deliberately in the
--     middle of the stretch -- it refuses and says to fill from the frame that states it.
--   * A frame that already exists at one of the wanted times is REUSED: its note and the other groups' positions
--     are left alone. Only its rev is bumped, because a frame that gains a position has changed and a planner
--     holding the old copy should be told to reload (PT409) rather than silently overwrite it.
--   * Groups that are not named are not written at all, so a stretch that only Sound is failing does not become a
--     row of new statements for everyone else.
--
-- A last self-check runs over the rows it just wrote: if rounding collapsed two steps onto the same second (a 200 m
-- jump squeezed into ten seconds cannot be split at all), a step would still be too long and the whole call is
-- refused with a message that says what to do. Nothing is left half-done: it is one transaction.
--
-- WHO MAY CALL IT: root or planner, the same rule as every other plan write (038). The ACL is restated here so the
-- file stands on its own, and PUBLIC is revoked first (finding 20).

create or replace function public.frames_fill(
  p_plan uuid,
  p_from uuid,
  p_to uuid,
  p_groups uuid[] default null
)
returns table (
  frames_added integer,
  frames_reused integer,
  positions_written integer,
  groups_filled integer,
  max_step_m integer
)
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_from public.plan_frames;
  v_to public.plan_frames;
  v_span integer;
  v_group uuid;
  v_i integer;
  v_groups uuid[] := '{}';
  v_times integer[] := '{}';
  v_time integer;
  v_frame uuid;
  -- The two ends of every filled group, in the same order as v_groups. Read once, used for both the arithmetic
  -- and the self-check, so the check cannot agree with a different calculation than the one that wrote the rows.
  v_start_lat float8[] := '{}';
  v_start_lng float8[] := '{}';
  v_end_lat float8[] := '{}';
  v_end_lng float8[] := '{}';
  v_a_lat float8;
  v_a_lng float8;
  v_b_lat float8;
  v_b_lng float8;
  v_lat float8;
  v_lng float8;
  v_m float8;
  v_steps integer;
  v_k integer;
  v_dx float8;
  v_dy float8;
  v_step float8;
  v_max_step float8 := 0;
  v_prev_lat float8;
  v_prev_lng float8;
  v_row_t integer;
begin
  frames_added := 0;
  frames_reused := 0;
  positions_written := 0;
  groups_filled := 0;
  max_step_m := 0;

  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;

  select * into v_from from public.plan_frames where id = p_from and plan_id = p_plan;
  if not found then
    raise exception 'That starting frame is not in this plan.' using errcode = '42501';
  end if;
  select * into v_to from public.plan_frames where id = p_to and plan_id = p_plan;
  if not found then
    raise exception 'That ending frame is not in this plan.' using errcode = '42501';
  end if;
  if v_from.t_s >= v_to.t_s then
    raise exception 'A gap runs forward in time: fill from % to a later frame.', public.plan_clock(v_from.t_s)
      using errcode = '22023';
  end if;
  v_span := v_to.t_s - v_from.t_s;

  -- ---------- which groups ----------
  -- No list means "everyone this stretch is already carrying": the groups that stand at the start and have said
  -- nothing since. For those the straight line is not a decision, it is what the plan already implies.
  if p_groups is null or cardinality(p_groups) = 0 then
    for v_group in
      select g.id
        from public.groups g
       where g.event_id = v_event
         and exists (
           select 1
             from public.plan_positions p
             join public.plan_frames f on f.id = p.frame_id
            where f.plan_id = p_plan and p.group_id = g.id and f.t_s <= v_from.t_s)
         and not exists (
           select 1
             from public.plan_positions p
             join public.plan_frames f on f.id = p.frame_id
            where f.plan_id = p_plan and p.group_id = g.id
              and f.t_s > v_from.t_s and f.t_s < v_to.t_s)
       order by g.name
    loop
      v_groups := v_groups || v_group;
    end loop;
    if cardinality(v_groups) = 0 then
      raise exception 'Nothing to fill: no group stands at both ends of that stretch without a position in between.'
        using errcode = '22023';
    end if;
  else
    foreach v_group in array p_groups loop
      if not exists (select 1 from public.groups g where g.id = v_group and g.event_id = v_event) then
        raise exception 'That group belongs to another event.' using errcode = '42501';
      end if;
      if not (v_groups @> array[v_group]) then
        v_groups := v_groups || v_group;
      end if;
    end loop;
  end if;

  -- ---------- where each group starts and ends, and what that needs ----------
  foreach v_group in array v_groups loop
    -- The position that stands at the start: the last thing this group said at or before it. Reading the resolved
    -- position rather than the frame's own row is what makes a stretch that begins at a frame this group inherited
    -- work at all -- and it is the same rule the board draws with.
    select p.lat, p.lng into v_a_lat, v_a_lng
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = p_plan and p.group_id = v_group and f.t_s <= v_from.t_s
     order by f.t_s desc
     limit 1;
    if not found then
      raise exception '% has no position at or before % to start from.',
        (select g.name from public.groups g where g.id = v_group), public.plan_clock(v_from.t_s)
        using errcode = '22023';
    end if;
    select p.lat, p.lng into v_b_lat, v_b_lng
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = p_plan and p.group_id = v_group and f.t_s <= v_to.t_s
     order by f.t_s desc
     limit 1;
    if not found then
      raise exception '% has no position at or before % to end at.',
        (select g.name from public.groups g where g.id = v_group), public.plan_clock(v_to.t_s)
        using errcode = '22023';
    end if;

    -- Refuse rather than overwrite: a position in the middle of the stretch is a decision somebody made.
    if exists (
      select 1
        from public.plan_positions p
        join public.plan_frames f on f.id = p.frame_id
       where f.plan_id = p_plan and p.group_id = v_group
         and f.t_s > v_from.t_s and f.t_s < v_to.t_s
    ) then
      raise exception '% already stands somewhere between % and %. Fill from the frame that states it, or move that one first.',
        (select g.name from public.groups g where g.id = v_group),
        public.plan_clock(v_from.t_s), public.plan_clock(v_to.t_s)
        using errcode = '22023';
    end if;

    v_start_lat := v_start_lat || v_a_lat;
    v_start_lng := v_start_lng || v_a_lng;
    v_end_lat := v_end_lat || v_b_lat;
    v_end_lng := v_end_lng || v_b_lng;

    -- Distance, then the number of 24 m steps it takes. The same planar metres the client and plan_check use.
    v_dx := (v_b_lng - v_a_lng) * 111320 * cos(radians((v_a_lat + v_b_lat) / 2));
    v_dy := (v_b_lat - v_a_lat) * 111320;
    v_m := sqrt(v_dx * v_dx + v_dy * v_dy);
    v_steps := ceil(v_m / 24.0)::int;
    if v_steps > 1 then
      for v_k in 1 .. v_steps - 1 loop
        v_time := v_from.t_s + round(v_span::numeric * v_k / v_steps)::int;
        if v_time > v_from.t_s and v_time < v_to.t_s and not (v_times @> array[v_time]) then
          v_times := v_times || v_time;
        end if;
      end loop;
    end if;
  end loop;

  if cardinality(v_times) = 0 then
    -- Already inside the limit: nothing to write, and saying so is better than creating a frame that proves it.
    groups_filled := cardinality(v_groups);
    return next;
    return;
  end if;

  -- ---------- the frames ----------
  -- Existing frames at a wanted time are reused, and their rev is bumped because they are about to gain a position.
  update public.plan_frames f
     set rev = f.rev + 1, updated_by = auth.uid(), updated_at = now()
   where f.plan_id = p_plan and f.t_s = any (v_times);
  get diagnostics frames_reused = row_count;

  insert into public.plan_frames (plan_id, event_id, t_s, created_by)
  select p_plan, v_event, t.t, auth.uid()
    from unnest(v_times) as t(t)
   where not exists (
     select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = t.t
   );
  get diagnostics frames_added = row_count;

  -- ---------- the positions ----------
  for v_i in 1 .. cardinality(v_groups) loop
    v_group := v_groups[v_i];
    for v_time in select unnest(v_times) order by 1 loop
      select f.id into v_frame from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_time;
      -- On the straight line, so the position depends only on the time -- which is exactly why the union of the
      -- wanted times is harmless for every group.
      v_lat := v_start_lat[v_i] + (v_end_lat[v_i] - v_start_lat[v_i]) * (v_time - v_from.t_s)::float8 / v_span;
      v_lng := v_start_lng[v_i] + (v_end_lng[v_i] - v_start_lng[v_i]) * (v_time - v_from.t_s)::float8 / v_span;
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
      values (v_frame, p_plan, v_event, v_group, v_lat, v_lng)
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng;
      positions_written := positions_written + 1;
    end loop;
  end loop;

  -- ---------- the self-check ----------
  -- Walk the rows that are now in the database, from the position standing at the start, through every statement
  -- in the stretch, to the position standing at the end. If two wanted times collapsed onto the same second -- a
  -- 200 m jump squeezed into ten seconds cannot be split at all -- this is where it shows.
  for v_i in 1 .. cardinality(v_groups) loop
    v_group := v_groups[v_i];
    v_prev_lat := v_start_lat[v_i];
    v_prev_lng := v_start_lng[v_i];
    for v_row_t, v_lat, v_lng in
      select s.t, s.lat, s.lng
        from (
          select f.t_s as t, p.lat, p.lng
            from public.plan_positions p
            join public.plan_frames f on f.id = p.frame_id
           where f.plan_id = p_plan and p.group_id = v_group
             and f.t_s > v_from.t_s and f.t_s <= v_to.t_s
        ) s
       order by s.t
    loop
      v_dx := (v_lng - v_prev_lng) * 111320 * cos(radians((v_lat + v_prev_lat) / 2));
      v_dy := (v_lat - v_prev_lat) * 111320;
      v_step := sqrt(v_dx * v_dx + v_dy * v_dy);
      if v_step > 25 then
        raise exception 'The stretch from % to % is too short in time: a step would still be % m apart. Push the later frame back, or move it closer.',
          public.plan_clock(v_from.t_s), public.plan_clock(v_to.t_s), round(v_step)::int
          using errcode = '22023';
      end if;
      v_max_step := greatest(v_max_step, v_step);
      v_prev_lat := v_lat;
      v_prev_lng := v_lng;
    end loop;
  end loop;

  update public.plans set updated_at = now() where id = p_plan;

  groups_filled := cardinality(v_groups);
  max_step_m := round(v_max_step)::int;
  return next;
end;
$body$;

revoke all on function public.frames_fill(uuid, uuid, uuid, uuid[]) from public;
grant execute on function public.frames_fill(uuid, uuid, uuid, uuid[]) to authenticated;

comment on function public.frames_fill(uuid, uuid, uuid, uuid[]) is
  'Insert the frames that space one impossible stretch out, for the named groups, in one call (042).';
