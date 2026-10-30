-- Step 16, checked at the database: a member's schedule is their group's timetable, and the plan surface is closed
-- behind it.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step16-schedule.sql
--
-- What has to be true, and why each one is here:
--
--   1. THE DONE-WHEN, AT THE DATABASE. As a member of one group, session_timetable() answers only that group's rows --
--      five moments, one per frame, and every one of the five state words appears exactly once across them
--      (arrived, not required, late, missed, pending). The planner's read of the same session has ten rows: the
--      member's five are a subset, not a different derivation.
--   2. THE CLOCK, NOT THE ROW. The states are judged at the instant asked (050's p_at): the same moment reads pending
--      before its planned time and late after it, and lateness is the difference. A recorded outcome outranks the
--      clock in both directions (a later mark does not turn into "late").
--   3. THE CLOSED PATHS. A member cannot read the plan's frames or notes at all any more (finding 23), cannot read
--      another group's positions, and cannot read another group's outcomes (step 14's debt). The timetable above is
--      the one read that still answers -- which is what makes closing the rest possible without taking the
--      timetable away. Both the table and the function are tried, because a table policy does not close an invoker
--      function that was written to bypass it.
--   4. OPS STAFF KEEP EVERYTHING. A marshal sees every group, every position, every outcome, every plan (draft
--      included): the narrowing must not narrow the people who run the night.
--   5. THE OTHER GROUP'S IC reads their own group only -- the same rule through four different doors.
--   6. A MEMBER WITH NO GROUP reads nothing, and the live plan is still the one plan they may read.
--   7. AN OUTSIDER is refused the timetable rather than handed an empty one, and reads no rows from any plan table.
--   8. anon cannot execute either function (R4) and cannot read the tables (037/038's grants).
--   9. THE ROW CARRIES WHAT THE SCREEN SHOWS: the plan's name, and each frame's own note (including a frame the group
--      is only carried into), with plan_rev on every row.
--  10. PUBLISHING STILL MOVES THE REVISION, and the member's read survives it -- the frames being closed is not the
--      timetable being closed.
--
-- The check builds its own plan and starts a real session through start_event(), then rolls the whole transaction
-- back, so the bench is left exactly as the fixture wrote it. The marks are inserted as the owner: progress_mark()
-- is proved in step 14, and this check is about what the read answers, not about the door that wrote it.

begin;

-- ---------- a bench of its own, and a clean event clock ----------
delete from public.plans where id in ('0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-00000000b16d');
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';

-- T+0 is fifteen minutes ago. The five frames are at +0:00, +5:00, +10:00, +13:00 and +25:00, so by the real clock
-- four of them have passed and the last is ten minutes ahead.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', 'Schedule bench',
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '15 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1601', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1602', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1603', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',  600, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1604', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',  780, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1605', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', 1500, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew walks 25 m north a frame; Sound stands still at +0:00, is off site at +5:00, and is back 25 m north at
-- +10:00, where it stays. The plan is legal, so the publish gate lets the session start on it.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f1601', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1602', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1603', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1604', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1605', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1601', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1602', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1603', '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3342171, 103.77300);

update public.plan_positions
   set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f1602'
   and group_id = '0b000000-0000-4000-8000-00000000a002';

-- A draft in the same event, so "a member reads the live plan and nothing else" has something it must not see.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-00000000b16d', '0b000000-0000-4000-8000-000000000e01',
   'Unpublished bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '1 hour');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1611', '0b000000-0000-4000-8000-00000000b16d', '0b000000-0000-4000-8000-000000000e01', 0, 'secret', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- A marshal who is not otherwise in the plan's story: ops staff have to keep seeing everything (testuser2).
insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e01', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'marshal');

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b16', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b16'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b16');
  perform set_config('check.session', v_s::text, true);
end $$;

-- ---------- the marks, written as the owner ----------
-- Sound arrived two minutes late at the call and was decided missed a minute after the curtain; Gate Crew arrived on
-- time and again thirty seconds late. Every one of them is in the past.
reset role;

insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select current_setting('check.session')::uuid, '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',
       '0b000000-0000-4000-8000-0000000f1601', '0b000000-0000-4000-8000-00000000a002', 'arrived',
       t0_at + interval '120 seconds', '2906655b-33ad-4e9d-a608-f083e43e22d4'
  from public.event_sessions where id = current_setting('check.session')::uuid;
insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select current_setting('check.session')::uuid, '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',
       '0b000000-0000-4000-8000-0000000f1604', '0b000000-0000-4000-8000-00000000a002', 'missed',
       t0_at + interval '840 seconds', '2906655b-33ad-4e9d-a608-f083e43e22d4'
  from public.event_sessions where id = current_setting('check.session')::uuid;
insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select current_setting('check.session')::uuid, '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',
       '0b000000-0000-4000-8000-0000000f1601', '0b000000-0000-4000-8000-00000000a001', 'arrived',
       t0_at, 'ba04a00c-518f-4252-91d5-1081cecec1d2'
  from public.event_sessions where id = current_setting('check.session')::uuid;
insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state, marked_at, marked_by)
select current_setting('check.session')::uuid, '0b000000-0000-4000-8000-000000000b16', '0b000000-0000-4000-8000-000000000e01',
       '0b000000-0000-4000-8000-0000000f1604', '0b000000-0000-4000-8000-00000000a001', 'arrived',
       t0_at + interval '810 seconds', 'ba04a00c-518f-4252-91d5-1081cecec1d2'
  from public.event_sessions where id = current_setting('check.session')::uuid;

set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

-- ---------- 1. the done-when: a member reads their own group, and all five words ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_n integer;
  v_words text;
  v_row record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 5 then
    raise exception 'FAIL 1a: a Sound member reads % rows, expected 5 (one per frame, their group only)', v_n;
  end if;

  -- One group, named once in the header and repeated on every row: the read is the rule, not the screen.
  select count(*) into v_n from public.session_timetable(v_s) where group_name <> 'Sound';
  if v_n <> 0 then
    raise exception 'FAIL 1b: % of the member''s rows name another group', v_n;
  end if;

  -- Every state word the schedule shows appears, in the order the night happened. This is the sentence the screen
  -- renders: arrived, not required, late, missed, pending.
  select string_agg(state, ',' order by t_s) into v_words from public.session_timetable(v_s);
  if v_words <> 'arrived,not_required,late,missed,pending' then
    raise exception 'FAIL 1c: the member''s five moments read "%", expected arrived,not_required,late,missed,pending', v_words;
  end if;

  -- The clock is t0_at + t_s, on every row.
  select count(*) into v_n from public.session_timetable(v_s) where planned_at <> v_t0 + make_interval(secs => t_s);
  if v_n <> 0 then
    raise exception 'FAIL 1d: % rows are not planned at t0_at + t_s', v_n;
  end if;

  -- The marks are in the read, with who and when.
  select * into v_row from public.session_timetable(v_s) where t_s = 0;
  if not found then raise exception 'FAIL 1e: no row for the call'; end if;
  if v_row.state <> 'arrived' then
    raise exception 'FAIL 1f: the marked call reads "%"', v_row.state;
  end if;
  if v_row.lateness is distinct from interval '120 seconds' then
    raise exception 'FAIL 1g: the arrival is % late, expected 120 s', v_row.lateness;
  end if;
  if v_row.marked_by <> '2906655b-33ad-4e9d-a608-f083e43e22d4' then
    raise exception 'FAIL 1h: the arrival was recorded by %', v_row.marked_by;
  end if;
  if v_row.marked_at <> v_t0 + interval '120 seconds' then
    raise exception 'FAIL 1i: the arrival was recorded at %, expected %', v_row.marked_at, v_t0 + interval '120 seconds';
  end if;
end $$;

-- ---------- 2. the planner's read is the control: every group, same clock ----------
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_mine integer;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 10 then
    raise exception 'FAIL 2a: a planner reads % rows, expected 10 (2 groups x 5 frames)', v_n;
  end if;

  -- The member's five are a subset of the planner's ten -- not a second derivation of them.
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  select count(*) into v_mine from public.session_timetable(v_s);
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select count(*) into v_n from public.session_timetable(v_s)
   where group_id = '0b000000-0000-4000-8000-00000000a002';
  if v_n <> v_mine then
    raise exception 'FAIL 2b: the planner sees % Sound rows while the member sees %', v_n, v_mine;
  end if;
end $$;

-- ---------- 3. the clock decides pending and late; a record outranks both ----------
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_row record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  -- The +10:00 moment asked about before it was due: pending, and no lateness to speak of.
  select * into v_row from public.session_timetable(v_s, v_t0 + interval '400 seconds') where t_s = 600;
  if not found then raise exception 'FAIL 3a: no row for +10:00'; end if;
  if v_row.state <> 'pending' or v_row.lateness is not null then
    raise exception 'FAIL 3b: +10:00 asked at T+6:40 reads % / %, expected pending / no lateness', v_row.state, v_row.lateness;
  end if;

  -- The same moment asked about after it was due: late, by exactly the clock.
  select * into v_row from public.session_timetable(v_s, v_t0 + interval '700 seconds') where t_s = 600;
  if v_row.state <> 'late' then
    raise exception 'FAIL 3c: +10:00 asked at T+11:40 reads "%", expected late', v_row.state;
  end if;
  if v_row.lateness is distinct from interval '100 seconds' then
    raise exception 'FAIL 3d: +10:00 asked at T+11:40 is % late, expected 100 s', v_row.lateness;
  end if;

  -- A recorded outcome is a fact: the curtain is missed at every instant, not late at some and missed at others.
  select * into v_row from public.session_timetable(v_s, v_t0 + interval '700 seconds') where t_s = 780;
  if v_row.state <> 'missed' then
    raise exception 'FAIL 3e: the missed curtain reads "%" at T+11:40', v_row.state;
  end if;
  if v_row.lateness is distinct from interval '60 seconds' then
    raise exception 'FAIL 3f: the missed curtain is % after its time, expected 60 s', v_row.lateness;
  end if;

  -- Off site is a statement about a moment, not a missing one: not required, with no lateness to report.
  select * into v_row from public.session_timetable(v_s, v_t0 + interval '700 seconds') where t_s = 300;
  if v_row.state <> 'not_required' or v_row.lateness is not null then
    raise exception 'FAIL 3g: the off-site build reads % / %, expected not_required / no lateness', v_row.state, v_row.lateness;
  end if;
end $$;

-- ---------- 4. the closed paths: the timetable is the member's only read ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  -- The frames of the very plan the session runs, and of the draft, and through the invoker function the board used.
  select count(*) into v_n from public.plan_frames where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then
    raise exception 'FAIL 4a: a member reads % plan frames, expected none (finding 23)', v_n;
  end if;
  select count(*) into v_n from public.plan_frames_list('0b000000-0000-4000-8000-000000000b16');
  if v_n <> 0 then
    raise exception 'FAIL 4b: plan_frames_list answered a member with % frames', v_n;
  end if;
  select count(*) into v_n from public.plan_frames_list('0b000000-0000-4000-8000-00000000b16d');
  if v_n <> 0 then
    raise exception 'FAIL 4c: plan_frames_list showed a member an unpublished plan (% frames)', v_n;
  end if;

  -- The plan list: the live plan only.
  select count(*) into v_n from public.plans where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 1 then
    raise exception 'FAIL 4d: a member reads % plans, expected 1 (the live one)', v_n;
  end if;
  if exists (select 1 from public.plans where id = '0b000000-0000-4000-8000-00000000b16d') then
    raise exception 'FAIL 4e: a member read an unpublished plan';
  end if;
  select count(*) into v_n from public.plans where id = '0b000000-0000-4000-8000-000000000b16' and status = 'live';
  if v_n <> 1 then
    raise exception 'FAIL 4f: the member cannot see the live plan';
  end if;

  -- Positions and outcomes: their own group, and off the live plan they follow.
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b16';
  if v_n <> 3 then
    raise exception 'FAIL 4g: a member reads % positions of the running plan, expected their own 3', v_n;
  end if;
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b16'
     and group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_n <> 0 then
    raise exception 'FAIL 4h: a member read % positions of another group', v_n;
  end if;
  -- 040's rule is deliberately unchanged (a group's own coordinates on any plan): the leak this step closed was the
  -- plan -- its frames and notes -- and the outcomes, not a member's own rows. Step 3's check asserts that rule.
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b02';
  if v_n <> 4 then
    raise exception 'FAIL 4h2: a member reads % of their own positions on an unpublished plan, expected 4 (040)', v_n;
  end if;
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 2 then
    raise exception 'FAIL 4i: a member reads % outcomes, expected their own 2', v_n;
  end if;
  select count(*) into v_n from public.plan_progress
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and group_id <> '0b000000-0000-4000-8000-00000000a002';
  if v_n <> 0 then
    raise exception 'FAIL 4j: a member read % outcomes of another group', v_n;
  end if;

  -- The engine, called straight, is scoped too: the timetable is not the only closed door.
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 5 then
    raise exception 'FAIL 4k: session_status answered a member with % rows, expected their own 5', v_n;
  end if;
end $$;

-- ---------- 5. ops staff keep everything ----------
set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 10 then raise exception 'FAIL 5a: a marshal reads % timetable rows, expected 10', v_n; end if;
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 10 then raise exception 'FAIL 5b: a marshal reads % engine rows, expected 10', v_n; end if;
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b16';
  if v_n <> 5 then raise exception 'FAIL 5c: a marshal reads % frames of the live plan, expected 5', v_n; end if;
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-00000000b16d';
  if v_n <> 1 then raise exception 'FAIL 5d: a marshal reads % frames of the draft, expected 1 (finding 23 over-corrected)', v_n; end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b16';
  if v_n <> 8 then raise exception 'FAIL 5e: a marshal reads % positions, expected 8', v_n; end if;
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 4 then raise exception 'FAIL 5f: a marshal reads % outcomes, expected 4', v_n; end if;
end $$;

-- ---------- 6. the other group's IC reads their own group, through all four doors ----------
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.session_timetable(v_s);
  if v_n <> 5 then raise exception 'FAIL 6a: a Gate Crew IC reads % timetable rows, expected 5', v_n; end if;
  select count(*) into v_n from public.session_timetable(v_s) where group_id <> '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 0 then raise exception 'FAIL 6b: a Gate Crew IC reads % rows of another group', v_n; end if;
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 5 then raise exception 'FAIL 6c: a Gate Crew IC reads % engine rows, expected 5', v_n; end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b16';
  if v_n <> 5 then raise exception 'FAIL 6d: a Gate Crew IC reads % positions of the running plan, expected their own 5', v_n; end if;
  select count(*) into v_n from public.plan_positions
   where plan_id = '0b000000-0000-4000-8000-000000000b16'
     and group_id <> '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 0 then raise exception 'FAIL 6d2: a Gate Crew IC reads % positions of another group', v_n; end if;
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 2 then raise exception 'FAIL 6e: a Gate Crew IC reads % outcomes, expected their own 2', v_n; end if;
  select count(*) into v_n from public.plan_frames where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then raise exception 'FAIL 6f: a Gate Crew IC reads % frames', v_n; end if;
end $$;

-- ---------- 7. a member with no group reads nothing, and still sees the live plan ----------
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
  if v_n <> 0 then raise exception 'FAIL 7a: a member with no group reads % timetable rows', v_n; end if;
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 0 then raise exception 'FAIL 7b: a member with no group reads % engine rows', v_n; end if;
  select count(*) into v_n from public.plan_positions where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then raise exception 'FAIL 7c: a member with no group reads % positions', v_n; end if;
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 0 then raise exception 'FAIL 7d: a member with no group reads % outcomes', v_n; end if;
  select count(*) into v_n from public.plans where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 1 then raise exception 'FAIL 7e: a member with no group reads % plans, expected the live one', v_n; end if;
end $$;

-- ---------- 8. an outsider, and anon ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
  begin
    perform public.session_timetable(v_s);
    raise exception 'FAIL 8a: somebody outside the event read the timetable';
  exception when sqlstate '42501' then null;
  end;
  select count(*) into v_n from public.plans where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then raise exception 'FAIL 8b: an outsider reads % plans', v_n; end if;
  select count(*) into v_n from public.plan_frames where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then raise exception 'FAIL 8c: an outsider reads % frames', v_n; end if;
  select count(*) into v_n from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then raise exception 'FAIL 8d: an outsider reads % outcomes', v_n; end if;
end $$;

set local role anon;
do $$
begin
  perform count(*) from public.session_timetable('0b000000-0000-4000-8000-00000000d001');
  raise exception 'FAIL 8e: anon could call session_timetable';
exception when insufficient_privilege then null;
end $$;
do $$
begin
  perform count(*) from public.session_status('0b000000-0000-4000-8000-00000000d001');
  raise exception 'FAIL 8f: anon could call session_status';
exception when insufficient_privilege then null;
end $$;
do $$
begin
  perform count(*) from public.plans;
  raise exception 'FAIL 8g: anon could read plans';
exception when insufficient_privilege then null;
end $$;
do $$
begin
  perform count(*) from public.plan_frames;
  raise exception 'FAIL 8h: anon could read plan_frames';
exception when insufficient_privilege then null;
end $$;

-- ---------- 9. the row carries what the screen shows ----------
-- Section 7 took the member out of Sound; put them back (an owner write, rolled back with everything else) before
-- the read is asked again.
reset role;
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, true);
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row record;
  v_n integer;
