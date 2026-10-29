-- 058_plan_log.sql
--
-- Step 22 of the planning plan: the plan's own log of what a planner said, one tap to ack it, and the "your timetable
-- changed" push that goes to the groups whose moments actually changed -- and to nobody else.
--
-- WHY A SECOND LOG. The event already has one: `broadcasts` (032) is a message to people, with a banner on the event
-- page, a "seen" instant and a "Got it" instant, and a line in `show_log` when a run sheet is running. None of that is
-- a plan's business. A plan's message is about moments: it is sent while a plan is running or about to, it is addressed
-- to the groups the plan places (a group with no part in the plan has nothing to be told), it is a record that outlives
-- the session, and its acknowledgement is one tap -- "the group's people have it" -- not a seen state nobody reads.
-- 031's `show_log` is the run sheet's log and is about to be deleted (step 25); a plan message must not be written into
-- a table that is going away, and a plan session must not borrow a log whose kinds are a run sheet's. So this file adds
-- `plan_log`, and the check asserts that a plan broadcast writes one row here and **zero** rows in `show_log`.
--
-- WHY A SINGLE ACK. 032's two instants are a compromise with banners: `seen_at` when the banner rendered, `acked_at`
-- when a person pressed. The plan log has no banner apart from the schedule, and the person reading the message is
-- already on the screen where it matters, so "seen" would be this app guessing that a browser painted something. One
-- tap writes `acked_at`; the tally a planner reads is "3 of 5 got it", which is a fact, and "waiting on Sound", which
-- is the list to radio. A second tap changes nothing (the first instant stands), so a double press cannot move the
-- record.
--
-- WHO A BROADCAST REACHES. The audience is worked out when it is sent:
--   all     every member of every group the plan places (a position of that group in any frame of this plan), not
--           every person in the event: a plan's message is about the plan, and a group with no part in it has nothing
--           to do on the ground.
--   group   one of those groups, named by the caller.
--   ops     the root, planners and marshals of the event -- a note to the people running it.
-- The sender is never a recipient (032's rule), so "3 of 5" counts the other four plus whoever else was addressed.
--
-- WHO SENDS. The root, a planner or a marshal: the ops board is where this is written from (PlanOps, step 20/21), and
-- the board is the marshal's screen during a plan. 032 keeps event-wide messages to root and planner; this is the
-- narrower instrument -- "Sound, hold at the gate" -- and the people taking the hand-back are exactly the people who
-- have to be able to say it. A group admin or a member is refused with 42501.
--
-- THE "TIMELINE CHANGED" PUSH IS TARGETED. A republish that moves Gate Crew's +5:00 point and leaves Sound's walk
-- alone is a change for Gate Crew only; telling everyone trains people to ignore the notification. So publishing
-- compares the walk it is announcing with the walk it replaces, group by group, and writes one `plan_log` row (kind
-- `timeline`) whose recipients are the members of the **affected groups only**. Three things make that comparison
-- honest rather than a string diff of the JSON:
--   1. it compares the walk as each group experiences it -- the position in force at *every* frame time, carry-forward
--      included (plan_version_walk). A frame moved earlier changes a carried group's walk too, and that group has to be
--      told; comparing only the frames that state a position would miss it.
--   2. it compares the frame's note as well as the time and the point: the note is what the group reads on their
--      schedule ("doors"), so changing it changes what they were told.
--   3. it rounds to six decimal places (about a tenth of a metre) so a float that comes back a hair different is not a
--      notification.
-- A republish that changes nothing (the same walk, re-announced) writes no log row and queues no push. A **first**
-- publish notifies nobody -- nobody was following that plan yet -- with one exception that is the whole point of
-- editing a running show: a **copy**'s first publish compares against the plan it was cut from, from the cut onward,
-- because the running session is carried onto it (053/054) and the people whose timetable just changed are the ones who
-- need to hear it.
--
-- WHAT IS NOT HERE. There is no clear/take-down and no banner: a message leaves the schedule when it is acked (it
-- collapses to a quiet line), and the log is a record rather than a wall. There is no reply and no thread. Pushes are
-- suppressed for simulation events, as 032 does and 057 does -- the log row is still written, because it is a record.
--
-- R3: both new tables get RLS, a read policy and no write grant at all; the two functions are the only doors. R4: both
-- grants are revoked from public and anon and given to authenticated. R8: plan_publish's body is 054's, with the
-- comparison and the log after the version insert.

-- ============================================================
-- 1. The log
-- ============================================================
create table if not exists public.plan_log (
  id bigserial primary key,
  -- Denormalised so the read policy needs no join, as plans/plan_frames do it.
  event_id uuid not null references public.events (id) on delete cascade,
  -- A plan's log; deleting the plan takes its messages (they are about that plan, not about the event).
  plan_id uuid not null references public.plans (id) on delete cascade,
  -- The session it was sent in, when there was one. A record, not a key: the log outlives the session.
  session_id uuid references public.event_sessions (id) on delete set null,
  -- The revision the change produced, on a `timeline` row. Null on a message: a message is not a version.
  rev integer,
  kind text not null check (kind in ('message', 'timeline')),
  audience text not null check (audience in ('all', 'group', 'ops', 'groups')),
  -- The one group of a `group` message. `groups` (a timeline change) leaves it null: the affected groups are the
  -- recipients' own groups, and there can be several.
  audience_group uuid references public.groups (id) on delete set null,
  body text not null check (char_length(body) between 1 and 300),
  urgent boolean not null default false,
  from_user uuid references auth.users (id) on delete set null,
  from_name text,
  -- Wall clock, not now(): two rows written in one transaction must be tellable apart (finding 74).
  at timestamptz not null default clock_timestamp(),
  check (kind = 'message' or rev is not null),
  check ((audience = 'group') = (audience_group is not null))
);
create index if not exists plan_log_plan on public.plan_log (plan_id, id desc);

comment on table public.plan_log is
  'What a planner told a plan''s groups, and what the plan itself changed (a timeline row). One row per message or '
  'per publish that moved somebody''s walk; recipients and their single ack live in plan_log_recipients (058, step 22).';

create table if not exists public.plan_log_recipients (
  log_id bigint not null references public.plan_log (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The group the person was told as (null for an `ops` message). Carried so "waiting on Sound" is a group name and
  -- not a person's name read off a screen.
  group_id uuid references public.groups (id) on delete set null,
  -- One tap. Null means the person has not said they have it; the first instant written stands.
  acked_at timestamptz,
  primary key (log_id, user_id)
);
create index if not exists plan_log_recipients_group on public.plan_log_recipients (group_id);

comment on table public.plan_log_recipients is
  'One row per person a plan message or timeline change was addressed to, with the instant they pressed Got it. '
  'Written by plan_broadcast()/plan_publish() only; ack is plan_log_ack() (058, step 22).';

alter table public.plan_log enable row level security;
alter table public.plan_log_recipients enable row level security;

-- The two read rules ask about each other's table, so each asks through a security definer helper (032's shape) and
-- Postgres does not go round in circles.
create or replace function public.plan_log_recipient_of(p_id bigint)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.plan_log_recipients r where r.log_id = p_id and r.user_id = auth.uid());
$$;

