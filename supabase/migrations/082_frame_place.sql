-- 082_frame_place.sql
--
-- Concurrent editing on the plan board, step 2: a badge is written on its own.
--
-- THE ROW THAT WAS SHARED. 081 explained the collision and left it standing: frame_save() replaces a frame's whole
-- position map, so Priya dragging Gate Crew sends Stage back exactly as she read it, and whatever Daniel moved in
-- between is overwritten -- silently, with no revision and no error. A lock on Gate Crew cannot help while the
-- write still carries Stage along with it. This file removes the carrying.
--
-- THE UNIT IS THE CELL. frame_place() writes one (frame, group): lat, lng, state, verify. It touches one row and
-- nothing else in the plan, which is the whole reason two planners can work at one moment on different groups.
-- frame_place_many() is one gesture -- a drag with three badges ticked, a bulk "off site" -- in one call and one
-- transaction, all or nothing. frame_unplace() removes a position, and is the ONLY way one disappears: after this
-- file no payload can say "this frame states nobody" and take rows with it.
--
-- A LOCK IS WHAT THE WRITE IS CHECKED AGAINST, not merely asked for. Every door here requires a live hold on every
-- cell it writes, from the session it was told about. A refusal is 081's PT423 with 081's sentences, so a planner
-- reads "Priya is editing Gate Crew at +1:00" whether it was the grab that was refused or the write that arrived
-- after the hold had gone. The client in this phase takes the hold immediately before the write and puts it down
-- after it; holding one for the length of a gesture is phase 3.
--
-- A CELL WRITE DOES NOT BUMP plan_frames.rev. rev is the frame's METADATA version now -- its time and its note.
-- Bumping it on every badge move would hand the next planner a stale-revision refusal for a note they had nothing
-- to do with, which is exactly the message this feature exists to delete. The board is told to reload by
-- plans.updated_at (055's channel), and every door here touches that once per call, never once per cell.
--
-- A NEW FRAME'S FIRST CELLS ARE STILL FRAME_SAVE'S. frame_save keeps writing `positions` when it INSERTS the
-- frame, and refuses them when the frame already exists. That is not a leftover: a frame that did not exist one
-- statement ago cannot have somebody else's badge standing on it, so the wholesale map has nothing to lose there
-- -- it is that moment's first cells. It is also what keeps plan_import() working without touching it (059 writes
-- one frame_save per frame of a sheet, and it deletes every frame first, so every one of them is a create), and
-- the undo stack's restore, which is 041's "the same frame comes back with its own id". A frame that is already in
-- the plan refuses a payload in so many words, because a page old enough to send one is old enough to lose a
-- colleague's work with it.
--
-- AND THE MOMENT. frame_save takes an optional session now. Given one, and on a frame that already exists, the
-- frame lock (081) must be that session's: the moment is the second resource, keyed by frame_id, and it is what
-- two people retiming the same moment contend for. Without a session the rev check is the only guard, which is
-- exactly what every caller had before this file -- plan_import has no page to offer a session from, and an
-- internal caller should not be given a credential it does not have.
--
-- WHAT THIS FILE DOES NOT DO. frame_hold() (045, 067), frames_fill() (042) and frame_set_verify() (047) still
-- write positions inside their own bodies, without a hold. A hold copies one group's coordinates to a later
-- moment, so on a target frame somebody else has open it can still write over a badge being dragged there; a grid
-- of confirmations can still set a flag on a cell being dragged. Neither is a whole-map write any more, and 083 is
-- where both meet the same rule. Said here rather than discovered later.