begin
  -- The plan's name is on every row, so the header needs no second read.
  select count(*) into v_n from public.session_timetable(v_s) where plan_name is distinct from 'Schedule bench';
  if v_n <> 0 then raise exception 'FAIL 9a: % rows do not name the plan', v_n; end if;

  -- The frame's own note, including on a frame this group is only carried into (+13:00 and +25:00 state nothing for
  -- Sound), and null where the planner wrote none.
  select * into v_row from public.session_timetable(v_s) where t_s = 780;
  if v_row.note is distinct from 'curtain' then
    raise exception 'FAIL 9b: the carried +13:00 row is labelled "%", expected "curtain"', v_row.note;
  end if;
  select * into v_row from public.session_timetable(v_s) where t_s = 600;
  if v_row.note is not null then
    raise exception 'FAIL 9c: +10:00 has no note, but the row says "%"', v_row.note;
  end if;
  select * into v_row from public.session_timetable(v_s) where t_s = 1500;
  if v_row.note is distinct from 'out' or v_row.state <> 'pending' then
    raise exception 'FAIL 9d: the last row is % / "%", expected pending / "out"', v_row.state, v_row.note;
  end if;
  -- The session was started on the plan's second revision (the publish that made it live).
  select count(*) into v_n from public.session_timetable(v_s) where plan_rev = 2;
  if v_n <> 5 then raise exception 'FAIL 9e: % of 5 rows carry revision 2', v_n; end if;
end $$;

-- ---------- 10. publishing still moves the revision, and the read survives it ----------
do $$
declare
  v_n integer;
begin
  -- Publishing is the planner's action; the member's claim is put back before the reads, because the point is what
  -- the member's schedule answers afterwards.
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b16', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b16'));

  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  select count(*) into v_n from public.session_timetable(current_setting('check.session')::uuid);
  if v_n <> 5 then
    raise exception 'FAIL 10a: a member reads % rows after a republish, expected 5', v_n;
  end if;
  select count(*) into v_n from public.session_timetable(current_setting('check.session')::uuid) where plan_rev = 3;
  if v_n <> 5 then
    raise exception 'FAIL 10b: % of 5 rows carry revision 3 after a republish', v_n;
  end if;
  select count(*) into v_n from public.plan_frames where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 0 then
    raise exception 'FAIL 10c: republishing opened the frames to a member (% rows)', v_n;
  end if;
end $$;

rollback;

select 'step 16: a member''s schedule -- their group only, all five words, the plan surface closed behind the one read, ops staff still seeing everything' as result;
