-- 050_plan_actuals.sql
--
-- Step 14 of the planning plan: what actually happened, against what the plan said.
--
-- THE PLAN IS A FORECAST; THIS IS THE RECORD. A plan says "at +2:00 Sound is at the stage". On the night Sound
-- either got there -- at a moment somebody can point at -- or did not. Until now there was nowhere to put that
-- sentence for a plan session: movement_status belongs to the run-sheet engine and dies with it (step 25).
--
-- WHAT A ROW IS. One group's outcome at one frame of one session: 'arrived' or 'missed', plus when that was said
-- ('marked_at') and by whom ('marked_by'). One row per (session, frame, group): saying it twice corrects it
-- rather than adding a second opinion. There is no revision, because "what happened" is a statement and not a
-- document; the history a hand-over wants is step 21's log.
--
-- WHY THE COLUMNS ARE NOT CALLED at AND by. The plan sketched them that way, and both are keywords PostgreSQL
-- will not read off a PL/pgSQL record: `r.by` (and even `r."by"`) answers "record r has no field by" on this
-- project's own Postgres. The first status reader would have hit it, so the names are marked_at / marked_by from
-- the start -- the same fact, spelled so that SQL can say it back.
--
-- WHY 'missed' IS NOT DERIVED FROM THE CLOCK. A frame whose planned time has passed with nobody marking it is
-- 'late', not 'missed': the group may be three minutes behind and about to arrive, and a timetable that declares
-- them missed at the exact planned second would be crying wolf all night. 'missed' is a decision somebody makes.
-- session_status() derives the whole vocabulary -- pending / late / arrived / missed / not_required -- so the
-- client never has to guess, and lateness is measured from the plan's own clock:
--
--     planned_at = event_sessions.t0_at + plan_frames.t_s
--
-- t0_at, NOT starts_at. The doors can be at 18:00 and the call at 18:45 (the bench's own story), and the frames
-- are on the plan's clock; 039 gave the session its own t0_at precisely so the two could differ. A status board
-- built on starts_at would be 45 minutes out on the bench -- which is why step 14's check keeps the two apart and
-- asserts that the wrong formula would answer differently.
--
-- WHICH MOMENT A GROUP IS IN. A frame states only the groups that move at it; everybody else stands where the
-- last statement left them (038). session_status() walks that carry-forward, so a group's state at a frame is
-- decided by its last position at or before that frame -- the same rule the board draws with. An off-site
-- statement (046) is not a place to arrive at: that frame reads 'not_required', and progress_mark() refuses it
-- with a sentence rather than recording a fiction.
--
-- DELETING A FRAME DELETES WHAT HAPPENED AT IT (frame_id on delete cascade). The alternative -- an orphan mark
-- for a moment the plan no longer states -- would make the timetable disagree with itself. 041's client-supplied
-- ids are what make that survivable: undoing a deleted frame recreates the same id, and a mark that cascaded away
-- with it belonged to a moment that was, for a while, genuinely gone.
--
-- RLS (R3). The default ACL grants arwdDxtm on a new public table to anon and authenticated (finding 1); this file
-- revokes that and grants SELECT back to authenticated, and there is no write policy at all. Writes go through
-- progress_mark(), a security-definer function that checks the caller's role -- so a table grant plus a policy is
-- never the door, which is exactly the hole finding 1 was about.
--
-- R4 on both functions: revoked from public and anon, granted to authenticated.

-- ---------- the table ----------
-- event_id is denormalised for the read policy, as in 037 and 038: a policy that had to join to the session on
-- every row would be reading a second RLS-protected table to decide about this one.
create table if not exists public.plan_progress (
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  plan_id    uuid not null references public.plans (id) on delete cascade,
  event_id   uuid not null references public.events (id) on delete cascade,
  -- The moment, not the time. Deleting the frame deletes what was recorded about it.
  frame_id   uuid not null references public.plan_frames (id) on delete cascade,
  group_id   uuid not null references public.groups (id) on delete cascade,
  state      text not null,
  -- When somebody said it. Not the frame's planned time, and not the row's creation time.
  marked_at  timestamptz not null default now(),
  marked_by  uuid references public.profiles (id) on delete set null,

  -- One outcome per group per moment per run: saying it again is a correction.
  primary key (session_id, frame_id, group_id),
  constraint plan_progress_state_check check (state in ('arrived', 'missed'))
);

create index if not exists plan_progress_group_idx on public.plan_progress (session_id, group_id);

comment on table public.plan_progress is
  'One group''s outcome at one frame of one session: arrived or missed, when, by whom (050).';
comment on column public.plan_progress.marked_at is
  'When the outcome was recorded, not when the frame was planned for (050).';
comment on column public.plan_progress.marked_by is
  'Who recorded it: the event''s ops, or the group''s IC or admin (050).';

alter table public.plan_progress enable row level security;

drop policy if exists plan_progress_read on public.plan_progress;
create policy plan_progress_read on public.plan_progress for select to authenticated
  using (public.is_event_member(event_id));

-- Read only. There is deliberately no insert/update/delete policy: progress_mark() is the only writer.
revoke all on table public.plan_progress from anon, authenticated, public;
grant select on table public.plan_progress to authenticated;

-- ---------- scope guard ----------
-- The three keys have to agree with each other: the frame belongs to the plan, the group to the event, the
-- session to that plan. progress_mark() checks the same things with readable sentences; this is the backstop for
-- any future writer (and for a restore that runs as the owner).
create or replace function public.plan_progress_check_scope()
returns trigger
language plpgsql
set search_path = ''
as $body$
begin
  if not exists (select 1 from public.plan_frames f
                  where f.id = new.frame_id
                    and f.plan_id = new.plan_id
                    and f.event_id = new.event_id) then
    raise exception 'That frame is not in this plan.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.groups g
                  where g.id = new.group_id and g.event_id = new.event_id) then
    raise exception 'That group belongs to another event.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.event_sessions s
                  where s.id = new.session_id
                    and s.plan_id = new.plan_id
                    and s.event_id = new.event_id) then
    raise exception 'That session is not running this plan.' using errcode = '42501';
  end if;
  return new;