-- ============================================================
-- 1. The cells a gesture names, with their places.
--
--    The same shape plan_lock_cells() takes (081's plan_cell_list: {frame, group}) with lat, lng, state and
--    verify added, so one list can be held and then written without the page translating between two spellings.
--    A number is required and a word is optional: an omitted flag means "as it was" on a row that already stands
--    and the old default on one that does not (046's rule, which is what stops a drag putting an off-site group
--    back on the map).
-- ============================================================
drop function if exists public.plan_cell_points(jsonb);
create function public.plan_cell_points(p_cells jsonb)
returns table (frame_id uuid, group_id uuid, lat float8, lng float8, state text, verify text)
language plpgsql immutable set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_item jsonb;
  v_frame text;
  v_group text;
  -- The canonical uuid spelling, as 081 has it: a typo comes back as a sentence about the board, not about a type.
  v_ok constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  if p_cells is null or jsonb_typeof(p_cells) <> 'array' then
    raise exception 'Name the badges as a list.' using errcode = '22023';
  end if;
  -- Unlike plan_cell_list, an empty list is refused: every caller of this is mid-gesture, and a gesture that
  -- names nothing is a bug in the page rather than a no-op.
  if jsonb_array_length(p_cells) = 0 then
    raise exception 'Name at least one badge.' using errcode = '22023';
  end if;

  for v_item in select e.value from jsonb_array_elements(p_cells) e loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'That is not a badge on this board.' using errcode = '22023';
    end if;
    v_frame := v_item ->> 'frame';
    v_group := v_item ->> 'group';
    if v_frame is null or v_frame !~ v_ok or v_group is null or v_group !~ v_ok then
      raise exception 'That is not a badge on this board.' using errcode = '22023';
    end if;
    -- coalesce because jsonb_typeof() of a key that is not there is NULL, and NULL <> 'number' is not true.
    if coalesce(jsonb_typeof(v_item -> 'lat'), '') <> 'number'
       or coalesce(jsonb_typeof(v_item -> 'lng'), '') <> 'number' then
      raise exception 'A badge needs a place on the map.' using errcode = '22023';
    end if;
    frame_id := v_frame::uuid;
    group_id := v_group::uuid;
    lat := (v_item ->> 'lat')::float8;
    lng := (v_item ->> 'lng')::float8;
    -- An empty string is the page saying "I have nothing to say about this flag", the same as leaving it out.
    state := nullif(v_item ->> 'state', '');
    verify := nullif(v_item ->> 'verify', '');
    return next;
  end loop;
end;
$body$;

-- ============================================================
-- 2. Every named cell must be this plan's, and mine to write.
--
--    The two checks are in this order on purpose. Scope first, so a stale page asking about a frame somebody
--    deleted is told "that frame is not in this plan" rather than "this badge stopped being yours"; then the
--    hold, so a write is never made against a cell somebody else has.
--
--    "Mine" is the same rule 081's steal and listing use -- last_seen inside 7 s and expires_at in the future --
--    because a hold that can be stolen is not a hold, and a write checked against a longer one would land in a
--    cell the next grab can already take. A row that is mine but has lapsed is not a refusal by somebody else,
--    and the two sentences are different: one names a person, the other says to try again.
-- ============================================================
drop function if exists public.plan_require_cell_holds(uuid, jsonb, uuid);
create function public.plan_require_cell_holds(p_plan uuid, p_cells jsonb, p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_event uuid;
  v_steal constant interval := interval '7 seconds';
  v_bad record;
  v_missing integer;
  v_name text;
  v_group_name text;
  v_t_s integer;
  v_mine boolean;
begin
  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  select p.event_id into v_event from public.plans p where p.id = p_plan;

  -- Every named cell must be a cell of THIS plan, before anything is read from the lock table: a lock row on
  -- another plan's frame cannot match p_plan anyway, and the sentence should say so.
  for v_bad in
    select c.frame_id, c.group_id,
           not exists (select 1 from public.plan_frames f where f.id = c.frame_id and f.plan_id = p_plan)
             as bad_frame,
           not exists (select 1 from public.groups g where g.id = c.group_id and g.event_id = v_event)
             as bad_group
      from public.plan_cell_list(p_cells) c
  loop
    if v_bad.bad_frame then
      raise exception 'That frame is not in this plan.' using errcode = '42501';
    end if;
    if v_bad.bad_group then
      raise exception 'That group belongs to another event.' using errcode = '42501';
    end if;
  end loop;

  select count(*) into v_missing
    from (select distinct c.frame_id, c.group_id from public.plan_cell_list(p_cells) c) w
   where not exists (
     select 1 from public.plan_cell_locks l
      where l.plan_id = p_plan
        and l.frame_id = w.frame_id
        and l.group_id = w.group_id
        and l.session_id = p_session
        and l.expires_at > now()
        and l.last_seen > now() - v_steal);

  if v_missing = 0 then
    return;
  end if;

  -- Who is in the way, earliest moment first, exactly as a refused grab names them.
  select coalesce(pr.display_name, 'Somebody'), g.name, f.t_s, (l.user_id = auth.uid())
    into v_name, v_group_name, v_t_s, v_mine
    from (select distinct c.frame_id, c.group_id from public.plan_cell_list(p_cells) c) w
    join public.plan_frames f on f.id = w.frame_id
    join public.groups g on g.id = w.group_id
    join public.plan_cell_locks l on l.frame_id = w.frame_id and l.group_id = w.group_id
    left join public.profiles pr on pr.id = l.user_id
   where l.plan_id = p_plan
     and l.session_id <> p_session
     and l.expires_at > now()
     and l.last_seen > now() - v_steal
   order by f.t_s, g.name
   limit 1;

  if v_name is not null then
    if v_mine then
      raise exception 'This badge is open in another of your windows (%, %). Take it over to edit here.',
        v_group_name, public.plan_clock(v_t_s)
        using errcode = 'PT423';
    end if;
    raise exception '% is editing % at %.', v_name, v_group_name, public.plan_clock(v_t_s)
      using errcode = 'PT423';
  end if;

  -- Nobody blocks it: my own hold has lapsed (the write took longer than 12 s, or the page let go a moment
  -- early). Nothing has happened, and the honest instruction is to try again, not to name a person.
  raise exception 'This badge stopped being yours to edit. Try again.' using errcode = 'PT423';
end;
$body$;

-- ============================================================
-- 3. Writing one cell.
--
--    The single place a position is written, after this file, except for frame_save's create. It takes no lock
--    of its own: the two callers that face a page check the hold first (section 4 and 5) and frame_save's create
--    cannot need one, because the frame did not exist a statement ago.
--
--    The words are named here rather than left to the table's check constraints (046's lesson), and an omitted
--    flag means "as it was": the conflict branch reads the stored value, which is what makes a drag that carries
--    only a coordinate leave an off-site group off site and a hand-confirmed position confirmed.
-- ============================================================
drop function if exists public.plan_place_cell(uuid, uuid, uuid, float8, float8, text, text);
create function public.plan_place_cell(
  p_plan uuid,
  p_frame uuid,
  p_group uuid,
  p_lat float8,
  p_lng float8,
  p_state text default null,
  p_verify text default null
)
returns void
language plpgsql security definer set search_path = ''
as $body$
declare
  v_event uuid;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if v_event is null then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.plan_frames f where f.id = p_frame and f.plan_id = p_plan) then
    raise exception 'That frame is not in this plan.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.groups g where g.id = p_group and g.event_id = v_event) then
    raise exception 'That group belongs to another event.' using errcode = '42501';
  end if;

  if p_lat is null or p_lng is null then
    raise exception 'A badge needs a place on the map.' using errcode = '22023';
  end if;
  if p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    raise exception 'That is not a place on the map.' using errcode = '22023';
  end if;

  if p_state is not null and p_state not in ('on_site', 'off_site') then
    raise exception 'A position is either on site or off site, not %.', p_state using errcode = '22023';
  end if;
  if p_verify is not null and p_verify not in ('auto', 'manual') then
    raise exception 'A position is confirmed automatically or by hand, not %.', p_verify using errcode = '22023';
  end if;

  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
  values (p_frame, p_plan, v_event, p_group, p_lat, p_lng,
          coalesce(p_state, 'on_site'), coalesce(p_verify, 'auto'))
  on conflict (frame_id, group_id) do update
     set lat = excluded.lat,
         lng = excluded.lng,
         -- Not excluded.state: an omitted flag is "as it was", and excluded would put the default back.
         state = coalesce(p_state, plan_positions.state),
         verify = coalesce(p_verify, plan_positions.verify);
