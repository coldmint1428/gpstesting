-- Step 15, checked at the database: one read carrying times, state, and the revision a running timetable follows.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step15-timetable.sql
--
-- What has to be true:
--
--   1. session_timetable() answers with one row per group per frame, named, with the planned clock time (t0_at +
--      t_s), the five-state word and lateness that 050 derives, and plan_rev on every row.
--   2. t0_at wins. The check moves the plan's for_date/t0_time ten minutes forward *under a running session*: the
--      read's planned_at does not move, while plan_t0() now says something else. A read built on the plan's
--      display hints would answer ten minutes late on every row.
--   3. Publishing moves the revision the session follows. plan_publish(plan, rev) bumps plans.rev and writes the same
--      number onto the open session in the same transaction, so a fresh read differs from the one a tab is
--      holding -- which is the whole point of the column (039's own purpose, made true by 051).
--   4. The read carries what was recorded (step 14): an arrival shows its state, lateness, when and by whom, and
--      the timetable still has one row per group per frame.
--   5. Who reads what is 040's rule: ops staff see every group, an IC or group admin only their own, a member
--      with no group nothing, an outsider nothing (refused), and anon cannot execute the function at all.
--   6. An edit is not an announcement: moving a frame changes the rows and their planned_at, but not plan_rev.
--      Publishing is what moves the revision; that distinction is recorded here rather than discovered later.
--   7. An ended session still reads, and keeps the revision it ran: a closed show is history, not a screen.
--
-- The check builds its own plan and starts a real session through start_event(), then rolls the whole transaction
-- back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a bench of its own, and a clean event clock ----------
delete from public.plans where id = '0b000000-0000-4000-8000-000000000b15';
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';

-- T+0 is ten minutes ago, so +0:00 and +1:00 are in the past and +1:00:00 is still ahead.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', 'Timetable bench',
       (now() at time zone 'Asia/Singapore' - interval '10 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '10 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1501', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01',    0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1502', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01',   60, 'doors', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1503', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', 3600, 'late',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Two groups, 20 m per step: a legal strip the publish gate accepts.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f1501', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1502', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3301800, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1503', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3303600, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1501', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1502', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3341800, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1503', '0b000000-0000-4000-8000-000000000b15', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3343600, 103.77300);

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b15', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b15'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b15');
  perform set_config('check.session', v_s::text, true);
end $$;

-- ---------- 1. one row per group per frame, and the row the screen reads ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_starts timestamptz;
  v_rev integer;
  v_at timestamptz;
  v record;
  v_n integer;
begin
  select t0_at, starts_at, plan_rev into v_t0, v_starts, v_rev from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  if v_starts - v_t0 <> interval '10 minutes' then
    raise exception 'FAIL 1a: starts_at is % after t0_at, expected exactly 10 minutes', v_starts - v_t0;
  end if;
  if v_rev <> 2 then
    raise exception 'FAIL 1b: the session follows plan revision %, expected 2 (published once)', v_rev;
  end if;

  select count(*) into v_n from public.session_timetable(v_s, v_at);
  if v_n <> 6 then
    raise exception 'FAIL 1c: the timetable has % rows, expected 6 (2 groups x 3 frames)', v_n;
  end if;

  -- One row, exactly: the clock time is t0_at + t_s, the group is named, and the revision comes with it.
  select * into v from public.session_timetable(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  if not found then raise exception 'FAIL 1d: no row for Gate Crew at +0:00'; end if;
  if v.group_name <> 'Gate Crew' then
    raise exception 'FAIL 1e: the row names the group "%"', v.group_name;
  end if;
  if v.planned_at <> v_t0 then
    raise exception 'FAIL 1f: +0:00 is planned for %, expected the session''s t0_at %', v.planned_at, v_t0;
  end if;
  if v.state <> 'late' then
    raise exception 'FAIL 1g: an unmarked moment 90 s ago reads "%", expected late', v.state;
  end if;
  if v.lateness is distinct from interval '90 seconds' then
    raise exception 'FAIL 1h: lateness is %, expected 90 s', v.lateness;
  end if;
  if v.plan_rev <> 2 then
    raise exception 'FAIL 1i: the row follows revision %, expected 2', v.plan_rev;
  end if;

  -- The plan's own word for the frame is T+0; the read's clock differs by exactly t0_at.
  select * into v from public.session_timetable(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a002' and t_s = 3600;
  if not found then raise exception 'FAIL 1j0: no row for Sound at +1:00:00'; end if;
  if v.planned_at <> v_t0 + interval '1 hour' then
    raise exception 'FAIL 1j: +1:00:00 is planned for %, expected %', v.planned_at, v_t0 + interval '1 hour';
  end if;
  if v.state <> 'pending' or v.lateness is not null then
    raise exception 'FAIL 1k: a future moment reads % / %, expected pending / no lateness', v.state, v.lateness;
  end if;

  -- Every row carries the same revision, and the wrapper loses nothing session_status had.
  select count(*) into v_n from public.session_timetable(v_s, v_at) where plan_rev = 2;
  if v_n <> 6 then
    raise exception 'FAIL 1l: % of 6 rows carry the revision', v_n;
  end if;
  select count(*) into v_n from public.session_status(v_s, v_at);
  if v_n <> 6 then
    raise exception 'FAIL 1m: the engine answers % rows while the read answers 6', v_n;
  end if;
end $$;

-- ---------- 2. t0_at wins over the plan's display hints ----------
-- The plan is moved ten minutes forward while the session is running. This is the case the two columns exist to
-- tell apart: for_date/t0_time describe a plan nobody has started; a running session carries its own clock.
-- Moving the printed time, and asking plan_t0() what it says now, are owner work: plan_t0 is deliberately not
-- callable by a client (039 revoked it from authenticated), and this is not the thing under test.
reset role;
update public.plans
   set for_date = (((select t0_at from public.event_sessions where id = current_setting('check.session')::uuid)
                    + interval '10 minutes') at time zone 'Asia/Singapore')::date,
       t0_time = (((select t0_at from public.event_sessions where id = current_setting('check.session')::uuid)
                    + interval '10 minutes') at time zone 'Asia/Singapore')::time
 where id = '0b000000-0000-4000-8000-000000000b15';
do $$
begin
  perform set_config('check.printed_t0', public.plan_t0('0b000000-0000-4000-8000-000000000b15')::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_planned timestamptz;
  v_from_plan timestamptz := current_setting('check.printed_t0')::timestamptz;
  v_moved record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  if v_from_plan = v_t0 then
    raise exception 'FAIL 2a: the fixture could not move the plan''s printed T+0';
  end if;

  select * into v_moved from public.session_timetable(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  if not found then raise exception 'FAIL 2e: no row for Gate Crew at +0:00 after the plan moved'; end if;
  v_planned := v_moved.planned_at;
  if v_planned <> v_t0 then
    raise exception 'FAIL 2b: after moving the plan, +0:00 is planned for % (t0_at %)', v_planned, v_t0;
  end if;
  if v_planned = v_from_plan then
    raise exception 'FAIL 2c: the read followed the plan''s printed time (%) instead of t0_at (%)', v_from_plan, v_t0;
  end if;
  if not (v_from_plan - (v_t0 + interval '10 minutes') between interval '-1 second' and interval '1 second') then
    raise exception 'FAIL 2d: the plan now prints T+0 as %, expected % (the fixture is wrong)', v_from_plan, v_t0 + interval '10 minutes';
  end if;
end $$;

-- ---------- 3. publishing moves the revision the session follows ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_plan_rev integer;
  v_published public.plans;
  v_row record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  v_published := public.plan_publish('0b000000-0000-4000-8000-000000000b15', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b15'));
  if v_published.rev <> 3 then
    raise exception 'FAIL 3a: the plan is at revision % after a second publish, expected 3', v_published.rev;
  end if;
  select plan_rev into v_plan_rev from public.event_sessions where id = v_s;
  if v_plan_rev <> 3 then
    raise exception 'FAIL 3b: the running session follows revision %, expected 3 -- publishing must move it', v_plan_rev;
  end if;

  -- A fresh read now answers a different revision than the one a tab that read before the publish holds.
  select * into v_row from public.session_timetable(v_s) where t_s = 0 limit 1;
  if not found then raise exception 'FAIL 3c0: a fresh read returned no rows'; end if;
  if v_row.plan_rev <> 3 then
    raise exception 'FAIL 3c: a fresh read still says revision %, expected 3', v_row.plan_rev;
  end if;

  -- Publishing changes the announcement, not the strip.
  select count(*) into v_n from public.session_timetable(v_s, v_t0 + interval '90 seconds');
  if v_n <> 6 then
    raise exception 'FAIL 3d: the timetable has % rows after the publish, expected 6', v_n;
  end if;
end $$;

-- ---------- 4. the read carries what step 14 recorded ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_row record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1501',
                                '0b000000-0000-4000-8000-00000000a001', 'arrived', v_at);

  -- Read it back as a planner: the recorded row and the other group's row are both in this read. (The member's own
  -- scope is the next section; a member asking about another group would be asking a question with no rows, which
  -- is not the assertion this section is making.)
  perform set_config('request.jwt.claims', '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}', true);

  select * into v_row from public.session_timetable(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  if not found then raise exception 'FAIL 4a0: no row for Gate Crew at +0:00'; end if;
  if v_row.state <> 'arrived' then
    raise exception 'FAIL 4a: the recorded moment reads "%"', v_row.state;
  end if;
  if v_row.lateness is distinct from interval '90 seconds' then
    raise exception 'FAIL 4b: the arrival reads lateness %', v_row.lateness;
  end if;
  if v_row.marked_at <> v_at then
    raise exception 'FAIL 4c: the arrival says it was recorded at %', v_row.marked_at;
  end if;
  if v_row.marked_by <> 'ba04a00c-518f-4252-91d5-1081cecec1d2' then
    raise exception 'FAIL 4d: the arrival was recorded by %', v_row.marked_by;
  end if;
  if v_row.plan_rev <> 3 then
    raise exception 'FAIL 4e: the recorded row follows revision %, expected 3', v_row.plan_rev;
  end if;

  -- The other group at the same moment is still late, and the row count is unchanged: one read, one row each.
  select * into v_row from public.session_timetable(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a002' and t_s = 0;
  if not found then raise exception 'FAIL 4f0: no row for Sound at +0:00'; end if;
  if v_row.state <> 'late' then
    raise exception 'FAIL 4f: the other group reads "%" at the same moment', v_row.state;
  end if;
  select count(*) into v_n from public.session_timetable(v_s, v_at);
  if v_n <> 6 then
    raise exception 'FAIL 4g: the timetable has % rows after a record, expected 6', v_n;
  end if;
end $$;

-- ---------- 5. who reads what ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_other integer;
begin
  -- Ops staff read every group.
  perform set_config('request.jwt.claims', '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}', true);
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 6 then raise exception 'FAIL 5a: a planner reads % rows, expected 6', v_n; end if;

  -- An IC reads their own group only (040's rule).
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  select count(*) into v_n from public.session_timetable(v_s);
  select count(*) into v_other from public.session_timetable(v_s) where group_id <> '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 3 then raise exception 'FAIL 5b: a Gate Crew IC reads % rows, expected 3', v_n; end if;
  if v_other <> 0 then raise exception 'FAIL 5c: a Gate Crew IC reads % rows of another group', v_other; end if;

  -- A group admin reads their own group only. (testuser3 is Sound's admin.)
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  select count(*) into v_n from public.session_timetable(v_s);
  select count(*) into v_other from public.session_timetable(v_s) where group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_n <> 3 then raise exception 'FAIL 5d: a Sound admin reads % rows, expected 3', v_n; end if;
  if v_other <> 0 then raise exception 'FAIL 5e: a Sound admin reads % rows of another group', v_other; end if;
end $$;

-- A participant in no group reads nothing. Taking the group away is an owner write, inside this transaction, so
-- the rollback puts it back.
reset role;
delete from public.group_members
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4';
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 0 then raise exception 'FAIL 5f: a member with no group reads % rows', v_n; end if;

  -- An outsider is refused a timetable, not handed an empty one.
  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
  begin
    perform public.session_timetable(v_s);
    raise exception 'FAIL 5g: somebody outside the event read the timetable';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- anon cannot execute the function at all (R4).
set local role anon;
do $$
begin
  perform count(*) from public.session_timetable('0b000000-0000-4000-8000-00000000d001');
  raise exception 'FAIL 5h: anon could call session_timetable';
exception when insufficient_privilege then null;
end $$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 6. the refusals the read inherits ----------
do $$
declare
  v_msg text;
begin
  -- A session that runs no plan (the bench's ended run-sheet session), and one that does not exist.
  begin
    perform public.session_timetable('0b000000-0000-4000-8000-00000000d001');
    raise exception 'FAIL 6a: a session with no plan returned a timetable';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not running a plan%' then raise exception 'FAIL 6b: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.session_timetable(gen_random_uuid());
    raise exception 'FAIL 6c: a session that does not exist returned a timetable';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 7. an edit changes the rows; only publishing moves the revision ----------
-- This is the distinction the client depends on: a tab notices a *publish*, not every draft edit. The debt it
-- implies (an edit to a live plan is not announced until somebody publishes) is recorded in the plan document.
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_row record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  perform public.frame_move('0b000000-0000-4000-8000-0000000f1502', 120, null);

  select count(*) into v_n from public.session_timetable(v_s, v_t0 + interval '200 seconds');
  if v_n <> 6 then raise exception 'FAIL 7a: the timetable has % rows after moving a frame, expected 6', v_n; end if;
  if exists (select 1 from public.session_timetable(v_s, v_t0 + interval '200 seconds') where t_s = 60) then
    raise exception 'FAIL 7b: the moved frame is still at +1:00';
  end if;
  select * into v_row from public.session_timetable(v_s, v_t0 + interval '200 seconds')
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 120;
  if not found then raise exception 'FAIL 7c0: the moved frame has no row at +2:00'; end if;
  if v_row.planned_at <> v_t0 + interval '120 seconds' then
    raise exception 'FAIL 7c: the moved frame is planned for %, expected %', v_row.planned_at, v_t0 + interval '120 seconds';
  end if;
  if v_row.plan_rev <> 3 then
    raise exception 'FAIL 7d: moving a frame moved the revision to % -- edits are not announcements', v_row.plan_rev;
  end if;
end $$;

-- ---------- 8. a closed show keeps the revision it ran ----------
-- Ending the session is a product action with its own door; this check is about what the read says afterwards, so
-- the row is written as the owner.
reset role;
update public.event_sessions
   set ended_at = now(), end_reason = 'ended'
 where id = current_setting('check.session')::uuid;
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_plan_rev integer;
  v_row record;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b15', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b15'));
  select plan_rev into v_plan_rev from public.event_sessions where id = v_s;
  if v_plan_rev <> 3 then
    raise exception 'FAIL 8a: an ended session moved to revision % when the plan was published again', v_plan_rev;
  end if;
  select * into v_row from public.session_timetable(v_s) where t_s = 0 limit 1;
  if v_row is null then
    raise exception 'FAIL 8b: an ended session no longer reads its timetable';
  end if;
  if v_row.plan_rev <> 3 then
    raise exception 'FAIL 8c: the closed show reports revision %, expected the 3 it ran', v_row.plan_rev;
  end if;
end $$;

rollback;

select 'step 15: one read of a running timetable -- t0_at not the plan''s printed clock, a revision that publishing moves, the member scope, and edits that are not announcements' as result;
