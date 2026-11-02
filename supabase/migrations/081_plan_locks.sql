-- 081_plan_locks.sql
--
-- Concurrent editing on the plan board, step 1: who is editing what.
--
-- THE PROBLEM. Two planners can have the same plan open, and the board's write path is per frame, not
-- per badge: frame_save() replaces a frame's whole position map. So when Priya moves Gate Crew, her save
-- carries every other group's position as it stood when her page loaded -- and whatever Daniel changed in
-- the meantime is silently overwritten. He never learns; the plan simply stops being what he drew. The
-- first thing to fix is therefore not the write (that is 082) but the question "may I write this cell at
-- all", answered by the database, per cell, before anybody's payload moves.
--
-- THE UNIT IS SMALLER THAN THE BENCH'S. 016 locks one object on the canvas, and one object is all a
-- planner there ever drags. Here the canvas is a timeline, and a badge belongs to a (frame, group) pair:
-- two planners working at the same moment on different groups are not in each other's way, and locking
-- the whole frame for one dragged dot would make the feature useless. So a lock is one CELL, which is one
-- drawn badge.
--
-- TWO RESOURCES, DELIBERATELY DISJOINT.
--
--   public.plan_cell_locks   keyed by (frame_id, group_id)  guards a badge's position, state and verify
--   public.plan_frame_locks  keyed by frame_id              guards the moment itself: t_s and note
--
-- They are different tables because they answer different questions and are taken by different gestures.
-- Holding a badge does not let me move the frame's clock, and holding the clock does not let me move a
-- badge. Nothing couples them: a retime and a badge drag write different rows after 082, so neither can
-- lose the other's work, and the frame lock is only ever about two people retiming the SAME moment.
--
-- THE SESSION IS THE UNIT, NOT THE PLANNER -- 016's rule, and it is the same reason. auth.uid() is what
-- the server needs to recognise "this is my renewal", so it cannot also be what tells my two tabs apart.
-- Two tabs of one account are two editors. The session is minted by the page, one per page load, and is
-- A SECRET: neither table below is published, both have row level security on with no policies at all,
-- and every grant is taken away, so the only way in is through these functions. plan_lock_holders() hands
-- out display names and never a session id -- the id a page PUBLISHES is never the id it is AUTHORISED by.
--
-- TIMING. heartbeat 2 s (client), steal 7 s, expiry 12 s. The three numbers are the product decision and
-- they live in this file in exactly two places: the column defaults and the `v_steal`/`v_ttl` constants.
-- The rule they encode:
--
--     a lock BLOCKS while   last_seen >  now() - 7 s   AND   expires_at > now()
--
-- and that sentence is used both to steal a lock (the upserts) and to list who is editing (section 9),
-- so a refusal, a steal and a painted ring can never disagree about who holds what. A planner who stops
-- moving lets go after 5 s by themselves (a client rule -- the page releases rather than quietly hoarding),
-- so reaching 7 s means the page stopped: a closed tab, a sleeping laptop, a lost network.
--
-- REFUSAL IS AN EXCEPTION, NOT A RETURNED FLAG. Every write door here is all-or-nothing: if one badge in
-- the gesture is held by somebody else, the gesture does not happen at all. A raised exception rolls the
-- whole function call back, which is precisely "nothing happened", and it carries the sentence the board
-- shows ("Priya is editing Gate Crew at +1:00") out to the page unchanged. The distinct SQLSTATE is
-- PT423 (HTTP 423, Locked) so the page can tell "somebody else has it" from "the network died" without
-- reading English.
--
-- WHAT THIS FILE DOES NOT DO. It does not write a single position. frame_place() and the change to
-- frame_save() are 082, and until they exist the board still writes the old way -- which is safe, because
-- a lock nobody consults cannot be broken by a writer who ignores it. Step 1 is invisible on purpose: the
-- only thing that changes for a planner is that the database can now answer "who is editing this badge".
--
-- RE-RUNNABLE, deliberately, like 016: every statement is `if not exists`, `create or replace` or a
-- `drop ... if exists` in front of a create, so applying this file a second time after an edit replaces
-- the functions in place. Nothing in it deletes data.

-- ============================================================
-- 1. The index the database needs to pin a lock to its plan.
--
--    Both tables carry plan_id, which is redundant (the frame already knows its plan) and necessary: it
--    is what lets one statement release or list everything a page holds in this plan, and it is what the
--    composite foreign key below uses to make an impossible row -- a lock on a frame of another plan --
--    unrepresentable rather than merely unlikely. `on delete cascade` then means a deleted frame takes
--    its locks with it, so a lock cannot outlive the badge it guards.
-- ============================================================
create unique index if not exists plan_frames_id_plan_uidx on public.plan_frames (id, plan_id);

