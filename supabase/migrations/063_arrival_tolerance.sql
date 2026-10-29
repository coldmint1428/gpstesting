-- 063_arrival_tolerance.sql
--
-- Step 27 of the planning stage: a moment closes itself when the group's IC is CLOSE ENOUGH to its point -- as close as
-- that IC's own radius, which the IC or the planner may set -- and not only when the IC is already standing inside a
-- zone that contains the point.
--
-- THE TWO HALVES OF THE MODEL, because this file is the second one and they must not be confused.
--   * On the member's end the timeline says what time to be at which zone, and the map draws the route. Those
--     intermediate moments are the route: they exist so the walk can be seen and so nobody is judged for cutting a
--     corner. A marshal may confirm one, and 057 lets a moment close itself when the IC is inside its zone.
--   * What actually matters is whether the group is where the plan wanted it BY the planned time. On the ground that
--     is a distance, not a polygon: a phone in a pocket at the back of a crowd, a stop drawn twenty metres from the
--     doorway, a zone whose edge nobody can see. 057's rule could not close those, so a planner had to tap every one.
--
-- WHY A RADIUS AND NOT A BETTER POLYGON. 046 deliberately ruled named states out, and step 26 settled that a point
-- inside a zone is a place. A polygon is a planner's statement about the venue and is locked once drawn; a radius is a
-- statement about a phone, which is a different fact and belongs to a different owner. Turning the polygon into the
-- judge would have meant either shrinking zones to doorways (destroying what they are for -- No-Go alerts, presence,
-- the member's "which zone") or judging people on the polygon's edge, which is exactly the thing GPS cannot resolve.
--
-- PER IC, PER EVENT, WHICH IS A ROW THAT ALREADY EXISTS. `group_members` is
-- (group, person, event) -- the membership row -- so the radius lives there, one column, no new table and no new
-- policy: 002's read policy already lets the event's people read their own membership, and R3 has nothing to add. Two
-- ICs of one group may honestly need two numbers (one phone in a pocket, one on a lanyard at the back of the crowd),
-- and the same person at another event has another venue.
--
-- WHAT THE NUMBER MAY BE. Default 30 m, band 5..100. The floor is below any honest fix -- a tighter radius than 5 m is
-- a claim about centimetres that no phone makes. The ceiling is where "here" stops meaning anything: a venue's crowd,
-- a phone's error and a two-minute-old reading all blur at about that distance, and beyond it a group could be told it
-- arrived while it is still two moments away. Both ends are a CHECK on the column, so a caller cannot store 0 or 400
-- even if a function forgets to ask.
--
-- WHAT COUNTS AS EVIDENCE, and why these two rules are borrowed rather than invented. 021 already decided, for the
-- live map and for zone presence, that a reading older than two minutes or worse than 100 m is not evidence, and that
-- GPS error at an edge is allowed for by widening the test by min(accuracy, 15). The distance test here is the same
-- sentence: `distance <= radius + min(accuracy, 15)`. A second set of thresholds would be a second opinion about the
-- same phone, which is the mistake finding 104 named.
--
-- AND WHY THE WINDOW IS BOUNDED BY THE SESSION'S OWN START. `locations` carries no session id -- it is a table of
-- readings per event, with a seven-day retention, written long before a plan is started -- so "the last two minutes"
-- alone could reach back before T+0 and use a reading taken while the group was setting up. The window is therefore
-- `greatest(p_at - 2 minutes, t0_at)`: inside this session, and recent. A reading with `source = 'stop'` is not a
-- position at all (003): the person pressed Stop sharing and the row keeps their last coordinate.
--
-- THE FIRST EVIDENCE DATES THE ARRIVAL. Two ICs, two ways of being there (inside the zone, or within the radius), and
-- a tick that runs every five seconds: the instant recorded is the earliest evidence any of them gave, and then the
-- later of that and the planned time -- `greatest(planned, first)`, the same expression 057 wrote, so a tick that runs
-- late dates the arrival when it happened and a group that was there early is dated to the plan. `marked_by` stays
-- null: nobody said it, the tick did.
--
-- THE PLACE GATE IS KEPT, and it is the one rule this file must not lose. A point in open ground is a ROUTE POINT: it
-- exists so the map can draw the walk, and a phone passing within thirty metres of a corner of the path is not an
-- arrival. So a moment may close itself only when its drawn point stands in a zone that is somewhere to stand -- the
-- same three kinds 062 calls a place (`zone`, `stage`, `entrance`), so "somewhere to have arrived at" means the same
-- thing in the read and in the tick (finding 104). A no-go area or an obstacle is a cordon, not a destination: a moment
-- drawn inside one waits for a tap like any other unplaceable moment.
--
-- THE DOOR IS A FUNCTION, because `group_members` has a read policy and no write policy anywhere (002/R3): a client
-- cannot update the column directly and should not be able to. `set_arrival_tolerance` is security definer and admits
-- the same three callers `progress_mark` admits (050): the person themself, the event's root or planner, and the group's
-- own admin. A marshal is not among them -- a marshal records outcomes, and this is a knob on the plan (038 keeps plan
-- writes to root and planner). Only an IC has a radius, because only an IC shares a phone; setting one for somebody
-- else's phone would be storing a number that nothing reads.
--
-- R2: the column is ADDED (no function signature changes), so `plan_auto_close` is `create or replace` and keeps the
-- grants 057 gave it (revoked from everyone -- it is the tick's, called as definer by `plan_push_tick`). R8: its body
-- is 057's verbatim except the gate's kinds and the evidence query. R4: the new function is revoked from public and
-- anon and granted to authenticated. R1: `extensions.` is qualified everywhere it is used.

-- ============================================================
-- 1. The radius, on the row that already says who this person is here
-- ============================================================
alter table public.group_members
  add column if not exists ic_tolerance_m integer not null default 30
    constraint group_members_ic_tolerance_check check (ic_tolerance_m between 5 and 100);

comment on column public.group_members.ic_tolerance_m is
  'How close this IC''s phone must be to a moment''s drawn point for the tick to close it automatically, in metres '
  '(5..100, default 30). Only read for is_ic rows and only when the point stands in a zone (063).';

-- ============================================================
-- 2. The door: who may set it
-- ============================================================
-- Returns the metres now in force, so a caller can show what was written rather than guess.
create or replace function public.set_arrival_tolerance(p_event uuid, p_metres integer, p_user uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_uid uuid := auth.uid();
  v_target uuid := coalesce(p_user, auth.uid());
  v_group uuid;
  v_is_ic boolean;
begin
  if v_uid is null then
    raise exception 'Sign in to set an arrival radius.' using errcode = '42501';
  end if;
  if p_metres is null then
    raise exception 'Say how many metres.' using errcode = '22023';
  end if;
  if p_metres < 5 or p_metres > 100 then
    raise exception 'An arrival radius is between 5 and 100 metres, not %.', p_metres using errcode = '22023';
  end if;

  select gm.group_id, gm.is_ic into v_group, v_is_ic
    from public.group_members gm
   where gm.event_id = p_event and gm.user_id = v_target;
  if not found then
    raise exception 'That person is not in a group of this event, so there is no radius to set.' using errcode = '42501';
  end if;

  if not coalesce(v_is_ic, false) then
    raise exception 'Only an IC shares a phone, so only an IC has an arrival radius.' using errcode = '42501';
  end if;

  -- The same three doors 050's progress_mark uses: the person themself, the event's ops, the group's own admin.
  if not (v_target = v_uid
          or public.has_event_role(p_event, array['root', 'planner'])
          or public.is_group_admin(v_group)) then
    raise exception 'Only the event''s ops, your group''s admin, or you can set your arrival radius.' using errcode = '42501';
  end if;

  update public.group_members gm
     set ic_tolerance_m = p_metres
   where gm.event_id = p_event and gm.user_id = v_target;
  return p_metres;
end;
$body$;

comment on function public.set_arrival_tolerance(uuid, integer, uuid) is
  'Set the arrival radius of one IC of one event (default: yourself), in metres, 5..100. Callable by the person '
  'themself, the event''s root or planner, or the group''s admin; refused for a person who is not an IC. Answers the '
  'metres now in force (063).';

-- ============================================================
-- 3. The tick: a moment closes when the IC is inside the zone OR within that IC's own radius
-- ============================================================
-- Returns how many moments it closed. p_session null means every live plan session (the tick); a named session is what
-- a check stands on.
create or replace function public.plan_auto_close(p_session uuid default null, p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_n integer := 0;
  v_session record;
  v_moment record;
  v_point extensions.geography;
  v_entered timestamptz;
begin
  for v_session in
    select es.id, es.event_id, es.plan_id, es.t0_at
      from public.event_sessions es
     where es.plan_id is not null
       and es.t0_at is not null
       and es.ended_at is null
       and (p_session is null or es.id = p_session)
     order by es.id
  loop
    -- The group's CURRENT moment only: the last one the clock has reached. An earlier moment that was never marked is
    -- history -- a tick that was not there cannot claim the group was in a zone ten minutes ago -- and the next one has
    -- not happened. Same carry-forward the board draws with: a frame that does not state the group is not its moment.
    for v_moment in
      select distinct on (s.group_id)
             s.group_id, s.frame_id, s.t_s, s.lat, s.lng, s.state, s.verify,
             v_session.t0_at + make_interval(secs => s.t_s) as planned_at
        from (
          select pos.group_id, f.id as frame_id, f.t_s, pos.lat, pos.lng, pos.state, pos.verify
            from public.plan_positions pos
            join public.plan_frames f on f.id = pos.frame_id
           where f.plan_id = v_session.plan_id
        ) s
       where v_session.t0_at + make_interval(secs => s.t_s) <= p_at
       order by s.group_id, s.t_s desc
    loop
      continue when v_moment.state <> 'on_site' or v_moment.verify <> 'auto';

      -- Already said. `progress_mark`'s rule is one row per group per moment, so the tick must not make a second
      -- opinion of its own either.
      if exists (
        select 1 from public.plan_progress pr
         where pr.session_id = v_session.id
           and pr.frame_id = v_moment.frame_id
           and pr.group_id = v_moment.group_id
      ) then
        continue;
      end if;

      v_point := extensions.st_setsrid(extensions.st_makepoint(v_moment.lng, v_moment.lat), 4326)::extensions.geography;

      -- THE PLACE GATE (057's rule, 062's kinds). A route point is not somewhere to have arrived: the gate is what
      -- keeps "a phone passed within thirty metres of this corner" from being an arrival.
      if not exists (
        select 1
          from public.zones z
         where z.event_id = v_session.event_id
           and z.kind in ('zone', 'stage', 'entrance')
           and extensions.st_dwithin(z.shape, v_point, 0)
      ) then
        continue;
      end if;

      -- The earliest evidence that an IC of this group is at this moment: inside a zone that contains the drawn point
      -- (057's test, unchanged), or within that IC's own radius of the point. Null when nobody has said anything.
      select min(ev.evidence_at) into v_entered
        from public.group_members gm
        join lateral (
          select zp.entered_at as evidence_at
            from public.zone_presence zp
            join public.zones z on z.id = zp.zone_id and z.event_id = v_session.event_id
           where zp.user_id = gm.user_id
             and zp.session_id = v_session.id
             and zp.exited_at is null
             and extensions.st_dwithin(z.shape, v_point, 0)
          union all
          select l.recorded_at as evidence_at
            from public.locations l
           where l.event_id = v_session.event_id
             and l.user_id = gm.user_id
             and coalesce(l.source, 'gps') <> 'stop'
             and l.accuracy > 0
             and l.accuracy <= 100
             and l.recorded_at <= p_at
             and l.recorded_at > greatest(p_at - interval '2 minutes', v_session.t0_at)
             and extensions.st_dwithin(
                   extensions.st_setsrid(extensions.st_makepoint(l.lng, l.lat), 4326)::extensions.geography,
                   v_point,
                   gm.ic_tolerance_m + least(greatest(coalesce(l.accuracy, 0), 0), 15))
        ) ev on true
       where gm.event_id = v_session.event_id
         and gm.group_id = v_moment.group_id
         and gm.is_ic;
      if v_entered is null then
        continue;
      end if;

      insert into public.plan_progress
        (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
      values
        (v_session.id, v_session.plan_id, v_session.event_id, v_moment.frame_id, v_moment.group_id,
         'arrived', greatest(v_moment.planned_at, v_entered), null)
      on conflict (session_id, frame_id, group_id) do nothing;
      if found then
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;
  return v_n;
end;
$body$;

comment on function public.plan_auto_close(uuid, timestamptz) is
  'Close the current moment of every group whose position is auto and on site, when the moment''s drawn point stands '
  'in a zone a group can be sent to AND one of its ICs is either inside a zone containing the point or within that '
  'IC''s own arrival radius of it, with a reading no older than two minutes inside this session; marked_by null and '
  'marked_at the later of the plan and the first evidence (057, radius in 063).';

-- ============================================================
-- 4. Grants (R4) and the schema cache
-- ============================================================
revoke execute on function public.set_arrival_tolerance(uuid, integer, uuid) from public, anon;
grant execute on function public.set_arrival_tolerance(uuid, integer, uuid) to authenticated;

-- R2, restated: `plan_auto_close` keeps 057's privileges across `create or replace` (it is revoked from public, anon
-- and authenticated, and `plan_push_tick` calls it as its definer). Nothing to grant here -- only to remember not to.

notify pgrst, 'reload schema';
