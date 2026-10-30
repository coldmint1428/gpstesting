-- 046_position_state.sql
--
-- Step 9 of the planning plan: a position can be off-site, and can need confirming.
--
-- TWO FLAGS ON A POSITION, NOT A DIFFERENT KIND OF ROW.
--   state   'on_site' | 'off_site' -- is this group standing on the map at this moment?
--   verify  'auto'    | 'manual'   -- may the app trust this without somebody confirming it?
-- An off-site position is still a position: it keeps its coordinates, it is still returned by plan_frames_list,
-- and it is still somebody's statement that "this group is not on site now". What changes is that it is not a
-- place on the map, so no rule that measures a walk may use it.
--
-- WHY IGNORE IT RATHER THAN DELETE IT. The alternative -- an off-site group simply has no row -- cannot say "off
-- site" apart from "has not moved since the last frame that mentioned me", which is the whole inheritance model.
-- A group that goes off site for twenty minutes and comes back would otherwise have its departure and return
-- silently deleted from the plan, and step 10 could not draw either. So the row stays, and every check that
-- measures a distance skips it: plan_check here, and findGaps() in src/utils/planFrames.js. Both skip it the same
-- way, by comparing the group's last ON-SITE statement with its next one.
--
-- THE CONSEQUENCE, stated rather than discovered later: an off-site excursion is invisible to the 25 m rule. A group
-- last seen on site at the gate, off site for ten minutes, then on site 400 m away is reported as one 400 m hop from
-- the gate -- because the plan does not know how they travelled, and pretending the far jump was a walk is worse
-- than saying it plainly. Coming back to where they left raises nothing, which is the ordinary case.
--
-- THE FLAG IS NOT THE DEFAULT. `positions` is replaced wholesale when present, so a point that omits a flag could
-- reasonably mean "back to the default" -- except that the board's drag sends a point with only a coordinate, and a
-- drag must not quietly put an off-site group back on site. So an omitted flag means "as it was" on an existing
-- row (the upsert keeps the stored value), and the defaults on_site / auto on a new one. Sending an explicit
-- 'on_site' is how a planner puts a group back on the map, and step 10 is where that becomes a button.
--
-- THE WORDS ARE NAMED IN THE FUNCTION. The table's check constraint would refuse a bad value too, but it would
-- describe it as a constraint name raised from inside an upsert -- the same lesson 044 applied to plan_frames_t_range.
--
-- AND THE TWO COPIES THAT WOULD LOSE IT. plan_fork copies a plan position by position, and frame_hold copies one
-- group's position to a later moment. Both were written before these columns existed, so both would have taken a
-- careful off-site / manual pair and turned it into on_site / auto -- silently, in the two operations whose whole
-- purpose is "the same plan, somewhere else in time". Both copy the flags now.

alter table public.plan_positions
  add column if not exists state text not null default 'on_site',
  add column if not exists verify text not null default 'auto';

alter table public.plan_positions drop constraint if exists plan_positions_state_check;
alter table public.plan_positions
  add constraint plan_positions_state_check check (state in ('on_site', 'off_site'));

alter table public.plan_positions drop constraint if exists plan_positions_verify_check;
alter table public.plan_positions
  add constraint plan_positions_verify_check check (verify in ('auto', 'manual'));

comment on column public.plan_positions.state is
  'on_site (standing on the map) or off_site (still a statement, but no rule may measure a walk from it) (046).';
comment on column public.plan_positions.verify is
  'auto (trusted as drawn) or manual (somebody has to confirm it -- step 10) (046).';