-- ============================================================
-- 2. The cells. One row per badge somebody is holding.
-- ============================================================
create table if not exists public.plan_cell_locks (
  frame_id uuid not null,
  group_id uuid not null,
  plan_id uuid not null references public.plans (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  -- The credential. Never published, never returned by any function in this file.
  session_id uuid not null,
  last_seen timestamptz not null default now(),
  -- Deliberately short, and renewed while the planner is working. The only way to reach it is to stop.
  expires_at timestamptz not null default now() + interval '12 seconds',
  primary key (frame_id, group_id),
  foreign key (frame_id, plan_id) references public.plan_frames (id, plan_id) on delete cascade,
  foreign key (group_id) references public.groups (id) on delete cascade
);

create index if not exists plan_cell_locks_plan_idx on public.plan_cell_locks (plan_id);
create index if not exists plan_cell_locks_session_idx on public.plan_cell_locks (session_id);
create index if not exists plan_cell_locks_user_idx on public.plan_cell_locks (user_id);

-- ============================================================
-- 3. The frames. One row per moment somebody is retiming.
-- ============================================================
create table if not exists public.plan_frame_locks (
  frame_id uuid primary key,
  plan_id uuid not null references public.plans (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  session_id uuid not null,
  last_seen timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '12 seconds',
  foreign key (frame_id, plan_id) references public.plan_frames (id, plan_id) on delete cascade
);

create index if not exists plan_frame_locks_plan_idx on public.plan_frame_locks (plan_id);
create index if not exists plan_frame_locks_session_idx on public.plan_frame_locks (session_id);
create index if not exists plan_frame_locks_user_idx on public.plan_frame_locks (user_id);

-- ============================================================
-- 4. No policies and no grants: these tables are reached only through the functions below. A planner who
--    could read them would learn other planners' session ids, which are the credential.
-- ============================================================
alter table public.plan_cell_locks enable row level security;
alter table public.plan_frame_locks enable row level security;

revoke all on table public.plan_cell_locks from anon, authenticated, public;
revoke all on table public.plan_frame_locks from anon, authenticated, public;

comment on table public.plan_cell_locks is
  'Who is editing which badge, live. Unreadable directly: sessions are credentials, so this is reached only through the plan_* functions (081).';
comment on table public.plan_frame_locks is
  'Who is retiming which moment, live. Unreadable directly: sessions are credentials, so this is reached only through the plan_* functions (081).';

-- ============================================================
-- 5. Two shared pieces: a badge list, and the role check every door starts with.
-- ============================================================
-- The page sends a grab as [{"frame": "<uuid>", "group": "<uuid>"}, ...] because one gesture may straddle
-- frames (drag a badge back through the next four moments) and because "ask for all of them or none" has
-- to be one call. This turns that JSON into rows and refuses anything that is not a badge: a cast would
-- otherwise fail as "invalid input syntax for type uuid" from inside the mapping, which names the type
-- rather than the mistake.
drop function if exists public.plan_cell_list(jsonb);
create function public.plan_cell_list(p_cells jsonb)
returns table (frame_id uuid, group_id uuid)
language plpgsql immutable set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_item jsonb;
  v_frame text;
  v_group text;
  -- The canonical uuid spelling. Anything else is refused as "not a badge" rather than cast, so a typo
  -- comes back as a sentence about the board instead of one about a type.
  v_ok constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  if p_cells is null or jsonb_typeof(p_cells) <> 'array' then
    raise exception 'Name the badges as a list.' using errcode = '22023';
  end if;

  -- An EMPTY list is not an error here: plan_renew() asks about everything a page holds, and a page that
  -- holds only a moment has no badges to ask about. "At least one" is a rule of taking, and is checked
  -- there (section 6), not of a list that is merely being read.
  for v_item in select e.value from jsonb_array_elements(p_cells) e loop
    v_frame := case when jsonb_typeof(v_item) = 'object' then v_item ->> 'frame' end;
    v_group := case when jsonb_typeof(v_item) = 'object' then v_item ->> 'group' end;
    if v_frame is null or v_frame !~ v_ok or v_group is null or v_group !~ v_ok then
      raise exception 'That is not a badge on this board.' using errcode = '22023';
    end if;
    frame_id := v_frame::uuid;
    group_id := v_group::uuid;
    return next;
  end loop;
end;
$body$;

-- Every door begins here. Returns the plan's event, because two of them need it to scope a group.
--
-- security definer, and revoked from everyone but its own siblings (section 10): it reads public.plans,
-- which a participant may not read, and it is the thing that decides whether the caller may write at all.
drop function if exists public.plan_require_editor(uuid);
create function public.plan_require_editor(p_plan uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_event uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if v_event is null then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  -- The same rule as every other write on a plan (038, src/utils/permissions.js): root or planner.
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  return v_event;
end;
$body$;

-- ============================================================
-- 6. Taking a badge.
--
--    One door for one badge and for forty, because they are the same operation: a gesture is atomic and
--    the page does not behave differently for an array of length one. p_take_over is the refusal strip's
--    "edit it here anyway" -- and it is narrow on purpose: it reaches MY OWN other window, never a
--    colleague who is working. Everybody else is reachable the ordinary way, by waiting 7 s.
-- ============================================================
drop function if exists public.plan_lock_cells(uuid, jsonb, uuid, boolean);
create function public.plan_lock_cells(
  p_plan uuid,
  p_cells jsonb,
  p_session uuid,
  p_take_over boolean default false
)
returns table (frame_id uuid, group_id uuid)
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_event uuid;
  v_ttl constant interval := interval '12 seconds';
  v_steal constant interval := interval '7 seconds';
  v_bad record;
  v_missing integer;
  v_elsewhere boolean;
  v_name text;
  v_group_name text;
  v_t_s integer;
begin
  v_event := public.plan_require_editor(p_plan);

  -- A page with no session cannot hold anything. Same refusal, same code as 016.
  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  if p_cells is null or jsonb_typeof(p_cells) <> 'array' then
    raise exception 'Name the badges as a list.' using errcode = '22023';
  end if;
  -- plan_cell_list() refuses a non-list in its own words; this adds "and not an empty one". Taking nothing
  -- is a bug in the page rather than a no-op, because every caller of this door is mid-gesture.
  if not exists (select 1 from public.plan_cell_list(p_cells)) then
    raise exception 'Name at least one badge.' using errcode = '22023';
  end if;

  -- Every named cell must be a cell of THIS plan, checked before anything is written, so a stale page
  -- asking about a frame somebody deleted gets a sentence rather than a foreign-key violation.
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

  -- One statement, so two grabs in the same millisecond are decided by the primary key and not by the
  -- page. The WHERE is the whole rule: a row that matches is mine to (re)take, and a row that does not
  -- match is left exactly as it was -- which is what makes "the loser of a race" mean the loser of a race
  -- rather than the slower writer.
  --
  -- Ordered by the cell's own identity, not by the order the page asked for them, so two pages claiming
  -- an overlapping set take the rows in the same order and cannot deadlock on each other.
  return query
    with want as (
      select distinct c.frame_id, c.group_id from public.plan_cell_list(p_cells) c
    ),
    claimed as (
      insert into public.plan_cell_locks (frame_id, group_id, plan_id, user_id, session_id)
      select w.frame_id, w.group_id, p_plan, auth.uid(), p_session
        from want w
       order by w.frame_id, w.group_id
      on conflict (frame_id, group_id) do update
         set user_id = excluded.user_id,
             session_id = excluded.session_id,
             last_seen = now(),
             expires_at = now() + v_ttl
       where plan_cell_locks.session_id = p_session         -- mine again (a heartbeat, or the same gesture)
          or plan_cell_locks.expires_at <= now()              -- the holder stopped
          or plan_cell_locks.last_seen <= now() - v_steal     -- ...or went quiet
          or (p_take_over and plan_cell_locks.user_id = auth.uid())  -- my own other window, if I asked
      returning plan_cell_locks.frame_id, plan_cell_locks.group_id
    )
    select c.frame_id, c.group_id from claimed c;

  -- If the statement above matched fewer rows than were asked for, then at least one badge is somebody
  -- else's. Raising rolls back the ones that DID match, which is the all-or-nothing half of the promise:
  -- a gesture across six frames either takes all six or moves nothing.
  select count(*) into v_missing
    from (select distinct c.frame_id, c.group_id from public.plan_cell_list(p_cells) c) w
   where not exists (
     select 1 from public.plan_cell_locks l
      where l.frame_id = w.frame_id and l.group_id = w.group_id and l.session_id = p_session);

  if v_missing > 0 then
    -- Name the first one in the way, earliest moment first: that is the one the planner's eye is on.
    select (l.user_id = auth.uid()), coalesce(pr.display_name, 'Somebody'), g.name, f.t_s
      into v_elsewhere, v_name, v_group_name, v_t_s
      from (select distinct c.frame_id, c.group_id from public.plan_cell_list(p_cells) c) w
      join public.plan_frames f on f.id = w.frame_id
      join public.groups g on g.id = w.group_id
      join public.plan_cell_locks l on l.frame_id = w.frame_id and l.group_id = w.group_id
      left join public.profiles pr on pr.id = l.user_id
     where l.session_id <> p_session
     order by f.t_s, g.name
     limit 1;

    if v_elsewhere then
      raise exception 'This badge is open in another of your windows (%, %). Take it over to edit here.',
        v_group_name, public.plan_clock(v_t_s)
        using errcode = 'PT423';
    elsif v_name is not null then
      raise exception '% is editing % at %.', v_name, v_group_name, public.plan_clock(v_t_s)
        using errcode = 'PT423';
    end if;
    -- The row went between the claim and the read above -- somebody let go, or a steal raced. Nothing has
    -- happened; say so rather than inventing a name.
    raise exception 'Somebody else is editing that badge right now.' using errcode = 'PT423';
  end if;
end;
$body$;

-- ============================================================
-- 7. Taking a moment (t_s and note).
--
--    Same machine, one resource up, and NOTHING to do with a badge. A moment and the badges standing in
--    it are separate resources held by separate gestures, and neither needs the other to be safe: after
--    082 a badge write touches only plan_positions and a retime touches only plan_frames.t_s, so the two
--    gestures do not write a shared row and cannot lose each other's work.
--
--    The first draft of this file refused a retime while another session held a badge in the moment, on
--    the theory that moving t_s slides the badge out from under the hand. It does not -- a badge is a
--    lat/lng, and a clock does not move one. What it slides is the frame's TICK in the strip, and the walk
--    lines and 25 m flags that are measured between moments. That is a picture reflowing, not a lost edit,
--    and the price of refusing was a deadlock: two planners dragging different badges at one moment would
--    each block the other's retime, for a reason neither could see. The rule is gone; the frame lock is
--    only ever about two people retiming the SAME moment.
-- ============================================================
drop function if exists public.plan_lock_frame(uuid, uuid, uuid, boolean);
create function public.plan_lock_frame(
  p_plan uuid,
  p_frame uuid,
  p_session uuid,
  p_take_over boolean default false
)
returns table (frame_id uuid)
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_ttl constant interval := interval '12 seconds';
  v_steal constant interval := interval '7 seconds';
  v_name text;
  v_elsewhere boolean;
begin
  perform public.plan_require_editor(p_plan);

  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  -- The frame must be this plan's, so a stale page cannot lock a frame somebody deleted.
  perform 1 from public.plan_frames f where f.id = p_frame and f.plan_id = p_plan;
  if not found then
    raise exception 'That frame is not in this plan.' using errcode = '42501';
  end if;

  return query
    insert into public.plan_frame_locks (frame_id, plan_id, user_id, session_id)
    values (p_frame, p_plan, auth.uid(), p_session)
    on conflict (frame_id) do update
       set user_id = excluded.user_id,
           session_id = excluded.session_id,
           last_seen = now(),
           expires_at = now() + v_ttl
     where plan_frame_locks.session_id = p_session
        or plan_frame_locks.expires_at <= now()
        or plan_frame_locks.last_seen <= now() - v_steal
        or (p_take_over and plan_frame_locks.user_id = auth.uid())
    returning plan_frame_locks.frame_id;

  -- Same verification as a badge: silence means somebody else's moment, and it is worth saying why.
  select not exists (
    select 1 from public.plan_frame_locks l where l.frame_id = p_frame and l.session_id = p_session
  ) into v_elsewhere;
  if v_elsewhere then
    select (l.user_id = auth.uid()), coalesce(pr.display_name, 'Somebody')
      into v_elsewhere, v_name
      from public.plan_frame_locks l
      left join public.profiles pr on pr.id = l.user_id
     where l.frame_id = p_frame
     limit 1;
    if v_elsewhere then
      raise exception 'This moment is open in another of your windows. Take it over to edit here.'
        using errcode = 'PT423';
    elsif v_name is not null then
      raise exception '% is editing this moment.', v_name using errcode = 'PT423';
    end if;
    raise exception 'Somebody else is editing that moment right now.' using errcode = 'PT423';
  end if;
end;
$body$;

-- ============================================================
-- 8. Keeping it, and letting it go.
--
--    plan_renew is the heartbeat: the page calls it every 2 s while it holds anything, and it refreshes
--    EVERYTHING that session holds in the plan (not only what it names) so that a page which has forgotten
--    part of its own state cannot quietly drop a lock and then be surprised by a refusal.
--
--    The reply is per thing the page THOUGHT it had, because the only useful fact after a heartbeat is
--    "which of these is no longer mine" -- that is what makes a badge snap back. It is computed from the
--    table, not from the request, so a page cannot talk itself into believing it still holds a badge that
--    was stolen while it slept.
--
--    Renewing also revives my own row if it expired but nobody took it, which is the silent re-acquire
--    after the 5 s idle release: the planner moves again, the page asks again, and the badge is theirs.
-- ============================================================
drop function if exists public.plan_renew(uuid, jsonb, uuid[], uuid);
create function public.plan_renew(
  p_plan uuid,
  p_cells jsonb,
  p_frames uuid[],
  p_session uuid
)
returns table (kind text, frame_id uuid, group_id uuid, held boolean)
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_ttl constant interval := interval '12 seconds';
begin
  perform public.plan_require_editor(p_plan);

  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  update public.plan_cell_locks l
     set last_seen = now(), expires_at = now() + v_ttl
   where l.plan_id = p_plan and l.session_id = p_session and l.user_id = auth.uid();

  update public.plan_frame_locks l
     set last_seen = now(), expires_at = now() + v_ttl
   where l.plan_id = p_plan and l.session_id = p_session and l.user_id = auth.uid();

  -- 'badge' for a cell, 'moment' for a frame: the words the board uses, so the page does not have to
  -- translate between what it draws and what the server calls things.
  return query
    select 'badge'::text, w.frame_id, w.group_id,
           exists (select 1 from public.plan_cell_locks l
                    where l.frame_id = w.frame_id and l.group_id = w.group_id and l.session_id = p_session)
      from (select distinct c.frame_id, c.group_id
              from public.plan_cell_list(coalesce(p_cells, '[]'::jsonb)) c) w
    union all
    select 'moment'::text, f.id, null::uuid,
           exists (select 1 from public.plan_frame_locks l
                    where l.frame_id = f.id and l.session_id = p_session)
      from (select distinct u as id from unnest(p_frames) u) f;
end;
$body$;

-- Putting one badge down (the gesture ended, or the 5 s idle release fired).
--
-- No role check and no auth.uid() test: the session id is the credential, exactly as 016's
-- release_my_locks() treats it, and a planner who has just been demoted must still be able to let go.
drop function if exists public.plan_unlock_cells(uuid, jsonb, uuid);
create function public.plan_unlock_cells(p_plan uuid, p_cells jsonb, p_session uuid)
returns void
language sql security definer set search_path = ''
as $body$
  delete from public.plan_cell_locks l
   where l.plan_id = p_plan
     and l.session_id = p_session
     and (l.frame_id, l.group_id) in (
       select c.frame_id, c.group_id from public.plan_cell_list(p_cells) c
     );
$body$;

drop function if exists public.plan_unlock_frame(uuid, uuid);
create function public.plan_unlock_frame(p_frame uuid, p_session uuid)
returns void
language sql security definer set search_path = ''
as $body$
  delete from public.plan_frame_locks l where l.frame_id = p_frame and l.session_id = p_session;
$body$;

-- Everything this page was holding, at once. A page that is going away cannot be trusted to walk its own
-- list, and a hidden tab is not working on anything. p_plan may be null, and usually is: a session can
-- have touched two plans in one page load, and a release on unload must not leave one of them behind.
drop function if exists public.plan_release_all(uuid, uuid);
create function public.plan_release_all(p_session uuid, p_plan uuid default null)
returns void
language plpgsql security definer set search_path = ''
as $body$
begin
  -- Both deletes always run: `p_plan is null or l.plan_id = p_plan` is a filter, not a branch, so there is
  -- no path where one table is emptied and the other is not.
  delete from public.plan_cell_locks l
   where l.session_id = p_session and (p_plan is null or l.plan_id = p_plan);
  delete from public.plan_frame_locks l
   where l.session_id = p_session and (p_plan is null or l.plan_id = p_plan);
end;
$body$;

-- ============================================================
-- 9. Who is editing, for the board.
--
--    Named rows rather than a presence list, because the strip needs "Priya is editing Gate Crew at +1:00"
--    and the overlay needs to know which badges are somebody else's. Only LIVE rows come back -- a row
--    that can be stolen is not in anybody's way, and painting a ring for it would teach planners to
--    ignore rings.
--
--    mine says "held by a session of my user", not "held by this page": two tabs of one account are
--    indistinguishable here on purpose, because telling them apart would mean handing out session ids.
--    The way past that is plan_lock_cells(..., p_take_over => true), which needs no id at all.
-- ============================================================
drop function if exists public.plan_lock_holders(uuid);
create function public.plan_lock_holders(p_plan uuid)
returns table (
  kind text,
  frame_id uuid,
  group_id uuid,
  t_s integer,
  group_name text,
  user_id uuid,
  display_name text,
  since timestamptz,
  expires_at timestamptz,
  mine boolean
)
language plpgsql security definer set search_path = ''
as $body$
#variable_conflict use_column
declare
  v_steal constant interval := interval '7 seconds';
begin
  perform public.plan_require_editor(p_plan);

  return query
    select 'badge'::text, c.frame_id, c.group_id, f.t_s, g.name, c.user_id, pr.display_name,
           c.last_seen, c.expires_at, (c.user_id = auth.uid())
      from public.plan_cell_locks c
      join public.plan_frames f on f.id = c.frame_id
      join public.groups g on g.id = c.group_id
      left join public.profiles pr on pr.id = c.user_id
     where c.plan_id = p_plan
       and c.expires_at > now()
       and c.last_seen > now() - v_steal
    union all
    select 'moment'::text, l.frame_id, null::uuid, f.t_s, null::text, l.user_id, pr.display_name,
           l.last_seen, l.expires_at, (l.user_id = auth.uid())
      from public.plan_frame_locks l
      join public.plan_frames f on f.id = l.frame_id
      left join public.profiles pr on pr.id = l.user_id
     where l.plan_id = p_plan
       and l.expires_at > now()
       and l.last_seen > now() - v_steal
     order by 1, 4, 5;
end;
$body$;

-- ============================================================
-- 10. Permissions, the pattern 016 and 040 established. The schema's default privileges hand every new
--     function an EXECUTE to anon, so each one is taken back explicitly and granted back only where it
--     belongs. The two internal helpers are granted to nobody: they are called by the functions above,
--     which run as the definer, so no client needs them and no client should have them.
-- ============================================================
revoke execute on function public.plan_cell_list(jsonb) from public, anon, authenticated;
revoke execute on function public.plan_require_editor(uuid) from public, anon, authenticated;

revoke execute on function public.plan_lock_cells(uuid, jsonb, uuid, boolean) from public, anon;
revoke execute on function public.plan_lock_frame(uuid, uuid, uuid, boolean) from public, anon;
revoke execute on function public.plan_renew(uuid, jsonb, uuid[], uuid) from public, anon;
revoke execute on function public.plan_unlock_cells(uuid, jsonb, uuid) from public, anon;
revoke execute on function public.plan_unlock_frame(uuid, uuid) from public, anon;
revoke execute on function public.plan_release_all(uuid, uuid) from public, anon;
revoke execute on function public.plan_lock_holders(uuid) from public, anon;

grant execute on function public.plan_lock_cells(uuid, jsonb, uuid, boolean) to authenticated;
grant execute on function public.plan_lock_frame(uuid, uuid, uuid, boolean) to authenticated;
grant execute on function public.plan_renew(uuid, jsonb, uuid[], uuid) to authenticated;
grant execute on function public.plan_unlock_cells(uuid, jsonb, uuid) to authenticated;
grant execute on function public.plan_unlock_frame(uuid, uuid) to authenticated;
grant execute on function public.plan_release_all(uuid, uuid) to authenticated;
grant execute on function public.plan_lock_holders(uuid) to authenticated;

comment on function public.plan_lock_cells(uuid, jsonb, uuid, boolean) is
  'Take these badges, all or none; refuses with PT423 and the holder''s name (081).';
comment on function public.plan_lock_frame(uuid, uuid, uuid, boolean) is
  'Take this moment for a retime; refuses while another session holds a badge standing in it (081).';
comment on function public.plan_lock_holders(uuid) is
  'Who is editing this plan right now, without their session ids (081).';

-- Next: 082 makes frame_place() the only way a position is written, so a lock is not merely asked for --
-- it is the thing the write is checked against.
