-- Step 14, checked at the database: actuals, and the clock they are measured against.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step14-actuals.sql
--
-- There is no screen for this yet -- step 16 builds the one members read -- so the proof is the functions
-- themselves, called the way the app will call them. What has to be true:
--
--   1. The plan's clock is t0_at, not starts_at. The fixture below keeps them 50 minutes apart, so a status
--      board built on the wrong one does not merely look odd: it answers with a different number (section 4
--      asserts that the wrong formula gives -2910 s where the right one gives +90 s). Finding 4 of the plan is
--      this distinction; the bench's own story is the same one (18:00 doors, 18:45 call).
--   2. One arrived and one missed come back with their exact state, lateness, when and by whom.
--   3. A future frame reports no lateness. So does an off-site frame ("not required"), and a group that is not
--      in the plan yet has no row at all rather than a phantom "late".
--   4. A frame nobody has marked is late, not missed: the plan refuses to call a group missed at the exact second
--      the plan said, because the group may be three minutes behind and about to walk in. Missed is a decision.
--   5. Writes go through progress_mark() only: the table is read-only to authenticated, refused to anon, and
--      every direct insert is refused. The role check is ops + the group's IC/admin, not any member.
--   6. Deleting a frame deletes what was recorded at it (frame_id on delete cascade), and the frame is then gone
--      from the timetable as well.
--   7. An ended session can still be recorded -- paperwork happens late -- and that is stated here rather than
--      discovered by a marshal the morning after.
--
-- The clock the check works on: it builds its own plan and starts a real session through start_event. The plan's
-- T+0 is "50 minutes ago", so the session's starts_at is 50 minutes after its t0_at by construction: start_event
-- sets starts_at = now() and t0_at from the plan's date/time, which is exactly the pair the product produces and
-- exactly the pair a starts_at implementation gets wrong.
--
-- Everything runs in one transaction and is rolled back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a bench of its own, and a clean event clock ----------
-- Built as the table's owner: frames are fixture, not the thing under test. The session itself is started through
-- the product's own door below.
delete from public.plans where id = '0b000000-0000-4000-8000-000000000b14';
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', 'Actuals bench',
       (now() at time zone 'Asia/Singapore' - interval '50 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '50 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1401', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1402', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',   60, 'doors',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1403', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',  120, 'doors in', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1404', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',  180, 'support', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1405', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', 3600, 'late',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  -- Gate Crew: 24 m north per frame for the first four, then still -- a legal strip for plan_publish.
  ('0b000000-0000-4000-8000-0000000f1401', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1402', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1403', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1404', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1405', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  -- Sound: on site for the first frame only, then stated off site at +3:00 and carried from there. So +0:00 has
  -- something to record and +3:00 has nothing -- the two halves of "off-site frames read as not required".
  ('0b000000-0000-4000-8000-0000000f1401', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1404', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  -- Backstage is first stated at +3:00: before that it is not in the plan, so it must not appear as "late".
  ('0b000000-0000-4000-8000-0000000f1404', '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3350000, 103.77500);

update public.plan_positions set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f1404'
   and group_id = '0b000000-0000-4000-8000-00000000a002';

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b14', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b14'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b14');
  perform set_config('check.session', v_s::text, true);
end $$;

-- ---------- 1. the clock the session carries ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_starts timestamptz;
  v_plan uuid;
begin
  select t0_at, starts_at, plan_id into v_t0, v_starts, v_plan
    from public.event_sessions where id = v_s;
  if v_plan is null then
    raise exception 'FAIL 1a: start_event did not put the plan on the session';
  end if;
  if v_t0 is null then
    raise exception 'FAIL 1b: the session has no t0_at';
  end if;
  if v_starts - v_t0 <> interval '50 minutes' then
    raise exception 'FAIL 1c: starts_at is % after t0_at, expected exactly 50 minutes', v_starts - v_t0;
  end if;
  if v_t0 <> now() - interval '50 minutes' then
    raise exception 'FAIL 1d: t0_at is %, expected 50 minutes before now', v_t0;
  end if;
end $$;

-- ---------- 2. before anything is recorded: the clock's own answer ----------
-- p_at is pinned to T+0+200 s so every number below is exact rather than "about right".
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '200 seconds';

  -- The plan says the first frame is at T+0; a starts_at implementation would put it 50 minutes later.
  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  if not found then raise exception 'FAIL 2a: no row for Gate Crew at +0:00'; end if;
  if v.planned_at <> v_t0 then
    raise exception 'FAIL 2b: +0:00 is planned for %, expected the session''s t0_at %', v.planned_at, v_t0;
  end if;
  if v.state <> 'late' then
    raise exception 'FAIL 2c: an unmarked frame in the past reads "%", expected late', v.state;
  end if;
  if v.lateness is distinct from interval '200 seconds' then
    raise exception 'FAIL 2d: lateness is %, expected 200 s of clock', v.lateness;
  end if;

  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 3600;
  if not found then raise exception 'FAIL 2e: no row for Gate Crew at +1:00:00'; end if;
  if v.state <> 'pending' then
    raise exception 'FAIL 2f: a future frame reads "%", expected pending', v.state;
  end if;
  if v.lateness is not null then
    raise exception 'FAIL 2g: a future frame reports lateness %', v.lateness;
  end if;

  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a002' and t_s = 180;
  if not found then raise exception 'FAIL 2h: no row for Sound at +3:00'; end if;
  if v.state <> 'not_required' then
    raise exception 'FAIL 2i: an off-site frame reads "%", expected not_required', v.state;
  end if;
  if v.lateness is not null then
    raise exception 'FAIL 2j: an off-site frame reports lateness %', v.lateness;
  end if;

  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a002' and t_s = 0;
  if v.state <> 'late' then
    raise exception 'FAIL 2k: Sound is off site only later; +0:00 reads "%", expected late', v.state;
  end if;

  -- A group that is not in the plan yet has no cell: no phantom "late" for Backstage before +3:00.
  if exists (select 1 from public.session_status(v_s, v_at)
              where group_id = '0b000000-0000-4000-8000-00000000a003' and t_s < 180) then
    raise exception 'FAIL 2l: Backstage has a status before it is placed in the plan';
  end if;
  select count(*) into v_n from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a003';
  if v_n <> 2 then
    raise exception 'FAIL 2m: Backstage has % rows, expected the 2 frames it is placed at (+3:00 and +1:00:00)', v_n;
  end if;

  select count(*) into v_n from public.session_status(v_s, v_at);
  if v_n <> 12 then
    raise exception 'FAIL 2n: the timetable has % rows, expected 12 (Gate Crew 5, Sound 5, Backstage 2)', v_n;
  end if;
end $$;

-- ---------- 3. one arrived and one missed, and a correction ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_row public.plan_progress;
  v record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '200 seconds';

  -- Gate Crew's IC says they arrived 90 s late; the planner says the next frame did not happen 150 s in.
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
  if v_row.state <> 'arrived' or v_row.marked_at <> v_t0 + interval '90 seconds' then
    raise exception 'FAIL 3a: the recorded row is % at %', v_row.state, v_row.marked_at;
  end if;
  if v_row.marked_by <> 'ba04a00c-518f-4252-91d5-1081cecec1d2' then
    raise exception 'FAIL 3b: the arrival says it was recorded by %', v_row.marked_by;
  end if;

  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1402',
                                '0b000000-0000-4000-8000-00000000a001', 'missed', v_t0 + interval '150 seconds');
  if v_row.state <> 'missed' or v_row.marked_at <> v_t0 + interval '150 seconds' then
    raise exception 'FAIL 3c: the missed row is % at %', v_row.state, v_row.marked_at;
  end if;

  -- Sound's admin records its own group, and the planner corrects it: saying it twice is a correction, not a
  -- second opinion.
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                               '0b000000-0000-4000-8000-00000000a002', 'arrived', v_t0 + interval '30 seconds');
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                               '0b000000-0000-4000-8000-00000000a002', 'missed', v_t0 + interval '100 seconds');
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 3 then
    raise exception 'FAIL 3d: % progress rows, expected 3 -- a correction replaced one instead of adding one', v_n;
  end if;

  -- The arrived row, exactly.
  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  if v.state <> 'arrived' then
    raise exception 'FAIL 3e: the arrived frame reads "%"', v.state;
  end if;
  if v.lateness is distinct from interval '90 seconds' then
    raise exception 'FAIL 3f: an arrival 90 s after the plan reads lateness %', v.lateness;
  end if;
  if v.marked_at <> v_t0 + interval '90 seconds' then
    raise exception 'FAIL 3g: the arrived frame says it was recorded at %', v.marked_at;
  end if;
  if v.marked_by <> 'ba04a00c-518f-4252-91d5-1081cecec1d2' then
    raise exception 'FAIL 3h: the arrived frame was recorded by %', v.marked_by;
  end if;

  -- The missed row, exactly. It was decided 90 s after the frame it is about (150 s after T+0).
  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 60;
  if v.state <> 'missed' then
    raise exception 'FAIL 3i: the missed frame reads "%"', v.state;
  end if;
  if v.lateness is distinct from interval '90 seconds' then
    raise exception 'FAIL 3j: a decision 90 s after the frame reads lateness %', v.lateness;
  end if;

  -- Sound's correction took.
  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a002' and t_s = 0;
  if v.state <> 'missed' or v.lateness is distinct from interval '100 seconds' then
    raise exception 'FAIL 3k: the corrected Sound row is % / %, expected missed / 100 s', v.state, v.lateness;
  end if;

  -- And the row count of the timetable did not change: a record is one row per group per frame.
  select count(*) into v_n from public.session_status(v_s, v_at);
  if v_n <> 12 then
    raise exception 'FAIL 3l: the timetable now has % rows, expected 12', v_n;
  end if;

  -- A future frame is still a future frame after two outcomes were recorded elsewhere.
  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 3600;
  if v.state <> 'pending' or v.lateness is not null then
    raise exception 'FAIL 3m: the future frame reads % / %, expected pending / no lateness', v.state, v.lateness;
  end if;
end $$;

-- ---------- 4. the plan's clock is the one that was used ----------
-- The bench keeps t0_at and starts_at 50 minutes apart. If the timetable had been built on starts_at, +0:00's
-- planned time would be 50 minutes later and the arrival's lateness would be -2910 s instead of +90 s. Asserting
-- that the wrong answer is different is what makes "measured from t0_at" a fact rather than a claim.
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_starts timestamptz;
  v_at timestamptz;
  v record;
  v_wrong interval;
begin
  select t0_at, starts_at into v_t0, v_starts from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '200 seconds';

  select * into v from public.session_status(v_s, v_at)
   where group_id = '0b000000-0000-4000-8000-00000000a001' and t_s = 0;
  v_wrong := v.marked_at - (v_starts + make_interval(secs => 0));
  if v_wrong = v.lateness then
    raise exception 'FAIL 4a: the two clocks give the same lateness (%): the fixture cannot tell them apart', v_wrong;
  end if;
  if v_wrong <> interval '-2910 seconds' then
    raise exception 'FAIL 4b: the starts_at answer is %, expected -2910 s -- the gap is not the 50 minutes it should be', v_wrong;
  end if;
  if v.lateness <> interval '90 seconds' then
    raise exception 'FAIL 4c: the t0_at answer is %, expected 90 s', v.lateness;
  end if;
end $$;

-- ---------- 5. the sentences a caller gets for the things that are not allowed ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_msg text;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  -- A group off site at that moment has nothing to arrive at.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1404',
                                 '0b000000-0000-4000-8000-00000000a002', 'arrived', v_t0 + interval '200 seconds');
    raise exception 'FAIL 5a: an off-site group was recorded as arriving';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%off site%' then raise exception 'FAIL 5b: the refusal reads "%"', v_msg; end if;
  end;

  -- A group that is not in the plan yet.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 '0b000000-0000-4000-8000-00000000a003', 'arrived', v_t0 + interval '200 seconds');
    raise exception 'FAIL 5c: a group that is not in the plan yet was recorded';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not in the plan%' then raise exception 'FAIL 5d: the refusal reads "%"', v_msg; end if;
  end;

  -- A moment that has not happened, and one before T+0.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1405',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', now() + interval '1 hour');
    raise exception 'FAIL 5e: a moment in the future was recorded';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not happened%' then raise exception 'FAIL 5f: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 - interval '1 second');
    raise exception 'FAIL 5g: a moment before T+0 was recorded';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%before the plan started%' then raise exception 'FAIL 5h: the refusal reads "%"', v_msg; end if;
  end;

  -- The two words.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 '0b000000-0000-4000-8000-00000000a001', 'maybe', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5i: the word "maybe" was accepted';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%arrived or missed%' then raise exception 'FAIL 5j: the refusal reads "%"', v_msg; end if;
  end;

  -- A frame from another plan, and a frame that does not exist.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f0401',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5k: a frame from another plan was recorded';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%another plan%' then raise exception 'FAIL 5l: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.progress_mark(v_s, gen_random_uuid(),
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5m: a frame that does not exist was recorded';
  exception when sqlstate '42501' then null;
  end;

  -- A group from nowhere.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 gen_random_uuid(), 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5n: a group that does not exist was recorded';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not in this event%' then raise exception 'FAIL 5o: the refusal reads "%"', v_msg; end if;
  end;

  -- Sound's admin may record Sound, and may not record Gate Crew or Backstage.
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5p: a group admin recorded another group';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%IC or admin%' then raise exception 'FAIL 5q: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1404',
                                 '0b000000-0000-4000-8000-00000000a003', 'arrived', v_t0 + interval '200 seconds');
    raise exception 'FAIL 5r: a group admin recorded a group they are not in';
  exception when sqlstate '42501' then null;
  end;

  -- Somebody who is not in the event at all.
  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1401',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 5s: somebody outside the event recorded an arrival';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not in this event%' then raise exception 'FAIL 5t: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.session_status(v_s);
    raise exception 'FAIL 5u: somebody outside the event read the timetable';
  exception when sqlstate '42501' then null;
  end;

  -- A session that runs no plan, and one that does not exist.
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  begin
    perform public.session_status('0b000000-0000-4000-8000-00000000d001');
    raise exception 'FAIL 5v: a session with no plan returned a timetable';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%not running a plan%' then raise exception 'FAIL 5w: the refusal reads "%"', v_msg; end if;
  end;
  begin
    perform public.session_status(gen_random_uuid());
    raise exception 'FAIL 5x: a session that does not exist returned a timetable';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 6. who may read, and the fact that nobody may write ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  -- A planner (a member) sees all three rows.
  perform set_config('request.jwt.claims', '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}', true);
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 3 then raise exception 'FAIL 6a: a planner sees % rows, expected 3', v_n; end if;

  -- An IC of one group sees their own group's outcomes, and only theirs. Until step 16 the policy was
  -- is_event_member, so this answered 3 -- every group's -- and that was recorded as the debt step 16 would close.
  -- 052 narrowed it to 040's rule, so the assertion is now the rule: two of the three rows are Gate Crew's.
  perform set_config('request.jwt.claims', '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}', true);
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 2 then
    raise exception 'FAIL 6b: a Gate Crew IC reads % outcomes, expected their own 2 (052)', v_n;
  end if;
  select count(*) into v_n from public.plan_progress
   where session_id = v_s and group_id <> '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 0 then raise exception 'FAIL 6b2: a Gate Crew IC reads % outcomes of another group', v_n; end if;
  -- The engine is scoped too (052 moved 040's rule into it), so the IC's timetable is their five moments.
  select count(*) into v_n from public.session_status(v_s);
  if v_n <> 5 then raise exception 'FAIL 6c: a member reads % timetable rows, expected their own 5', v_n; end if;

  -- Nobody outside the event sees a row.
  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 0 then raise exception 'FAIL 6d: an outsider sees % rows', v_n; end if;

  -- A direct insert is refused, even for the root user: progress_mark() is the only door.
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  begin
    insert into public.plan_progress (session_id, plan_id, event_id, frame_id, group_id, state)
    values (v_s, '0b000000-0000-4000-8000-000000000b14', '0b000000-0000-4000-8000-000000000e01',
            '0b000000-0000-4000-8000-0000000f1403', '0b000000-0000-4000-8000-00000000a001', 'arrived');
    raise exception 'FAIL 6e: a direct insert was accepted';
  exception when insufficient_privilege then null;
  end;
end $$;

-- anon is shut out of the table entirely.
set local role anon;
do $$
begin
  perform count(*) from public.plan_progress;
  raise exception 'FAIL 6f: anon could read the table';
exception when insufficient_privilege then null;
end $$;
set local role authenticated;

-- ---------- 7. deleting the frame deletes what was recorded at it ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_n integer;
  v_msg text;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);

  select count(*) into v_n from public.plan_progress
   where frame_id = '0b000000-0000-4000-8000-0000000f1402';
  if v_n <> 1 then raise exception 'FAIL 7a: the missed frame holds % rows before the delete', v_n; end if;

  perform public.frame_delete('0b000000-0000-4000-8000-0000000f1402', null);

  select count(*) into v_n from public.plan_progress
   where frame_id = '0b000000-0000-4000-8000-0000000f1402';
  if v_n <> 0 then raise exception 'FAIL 7b: a deleted frame left % progress rows behind', v_n; end if;
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 2 then raise exception 'FAIL 7c: % progress rows left, expected 2', v_n; end if;

  -- And the moment is gone from the timetable too, rather than lingering with a state from nowhere.
  if exists (select 1 from public.session_status(v_s, v_t0 + interval '200 seconds') where t_s = 60) then
    raise exception 'FAIL 7d: the timetable still states a deleted frame';
  end if;
  select count(*) into v_n from public.session_status(v_s, v_t0 + interval '200 seconds');
  if v_n <> 10 then raise exception 'FAIL 7e: the timetable has % rows after the delete, expected 10', v_n; end if;

  -- The frame is really gone: recording at it is refused like any other missing frame.
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1402',
                                 '0b000000-0000-4000-8000-00000000a001', 'arrived', v_t0 + interval '90 seconds');
    raise exception 'FAIL 7f: a deleted frame accepted an outcome';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- ---------- 8. paperwork happens late ----------
-- The event is over and somebody is reconciling: the record must still take a row. A status screen refuses
-- nothing here; it is the plan that is closed, not the truth.
-- The "ended" row is written as the owner: ending an event is a product action with its own door, and this check
-- is about what happens to the record afterwards, not about that door.
reset role;
update public.event_sessions
   set ended_at = now(), end_reason = 'ended'
 where id = current_setting('check.session')::uuid;
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_row public.plan_progress;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f1404',
                                '0b000000-0000-4000-8000-00000000a003', 'arrived', v_t0 + interval '200 seconds');
  if v_row.state <> 'arrived' then
    raise exception 'FAIL 8a: after the event ended, the record took %', v_row.state;
  end if;
  if not exists (select 1 from public.session_status(v_s, v_t0 + interval '200 seconds')
                  where group_id = '0b000000-0000-4000-8000-00000000a003' and t_s = 180 and state = 'arrived') then
    raise exception 'FAIL 8b: the late record does not read back';
  end if;
end $$;

rollback;

select 'step 14: t0_at not starts_at, arrived and missed exactly, future frames no lateness, writes only through progress_mark, and a frame delete takes its record with it' as result;
