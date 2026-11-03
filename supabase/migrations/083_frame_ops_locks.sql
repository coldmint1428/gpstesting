-- 083_frame_ops_locks.sql
--
-- Concurrent editing on the plan board, step 5: the rest of the board's writes, against the same rule.
--
-- WHAT WAS STILL UNGUARDED. 082 made a badge's position a per-cell write checked against a hold. Every other write on
-- the board still went straight at the rows: deleting a frame, dragging one along the time bar, pushing a stretch,
-- filling a gap, holding a group at a later moment, confirming a grid of positions. Each of them can do one of two
-- things to a colleague mid-edit -- take away what their hand is on, or write over it -- and none of them asked.
--
-- THE RULE, IN ONE SENTENCE: a door that would take away or overwrite something a live hold is guarding refuses, and
-- names the holder; a door that only adds something that was not there may go ahead. Two refusals follow from it and
-- they are deliberately different:
--
--   * A POSITIVE CHECK, for the one door that is a gesture of its own: frame_move() retimes a moment, and a retime is
--     what the frame lock (081) exists for. The caller must hold that moment, exactly as frame_save() requires since
--     082. "I am retiming this" is a claim the database can check, and the client makes it in the same breath.
--
--   * A NEGATIVE CHECK, for the bulk doors: they do not take a hold, because a push across forty frames or a grid of
--     confirmations is not a hand on anything -- it is one action. They ask instead whether anybody else is holding
--     something they are about to write, and refuse if so. Taking and releasing forty holds to write forty flags would
--     lock a colleague out of the board for a click.
--
-- WHY DELETING A FRAME IS REFUSED RATHER THAN ALLOWED TO CASCADE (the decision this file is built from). A badge only
-- exists inside a frame, and 081 gave the lock a composite foreign key with `on delete cascade`: deleting the frame
-- deletes the lock with it. So doing nothing is an option, and it is the wrong one. The colleague's hand is on a badge
-- that is about to cease to exist; their drag ends on a refusal about a badge that is gone, and the moment they were
-- drawing is gone too, so there is nothing to redo. Refusing instead costs the deleter the twelve seconds a hold can
-- last at most -- and it is the same rule the board already has for the two bigger destructive acts, replacing a plan
-- from a sheet and deleting the whole plan. A moment is not something to take away while somebody's hand is in it.
--
-- WHAT IS DELIBERATELY STILL ALLOWED. A retime is not refused because a badge stands in the moment: 081 settled that
-- (the first draft had the opposite rule and deadlocked), and a badge is a lat/lng -- moving the clock slides its tick
-- in the strip, not its place on the map. This file does not reintroduce it. Likewise a push or a fill is refused only
-- by a MOMENT hold, never by a badge hold: neither of them changes a position, and both would otherwise be blocked by
-- the very drags they are not touching.
--
-- REFUSAL IS STILL AN EXCEPTION WITH PT423, and the sentences are written for a planner:
--
--     Priya is editing Gate Crew at +1:00, so this moment cannot be deleted yet.
--     Priya is editing the moment at +2:00, so the stretch cannot be moved yet.
--     This badge is open in another of your windows (Gate Crew, +1:00), so this plan cannot be deleted yet.
--
-- The last one is the case the page must not lie about: a hold of the same account in another tab is not a colleague,
-- and the sentence says so without handing out the session id that would tell the tabs apart.
--
-- WHAT THIS FILE STILL DOES NOT DO. It does not add a "delete the moment anyway" escape. A holder who has walked away
-- is not a holder: the lock lapses after 12 s (081), so the delete works a few seconds later, which is the honest
-- answer to "I need this gone now". p_take_over stays what it was -- a way past my OWN other window, on the two doors
-- that are a gesture, and not a way to delete somebody's badge from under them.
--
-- RE-RUNNABLE, deliberately: every function is `drop ... if exists` then a create, so applying this file twice after
-- an edit replaces them in place, and the drops are also what keep the new arities from colliding with the old ones.

-- ============================================================
-- 1. Four internal helpers: who is in the way, and how to say so.
--
--    None of them is granted to a client. They are the shared vocabulary of the eight doors below, so that a refusal
--    composed by a delete, a push and a confirmation is the same sentence read three ways -- and so that the words
--    live in one place when somebody wants to change them.
-- ============================================================