-- ---------- frame_save reads both ----------
-- The body is 044's, which is the one that honours a client-supplied id (041); 038's was older and copying from
-- where a function was born is how 044 reverted 041 in the first place.
create or replace function public.frame_save(p_plan uuid, p_frame jsonb)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_id uuid := nullif(p_frame ->> 'id', '')::uuid;
  v_row public.plan_frames;
  v_t integer := (p_frame ->> 't_s')::int;
  v_rev integer := nullif(p_frame ->> 'rev', '')::int;
  v_group_text text;
  v_point jsonb;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if v_t is null or v_t < 0 then
    raise exception 'A frame cannot sit before T+0.' using errcode = '22023';
  end if;
  if v_t > 86400 * 3 then
    raise exception 'A plan stops three days after T+0. That would push a frame past the end.' using errcode = '22023';
  end if;

  if v_id is null then
    if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t) then
      raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
        using errcode = '22023';
    end if;
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    values (p_plan, v_event, v_t, nullif(p_frame ->> 'note', ''), auth.uid())
    returning * into v_row;
  else
    select * into v_row from public.plan_frames where id = v_id and plan_id = p_plan for update;
    if found then
      if v_rev is not null and v_rev <> v_row.rev then
        raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
      end if;
      if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t and f.id <> v_id) then
        raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
          using errcode = '22023';
      end if;
      update public.plan_frames
         set t_s = v_t,
             note = case when p_frame ? 'note' then nullif(p_frame ->> 'note', '') else note end,
             rev = rev + 1,
             updated_by = auth.uid(),
             updated_at = now()
       where id = v_id
      returning * into v_row;
    else
      -- 041: the id is not in this plan, so this is a restore or a create that names its own id. It must not be
      -- pulled out of another plan -- that would move a frame between plans under a caller who only meant to write
      -- one, and leave the other plan's frames and progress pointing at nothing.
      if exists (select 1 from public.plan_frames f where f.id = v_id) then
        raise exception 'That frame id belongs to another plan.' using errcode = '42501';
      end if;
      if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t) then
        raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
          using errcode = '22023';
      end if;
      insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
      values (v_id, p_plan, v_event, v_t, nullif(p_frame ->> 'note', ''), auth.uid())
      returning * into v_row;
    end if;
  end if;

  if p_frame ? 'positions' then
    -- Drop the groups this frame no longer mentions ...
    delete from public.plan_positions pp
     where pp.frame_id = v_row.id
       and not (coalesce(p_frame -> 'positions', '{}'::jsonb) ? pp.group_id::text);

    -- ... then write the ones it does.
    for v_group_text, v_point in
      select key, value from jsonb_each(coalesce(p_frame -> 'positions', '{}'::jsonb))
    loop
      if not exists (select 1 from public.groups g where g.id = v_group_text::uuid and g.event_id = v_event) then
        raise exception 'That group belongs to another event.' using errcode = '42501';
      end if;
      -- The two words, named here so a typo comes back as a sentence and not as plan_positions_state_check.
      if v_point ? 'state' and coalesce(v_point ->> 'state', '') not in ('on_site', 'off_site') then
        raise exception 'A position is either on site or off site, not %.', coalesce(v_point ->> 'state', 'nothing')
          using errcode = '22023';
      end if;
      if v_point ? 'verify' and coalesce(v_point ->> 'verify', '') not in ('auto', 'manual') then
        raise exception 'A position is confirmed automatically or by hand, not %.', coalesce(v_point ->> 'verify', 'nothing')
          using errcode = '22023';
      end if;
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
      values (v_row.id, p_plan, v_event, v_group_text::uuid,
              (v_point ->> 'lat')::float8, (v_point ->> 'lng')::float8,
              coalesce(v_point ->> 'state', 'on_site'), coalesce(v_point ->> 'verify', 'auto'))
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat,
            lng = excluded.lng,
            -- A flag the payload leaves out means "as it was", not "back to the default": the drag that carries a
            -- badge sends a coordinate and nothing else.
            state = case when v_point ? 'state' then excluded.state else plan_positions.state end,
            verify = case when v_point ? 'verify' then excluded.verify else plan_positions.verify end;
    end loop;
  end if;

  update public.plans set updated_at = now() where id = p_plan;
  return v_row;
end;
$body$;

-- ---------- plan_frames_list returns them ----------
create or replace function public.plan_frames_list(p_plan uuid)
returns table (id uuid, t_s integer, note text, rev integer, positions jsonb)
language sql
stable
security invoker
set search_path = public
as $body$
  select f.id, f.t_s, f.note, f.rev,
         coalesce(
           jsonb_object_agg(p.group_id::text,
                            jsonb_build_object('lat', p.lat, 'lng', p.lng, 'state', p.state, 'verify', p.verify))
             filter (where p.group_id is not null),
           '{}'::jsonb)
  from public.plan_frames f
  left join public.plan_positions p on p.frame_id = f.id
  where f.plan_id = p_plan
  group by f.id, f.t_s, f.note, f.rev
  order by f.t_s;