end;
$body$;

-- ============================================================
-- 4. Placing a badge, and placing a gesture's worth of them.
--
--    p_cells is section 1's list. The many-form exists because a drag with three groups ticked is ONE statement a
--    planner made, and because "all or nothing" has to be one call: a loop of single places would leave two of
--    three written when the third is somebody else's.
-- ============================================================
drop function if exists public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text);
create function public.frame_place(
  p_plan uuid,
  p_frame uuid,
  p_group uuid,
  p_session uuid,
  p_lat float8,
  p_lng float8,
  p_state text default null,
  p_verify text default null
)
returns public.plan_positions
language plpgsql security definer set search_path = ''
as $body$
declare
  v_row public.plan_positions;
begin
  perform public.plan_require_editor(p_plan);
  -- The same JSON shape the grab and the write use, so the refusal is the grab's refusal.
  perform public.plan_require_cell_holds(
    p_plan,
    jsonb_build_array(jsonb_build_object('frame', p_frame::text, 'group', p_group::text)),
    p_session);
  perform public.plan_place_cell(p_plan, p_frame, p_group, p_lat, p_lng, p_state, p_verify);
  update public.plans set updated_at = now() where id = p_plan;
  select * into v_row from public.plan_positions where frame_id = p_frame and group_id = p_group;
  return v_row;
end;
$body$;