-- The sentence. Takes the facts rather than a row, because plpgsql cannot pass a record between functions.
drop function if exists public.plan_raise_hold(text, text, text, integer, boolean, text, text);
create function public.plan_raise_hold(
  p_kind text,
  p_name text,
  p_group text,
  p_t_s integer,
  p_mine boolean,
  p_subject text,
  p_verb text
)
returns void
language plpgsql
set search_path = ''
as $body$
begin
  -- My own account, another tab. The display name would be mine, which is the one name a planner should not be shown
  -- as a stranger -- and the badge's own place is still said, because that is what the planner has to recognise.
  if p_mine then
    if p_kind = 'badge' then
      raise exception 'This badge is open in another of your windows (%, %), so % cannot be % yet.',
        p_group, public.plan_clock(p_t_s), p_subject, p_verb
        using errcode = 'PT423';
    end if;
    raise exception 'This moment is open in another of your windows (%), so % cannot be % yet.',
      public.plan_clock(p_t_s), p_subject, p_verb
      using errcode = 'PT423';
  end if;

  if p_kind = 'badge' then
    raise exception '% is editing % at %, so % cannot be % yet.',
      coalesce(p_name, 'Somebody'), p_group, public.plan_clock(p_t_s), p_subject, p_verb
      using errcode = 'PT423';
  end if;
  raise exception '% is editing the moment at %, so % cannot be % yet.',
    coalesce(p_name, 'Somebody'), public.plan_clock(p_t_s), p_subject, p_verb
    using errcode = 'PT423';
end;
$body$;

-- Any live hold in these frames (or in the whole plan, when p_frames is null), except this page's own.
--
-- "Live" is 081's one blocking rule -- last_seen inside 7 s AND not expired -- so a hold that can be stolen is not a
-- reason to refuse, and a door and a steal can never disagree about who is in the way. p_frames = '{}' is "nothing to
-- look at" and passes; null is "the whole plan" (a delete of the plan, an import over it).
drop function if exists public.plan_refuse_holds(uuid, uuid[], uuid, text, text, text);
create function public.plan_refuse_holds(
  p_plan uuid,
  p_frames uuid[] default null,
  p_session uuid default null,
  p_kinds text default 'both',
  p_subject text default 'it',
  p_verb text default 'changed'
)
returns void
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_steal constant interval := interval '7 seconds';
  v_kind text;
  v_name text;
  v_group text;
  v_t_s integer;
  v_user uuid;
  v_holder uuid;
begin
  if p_kinds is null or p_kinds not in ('badge', 'moment', 'both') then
    raise exception 'Say which kind of hold to look for.' using errcode = '22023';
  end if;

  -- One read, both tables, earliest moment first: the first thing in the way is the one the planner's eye is on.
  -- Ordered by kind too, so a badge in the same moment is named before the moment itself -- it is the more specific
  -- reason, and "Priya has Sound at +1:00" is more useful than "somebody has +1:00".
  select k.kind, k.name, k.group_name, k.t_s, k.user_id, k.session_id
    into v_kind, v_name, v_group, v_t_s, v_user, v_holder
    from (
      select 'badge'::text as kind, pr.display_name as name, g.name as group_name,
             f.t_s, l.user_id, l.session_id
        from public.plan_cell_locks l
        join public.plan_frames f on f.id = l.frame_id
        join public.groups g on g.id = l.group_id
        left join public.profiles pr on pr.id = l.user_id
       where l.plan_id = p_plan
         and (p_frames is null or l.frame_id = any (p_frames))
         and l.expires_at > now()
         and l.last_seen > now() - v_steal
         and l.session_id is distinct from p_session
         and p_kinds in ('badge', 'both')
      union all
      select 'moment'::text, pr.display_name, null::text, f.t_s, l.user_id, l.session_id
        from public.plan_frame_locks l
        join public.plan_frames f on f.id = l.frame_id
        left join public.profiles pr on pr.id = l.user_id
       where l.plan_id = p_plan
         and (p_frames is null or l.frame_id = any (p_frames))
         and l.expires_at > now()
         and l.last_seen > now() - v_steal
         and l.session_id is distinct from p_session
         and p_kinds in ('moment', 'both')
    ) k
   order by k.t_s, k.kind, k.group_name
   limit 1;

  if v_holder is null then
    return;
  end if;

  perform public.plan_raise_hold(v_kind, v_name, v_group, v_t_s, v_user = auth.uid(), p_subject, p_verb);
