-- 044_frame_shift_range.sql
--
-- Step 6 of the planning plan: push a chunk.
--
-- 038's frame_shift moved every frame at or after a given time. That is the "we are five minutes behind, push the
-- rest of the run" operation, and it is the wrong shape for the gesture the board is built around: an animation
-- timeline, where you select a few frames, drag them along the scrollbar, and everything outside the selection
-- stays exactly where it was. So the function gains p_to_s: name both ends of the stretch and only the frames
-- between them move. Leave it null and nothing has changed -- everything at or after p_from_s still travels.
--
-- A BOUNDED SHIFT IS NOT A RIPPLE. The frames after the stretch do not make room, so a chunk pushed far enough
-- passes over a frame that is staying put: 0/60/120/180 with 60..120 pushed by +300 becomes 0/180/360/420. That
-- is allowed on purpose, and it is what the plan's own Done-when asks for. The strip is ordered by time, not by
-- an index, so two moments swapping order is a legal edit -- and whether the new order is walkable is exactly
-- what plan_check (and the board's red dots) answer. What is refused is landing *exactly* on a frame that stays
-- put: that is a collision, not a reordering.
--
-- THE CEILING. plan_frames_t_range allows t_s from 0 to 86400 * 3 -- three days. The floor was guarded from 038;
-- the ceiling was not, so a shift or a move past it came back as a raw check-constraint violation raised from the
-- middle of an UPDATE, which reaches the planner as a sentence about a constraint name. frame_shift, frame_move
-- and frame_save all name the limit here, so no path can produce it. This is the "the t_s ceiling (currently
-- unguarded)" line of step 6, taken to every function that writes a time rather than only the one the step named.
--
-- AND "0 FRAMES MOVED". A stretch that holds no frame now says so instead of returning 0: at the other end of the
-- wire a count of zero is indistinguishable from a shift that worked.

-- The signature changes (a fourth argument), so this is a drop and a create rather than a replace. The drop takes
-- the grants with it, which is why the revoke/grant pair at the bottom is not optional: this schema's default
-- privileges hand every new function an EXECUTE to anon, and 042 learned that the hard way (043).
drop function if exists public.frame_shift(uuid, integer, integer);

create or replace function public.frame_shift(
  p_plan uuid,
  p_from_s integer,
  p_delta_s integer,
  p_to_s integer default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_first integer;   -- the earliest frame in the stretch, not the parameter: a stretch may start between frames
  v_last integer;    -- the latest
  v_count integer;
  v_max_s constant integer := 86400 * 3;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_from_s is null then
    raise exception 'Name the moment the stretch starts at.' using errcode = '22023';
  end if;
  if p_to_s is not null and p_to_s < p_from_s then
    raise exception 'That stretch ends before it starts.' using errcode = '22023';
  end if;
  if p_delta_s is null or p_delta_s = 0 then
    return 0;
  end if;

  select min(f.t_s), max(f.t_s)
    into v_first, v_last
    from public.plan_frames f
   where f.plan_id = p_plan
     and f.t_s >= p_from_s
     and (p_to_s is null or f.t_s <= p_to_s);
  if v_first is null then
    raise exception 'There is no frame in that stretch to move.' using errcode = '22023';
  end if;

  -- The whole chunk moves rigidly, so only its two ends can leave the allowed range.
  if v_first + p_delta_s < 0 then
    raise exception 'That would push a frame before T+0.' using errcode = '22023';
  end if;
  if v_last + p_delta_s > v_max_s then
    raise exception 'A plan stops three days after T+0. That would push a frame past the end.' using errcode = '22023';
  end if;

  -- Moving the whole tail later can never land on a frame that stays put; moving earlier can, and so can a bounded
  -- chunk crossing a neighbour. Say it plainly rather than letting the deferred unique constraint surface from
  -- inside the update.
  if exists (
    select 1
      from public.plan_frames f
      join public.plan_frames g
        on g.plan_id = f.plan_id and g.t_s = f.t_s + p_delta_s
     where f.plan_id = p_plan
       and f.t_s >= p_from_s
       and (p_to_s is null or f.t_s <= p_to_s)
       and not (g.t_s >= p_from_s and (p_to_s is null or g.t_s <= p_to_s))
  ) then
    raise exception 'Those frames would land on a frame that is staying put. Shift the whole stretch instead.'
      using errcode = '22023';
  end if;

  update public.plan_frames
     set t_s = t_s + p_delta_s, rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where plan_id = p_plan
     and t_s >= p_from_s
     and (p_to_s is null or t_s <= p_to_s);

  get diagnostics v_count = row_count;
  update public.plans set updated_at = now() where id = p_plan;
  return v_count;
end;
$body$;

-- ---------- the ceiling, in the two functions that write one time ----------
-- Same bodies as they stand *now*, with the upper bound added -- and "as they stand now" is the point. 041 had
-- already rewritten frame_save to honour a client-supplied id on create, so taking the body from 038 (where the
-- function was born) quietly reverted it, and dev/checks/step4-frame-id.sql caught it on the next run: "That frame
-- is not in this plan." A function copied from the file that introduced it is a function copied from the past.
-- frame_move is unchanged since 038 (040 only revoked its grants), and here it only gains the bound.

create or replace function public.frame_move(p_id uuid, p_t_s integer, p_rev integer)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_row public.plan_frames;
begin
  select * into v_row from public.plan_frames where id = p_id for update;
  if not found then
    raise exception 'That frame does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_row.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_rev is not null and p_rev <> v_row.rev then
    raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
  end if;
  if p_t_s is null or p_t_s < 0 then
    raise exception 'A frame cannot sit before T+0.' using errcode = '22023';
  end if;
  if p_t_s > 86400 * 3 then
    raise exception 'A plan stops three days after T+0. That would push a frame past the end.' using errcode = '22023';
  end if;
  if exists (select 1 from public.plan_frames f where f.plan_id = v_row.plan_id and f.t_s = p_t_s and f.id <> p_id) then
    raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(p_t_s)
      using errcode = '22023';
  end if;
  update public.plan_frames
     set t_s = p_t_s, rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_id
  returning * into v_row;
  update public.plans set updated_at = now() where id = v_row.plan_id;
  return v_row;
end;
$body$;

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
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
      values (v_row.id, p_plan, v_event, v_group_text::uuid,
              (v_point ->> 'lat')::float8, (v_point ->> 'lng')::float8)
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng;
    end loop;
  end if;

  update public.plans set updated_at = now() where id = p_plan;
  return v_row;
end;
$body$;

-- ---------- grants ----------
-- An explicit grant to authenticated, and the anon grant the default privileges add taken back off. The new
-- signature is what matters: the old one went with the drop.
revoke execute on function public.frame_shift(uuid, integer, integer, integer) from public, anon;
grant execute on function public.frame_shift(uuid, integer, integer, integer) to authenticated;