drop function if exists public.frame_place_many(uuid, jsonb, uuid);
create function public.frame_place_many(p_plan uuid, p_cells jsonb, p_session uuid)
returns integer
language plpgsql security definer set search_path = ''
as $body$
declare
  v_cell record;
  v_n integer := 0;
begin
  perform public.plan_require_editor(p_plan);
  -- The list is read once here so that a malformed or empty one is refused by section 1 in the grab's own words,
  -- before any hold is looked at; the loop below reads it again for the places.
  perform public.plan_cell_points(p_cells);
  perform public.plan_require_cell_holds(p_plan, p_cells, p_session);

  for v_cell in select * from public.plan_cell_points(p_cells) loop
    perform public.plan_place_cell(p_plan, v_cell.frame_id, v_cell.group_id,
                                   v_cell.lat, v_cell.lng, v_cell.state, v_cell.verify);
    v_n := v_n + 1;
  end loop;

  update public.plans set updated_at = now() where id = p_plan;
  return v_n;
end;
$body$;

-- ============================================================
-- 5. Taking a badge off the plan.
--
--    A position disappears here and nowhere else. That is a deliberate narrowing: the old payload said "this
--    frame states nobody" by leaving groups out, and a page whose map was a minute old therefore deleted
--    whatever a colleague had just added. A removal is now a statement a caller has to make, about one cell it
--    holds.
--
--    A cell that is already gone answers 0 rather than raising: undo walks a stored diff (step 13) and the row it
--    wants to take away may have been removed by the frame's own deletion in the meantime.
-- ============================================================
drop function if exists public.frame_unplace(uuid, uuid, uuid, uuid);
create function public.frame_unplace(p_plan uuid, p_frame uuid, p_group uuid, p_session uuid)
returns integer
language plpgsql security definer set search_path = ''
as $body$
declare
  v_n integer := 0;
begin
  perform public.plan_require_editor(p_plan);
  perform public.plan_require_cell_holds(
    p_plan,
    jsonb_build_array(jsonb_build_object('frame', p_frame::text, 'group', p_group::text)),
    p_session);
  delete from public.plan_positions p
   where p.plan_id = p_plan and p.frame_id = p_frame and p.group_id = p_group;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    update public.plans set updated_at = now() where id = p_plan;
  end if;
  return v_n;
end;
$body$;

drop function if exists public.frame_unplace_many(uuid, jsonb, uuid);
create function public.frame_unplace_many(p_plan uuid, p_cells jsonb, p_session uuid)
returns integer
language plpgsql security definer set search_path = ''
as $body$
declare
  v_n integer := 0;
begin
  perform public.plan_require_editor(p_plan);
  perform public.plan_require_cell_holds(p_plan, p_cells, p_session);
  delete from public.plan_positions p
   where p.plan_id = p_plan
     and (p.frame_id, p.group_id) in (
       select c.frame_id, c.group_id from public.plan_cell_list(p_cells) c
     );
  get diagnostics v_n = row_count;
  if v_n > 0 then
    update public.plans set updated_at = now() where id = p_plan;
  end if;
  return v_n;
end;
$body$;

