-- 054_publish_versions.sql
--
-- Step 18 of the planning plan: publishing is compare-and-set, and every publish leaves a version behind.
--
-- WHAT WAS WRONG. plan_publish() published whatever the plan was when it ran and bumped the revision afterwards. A
-- planner who opened the board at revision 3, went to make a coffee, and pressed Publish announced the timetable as
-- it stood then -- even if revision 4 had been published while they were away -- and the strip that had been warning
-- them about it was overruled by a publish that never asked. The publish did not have to say which revision it was
-- publishing at all: the client sent a plan id and nothing else, so "the revision this screen holds" was a number the
-- database never heard.
--
-- WHAT THIS FILE DOES.
--
--   1. plan_publish(p_plan, p_plan_rev) takes the revision the caller is holding and refuses when it is not the
--      plan's. The row is read FOR UPDATE and the bump happens under that lock: two publishes that both read 3 must
--      not both succeed. Without the lock the comparison is theatre -- both transactions read 3, both pass, and the
--      second one's version is 4 written from a picture of 3.
--
--   2. Every publish writes one plan_versions row: the plan as it was published, its frames and their positions, the
--      revision the publish produced, and who published it. (plan_id, rev) is unique, so a version is a fact rather
--      than a log line that can be written twice.
--
--   3. A version is a copy, not a pointer. Editing a frame afterwards does not change it: the snapshot is JSON taken
--      in the publishing transaction, so it is what people were shown, and the thing step 19's channel and step 21's
--      log will name.
--
-- WHO READS A VERSION. Ops staff (root, planner, marshal) of the event -- the same people who read the frames. A
-- version is every group's walk at once, and a member's copy of a plan is their own timetable (052), so it is not
-- theirs. Nothing in the client writes this table: the publishing function does, as its owner, in the same
-- transaction as the bump.
--
-- R2: the signature changes (a second argument cannot be added in place), so the one-argument function is dropped and
-- the replacement granted from scratch (R4). R8: the body is 053's, with the comparison first and the version after
-- the bump.
--
-- (The old plans these facts are about are joined by `plan_id`, and the event id is carried on the row so the read
-- policy needs no join. Deleting a plan takes its versions with it -- they are a record of that plan, not of the
-- event -- and deleting the plan a copy was cut from only nulls the copy's `fork_of` column, here as on plans.)

-- ---------- 1. the versions ----------
create table if not exists public.plan_versions (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans (id) on delete cascade,
  -- Denormalised so the read policy needs no join to the plan, exactly as plans/plan_frames do it.
  event_id uuid not null references public.events (id) on delete cascade,
  -- The revision this publish produced. The pair with plan_id is the fact: a plan has one version per revision.
  rev integer not null,
  -- The plan at the moment it was published. name/for_date/t0_time are kept with the frames because a version is
  -- what people were told to follow, and the printed T+0 is part of what they were told.
  name text not null,
  for_date date,
  t0_time time not null,
  -- A copy remembers the plan it was cut from and where; a plan published as itself has both null.
  fork_of uuid references public.plans (id) on delete set null,
  fork_cut_s integer,
  -- [ { id, t_s, note, positions: [ { group_id, lat, lng, state, verify } ] } ], frames ordered by t_s and positions
  -- by group id, so two versions of the same plan compare by their content and not by the heap.
  frames jsonb not null default '[]'::jsonb,
  published_at timestamptz not null default now(),
  published_by uuid not null default auth.uid(),
  -- The btree behind this constraint is the only index a version needs: every read is "a plan's versions", newest
  -- first, and that is a backward scan of this one.
  unique (plan_id, rev)
);

comment on table public.plan_versions is
  'One immutable snapshot per publish: the plan, its frames and positions at the revision a publish produced, and '
  'who published it. Written by plan_publish() only; ops staff read it (054, step 18).';

alter table public.plan_versions enable row level security;

-- R3: a read policy, and no write policy at all. The only writer is plan_publish(), which is security definer and
-- therefore the owner. A row someone can edit is not a version.
drop policy if exists plan_versions_read on public.plan_versions;
create policy plan_versions_read on public.plan_versions for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']));

comment on policy plan_versions_read on public.plan_versions is
  'Ops staff only: a version is every group''s walk at once, and a member follows their own timetable (052''s rule).';

-- ---------- 2. publishing names the revision it is publishing ----------
-- The one-argument function goes: a caller that cannot say which revision it holds is exactly the caller this step is
-- about. Nothing else in the schema calls it (the client and the checks are the only callers), so the drop is clean.
drop function if exists public.plan_publish(uuid);

-- `create or replace`, not `create`: the signature is new, so the first run creates it and a re-run of this file (a
-- fixed body, or a check's own bite) replaces it without a second drop. The one-argument function is dropped above.
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
  'writes one immutable plan_versions row, moves the running sessions'' revision, and carries an open session from the '
  'plan a copy was cut from (054, step 18; 053''s hand-over).';

-- ---------- grants (R4) ----------
-- The function is new (the old one was dropped), so the schema default would have granted it to anon as well.
revoke execute on function public.plan_publish(uuid, integer) from public, anon;
grant execute on function public.plan_publish(uuid, integer) to authenticated;

-- R3: a new table gets a read grant and no write grant. anon is revoked because the default ACL hands a new public
-- table arwdDxtm to it (finding 1, and 052's habit); authenticated keeps SELECT so the policy is the only gate.
revoke all on table public.plan_versions from anon;
revoke insert, update, delete, truncate, references, trigger on table public.plan_versions from authenticated;
grant select on table public.plan_versions to authenticated;