$body$;

-- ---------- plan_check ignores an off-site row ----------
-- The 25 m rule measures walks. An off-site statement is not a place a group walked to, so it is not an endpoint:
-- each group is followed from its last on-site statement to its next one. Everything else about the function -- one
-- error per broken pair, the distance and the two times in the message -- is unchanged.
create or replace function public.plan_check(p_plan uuid)
returns table (
  severity text, group_id uuid, from_frame uuid, from_s integer,
  to_frame uuid, to_s integer, metres integer, message text
)
language plpgsql
stable
security invoker
set search_path = public
as $body$
declare
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
begin
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
                          public.plan_clock(v_s - v_prev_s),
                          public.plan_clock(v_prev_s),
                          public.plan_clock(v_s));
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

-- ---------- the fork copies the flags ----------
create or replace function public.plan_fork(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_src public.plans;
  v_row public.plans;
  v_name text;
begin
  select * into v_src from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_src.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can copy a plan.' using errcode = '42501';
  end if;

  v_name := left(v_src.name || ' (edited)', 80);

  insert into public.plans (event_id, name, for_date, t0_time, status, fork_of, forked_at, created_by)
  values (v_src.event_id, v_name, v_src.for_date, v_src.t0_time, 'draft', v_src.id, now(), auth.uid())
  returning * into v_row;

  with copied as (
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    select v_row.id, f.event_id, f.t_s, f.note, auth.uid()
    from public.plan_frames f
    where f.plan_id = p_plan
    returning id, t_s
  )
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
  select c.id, v_row.id, v_row.event_id, p.group_id, p.lat, p.lng, p.state, p.verify
  from copied c
  join public.plan_frames f_old on f_old.plan_id = p_plan and f_old.t_s = c.t_s
  join public.plan_positions p on p.frame_id = f_old.id;

  return v_row;
end;
$body$;

-- ---------- the hold copies the flags ----------
-- 045's body, with the flags read from the position that stands at the source frame and written at the target. A hold
-- of an off-site group stays off site -- otherwise the hold would plant an on-site row at a coordinate nobody
-- walked to, which is exactly the lie plan_check now ignores.
create or replace function public.frame_hold(
  p_plan uuid,
  p_frame uuid,
  p_seconds integer,
  p_groups uuid[] default null
)
returns table (
  held_frame_id uuid,
  held_t_s integer,
  frames_added integer,
  frames_reused integer,
  positions_written integer,
  groups_held integer
)
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_src public.plan_frames;
  v_target integer;
  v_frame uuid;
  v_group uuid;
  v_name text;
  v_groups uuid[] := '{}';
  -- The groups that still need a row at the target: everything named, minus the ones already standing exactly
  -- there, flags included. Keeping the two lists apart is what makes a second click on Hold say "already there"
  -- instead of bumping a revision for nothing.
  v_need uuid[] := '{}';
  v_lat float8[] := '{}';
  v_lng float8[] := '{}';
  v_state text[] := '{}';
  v_verify text[] := '{}';
  v_lat_one float8;
  v_lng_one float8;
  v_state_one text;
  v_verify_one text;
  v_have_lat float8;
  v_have_lng float8;
  v_have_state text;
  v_have_verify text;
  v_at_target boolean;
  v_between_s integer;
  v_i integer;
  v_max_s constant integer := 86400 * 3;
begin
  frames_added := 0;
  frames_reused := 0;
  positions_written := 0;
  groups_held := 0;

  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;

  select * into v_src from public.plan_frames where id = p_frame and plan_id = p_plan;
  if not found then
    raise exception 'That frame is not in this plan.' using errcode = '42501';
  end if;

  if p_seconds is null or p_seconds <= 0 then
    raise exception 'A hold runs forward: say how many seconds the group stays put.' using errcode = '22023';
  end if;
  v_target := v_src.t_s + p_seconds;
  if v_target > v_max_s then
    raise exception 'A plan stops three days after T+0. That would push a frame past the end.' using errcode = '22023';
  end if;

  -- ---------- which groups ----------
  -- No list means "everyone standing at this frame": the planner pressed Hold without ticking anybody, and holding
  -- the whole event where it is -- a rain delay, a late start -- is a real thing to ask for. A ticked group narrows
  -- it, which is how the board offers a single group.
  if p_groups is null or cardinality(p_groups) = 0 then
    for v_group in
      select g.id
        from public.groups g
       where g.event_id = v_event
         and exists (
           select 1
             from public.plan_positions p
             join public.plan_frames f on f.id = p.frame_id
            where f.plan_id = p_plan and p.group_id = g.id and f.t_s <= v_src.t_s)
       order by g.name
    loop
      v_groups := v_groups || v_group;
    end loop;
    if cardinality(v_groups) = 0 then
      raise exception 'Nothing to hold: no group stands at or before % yet.', public.plan_clock(v_src.t_s)
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

  -- The frame that is already there. Its id is reused; the positions are what may need writing.
  select f.id into v_frame from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_target;

  -- ---------- where each group is, and whether a hold there tells the truth ----------
  foreach v_group in array v_groups loop
    select g.name into v_name from public.groups g where g.id = v_group;

    select p.lat, p.lng, p.state, p.verify into v_lat_one, v_lng_one, v_state_one, v_verify_one
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = p_plan and p.group_id = v_group and f.t_s <= v_src.t_s
     order by f.t_s desc
     limit 1;
    if not found then
      raise exception '% stands nowhere at or before % to hold.', v_name, public.plan_clock(v_src.t_s)
        using errcode = '22023';
    end if;

    -- A statement in between is a decision: the group moves there. Holding would add a return trip rather than a
    -- delay, so the sentence points at the frame the hold should have started from.
    select f.t_s into v_between_s
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = p_plan and p.group_id = v_group
       and f.t_s > v_src.t_s and f.t_s < v_target
     order by f.t_s
     limit 1;
    if found then
      raise exception '% moves before %: it is somewhere else at %. Hold from that frame, or push those frames later first.',
        v_name, public.plan_clock(v_target), public.plan_clock(v_between_s)
        using errcode = '22023';
    end if;

    v_at_target := false;
    if v_frame is not null then
      select p.lat, p.lng, p.state, p.verify into v_have_lat, v_have_lng, v_have_state, v_have_verify
        from public.plan_positions p
       where p.frame_id = v_frame and p.group_id = v_group;
      if found then
        if v_have_lat <> v_lat_one or v_have_lng <> v_lng_one then
          raise exception '% already stands somewhere else at %. Hold for a shorter time, or move that position first.',
            v_name, public.plan_clock(v_target)
            using errcode = '22023';
        end if;
        -- Already said, exactly here, the same way: nothing to write for this group.
        if v_have_state = v_state_one and v_have_verify = v_verify_one then
          v_at_target := true;
        end if;
      end if;
    end if;

    v_lat := v_lat || v_lat_one;
    v_lng := v_lng || v_lng_one;
    v_state := v_state || v_state_one;
    v_verify := v_verify || v_verify_one;
    if not v_at_target then
      v_need := v_need || v_group;
    end if;
  end loop;

  groups_held := cardinality(v_groups);
  held_t_s := v_target;

  if cardinality(v_need) = 0 then
    held_frame_id := v_frame;
    return next;
    return;
  end if;

  -- ---------- the frame, then only the rows the hold is about ----------
  if v_frame is null then
    insert into public.plan_frames (plan_id, event_id, t_s, created_by)
    values (p_plan, v_event, v_target, auth.uid())
    returning id into v_frame;
    frames_added := 1;
  else
    update public.plan_frames f
       set rev = f.rev + 1, updated_by = auth.uid(), updated_at = now()
     where f.id = v_frame;
    frames_reused := 1;
  end if;

  for v_i in 1 .. cardinality(v_groups) loop
    if v_need @> array[v_groups[v_i]] then
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
      values (v_frame, p_plan, v_event, v_groups[v_i], v_lat[v_i], v_lng[v_i], v_state[v_i], v_verify[v_i])
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng, state = excluded.state, verify = excluded.verify;
      positions_written := positions_written + 1;
    end if;
  end loop;

  update public.plans set updated_at = now() where id = p_plan;

  held_frame_id := v_frame;
  return next;
end;
$body$;

comment on function public.frame_hold(uuid, uuid, integer, uuid[]) is
  'State the named groups again, where they already stand (flags included), at a later moment: the strip''s "hold one group" (045, flags 046).';