-- ============================================================
-- 6. The moment: frame_save, without the wholesale map.
--
--    046's body, with three changes and no others:
--      * p_session, optional (the header says why it may be null and what that leaves as the guard);
--      * a frame that already exists refuses `positions` instead of replacing its map;
--      * a frame this call CREATES gets its first cells through plan_place_cell, so a position has one writer
--        even here.
--
--    The insert branches are the ones 041, 044 and 046 left: a frame with no id, and a frame whose id is not in
--    this plan (a restore, or a create that names its own id). Both INSERT, which is what makes `positions` safe
--    on them and refused on the third branch, the update.
--
--    The 2-argument form is DROPPED rather than replaced: a default argument makes a second function of arity 3,
--    and leaving the old one behind would make frame_save(plan, frame) ambiguous between them. Every caller in
--    the repository passes two arguments and keeps working, because the third has a default.
-- ============================================================
drop function if exists public.frame_save(uuid, jsonb);
-- ...and 082's own arity, so that applying this file a second time replaces the function instead of colliding
-- with it. A default argument does not make the two spellings one function: it makes a second one.
drop function if exists public.frame_save(uuid, jsonb, uuid);
create function public.frame_save(p_plan uuid, p_frame jsonb, p_session uuid default null)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_id uuid := nullif(p_frame ->> 'id', '')::uuid;
  v_row public.plan_frames;
  v_created boolean := false;
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
    v_created := true;
  else
    select * into v_row from public.plan_frames where id = v_id and plan_id = p_plan for update;
    if found then
      -- A badge of a frame that already stands is not this function's to write any more (082). Said in words,
      -- because the only page that can still send one is a page old enough to overwrite a colleague with it.
      if p_frame ? 'positions' then
        raise exception 'This frame already has badges, and they are edited one at a time. Reload the board.'
          using errcode = '22023';
      end if;
      -- The moment, when the caller has a session to be checked by. A session that does not hold it is not
      -- refused by name here: a page only reaches this line after plan_lock_frame() has said yes, so this can
      -- only be a hold that lapsed or was taken in between, and the board's answer to that is to reload.
      if p_session is not null and not exists (
           select 1 from public.plan_frame_locks l
            where l.plan_id = p_plan
              and l.frame_id = v_id
              and l.session_id = p_session
              and l.expires_at > now()
              and l.last_seen > now() - interval '7 seconds'
         ) then
        raise exception 'Somebody else is editing this moment right now.' using errcode = 'PT423';
      end if;
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
      v_created := true;
    end if;
  end if;

  -- The first cells of a frame this call made. No delete: a frame that has just been inserted has no rows to
  -- take away, and a frame that already existed never reaches here.
  if v_created and p_frame ? 'positions' then
    for v_group_text, v_point in
      select key, value from jsonb_each(coalesce(p_frame -> 'positions', '{}'::jsonb))
    loop
      perform public.plan_place_cell(
        p_plan,
        v_row.id,
        v_group_text::uuid,
        (v_point ->> 'lat')::float8,
        (v_point ->> 'lng')::float8,
        nullif(v_point ->> 'state', ''),
        nullif(v_point ->> 'verify', ''));
    end loop;
  end if;

  update public.plans set updated_at = now() where id = p_plan;
  return v_row;
end;
$body$;

comment on function public.frame_save(uuid, jsonb, uuid) is
  'One moment: its time and note, and the first cells of a frame it creates. An existing frame''s badges are '
  'frame_place()''s, one at a time (082).';

-- ============================================================
-- 7. Permissions: 081's pattern. The helpers are granted to nobody and reached only from the doors, which run as
--    the definer; the four doors are granted to authenticated, which is the only role the board has.
-- ============================================================
revoke execute on function public.plan_cell_points(jsonb) from public, anon, authenticated;
revoke execute on function public.plan_require_cell_holds(uuid, jsonb, uuid) from public, anon, authenticated;
revoke execute on function public.plan_place_cell(uuid, uuid, uuid, float8, float8, text, text)
  from public, anon, authenticated;

revoke execute on function public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text) from public, anon;
revoke execute on function public.frame_place_many(uuid, jsonb, uuid) from public, anon;
revoke execute on function public.frame_unplace(uuid, uuid, uuid, uuid) from public, anon;
revoke execute on function public.frame_unplace_many(uuid, jsonb, uuid) from public, anon;
revoke execute on function public.frame_save(uuid, jsonb, uuid) from public, anon;

grant execute on function public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text) to authenticated;
grant execute on function public.frame_place_many(uuid, jsonb, uuid) to authenticated;
grant execute on function public.frame_unplace(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.frame_unplace_many(uuid, jsonb, uuid) to authenticated;
grant execute on function public.frame_save(uuid, jsonb, uuid) to authenticated;

comment on function public.frame_place(uuid, uuid, uuid, uuid, float8, float8, text, text) is
  'Write one badge, against a live hold on it; refuses with PT423 and the holder''s name (082).';
comment on function public.frame_place_many(uuid, jsonb, uuid) is
  'Write one gesture''s badges in one statement, all or none (082).';
comment on function public.frame_unplace(uuid, uuid, uuid, uuid) is
  'The only way a position disappears: one badge, against a live hold on it (082).';
comment on function public.frame_unplace_many(uuid, jsonb, uuid) is
  'The only way positions disappear: one gesture''s worth, all or none (082).';

-- 081's comment on plan_lock_frame still described the rule that was dropped (a retime waiting for the badges in
-- the moment). Rewritten here rather than by editing 081, so a database that has already applied 081 is corrected
-- without its file drifting.
comment on function public.plan_lock_frame(uuid, uuid, uuid, boolean) is
  'Take this moment for a retime; refuses while another SESSION is retiming the same moment (081).';

-- Next: 083 gives the structural operations the same treatment -- frame_move, frame_delete, frame_shift, hold and
-- the confirmation grid -- so every write on the board is checked against a hold rather than only the badge drag.