create or replace function public.plan_log_ops_of(p_id bigint)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.plan_log l
    where l.id = p_id and public.has_event_role(l.event_id, array['root', 'planner', 'marshal'])
  );
$$;

-- Ops staff of the event read the whole log; everyone else only what was addressed to them.
drop policy if exists plan_log_read on public.plan_log;
create policy plan_log_read on public.plan_log for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']) or public.plan_log_recipient_of(id));

comment on policy plan_log_read on public.plan_log is
  'Ops staff read the plan''s log; a member reads the rows addressed to them (058, step 22). No write policy: the two '
  'functions are the doors.';

-- Your own receipt; ops staff see every receipt (the "who got it" tally).
drop policy if exists plan_log_recipients_read on public.plan_log_recipients;
create policy plan_log_recipients_read on public.plan_log_recipients for select to authenticated
  using (user_id = (select auth.uid()) or public.plan_log_ops_of(log_id));

-- R3/R4: a read grant and no write grant. anon is revoked because the default ACL hands a new public table arwdDxtm
-- to it (finding 1).
revoke all on table public.plan_log, public.plan_log_recipients from anon, authenticated, public;
grant select on table public.plan_log, public.plan_log_recipients to authenticated;

-- ============================================================
-- 2. A version's walk, group by group
-- ============================================================
-- The frames JSON a version stores, expanded into the position each group is in at every frame time -- the earlier
-- statement carried forward, exactly as the board draws it (046's flags travel with the point). This is the comparison
-- unit for "did this group's walk change": a frame that moves earlier moves a carried group's walk too, and that group
-- is affected whether or not it has a position of its own at that frame.
--
-- An off-site statement is emitted as a row with no coordinates, so the sequence shows the excursion and a move from
-- on site to off site is a change like any other. Frames with no position anywhere are skipped; a group with no
-- position at any frame does not appear for that version (and so is "new" when it appears at all).
create or replace function public.plan_version_walk(p_frames jsonb)
returns table (group_id uuid, t_s integer, note text, state text, lat double precision, lng double precision)
language plpgsql
immutable
security definer
set search_path = ''
as $body$
declare
  v_frame jsonb;
  v_pos jsonb;
  v_t integer;
  v_last jsonb := '{}'::jsonb; -- group id -> the position statement in force
  v_groups text[];
  g text;
begin
  select array_agg(distinct p ->> 'group_id')
    into v_groups
    from jsonb_array_elements(coalesce(p_frames, '[]'::jsonb)) f,
         jsonb_array_elements(coalesce(f -> 'positions', '[]'::jsonb)) p;
  if v_groups is null then
    return;
  end if;

  for v_frame in
    select f from jsonb_array_elements(coalesce(p_frames, '[]'::jsonb)) f order by (f ->> 't_s')::integer
  loop
    v_t := (v_frame ->> 't_s')::integer;
    for v_pos in
      select p from jsonb_array_elements(coalesce(v_frame -> 'positions', '[]'::jsonb)) p
    loop
      v_last := jsonb_set(v_last, array[v_pos ->> 'group_id'], v_pos, true);
    end loop;
    foreach g in array v_groups
    loop
      if v_last ? g then
        group_id := g::uuid;
        t_s := v_t;
        -- The note is the frame's own, which is what the schedule shows for that moment: a carried-forward position
        -- still sits in a frame whose note is what the group reads.
        note := coalesce(v_frame ->> 'note', '');
        state := coalesce(v_last -> g ->> 'state', 'on_site');
        lat := case when state = 'off_site' then null else (v_last -> g ->> 'lat')::double precision end;
        lng := case when state = 'off_site' then null else (v_last -> g ->> 'lng')::double precision end;
        return next;
      end if;
    end loop;
  end loop;
end;
$body$;

comment on function public.plan_version_walk(jsonb) is
  'A plan version''s frames expanded into each group''s effective position at every frame time (carry-forward, notes, '
  'off-site gaps). The unit publishing compares to decide whose timetable changed (058, step 22).';

revoke execute on function public.plan_version_walk(jsonb) from public, anon, authenticated;

-- ============================================================
-- 3. Send a message to the plan's groups
-- ============================================================
create or replace function public.plan_broadcast(
  p_plan uuid,
  p_body text,
  p_audience text default 'all',
  p_group uuid default null,
  p_urgent boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_session uuid;
  v_me uuid := auth.uid();
  v_from text := public.show_who(auth.uid());
  v_id bigint;
  v_people integer;
  v_groups integer;
  v_label text;
  v_sim boolean;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if v_event is null then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner', 'marshal']) then
    raise exception 'Only the root, a planner or a marshal can message a plan''s groups.' using errcode = '42501';
  end if;

  p_audience := coalesce(nullif(btrim(p_audience), ''), 'all');
  if p_audience not in ('all', 'group', 'ops') then
    raise exception 'Pick who gets the message';
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 300 then
    raise exception 'Write a message of 1 to 300 characters';
  end if;

  if p_audience = 'group' and p_group is null then
    raise exception 'Pick the group';
  end if;
  if p_audience <> 'group' then
    p_group := null;
  elsif not exists (
    select 1
      from public.plan_positions pp
      join public.plan_frames f on f.id = pp.frame_id
     where f.plan_id = p_plan and pp.group_id = p_group
  ) then
    -- The same rule the audience uses: a plan's message is about the plan, and a group the plan never places has
    -- nothing to do on the ground.
    raise exception 'That group has no part in this plan.' using errcode = '22023';
  end if;

  select s.id into v_session
    from public.event_sessions s
   where s.plan_id = p_plan and s.ended_at is null and s.starts_at <= now()
   order by s.starts_at desc
   limit 1;

  insert into public.plan_log (event_id, plan_id, session_id, kind, audience, audience_group, body, urgent, from_user,
                               from_name)
  values (v_event, p_plan, v_session, 'message', p_audience, p_group, p_body, coalesce(p_urgent, false), v_me, v_from)
  returning id into v_id;

  insert into public.plan_log_recipients (log_id, user_id, group_id)
  select v_id, gm.user_id, gm.group_id
    from public.group_members gm
   where gm.event_id = v_event
     and gm.user_id is distinct from v_me
     and case p_audience
           when 'all' then exists (
             select 1
               from public.plan_positions pp
               join public.plan_frames f on f.id = pp.frame_id
              where f.plan_id = p_plan and pp.group_id = gm.group_id)
           when 'group' then gm.group_id = p_group
           else false
         end;

  if p_audience = 'ops' then
    insert into public.plan_log_recipients (log_id, user_id, group_id)
    select distinct on (er.user_id) v_id, er.user_id, null::uuid
      from public.event_roles er
     where er.event_id = v_event
       and er.role in ('root', 'planner', 'marshal')
       and er.user_id is distinct from v_me
     order by er.user_id;
  end if;

  select count(*)::integer,
         count(distinct r.group_id)::integer
    into v_people, v_groups
    from public.plan_log_recipients r
   where r.log_id = v_id;

  -- Nobody to tell is a message that never existed: take the row away, so the log does not record an announcement that
  -- reached no one.
  if v_people = 0 then
    delete from public.plan_log where id = v_id;
    raise exception 'Nobody would get this message: the plan has no groups, or nobody but you is in them';
  end if;

  v_label := case p_audience
               when 'all' then 'every group'
               when 'group' then coalesce((select g.name from public.groups g where g.id = p_group), 'the group')
               else 'the ops team (' || v_people || ')' end;

  select e.is_simulation into v_sim from public.events e where e.id = v_event;
  if not coalesce(v_sim, false) then
    insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
    select r.user_id, v_event, v_session, 'plan_message',
           'plan_message:' || v_id || ':' || r.user_id,
           case when coalesce(p_urgent, false) then 'URGENT · ' else '' end ||
             'Message from ' || v_from || ' to ' || v_label,
           p_body,
           jsonb_build_object('kind', 'plan_message', 'eventId', v_event, 'planId', p_plan,
                              'sessionId', v_session, 'logId', v_id, 'tag', 'plan-message-' || v_id)
      from public.plan_log_recipients r
     where r.log_id = v_id
    on conflict (dedup) do nothing;
    perform public.push_kick();
  end if;

  return jsonb_build_object('id', v_id, 'recipients', v_people, 'groups', v_groups);
end;
$body$;

comment on function public.plan_broadcast(uuid, text, text, uuid, boolean) is
  'Send a message to a plan''s groups (all / one / the ops team), record it in plan_log with one recipient row per '
  'person, and queue one plan_message push each. A member of the groups is never a sender; nobody gets the row the '
  'sender sent (058, step 22).';

-- ============================================================
-- 4. Read the log, and ack it
-- ============================================================
-- One call for both halves: the ops board wants the tally ("3 of 5", "waiting on Sound") and the member's schedule
-- wants their own rows with the instant they acked. The tally is null for a member: how many people a message reached
-- is the sender's business, and a member's own row is all they need.
--
-- A plan that no longer exists answers **no rows** rather than raising: a schedule can be holding a plan id for a
-- moment after the plan is deleted (the same lesson as finding 79), and "no messages" is the truth about a plan there
-- is nothing left to say about.
create or replace function public.plan_log_list(p_plan uuid, p_limit integer default 20)
returns table (
  id bigint,
  kind text,
  audience text,
  audience_group uuid,
  body text,
  urgent boolean,
  from_name text,
  at timestamptz,
  rev integer,
  recipients integer,
  acked integer,
  waiting text[],
  i_acked timestamptz,
  i_recipient boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_event uuid;
  v_ops boolean;
begin
  select p.event_id into v_event from public.plans p where p.id = p_plan;
  if v_event is null then
    return;
  end if;
  if not exists (select 1 from public.event_roles er where er.event_id = v_event and er.user_id = auth.uid())
     and not exists (select 1 from public.group_members gm where gm.event_id = v_event and gm.user_id = auth.uid())
  then
    raise exception 'You are not part of this event.' using errcode = '42501';
  end if;

  v_ops := public.has_event_role(v_event, array['root', 'planner', 'marshal']);

  return query
  select l.id,
         l.kind,
         l.audience,
         l.audience_group,
         l.body,
         l.urgent,
         l.from_name,
         l.at,
         l.rev,
         case when v_ops then (select count(*)::integer from public.plan_log_recipients r where r.log_id = l.id) end,
         case when v_ops then (select count(*)::integer from public.plan_log_recipients r
                                where r.log_id = l.id and r.acked_at is not null) end,
         case when v_ops then (
           select array_agg(distinct g.name order by g.name)
             from public.plan_log_recipients r
             join public.groups g on g.id = r.group_id
            where r.log_id = l.id and r.acked_at is null and r.group_id is not null
         ) end,
         (select r.acked_at from public.plan_log_recipients r where r.log_id = l.id and r.user_id = auth.uid()),
         exists (select 1 from public.plan_log_recipients r where r.log_id = l.id and r.user_id = auth.uid())
    from public.plan_log l
   where l.plan_id = p_plan
     and (v_ops or exists (select 1 from public.plan_log_recipients r
                            where r.log_id = l.id and r.user_id = auth.uid()))
   order by l.id desc
   limit greatest(1, least(coalesce(p_limit, 20), 100));
end;
$body$;

comment on function public.plan_log_list(uuid, integer) is
  'A plan''s log, newest first: every row with its tally and who is still to ack for ops staff, only the rows addressed '
  'to them (with their own ack instant) for everyone else (058, step 22).';

-- One tap. The first instant written stands, so pressing twice cannot move the record; a person the message was not
-- sent to is refused rather than silently ignored.
create or replace function public.plan_log_ack(p_log bigint)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_at timestamptz;
begin
  update public.plan_log_recipients
     set acked_at = clock_timestamp()
   where log_id = p_log and user_id = auth.uid() and acked_at is null
  returning acked_at into v_at;

  if v_at is null then
    select r.acked_at into v_at
      from public.plan_log_recipients r
     where r.log_id = p_log and r.user_id = auth.uid();
    if not found then
      raise exception 'That message was not sent to you.' using errcode = '42501';
    end if;
  end if;
  return v_at;
end;
$body$;

comment on function public.plan_log_ack(bigint) is
  'The recipient''s single ack: writes the wall-clock instant once and returns it; a second press returns the first '
  'instant; a non-recipient is refused with 42501 (058, step 22).';

-- ============================================================
-- 5. Publishing: announce, and tell the groups whose walk changed
-- ============================================================
-- R8: this is 054's body, with section 5's comparison and log inserted after the version insert. Everything above that
-- point is unchanged; the hand-over below it is unchanged.
create or replace function public.plan_publish(p_plan uuid, p_plan_rev integer)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_current integer;
  v_row public.plans;
  v_errors integer;
  v_first text;
  v_message text;
  v_frames jsonb;
  v_anchor uuid;
  v_session record;
  v_group uuid;
  v_cut_at timestamptz;
  -- step 22: the walk being replaced, the groups whose walk moved, and the log row that says so.
  v_prev jsonb;
  v_next jsonb;
  v_changed uuid[];
  v_n integer;
  v_names text;
  v_one text;
  v_label text;
  v_log bigint;
  v_log_session uuid;
begin
  -- Locked, not merely read. The revision compared below has to be the one the update bumps, or two publishes that
  -- both read 3 both pass this check and write versions 4 and 4-from-3.
  select event_id, rev into v_event, v_current
    from public.plans
   where id = p_plan
     for update;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can publish a plan.' using errcode = '42501';
  end if;

  -- A null is not a wildcard. The client always knows the revision it read; a caller that does not say is telling the
  -- database to publish over whatever is there, which is the behaviour this step exists to end.
  if p_plan_rev is null then
    raise exception 'Publishing must say which revision the screen is showing. Reload the plan and publish again.'
      using errcode = '22023';
  end if;

  if p_plan_rev <> v_current then
    raise exception
      'This plan changed while this screen had version % on it (it is now version %). Nothing was published; reload the plan and publish again.',
      p_plan_rev, v_current
      using errcode = 'PT409';
  end if;

  -- The 25 m rule is a warning while a plan is being drawn and a hard gate before anyone's timetable depends on
  -- it. Without this, "the limit" was only ever advice: the board coloured frames red and then let you publish.
  select count(*) into v_errors
    from public.plan_check(p_plan) c
   where c.severity = 'error';

  if v_errors > 0 then
    select c.message into v_first
      from public.plan_check(p_plan) c
     where c.severity = 'error'
     order by c.from_s, c.to_s, c.group_id
     limit 1;
    v_message := case
      when v_errors = 1 then format('This plan cannot be published yet: %s.', v_first)
      else format('This plan cannot be published yet (%s problems). The first is: %s.', v_errors, v_first)
    end;
    raise exception '%', v_message using errcode = '22023';
  end if;

  update public.plans
     set status = 'archived', updated_by = auth.uid(), updated_at = now()
   where event_id = v_event and status = 'live' and id <> p_plan;

  update public.plans
     set status = 'live', published_at = now(), rev = rev + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_plan
  returning * into v_row;

  -- ---------- the version ----------
  -- Taken from the tables, in this transaction, not from the row above: the frames are what was published. A publish
  -- of a plan with no frames still writes a version (an empty walk is a thing somebody published), which is why the
  -- aggregate is a scalar subquery and not the source of the INSERT.
  select coalesce(
           jsonb_agg(
             jsonb_build_object('id', s.id, 't_s', s.t_s, 'note', s.note, 'positions', s.positions)
             order by s.t_s
           ),
           '[]'::jsonb)
    into v_frames
    from (
      select f.id,
             f.t_s,
             f.note,
             coalesce(
               jsonb_agg(
                 jsonb_build_object('group_id', p.group_id, 'lat', p.lat, 'lng', p.lng,
                                    'state', p.state, 'verify', p.verify)
                 order by p.group_id
               ) filter (where p.group_id is not null),
               '[]'::jsonb) as positions
        from public.plan_frames f
        left join public.plan_positions p on p.frame_id = f.id
       where f.plan_id = p_plan
       group by f.id, f.t_s, f.note
    ) s;

  insert into public.plan_versions
    (plan_id, event_id, rev, name, for_date, t0_time, fork_of, fork_cut_s, frames, published_by)
  values
    (v_row.id, v_row.event_id, v_row.rev, v_row.name, v_row.for_date, v_row.t0_time,
     v_row.fork_of, v_row.fork_cut_s, v_frames, auth.uid());

  -- ---------- who has to be told (step 22) ----------
  -- The walk this publish replaces. For a plan that has been published before it is its own previous version; for the
  -- first publish of a copy it is the plan the copy was cut from, restricted to the part the copy could inherit (the
  -- cut onward) -- because a copy's first publish is how a running session is moved onto it and those people's
  -- timetable really did change. A first publish of a plan that is not a copy replaces nothing: nobody was following
  -- it, so nobody is told.
  select v.frames into v_prev
    from public.plan_versions v
   where v.plan_id = v_row.id and v.rev < v_row.rev
   order by v.rev desc
   limit 1;

  if v_prev is null and v_row.fork_of is not null and v_row.fork_cut_s is not null then
    select v.frames into v_prev
      from public.plan_versions v
     where v.plan_id = v_row.fork_of
     order by v.rev desc
     limit 1;
    if v_prev is not null then
      -- Only the future. The copy's own cut frame is where everyone already stood (the hand-over records them arrived
      -- at it), so a row at the cut is not a change for anybody; what the groups were told changes between the cut and
      -- the end of the walk. Comparing the two sides over the same window is what keeps "edit one group's moment,
      -- publish the copy" from telling every group on the plan.
      v_prev := (
        select coalesce(jsonb_agg(f order by (f ->> 't_s')::integer), '[]'::jsonb)
          from jsonb_array_elements(v_prev) f
         where (f ->> 't_s')::integer > v_row.fork_cut_s
      );
      v_next := (
        select coalesce(jsonb_agg(f order by (f ->> 't_s')::integer), '[]'::jsonb)
          from jsonb_array_elements(v_frames) f
         where (f ->> 't_s')::integer > v_row.fork_cut_s
      );
    end if;
  end if;

  if v_next is null then
    v_next := v_frames;
  end if;

  if v_prev is not null then
    with old_walk as (
      select w.group_id,
             array_agg(format('%s|%s|%s|%s|%s', w.t_s, w.note, w.state,
                              coalesce(round(w.lat::numeric, 6)::text, ''),
                              coalesce(round(w.lng::numeric, 6)::text, ''))
                       order by w.t_s) as path
        from public.plan_version_walk(v_prev) w
       group by w.group_id
    ), new_walk as (
      select w.group_id,
             array_agg(format('%s|%s|%s|%s|%s', w.t_s, w.note, w.state,
                              coalesce(round(w.lat::numeric, 6)::text, ''),
                              coalesce(round(w.lng::numeric, 6)::text, ''))
                       order by w.t_s) as path
        from public.plan_version_walk(v_next) w
       group by w.group_id
    )
    select array_agg(coalesce(n.group_id, o.group_id))
      into v_changed
      from new_walk n
      full join old_walk o on o.group_id = n.group_id
     where n.path is distinct from o.path;
  end if;

  if v_changed is not null and array_length(v_changed, 1) > 0 then
    v_n := array_length(v_changed, 1);
    select string_agg(g.name, ', ' order by g.name) into v_names
      from public.groups g where g.id = any(v_changed);
    if v_n = 1 then
      select g.name into v_one from public.groups g where g.id = v_changed[1];
    end if;
    v_label := case when v_n = 1 then v_one when v_n <= 3 then v_names else v_n || ' groups' end;

    select s.id into v_log_session
      from public.event_sessions s
     where s.plan_id = v_row.id and s.ended_at is null and s.starts_at <= now()
     order by s.starts_at desc
     limit 1;

    insert into public.plan_log (event_id, plan_id, session_id, rev, kind, audience, body, from_user, from_name)
    values (v_row.event_id, v_row.id, v_log_session, v_row.rev, 'timeline', 'groups',
            left(format('The timetable changed for %s (version %s).', v_label, v_row.rev), 300),
            auth.uid(), public.show_who(auth.uid()))
    returning id into v_log;

    insert into public.plan_log_recipients (log_id, user_id, group_id)
    select v_log, gm.user_id, gm.group_id
      from public.group_members gm
     where gm.event_id = v_row.event_id
       and gm.group_id = any(v_changed)
       and gm.user_id is distinct from auth.uid()
    on conflict do nothing;

    if exists (select 1 from public.events e where e.id = v_row.event_id and not e.is_simulation) then
      insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
      select r.user_id, v_row.event_id, v_log_session, 'plan_changed',
             'plan_changed:' || v_log || ':' || r.user_id,
             'Your timetable changed',
             g.name || ': version ' || v_row.rev || ' is published, and your moments changed. Check your schedule.',
             jsonb_build_object('kind', 'plan_changed', 'eventId', v_row.event_id, 'planId', v_row.id,
                                'sessionId', v_log_session, 'rev', v_row.rev, 'groupId', r.group_id,
                                'logId', v_log, 'tag', 'plan-change-' || v_log)
        from public.plan_log_recipients r
        join public.groups g on g.id = r.group_id
       where r.log_id = v_log
      on conflict (dedup) do nothing;
      perform public.push_kick();
    end if;
  end if;

  -- The revision a running session follows. A session that has ended keeps the one it ran. This is what a screen
  -- holding the old timetable compares a fresh read against (step 15), and it is written here, not by a trigger,
  -- so the two bumps are one statement's worth of truth.
  update public.event_sessions
     set plan_rev = v_row.rev
   where plan_id = p_plan
     and ended_at is null;

  -- ---------- the hand-over (053) ----------
  if v_row.fork_of is not null and v_row.fork_cut_s is not null then
    select f.id into v_anchor
      from public.plan_frames f
     where f.plan_id = v_row.id and f.t_s = v_row.fork_cut_s;

    for v_session in
      select s.id, s.t0_at
        from public.event_sessions s
       where s.plan_id = v_row.fork_of
         and s.event_id = v_row.event_id
         and s.ended_at is null
         and s.starts_at <= now()
         for update
    loop
      update public.event_sessions
         set plan_id = v_row.id, plan_rev = v_row.rev
       where id = v_session.id;

      v_cut_at := v_session.t0_at + make_interval(secs => v_row.fork_cut_s);
      if v_anchor is not null and v_session.t0_at is not null and v_cut_at <= now() then
        for v_group in
          select pp.group_id
            from public.plan_positions pp
           where pp.frame_id = v_anchor
             and pp.state <> 'off_site'
             and not exists (select 1 from public.plan_progress pg
                              where pg.session_id = v_session.id
                                and pg.frame_id = v_anchor
                                and pg.group_id = pp.group_id)
           order by pp.group_id
        loop
          perform public.progress_mark(v_session.id, v_anchor, v_group, 'arrived', v_cut_at);
        end loop;
      end if;
    end loop;
  end if;

  return v_row;
end;
$body$;

comment on function public.plan_publish(uuid, integer) is
  'Publishes a plan at the revision the caller is holding: refuses a stale one (PT409) and a missing one (22023), '
  'writes one immutable plan_versions row, tells the groups whose walk changed (a plan_log timeline row and one '
  'plan_changed push each), moves the running sessions'' revision, and carries an open session from the plan a copy '
  'was cut from (054, step 18; 058, step 22).';

-- ============================================================
-- 6. The two new push kinds
-- ============================================================
-- 057 restated this list from the database, and the database is the inventory: thirteen kinds, including the `sos` no
-- migration in this repository writes (finding 73). Two more, and nothing removed.
alter table public.push_queue drop constraint if exists push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check
  check (kind in ('get_ready', 'leave_now', 'late', 'message', 'nogo', 'next', 'hold', 'resume', 'change', 'sos',
                  'plan_due', 'plan_leave', 'plan_late', 'plan_message', 'plan_changed'));

-- ============================================================
-- 7. Grants (R4)
-- ============================================================
revoke execute on function public.plan_broadcast(uuid, text, text, uuid, boolean) from public, anon;
grant execute on function public.plan_broadcast(uuid, text, text, uuid, boolean) to authenticated;
revoke execute on function public.plan_log_list(uuid, integer) from public, anon;
grant execute on function public.plan_log_list(uuid, integer) to authenticated;
revoke execute on function public.plan_log_ack(bigint) from public, anon;
grant execute on function public.plan_log_ack(bigint) to authenticated;
-- The two policy helpers are called by the policies themselves, so they must be executable by a signed-in reader.
revoke execute on function public.plan_log_recipient_of(bigint) from public, anon;
grant execute on function public.plan_log_recipient_of(bigint) to authenticated;
revoke execute on function public.plan_log_ops_of(bigint) from public, anon;
grant execute on function public.plan_log_ops_of(bigint) to authenticated;