end;
$body$;

drop trigger if exists plan_progress_check_scope on public.plan_progress;
create trigger plan_progress_check_scope
  before insert or update of session_id, plan_id, event_id, frame_id, group_id on public.plan_progress
  for each row execute function public.plan_progress_check_scope();

-- ---------- recording one outcome ----------
-- The only door that writes the table. Who may use it: the event's ops (root, planner, marshal), the group's IC,
-- or the group's admin. Not the group's ordinary members: recording an arrival is a trust action, and the person
-- allowed to mark it is the one who is expected to know.
--
-- p_at is the moment the outcome is being recorded for, defaulting to now(). A marshal who is told at 18:20 that
-- the group arrived at 18:12 can say so; a moment that has not happened yet cannot be recorded, and neither can
-- one before T+0.
create or replace function public.progress_mark(
  p_session uuid,
  p_frame uuid,
  p_group uuid,
  p_state text,
  p_at timestamptz default null
)
returns public.plan_progress
language plpgsql
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_frame public.plan_frames;
  v_row public.plan_progress;
  v_name text;
  v_pos_state text;
  v_at timestamptz := coalesce(p_at, now());
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if v_session.plan_id is null or v_session.t0_at is null then
    raise exception 'That session is not running a plan.' using errcode = '22023';
  end if;

  if not (public.has_event_role(v_session.event_id, array['root', 'planner', 'marshal'])
          or public.is_ic_of(v_session.event_id, p_group)
          or public.is_group_admin(p_group)) then
    raise exception 'Only the event''s ops, or the group''s IC or admin, can record an outcome.'
      using errcode = '42501';
  end if;

  -- The two words, named here so a typo comes back as a sentence rather than as plan_progress_state_check.
  if coalesce(p_state, '') not in ('arrived', 'missed') then
    raise exception 'A frame is recorded as arrived or missed, not %.', coalesce(p_state, 'nothing')
      using errcode = '22023';
  end if;

  select * into v_frame from public.plan_frames
   where id = p_frame and plan_id = v_session.plan_id and event_id = v_session.event_id;
  if not found then
    if exists (select 1 from public.plan_frames where id = p_frame) then
      raise exception 'That frame belongs to another plan.' using errcode = '42501';
    end if;
    raise exception 'That frame does not exist.' using errcode = '42501';
  end if;

  select g.name into v_name from public.groups g
   where g.id = p_group and g.event_id = v_session.event_id;
  if not found then
    raise exception 'That group is not in this event.' using errcode = '42501';
  end if;

  -- Where the group stands at that moment, by the same carry-forward the board draws with.
  select pp.state into v_pos_state
    from public.plan_positions pp
    join public.plan_frames pf on pf.id = pp.frame_id
   where pf.plan_id = v_session.plan_id
     and pp.group_id = p_group
     and pf.t_s <= v_frame.t_s
   order by pf.t_s desc
   limit 1;
  if not found then
    raise exception '% is not in the plan at %; there is nothing to record yet.',
      v_name, public.plan_clock(v_frame.t_s) using errcode = '22023';
  end if;
  if v_pos_state = 'off_site' then
    raise exception '% is off site at %; there is nothing to record.',
      v_name, public.plan_clock(v_frame.t_s) using errcode = '22023';
  end if;

  if v_at > now() then
    raise exception 'That moment has not happened yet.' using errcode = '22023';
  end if;
  if v_at < v_session.t0_at then
    raise exception 'That is before the plan started (T+0).' using errcode = '22023';
  end if;

  insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
  values (v_session.id, v_session.plan_id, v_session.event_id, v_frame.id, p_group, p_state, v_at, auth.uid())
  on conflict (session_id, frame_id, group_id) do update
    set state = excluded.state,
        marked_at = excluded.marked_at,
        marked_by = excluded.marked_by
  returning * into v_row;

  return v_row;