end;
$body$;

-- The same question about specific cells: "is anybody else's hand on one of these badges". 082's
-- plan_require_cell_holds asks the opposite direction (do I hold all of these?); this asks "is somebody else holding
-- any?" -- which is what a write that takes no hold needs to know. An empty list is not an error: frame_hold and
-- frame_set_verify both reach a point where they have nothing left to write.
drop function if exists public.plan_refuse_cells(uuid, jsonb, uuid, text, text);
create function public.plan_refuse_cells(
  p_plan uuid,
  p_cells jsonb,
  p_session uuid default null,
  p_subject text default 'it',
  p_verb text default 'changed'
)
returns void
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_steal constant interval := interval '7 seconds';
  v_name text;
  v_group text;
  v_t_s integer;
  v_user uuid;
  v_holder uuid;
begin
  if p_cells is null or jsonb_typeof(p_cells) <> 'array' then
    raise exception 'Name the badges as a list.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_cells) = 0 then
    return;
  end if;

  select pr.display_name, g.name, f.t_s, l.user_id, l.session_id
    into v_name, v_group, v_t_s, v_user, v_holder
    from public.plan_cell_locks l
    join public.plan_frames f on f.id = l.frame_id
    join public.groups g on g.id = l.group_id
    left join public.profiles pr on pr.id = l.user_id
   where l.plan_id = p_plan
     and (l.frame_id, l.group_id) in (
       select c.frame_id, c.group_id from public.plan_cell_list(p_cells) c
     )
     and l.expires_at > now()
     and l.last_seen > now() - v_steal
     and l.session_id is distinct from p_session
   order by f.t_s, g.name
   limit 1;

  if v_holder is null then
    return;
  end if;
  perform public.plan_raise_hold('badge', v_name, v_group, v_t_s, v_user = auth.uid(), p_subject, p_verb);
end;
$body$;

-- The positive check: this page must hold this moment. 082's plan_require_cell_holds, one resource up.
--
-- No session is the old guard only (the revision), which is what an internal caller -- an import, a repair -- has to
-- offer, and what every caller had before this file. A hold that is mine but has lapsed is not somebody else's: the
-- two sentences are different, and the lapsed one tells the planner to try again rather than naming a person.
drop function if exists public.plan_require_moment_hold(uuid, uuid, uuid, text, text);
create function public.plan_require_moment_hold(
  p_plan uuid,
  p_frame uuid,
  p_session uuid,
  p_subject text default 'this moment',
  p_verb text default 'moved'
)
returns void
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_steal constant interval := interval '7 seconds';
begin
  if p_session is null then
    return;
  end if;

  perform 1
     from public.plan_frame_locks l
    where l.plan_id = p_plan
      and l.frame_id = p_frame
      and l.session_id = p_session
      and l.expires_at > now()
      and l.last_seen > now() - v_steal;
  if found then
    return;
  end if;

  -- Somebody else has it, if anybody live does: name them. Otherwise the hold was mine and has lapsed.
  perform public.plan_refuse_holds(p_plan, array[p_frame], p_session, 'moment', p_subject, p_verb);

  raise exception 'This moment stopped being yours to edit. Try again.' using errcode = 'PT423';
end;
$body$;

-- ============================================================
-- 2. One moment: the retime, and the delete.
--
--    frame_move is 044's body with the moment hold in it. A retime is a gesture on the frame lock (081), so it takes
--    the same lock frame_save takes for a note -- and the client holds it for the length of the call, which is why a
--    held moment is written here rather than merely checked for.
--
--    frame_delete is 038's body with the decision at the top of this file: a live hold of either kind in the frame --
--    a badge being dragged, or the moment being retimed -- refuses it, by name, until it lapses. After that the
--    delete's own cascade is what takes the locks away, which is the point it is no longer in anybody's way.
-- ============================================================
drop function if exists public.frame_move(uuid, integer, integer);
-- ...and this file's own arity, so applying 083 a second time replaces the function instead of colliding with it.
-- A default argument does not make the two spellings one function: it makes a second one.
drop function if exists public.frame_move(uuid, integer, integer, uuid);
create function public.frame_move(p_id uuid, p_t_s integer, p_rev integer, p_session uuid default null)
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
  -- The hold first, then the revision: "somebody else is retiming this" is a fact about now, and a stale revision is
  -- a fact about this page's picture. The holder is named; a page whose own hold lapsed is told to try again.
  perform public.plan_require_moment_hold(v_row.plan_id, p_id, p_session, 'this moment', 'moved');
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

