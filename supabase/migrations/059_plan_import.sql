-- 059_plan_import.sql
--
-- Step 23: a whole plan, in from a sheet, or not at all.
--
-- WHY ONE FUNCTION AND NOT A LOOP IN THE BROWSER. A sheet replaces every moment of a plan: the old frames go, the new
-- ones arrive. Done from the client that is N deletes and N writes in N transactions, and a refusal at the ninth
-- frame -- a plan somebody else republished, a group that was deleted, a connection that drops -- leaves the planner
-- with eight frames of a plan that is no longer the one they exported. That is the same half-applied state step 25
-- refuses to let a drop produce, so the replacement is one transaction: any error, and nothing changed at all.
--
-- WHAT A SHEET IS. `p_frames` is an array of { t_s, note, positions }, the shape frame_save already takes, with
-- `positions` as a map from group id to { lat, lng, state, verify }. Those are the objects plan_frames_list returns,
-- so what the client read out of a file and what it read out of the database are the same two shapes and neither
-- needs translating.
--
-- WHY IT CALLS frame_save RATHER THAN INSERTING. frame_save owns every rule a frame has: the time's range, "there is
-- already a frame at ...", the two words a position's flags may take, a group that belongs to another event, and the
-- ownership of a client-supplied id. Repeating those INSERTs here would be a second copy of the rules -- and the next
-- fix to one of them would forget this one (R8). The loop costs one call per frame, and every call is inside the same
-- transaction, so its refusals roll the whole import back.
--
-- WHAT A SHEET MAY NOT ERASE: WHAT HAPPENED. plan_progress rows hang off frame ids with `on delete cascade` (050),
-- because a mark about a moment that no longer exists is a timetable disagreeing with itself. That is right for a
-- planner deleting one frame by hand and wrong for a bulk replace: importing over a plan somebody has already marked
-- would silently delete the record of the night. So a plan with any progress rows is refused, in words that say what
-- to do instead. A sheet imported into a plan nobody has marked -- a draft, a fresh copy, the plan for a walk that has
-- not happened -- is unaffected.
--
-- WHAT THIS FUNCTION DOES NOT CHECK, deliberately:
--   * the 25 m rule. The client refuses a sheet before it calls this, in the board's own sentence (gapDetail), and the
--     database's gate on a broken walk is still plan_check at publish. A third copy here would refuse a sheet twice
--     in two wordings, and step 23's proof is that the refusal says exactly what the board says.
--   * the locked polygons and pace. plan_check reports those on the board as warnings, exactly as if the walk had been
--     drawn by hand, because they are planning questions (move the time, add the waypoint) and not file errors.
--   * the file's shape beyond what makes a readable sentence. The client's reader reports the row number and the
--     mistake; this only has to stop a direct caller pushing garbage into the tables.
--
-- THE PLAN'S REVISION DOES NOT MOVE. Content changes never do: 038's frame functions touch updated_at and nothing
-- else. The revision is what people are following (step 15), and a publish is the only thing that announces a new
-- one. A sheet imported into the live plan therefore changes what the board shows without telling anybody -- the same
-- as editing that plan by hand, and the confirm in front of the import says so.
--
-- R1: everything qualified, search_path pinned to public (frames and groups are both there). R4: revoked from public
-- and anon, granted to authenticated only.

create or replace function public.plan_import(p_plan uuid, p_frames jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_frame jsonb;
  v_t text;
  v_frames integer := 0;
  v_positions integer := 0;
  v_progress integer;
  v_seen text[] := '{}';
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if p_frames is null or jsonb_typeof(p_frames) <> 'array' then
    raise exception 'A sheet is a list of frames.' using errcode = '22023';
  end if;

  -- What actually happened is not the sheet's to erase (050). Counted before anything is deleted, so the sentence is
  -- the first thing the caller hears.
  select count(*) into v_progress from public.plan_progress pp where pp.plan_id = p_plan;
  if v_progress > 0 then
    raise exception 'This plan already has what actually happened at % moment%, and a sheet replaces every moment. Copy the plan and import into the copy.',
      v_progress, case when v_progress = 1 then '' else 's' end using errcode = '22023';
  end if;

  -- Shape, times and uniqueness said as sentences rather than as 22P02 or plan_frames_unique_time. Everything about a
  -- position is frame_save's to judge, in its own words, below.
  for v_frame in select value from jsonb_array_elements(p_frames) loop
    if jsonb_typeof(v_frame) <> 'object' then
      raise exception 'A sheet is a list of frames, and one of them is not a frame.' using errcode = '22023';
    end if;
    v_t := v_frame ->> 't_s';
    if v_t is null or v_t !~ '^[0-9]+$' then
      raise exception 'A frame needs a time in whole seconds from T+0.' using errcode = '22023';
    end if;
    if v_t::int > 86400 * 3 then
      raise exception 'A plan stops three days after T+0. That would push a frame past the end.' using errcode = '22023';
    end if;
    if v_t = any (v_seen) then
      raise exception 'This sheet has two frames at %.', public.plan_clock(v_t::int) using errcode = '22023';
    end if;
    v_seen := v_seen || v_t;
    if v_frame ? 'positions' and jsonb_typeof(v_frame -> 'positions') not in ('object', 'null') then
      raise exception 'The positions of a frame are a map from group to place.' using errcode = '22023';
    end if;
  end loop;

  -- Replace, in this order, inside this transaction: the moments the plan had are gone before the first new one is
  -- written, so a frame whose time the old plan already used is not a collision. Positions and progress go with the
  -- frames by cascade; progress was refused above, so there is none.
  delete from public.plan_frames f where f.plan_id = p_plan;

  for v_frame in select value from jsonb_array_elements(p_frames) order by (value ->> 't_s')::int loop
    perform public.frame_save(p_plan, jsonb_build_object(
      't_s', (v_frame ->> 't_s')::int,
      'note', coalesce(v_frame ->> 'note', ''),
      'positions', coalesce(v_frame -> 'positions', '{}'::jsonb)
    ));
    v_frames := v_frames + 1;
  end loop;

  -- Counted from the table rather than from the sheet: what the caller is told is what was written, including a
  -- position a frame's map repeated (nothing does) and excluding one frame_save refused (it cannot have).
  select count(*) into v_positions
    from public.plan_positions pp
    join public.plan_frames f on f.id = pp.frame_id
   where f.plan_id = p_plan;

  -- frame_save touches this per frame, but a sheet with no frames would otherwise leave no trace for the other tabs
  -- (055's channel listens to plans). One row, and the board's own read comes back to it.
  update public.plans p set updated_at = now() where p.id = p_plan;

  return jsonb_build_object('frames', v_frames, 'positions', v_positions);
end;
$body$;

comment on function public.plan_import(uuid, jsonb) is
  'Replaces every frame of a plan with a sheet, in one transaction (step 23). Refuses a plan that has recorded what '
  'actually happened, because the marks hang off the frames and would cascade away.';

revoke all on function public.plan_import(uuid, jsonb) from public, anon;
grant execute on function public.plan_import(uuid, jsonb) to authenticated;
