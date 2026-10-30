-- 047_frame_verify.sql
--
-- Step 10 of the planning plan: the board for state and verification, with bulk toggles.
--
-- ONE BATCH FUNCTION FOR THE FLAG THAT CAN BE PATCHED IN PLACE. `verify` says how much the app may trust a position
-- it already has: `auto` is trusted as drawn, `manual` is "somebody has to confirm this". Confirming a position does
-- not move it, so the write is a flag on the rows that exist -- not a new statement. That is why this function
-- patches rows and never creates them: a frame that does not state a group has no position of its own to confirm,
-- and inventing one (a copy of the inherited position) would turn "same" into "set" all over the plan for a change
-- that did not touch the geometry. The cells it cannot write are counted and returned, so the board can say
-- "4 of 6" rather than pretend.
--
-- WHY A BATCH AND NOT A LOOP OF SAVES. `frame_save` replaces a frame's positions wholesale and needs that frame's
-- live revision; four frames times six groups as individual saves is twenty-four round trips, each followed by a
-- reload, and any of them can lose a race against another planner. Naming the frames and the groups once is one
-- transaction, and a frame whose revision moved under us is simply updated -- the caller is not replacing a payload,
-- it is setting one flag on rows that are still there.
--
-- A REVISION MOVES ONLY WHEN SOMETHING CHANGED. A frame that gains a flag has changed, so its rev is bumped once
-- (not once per row), and a caller holding the old copy is told to reload before overwriting it. A call that sets
-- every named row to the value it already had writes nothing, bumps nothing and answers 0 -- twice is once, the
-- same rule `frame_hold` applies to "already there".
--
-- WHO MAY CALL IT: root or planner, checked against the plan's own event, like every other plan write. The doors
-- are re-declared at the bottom because this schema's default privileges hand every new function an EXECUTE to
-- `anon` directly; revoking from PUBLIC alone is not enough (finding 20, and 043 cleaning up after 042).

create or replace function public.frame_set_verify(
  p_plan uuid,
  p_frames uuid[],
  p_groups uuid[] default null,
  p_verify text default null
)
returns table (
  frames_touched integer,
  positions_set integer,
  positions_skipped integer
)
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_verify text := nullif(p_verify, '');
  v_frames uuid[];
  v_groups uuid[];
  v_group uuid;
  v_missing integer;
  v_touched uuid[];
begin
  frames_touched := 0;
  positions_set := 0;
  positions_skipped := 0;

  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;

  -- The words, named here so a typo comes back as a sentence naming it rather than as plan_positions_verify_check
  -- raised from inside an UPDATE (044's lesson). An explicit null is not "leave it alone": it is a value nobody can
  -- act on, and this function has nothing else to do with a null.
  if v_verify is null then
    raise exception 'A position is confirmed automatically or by hand, not nothing.' using errcode = '22023';
  end if;
  if v_verify not in ('auto', 'manual') then
    raise exception 'A position is confirmed automatically or by hand, not %.', v_verify using errcode = '22023';
  end if;

  if p_frames is null then
    raise exception 'Name at least one frame to confirm.' using errcode = '22023';
  end if;
  select array_agg(distinct f) into v_frames from unnest(p_frames) as f where f is not null;
  if v_frames is null or cardinality(v_frames) = 0 then
    raise exception 'Name at least one frame to confirm.' using errcode = '22023';
  end if;

  -- Every frame must be this plan's. A frame from another plan would be a flag written on somebody else's work under
  -- a plan id that looks right, so it is refused rather than skipped.
  select count(*) into v_missing
    from unnest(v_frames) as f
   where not exists (select 1 from public.plan_frames pf where pf.id = f and pf.plan_id = p_plan);
  if v_missing > 0 then
    raise exception 'That frame is not in this plan.' using errcode = '42501';
  end if;

  if p_groups is null then
    -- No list means "every position these frames hold". Nothing is named, so nothing can be missing.
    select array_agg(distinct p.group_id) into v_groups
      from public.plan_positions p
     where p.plan_id = p_plan and p.frame_id = any(v_frames);
    v_groups := coalesce(v_groups, '{}');
  else
    select array_agg(distinct g) into v_groups from unnest(p_groups) as g where g is not null;
    v_groups := coalesce(v_groups, '{}');
    foreach v_group in array v_groups loop
      if not exists (select 1 from public.groups g where g.id = v_group and g.event_id = v_event) then
        raise exception 'That group belongs to another event.' using errcode = '42501';
      end if;
    end loop;
    -- The named cells with no row: frames that carry this group forward instead of stating it. Counted, not written.
    select count(*) into positions_skipped
      from unnest(v_frames) as f
      cross join unnest(v_groups) as g
     where not exists (select 1 from public.plan_positions p where p.frame_id = f and p.group_id = g);
  end if;

  if cardinality(v_frames) = 0 or cardinality(v_groups) = 0 then
    return next;
    return;
  end if;

  with changed as (
    update public.plan_positions p
       set verify = v_verify
     where p.plan_id = p_plan
       and p.frame_id = any(v_frames)
       and p.group_id = any(v_groups)
       -- Only the rows whose value is actually different: a row updated with the value it already holds would still
       -- be a new row version and would still bump the frame's revision for nothing.
       and p.verify is distinct from v_verify
    returning p.frame_id
  )
  select count(*), array_agg(distinct frame_id) into positions_set, v_touched from changed;

  if positions_set = 0 then
    frames_touched := 0;
    return next;
    return;
  end if;
  frames_touched := cardinality(v_touched);

  update public.plan_frames f
     set rev = f.rev + 1,
         updated_by = auth.uid(),
         updated_at = now()
   where f.id = any(v_touched);

  update public.plans set updated_at = now() where id = p_plan;

  return next;
end;
$body$;

comment on function public.frame_set_verify(uuid, uuid[], uuid[], text) is
  'Set verify on the positions these frames already hold for these groups; patch only, one rev per frame touched (047).';

-- R4: the schema''s default ACL grants every new function an EXECUTE to anon directly, so revoking from PUBLIC
-- alone leaves anon=X behind. Revoke from both, grant to authenticated.
revoke execute on function public.frame_set_verify(uuid, uuid[], uuid[], text) from public, anon;
grant execute on function public.frame_set_verify(uuid, uuid[], uuid[], text) to authenticated;