end;
$body$;

comment on function public.progress_mark(uuid, uuid, uuid, text, timestamptz) is
  'Record one group''s outcome at one frame of a plan session; the only writer of plan_progress (050).';

-- ---------- the timetable as the clock makes it ----------
-- One row per group per frame the plan states that group at, with the planned clock time, what is known about it,
-- and how late it is. p_at is the clock to judge by, defaulting to now(); it is a parameter so a check can stand
-- at a chosen second and so a screen can ask "how did this look at 18:20".
--
-- The five states:
--   pending       the planned moment has not arrived and nobody has said anything
--   late          it has passed and nobody has said anything -- lateness grows with the clock
--   arrived       somebody recorded it arrived; lateness is when they said so, minus the plan
--   missed        somebody decided it did not happen; lateness is the same difference
--   not_required  the group is off site at that moment, so there is no arrival to want
--
-- A recorded outcome wins over the off-site flag: the plan may be edited after the event, and editing the
-- forecast must not erase what was already seen.
create or replace function public.session_status(p_session uuid, p_at timestamptz default now())
returns table (
  group_id uuid, frame_id uuid, t_s integer, planned_at timestamptz,
  state text, lateness interval, marked_at timestamptz, marked_by uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $body$
declare
  v_session public.event_sessions;
  v_at timestamptz := coalesce(p_at, now());
begin
  select * into v_session from public.event_sessions where id = p_session;
  if not found then
    raise exception 'That session does not exist.' using errcode = '42501';
  end if;
  if not public.is_event_member(v_session.event_id) then
    raise exception 'You are not in this event.' using errcode = '42501';
  end if;
  if v_session.plan_id is null or v_session.t0_at is null then
    raise exception 'That session is not running a plan.' using errcode = '22023';
  end if;

  return query
  with frames as (
    select f.id, f.t_s from public.plan_frames f where f.plan_id = v_session.plan_id
  ), stated as (
    select p.group_id, f.t_s, p.state
      from public.plan_positions p
      join public.plan_frames f on f.id = p.frame_id
     where f.plan_id = v_session.plan_id
  ), cells as (
    -- Every frame crossed with every group that stands somewhere in this plan, minus the frames that come
    -- before the group's first statement: that group is not part of the plan yet, so it has no state to have.
    select fr.id as frame_id, fr.t_s, g.group_id, pos.state as pos_state
      from frames fr
      cross join (select distinct s.group_id from stated s) g
      cross join lateral (
        select st.state
          from stated st
         where st.group_id = g.group_id and st.t_s <= fr.t_s
         order by st.t_s desc
         limit 1
      ) pos
  )
  select c.group_id,
         c.frame_id,
         c.t_s,
         v_session.t0_at + make_interval(secs => c.t_s) as planned_at,
         case
           when m.state is not null then m.state
           when c.pos_state = 'off_site' then 'not_required'
           when v_session.t0_at + make_interval(secs => c.t_s) < v_at then 'late'
           else 'pending'
         end,
         case
           when m.state is not null then m.marked_at - (v_session.t0_at + make_interval(secs => c.t_s))
           when c.pos_state = 'off_site' then null
           when v_session.t0_at + make_interval(secs => c.t_s) < v_at
             then v_at - (v_session.t0_at + make_interval(secs => c.t_s))
           else null
         end as lateness,
         m.marked_at,
         m.marked_by
    from cells c
    left join public.plan_progress m
      on m.session_id = v_session.id
     and m.frame_id = c.frame_id
     and m.group_id = c.group_id
   order by c.t_s, c.group_id;
end;
$body$;

comment on function public.session_status(uuid, timestamptz) is
  'One row per group per frame: planned clock time, pending/late/arrived/missed/not_required, lateness from t0_at (050).';

-- ---------- grants (R4) ----------
revoke execute on function public.progress_mark(uuid, uuid, uuid, text, timestamptz) from public, anon;
revoke execute on function public.session_status(uuid, timestamptz) from public, anon;
grant execute on function public.progress_mark(uuid, uuid, uuid, text, timestamptz) to authenticated;
grant execute on function public.session_status(uuid, timestamptz) to authenticated;