drop function if exists public.frame_delete(uuid, integer);
drop function if exists public.frame_delete(uuid, integer, uuid);
create function public.frame_delete(p_id uuid, p_rev integer, p_session uuid default null)
returns void
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
  -- Somebody's hand is in this moment: a badge being dragged in it, or its own clock being retimed. Either way the row
  -- they are working on is about to go, and the cascade would take their hold with it (081's foreign key). Refuse,
  -- name them, and let the twelve seconds run out.
  perform public.plan_refuse_holds(v_row.plan_id, array[p_id], p_session, 'both', 'this moment', 'deleted');
  delete from public.plan_frames where id = p_id;
  update public.plans set updated_at = now() where id = v_row.plan_id;
end;
$body$;

-- ============================================================
-- 3. A stretch: the push, and the fill.
--
--    Both move or invent MOMENTS, and neither changes a badge's place: a push only rewrites t_s, and a fill only ever
--    writes a position where the group has none (the middle of the stretch is refused when a statement stands there).
--    So neither is refused by a badge hold -- and both bump the revision of every frame they touch, which is why a
--    MOMENT hold in the stretch is a refusal: the planner retiming +2:00 would otherwise save a note against a
--    revision a push moved under them, and be told "someone else changed this frame first" about a change they had
--    nothing to do with.
-- ============================================================
drop function if exists public.frame_shift(uuid, integer, integer, integer);
drop function if exists public.frame_shift(uuid, integer, integer, integer, uuid);
create function public.frame_shift(
  p_plan uuid,
  p_from_s integer,
  p_delta_s integer,
  p_to_s integer default null,
  p_session uuid default null
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

  -- Last, the hands: everything structural above is refused in its own words first, and this is the check that has to
  -- be nearest the write.
  perform public.plan_refuse_holds(
    p_plan,
    (select coalesce(array_agg(f.id), '{}'::uuid[])
       from public.plan_frames f
      where f.plan_id = p_plan
        and f.t_s >= p_from_s
        and (p_to_s is null or f.t_s <= p_to_s)),
    p_session, 'moment', 'the stretch', 'moved');

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

drop function if exists public.frames_fill(uuid, uuid, uuid, uuid[]);
drop function if exists public.frames_fill(uuid, uuid, uuid, uuid[], uuid);
create function public.frames_fill(
  p_plan uuid,
  p_from uuid,
  p_to uuid,
  p_groups uuid[] default null,
  p_session uuid default null
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

  -- Nothing above wrote anything, and this is the first statement that would: a moment in the stretch is somebody's
  -- clock, and every frame here is about to have its revision bumped. Refuse before the first row.
  perform public.plan_refuse_holds(
    p_plan,
    (select coalesce(array_agg(f.id), '{}'::uuid[])
       from public.plan_frames f
      where f.plan_id = p_plan
        and f.t_s >= v_from.t_s
        and f.t_s <= v_to.t_s),
    p_session, 'moment', 'this gap', 'filled');

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
  -- Every one of these is an INSERT, never an overwrite: the check above refused every group with a statement strictly
  -- inside the stretch, and the times written are strictly inside it. So no badge is replaced here, and no hold is
  -- needed -- the rule at the top of this file is about what a door takes away or overwrites.
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

-- ============================================================
-- 4. The two bulk position writers: hold, and the confirmation grid.
--
--    Neither is a gesture on one badge, so neither takes a hold. Both ask the negative question instead: is anybody
--    else's hand on a badge this call would write? A row this call INVENTS is not a conflict -- nothing stood there to
--    lose -- but 082's rule is about badges somebody has hold of, and the hold does not care whether the row exists.
--    So the answer is per cell, and it is the same sentence a refused drag gets.
--
--    frame_hold is 046's body plus 067's condition (a statement at the SAME place is not a move) -- 067 patched the
--    live definition with a text replacement, so its condition has to be carried over by hand here.
-- ============================================================
drop function if exists public.frame_hold(uuid, uuid, integer, uuid[]);
drop function if exists public.frame_hold(uuid, uuid, integer, uuid[], uuid);
create function public.frame_hold(
  p_plan uuid,
  p_frame uuid,
  p_seconds integer,
  p_groups uuid[] default null,
  p_session uuid default null
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
    -- delay, so the sentence points at the frame the hold should have started from. 067's condition: a statement at
    -- the same place, in the same state, is not a move.
    select f.t_s into v_between_s
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = p_plan and p.group_id = v_group
       and f.t_s > v_src.t_s and f.t_s < v_target
       and (p.lat <> v_lat_one or p.lng <> v_lng_one or p.state <> v_state_one)
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

  -- ---------- nobody else's hand is written over ----------
  -- A cell this call writes is refused while another session holds it: the badge's row is about to be stated again,
  -- and a drag in flight would be written over. And a target frame that already stands has its revision bumped, which
  -- is a claim on the MOMENT somebody may be retiming -- the same revision a note save would then be judged against.
  if v_frame is not null then
    perform public.plan_refuse_cells(
      p_plan,
      (select coalesce(jsonb_agg(jsonb_build_object('frame', v_frame, 'group', g)), '[]'::jsonb)
         from unnest(v_need) as g),
      p_session, 'this hold', 'made');
    perform public.plan_refuse_holds(p_plan, array[v_frame], p_session, 'moment', 'this hold', 'made');
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

drop function if exists public.frame_set_verify(uuid, uuid[], uuid[], text);
drop function if exists public.frame_set_verify(uuid, uuid[], uuid[], text, uuid);
create function public.frame_set_verify(
  p_plan uuid,
  p_frames uuid[],
  p_groups uuid[] default null,
  p_verify text default null,
  p_session uuid default null
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
  v_cells jsonb;
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

  -- The grid, named as cells before it is written: exactly the rows the UPDATE below would change (a row whose flag
  -- is already the value asked for is not written at all, and so is not in the way of anything).
  select coalesce(jsonb_agg(jsonb_build_object('frame', p.frame_id, 'group', p.group_id)), '[]'::jsonb)
    into v_cells
    from public.plan_positions p
   where p.plan_id = p_plan
     and p.frame_id = any(v_frames)
     and p.group_id = any(v_groups)
     and p.verify is distinct from v_verify;

  perform public.plan_refuse_cells(p_plan, v_cells, p_session, 'the confirmation', 'changed');
  -- ...and the moments those frames are, because a frame this call touches has its revision bumped: a colleague
  -- retiming one of them would be handed a stale revision by an edit of a flag.
  perform public.plan_refuse_holds(p_plan, v_frames, p_session, 'moment', 'the confirmation', 'changed');

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

-- ============================================================
-- 5. The whole plan: taking it away, or replacing every moment of it.
--
--    The two biggest destructive acts the board has, and the two the failure matrix already promised were refused
--    while anybody was mid-edit. Deleting the plan cascades every frame (and with it every hold); an import deletes
--    every frame before writing the sheet. Both are refused while anybody's hand is anywhere in the plan -- badge or
--    moment -- because everything they are working on is about to go.
--
--    Neither takes a hold. A plan is not a lockable thing (the model table in the design note says `plan_id` is "not a
--    lock: a read"), and a two-step confirm in front of both is where their safety comes from.
-- ============================================================
drop function if exists public.plan_delete(uuid);
drop function if exists public.plan_delete(uuid, uuid);
create function public.plan_delete(p_plan uuid, p_session uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can delete a plan.' using errcode = '42501';
  end if;
  perform public.plan_refuse_holds(p_plan, null, p_session, 'both', 'this plan', 'deleted');
  delete from public.plans where id = p_plan;
end;
$body$;

drop function if exists public.plan_import(uuid, jsonb);
drop function if exists public.plan_import(uuid, jsonb, uuid);
create function public.plan_import(p_plan uuid, p_frames jsonb, p_session uuid default null)
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

  -- Somebody is drawing on the plan this sheet would replace. Everything they are moving disappears with the delete
  -- below, and their hold with it, so an import is refused until the board is still.
  perform public.plan_refuse_holds(p_plan, null, p_session, 'both', 'the plan', 'replaced');

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

-- ============================================================
-- 6. Permissions: 081's pattern, restated because every door was dropped and re-created with its new arity -- which
--    takes the old grants with it. The helpers are granted to nobody and reached only from the doors, which run as
--    the definer.
-- ============================================================
revoke execute on function public.plan_raise_hold(text, text, text, integer, boolean, text, text)
  from public, anon, authenticated;
revoke execute on function public.plan_refuse_holds(uuid, uuid[], uuid, text, text, text)
  from public, anon, authenticated;
revoke execute on function public.plan_refuse_cells(uuid, jsonb, uuid, text, text)
  from public, anon, authenticated;
revoke execute on function public.plan_require_moment_hold(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;

revoke execute on function public.frame_move(uuid, integer, integer, uuid) from public, anon;
revoke execute on function public.frame_delete(uuid, integer, uuid) from public, anon;
revoke execute on function public.frame_shift(uuid, integer, integer, integer, uuid) from public, anon;
revoke execute on function public.frames_fill(uuid, uuid, uuid, uuid[], uuid) from public, anon;
revoke execute on function public.frame_hold(uuid, uuid, integer, uuid[], uuid) from public, anon;
revoke execute on function public.frame_set_verify(uuid, uuid[], uuid[], text, uuid) from public, anon;
revoke execute on function public.plan_delete(uuid, uuid) from public, anon;
revoke execute on function public.plan_import(uuid, jsonb, uuid) from public, anon;

grant execute on function public.frame_move(uuid, integer, integer, uuid) to authenticated;
grant execute on function public.frame_delete(uuid, integer, uuid) to authenticated;
grant execute on function public.frame_shift(uuid, integer, integer, integer, uuid) to authenticated;
grant execute on function public.frames_fill(uuid, uuid, uuid, uuid[], uuid) to authenticated;
grant execute on function public.frame_hold(uuid, uuid, integer, uuid[], uuid) to authenticated;
grant execute on function public.frame_set_verify(uuid, uuid[], uuid[], text, uuid) to authenticated;
grant execute on function public.plan_delete(uuid, uuid) to authenticated;
grant execute on function public.plan_import(uuid, jsonb, uuid) to authenticated;

comment on function public.frame_move(uuid, integer, integer, uuid) is
  'Retime one moment under a live hold on it; refuses with PT423 while another session is retiming it (083).';
comment on function public.frame_delete(uuid, integer, uuid) is
  'Delete one moment, refused while any live hold is in it -- a badge being dragged or its own clock (083).';
comment on function public.frame_shift(uuid, integer, integer, integer, uuid) is
  'Push a stretch of moments; refused while another session is retiming one of them (083).';
comment on function public.frames_fill(uuid, uuid, uuid, uuid[], uuid) is
  'Insert the frames that space a stretch out; refused while another session is retiming one in it (083).';
comment on function public.frame_hold(uuid, uuid, integer, uuid[], uuid) is
  'State the named groups again at a later moment; refused over another session''s badge or moment (083).';
comment on function public.frame_set_verify(uuid, uuid[], uuid[], text, uuid) is
  'Set verify on the positions these frames hold; refused over another session''s badge or moment (083).';
comment on function public.plan_delete(uuid, uuid) is
  'Delete a plan and every moment in it; refused while anybody is mid-edit anywhere in it (083).';
comment on function public.plan_import(uuid, jsonb, uuid) is
  'Replace every moment of a plan with a sheet; refused while anybody is mid-edit anywhere in it (083).';

-- WHAT IS STILL NOT GUARDED, said rather than discovered:
--
--   * frame_save()'s RESTORE branch (041). A frame id the plan does not have is inserted, with its first cells -- the
--     undo of a delete. A note save that arrives after the frame was deleted therefore brings it back, empty. That
--     predates this file, the badge door refuses a deleted frame (082), and the only way to tell a restore from a
--     stale save is a flag nobody has asked for. The merge is that a delete is now refused while the retime that
--     would race it is live, which is the half of the window this file can close.
--   * The click that starts a delete is not a hold. Two planners who both press Delete at the same instant both pass
--     the check and one of them gets "That frame does not exist." -- honest, and the cascade is atomic.
--   * A retime is still allowed while a badge stands in the moment (081's decision, restated at the top).
