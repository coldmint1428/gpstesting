-- 045_frame_hold.sql
--
-- Step 7 of the planning plan: hold one group.
--
-- WHAT A HOLD IS, IN A STRIP OF FRAMES. A group "moves" between two frames that state it and stays put everywhere
-- else. So to hold a group is to state it again, at a later moment, in the place it already stands: +0:00 says the
-- crew is by the gate, +10:00 says it again, and the walk to the stage now begins at +10:00 instead of at the moment
-- it was drawn at. That is the spec's "hold one group; rewrite that group's future spans so its next move happens
-- later", expressed in the only vocabulary this plan has -- frames and positions.
--
-- WHY A FUNCTION AND NOT frame_save. frame_save replaces a frame's positions *wholesale* when `positions` is
-- present: it deletes every group the payload does not mention. Writing the hold through it would therefore either
-- state every group again at the later moment (the hold is about one group) or wipe the ones that frame already
-- says. The hold has to be a partial write -- add these groups, touch nothing else -- and that is a shape only the
-- server can promise. It is also one call for N groups instead of N, and it answers with what it did.
--
-- THE TWO RULES IT INHERITS FROM 042 (that is the "needs 5" of the plan):
--   * The position it writes is the one that *stands* at the source frame -- the last thing the group said at or
--     before it -- not the frame's own row. A hold asked for at a frame that inherits the position has to use the
--     inherited one, because that is what the planner is looking at on the map.
--   * A frame that already exists at the wanted moment is REUSED, never duplicated: its note and every other
--     group's position stay, and only its rev is bumped, because a frame that gains a position has changed.
--
-- WHAT IT REFUSES, AND WHY EACH IS A DECISION RATHER THAN A FAILURE:
--   * A group that stands nowhere at or before the frame. There is no position to hold, and inventing one would be
--     a placement the planner did not make.
--   * A group that moves before the wanted moment: if it is stated somewhere between the source and the target,
--     the hold would contradict that statement and draw a return trip (a 72 m jump back in Push bench's case).
--     The sentence names the frame it moves at, because the fix is to hold from there -- or to push those frames
--     later first, which is step 6's operation.
--   * A frame at the wanted moment that already states this group somewhere ELSE. That position is somebody's
--     decision; overwriting it silently is exactly what 042 refuses to do to a position in the middle of a stretch.
--     Saying so ("Hold for a shorter time, or move that position first") leaves the choice with the planner.
--   * A target past the t_s ceiling (three days), named as a limit rather than arriving as plan_frames_t_range
--     from inside an INSERT (044).
--
-- THE INVARIANT WORTH KNOWING: a hold cannot make the 25 m rule worse. With no statement in between, the old hop
-- P -> N becomes P -> P (zero metres) plus P -> N (unchanged), so plan_check reports the same breaks it did before.
-- The check asserts that over a plan that already has one, rather than trusting the argument.
--
-- WHO MAY CALL IT: root or planner, the same rule as every other plan write (038). The ACL is stated at the bottom,
-- revoking PUBLIC *and* anon: this schema's default privileges hand every new function an EXECUTE to anon directly,
-- which 042 got wrong and 043 fixed.

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
  -- there. Keeping the two lists apart is what makes a second click on Hold say "already there" instead of
  -- bumping a revision for nothing.
  v_need uuid[] := '{}';
  v_lat float8[] := '{}';
  v_lng float8[] := '{}';
  v_lat_one float8;
  v_lng_one float8;
  v_have_lat float8;
  v_have_lng float8;
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

    select p.lat, p.lng into v_lat_one, v_lng_one
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
      select p.lat, p.lng into v_have_lat, v_have_lng
        from public.plan_positions p
       where p.frame_id = v_frame and p.group_id = v_group;
      if found then
        if v_have_lat <> v_lat_one or v_have_lng <> v_lng_one then
          raise exception '% already stands somewhere else at %. Hold for a shorter time, or move that position first.',
            v_name, public.plan_clock(v_target)
            using errcode = '22023';
        end if;
        -- Already said, exactly here: nothing to write for this group.
        v_at_target := true;
      end if;
    end if;

    v_lat := v_lat || v_lat_one;
    v_lng := v_lng || v_lng_one;
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
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
      values (v_frame, p_plan, v_event, v_groups[v_i], v_lat[v_i], v_lng[v_i])
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng;
      positions_written := positions_written + 1;
    end if;
  end loop;

  update public.plans set updated_at = now() where id = p_plan;

  held_frame_id := v_frame;
  return next;
end;
$body$;

-- Every new function gets an EXECUTE for anon from the schema's default privileges, so revoking PUBLIC alone would
-- leave anon=X behind (042 did exactly that; 043 fixed it). Both, every time.
revoke execute on function public.frame_hold(uuid, uuid, integer, uuid[]) from public, anon;
grant execute on function public.frame_hold(uuid, uuid, integer, uuid[]) to authenticated;

comment on function public.frame_hold(uuid, uuid, integer, uuid[]) is
  'State the named groups again, where they already stand, at a later moment: the strip''s "hold one group" (045).';
