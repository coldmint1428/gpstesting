-- Step 20, checked at the database: the ops picture of a running plan, and where a group really is.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step20-ops.sql
--
-- What the step asks for, and what is proved here:
--
--   1. ONE ROW PER GROUP PER MOMENT, AND A STATUS THAT FLIPS. pending / active / done are attached to a moment and the
--      walk that begins at it (056). The check stands at every one of a group's moments -- one second before it, at
--      it, one second before the next -- and asserts the row that flips and the row it leaves behind. That is the
--      step's "status flips as the clock passes each frame", asserted at the frame and not merely across the night.
--   2. TRAVEL TIME IS THE STRIP'S INTERVAL. travel_s is the time between a moment and the group's next, with the last
--      moment null; it is asserted to be 60 s where "now - t_s" would say 30, and 3420 s across a 57-minute gap, and
--      120 s for a group whose two statements are the same place (the strip may be telling it not to move).
--   3. WHERE A GROUP REALLY IS, NUMERICALLY. Two ICs 20 m apart, 5 m and 20 m accurate: the group lands 1.18 m from
--      the accurate one and the read rounds that to "1 m from the walk". Swapping the two accuracies moves it to
--      18.82 m -- so an average (10 m) or "trust the best one" (0 m or 20 m) both fail. A third, unusable reading is
--      counted as sharing and not used; a reading older than two minutes is not used at all; "stopped sharing" is not
--      a position. The errors here are in metres and degrees, not "it looked right".
--   4. ONE RULE, TWO CALLERS. 056 moved the midpoint into group_position_at() and 021's trigger now calls it. The
--      check asserts that group_positions and plan_ops answer the same numbers from the same readings: the map's
--      position and the ops board's position cannot drift apart.
--   5. WHO READS IT. 040's rule: ops staff every group, a member their own, a member with no group none, an outsider
--      refused; a session with no plan refused with a sentence, an unknown session refused, anon not granted the
--      read, and the internal helper not executable by authenticated at all.
--   6. OFF SITE HAS NO DISTANCE. A moment that puts a group off site still says where its phones are, but off_m is
--      null: there is no place on the map to measure to.
--
-- The clock the check works on. It builds its own plan and starts a real session through start_event, so t0_at is the
-- plan's printed T+0 (50 minutes ago) and starts_at is now -- the pair step 14 proved t0_at must win. Every read below
-- passes p_at explicitly: a check that compared a clock to a frame has to say which clock it means, and this one does.
-- The locations are inserted as the table's owner, with the session's starts_at moved back five minutes so the
-- presence trigger finds it: that trigger is 021's subject, not this step's, and the readings are fixture.
--
-- Everything runs in one transaction and is rolled back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a bench of its own, and a clean event clock ----------
delete from public.plans where id = '0b000000-0000-4000-8000-000000000b20';
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;

-- The bench's own session (d001) starts at 18:45 and ends at 19:30, and 021's trigger gives a reading to the open-or-
-- covering session with the LATEST start. A reading "ten seconds ago" is inside d001 after 18:45 -- so from that hour on,
-- the trigger wrote this check's midpoint into d001 instead of the session the check had just started, and section 4
-- failed on a check that had passed all afternoon (finding 80). The fixture moves d001 a week back, which keeps its id
-- (the "session with no plan" assertions still use it) and takes its window out of the readings' way.
update public.event_sessions
   set starts_at = starts_at - interval '7 days', ended_at = ended_at - interval '7 days'
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and ended_at is not null
   and ended_at > now() - interval '1 day';

insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', 'Ops bench',
       (now() at time zone 'Asia/Singapore' - interval '50 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '50 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

-- Five moments. The last one is an hour after the fourth, so a group's "active" leg can be long and its travel time
-- is plainly the strip's number and not the clock's.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2001', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01',    0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2002', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01',   60, 'doors', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2003', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01',  120, 'build', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2004', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01',  180, 'out',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2005', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', 3600, 'end',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

-- Gate Crew walks 24 m north a step to +3:00 and then stands at that point until the hour: the two last statements are
-- the same place, so the walk's expectation at "now" (50 minutes in) is a fixed coordinate the position section can
-- measure against. Sound is stated at the call and then off site at +2:00. Backstage appears once, at +2:00, and
-- Security once, at +1:00:00 -- the two shapes the status rules have to handle without inventing a walk.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f2001', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2002', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2003', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2004', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2005', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2001', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2003', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2003', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3350000, 103.77500),
  ('0b000000-0000-4000-8000-0000000f2005', '0b000000-0000-4000-8000-000000000b20', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3360000, 103.77600);

update public.plan_positions set state = 'off_site'
 where frame_id = '0b000000-0000-4000-8000-0000000f2003'
   and group_id = '0b000000-0000-4000-8000-00000000a002';

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b20',
                              (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b20'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b20');
  perform set_config('check.session', v_s::text, true);
end $$;

-- The presence trigger looks for the session whose starts_at covers a reading's time (021). start_event set starts_at
-- to now, and this check's readings are a few seconds old, so the fixture moves it back -- t0_at is untouched.
reset role;
update public.event_sessions
   set starts_at = now() - interval '5 minutes'
 where id = current_setting('check.session')::uuid;

-- ---------- 1. what one read answers ----------
-- Standing at T+1:30, between Gate Crew's +1:00 and +2:00 moments and after Sound's only walk has begun.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_n integer;
  v_g integer;
  v_r record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  select count(*), count(distinct group_name) into v_n, v_g from public.plan_ops(v_s, v_at);
  if v_n is distinct from 9 then
    raise exception 'FAIL 1a: % rows, expected 9 (5 Gate Crew + 2 Sound + 1 Backstage + 1 Security)', v_n;
  end if;
  if v_g is distinct from 4 then
    raise exception 'FAIL 1b: % groups, expected 4', v_g;
  end if;

  -- The active row of Gate Crew: the moment it is on, the moment after, and the time between them.
  select * into v_r from public.plan_ops(v_s, v_at) where group_name = 'Gate Crew' and t_s = 60;
  if not found then
    raise exception 'FAIL 1c: Gate Crew has no +1:00 moment';
  end if;
  if v_r.status is distinct from 'active' then
    raise exception 'FAIL 1d: at T+1:30 Gate Crew''s +1:00 moment reads %, expected active', v_r.status;
  end if;
  if v_r.planned_at is distinct from v_t0 + interval '60 seconds' then
    raise exception 'FAIL 1e: the moment''s clock time is %, expected t0_at + 1:00', v_r.planned_at;
  end if;
  if v_r.next_t_s is distinct from 120 or v_r.next_at is distinct from v_t0 + interval '120 seconds' then
    raise exception 'FAIL 1f: next moment is % / %, expected 120 / t0_at + 2:00', v_r.next_t_s, v_r.next_at;
  end if;
  if v_r.travel_s is distinct from 60 then
    raise exception 'FAIL 1g: travel_s is %, expected 60', v_r.travel_s;
  end if;
  if v_r.note is distinct from 'doors' then
    raise exception 'FAIL 1h: the moment''s note is %, expected doors', v_r.note;
  end if;
  if v_r.plan_verify is distinct from 'auto' then
    raise exception 'FAIL 1i: the moment''s verify flag is %, expected auto', v_r.plan_verify;
  end if;

  -- The walk's own arithmetic, at an instant between two statements: half way from +1:00 to +2:00.
  if v_r.expected_lat is null then
    raise exception 'FAIL 1j: no expected position at an instant the group is walking';
  end if;
  if abs(v_r.expected_lat - 1.33032565) > 0.0000005 then
    raise exception 'FAIL 1k: expected latitude is %, expected the midpoint 1.33032565', v_r.expected_lat;
  end if;
  if v_r.expected_state is distinct from 'on_site' then
    raise exception 'FAIL 1l: the walk says the group is %, expected on_site', v_r.expected_state;
  end if;

  -- Exactly two rows are active: Gate Crew's walk and Sound's (its next moment is at +2:00).
  select count(*) into v_n from public.plan_ops(v_s, v_at) where status = 'active';
  if v_n is distinct from 2 then
    raise exception 'FAIL 1m: % active rows at T+1:30, expected 2', v_n;
  end if;

  -- Rows come back by group name and then by the clock: the ops board's own order.
  select group_name, t_s into v_r from public.plan_ops(v_s, v_at) order by 1, 2 limit 1;
  if v_r.group_name is distinct from 'Backstage' or v_r.t_s is distinct from 120 then
    raise exception 'FAIL 1n: the first row is % at %s, expected Backstage at 120', v_r.group_name, v_r.t_s;
  end if;
end $$;

-- ---------- 2. the clock passes each moment ----------
-- One second before a moment, at it, and one second before the next: the row that flips and the row it leaves. A
-- moment's status is the walk that begins at it, so passing +2:00 makes Gate Crew's +1:00 row done and its +2:00 row
-- active, leaves Sound's +2:00 row done (its last moment has no walk), and finishes Backstage's single moment.
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_case record;
  v_have text;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  for v_case in
    select * from (values
      (-1,   'Gate Crew',    0, 'pending'),
      (-1,   'Gate Crew', 3600, 'pending'),
      (-1,   'Sound',        0, 'pending'),
      (-1,   'Backstage',  120, 'pending'),
      (0,    'Gate Crew',    0, 'active'),
      (0,    'Gate Crew',   60, 'pending'),
      (0,    'Sound',        0, 'active'),
      (0,    'Security',  3600, 'pending'),
      (59,   'Gate Crew',    0, 'active'),
      (60,   'Gate Crew',    0, 'done'),
      (60,   'Gate Crew',   60, 'active'),
      (119,  'Gate Crew',   60, 'active'),
      (120,  'Gate Crew',   60, 'done'),
      (120,  'Gate Crew',  120, 'active'),
      (120,  'Sound',        0, 'done'),
      (120,  'Sound',      120, 'done'),
      (120,  'Backstage',  120, 'done'),
      (120,  'Security',  3600, 'pending'),
      (180,  'Gate Crew',  120, 'done'),
      (180,  'Gate Crew',  180, 'active'),
      (3599, 'Gate Crew',  180, 'active'),
      (3599, 'Security',  3600, 'pending'),
      (3600, 'Gate Crew',  180, 'done'),
      (3600, 'Gate Crew', 3600, 'done'),
      (3600, 'Security',  3600, 'done')
    ) as c (off_s, grp, t_s, want)
  loop
    select o.status into v_have
      from public.plan_ops(v_s, v_t0 + make_interval(secs => v_case.off_s)) o
     where o.group_name = v_case.grp and o.t_s = v_case.t_s;
    if not found then
      raise exception 'FAIL 2a: at T+%s the read has no % %s moment', v_case.off_s, v_case.grp, v_case.t_s;
    end if;
    if v_have is distinct from v_case.want then
      raise exception 'FAIL 2b: at T+%s % at %s reads %, expected %',
        v_case.off_s, v_case.grp, v_case.t_s, v_have, v_case.want;
    end if;
  end loop;

  -- The number of moments under way, at each of the same instants: two while both first walks are on, one after +2:00
  -- (Gate Crew alone), none once the hour is reached.
  for v_case in
    select * from (values (-1, 0), (0, 2), (59, 2), (60, 2), (119, 2), (120, 1), (180, 1), (3599, 1), (3600, 0))
      as c (off_s, want)
  loop
    select count(*) into v_n from public.plan_ops(v_s, v_t0 + make_interval(secs => v_case.off_s)) where status = 'active';
    if v_n is distinct from v_case.want then
      raise exception 'FAIL 2c: at T+%s % moments are active, expected %', v_case.off_s, v_n, v_case.want;
    end if;
  end loop;

  -- Before T+0 nothing has happened: every row pending, and the walk has no expectation to give.
  select count(*) into v_n from public.plan_ops(v_s, v_t0 - interval '5 minutes') where status <> 'pending';
  if v_n is distinct from 0 then
    raise exception 'FAIL 2d: % rows are not pending before T+0', v_n;
  end if;
  select count(*) into v_n from public.plan_ops(v_s, v_t0 - interval '5 minutes') where expected_lat is not null;
  if v_n is distinct from 0 then
    raise exception 'FAIL 2e: % rows have an expected position before T+0', v_n;
  end if;
end $$;

-- ---------- 3. travel time is the strip's interval ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_travel integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  -- Gate Crew: 60 s legs while it walks, then the 57 minutes the strip gives it to stand still.
  select travel_s into v_travel from public.plan_ops(v_s, v_at) where group_name = 'Gate Crew' and t_s = 0;
  if not found then
    raise exception 'FAIL 3a: no Gate Crew +0:00 row';
  end if;
  if v_travel is distinct from 60 then
    raise exception 'FAIL 3b: Gate Crew''s +0:00 leg is % s, expected 60', v_travel;
  end if;

  select travel_s into v_travel from public.plan_ops(v_s, v_at) where group_name = 'Gate Crew' and t_s = 180;
  if v_travel is distinct from 3420 then
    raise exception 'FAIL 3c: the +3:00 leg is % s, expected 3420 (57 minutes)', v_travel;
  end if;

  select travel_s into v_travel from public.plan_ops(v_s, v_at) where group_name = 'Gate Crew' and t_s = 3600;
  if not found then
    raise exception 'FAIL 3d: no Gate Crew +1:00:00 row';
  end if;
  if v_travel is not null then
    raise exception 'FAIL 3e: the last moment has a travel time of % s, expected none', v_travel;
  end if;

  -- Sound's statements are the same place: the strip is still giving it two minutes to get from one to the other,
  -- which is why travel time is not a distance over a pace.
  select travel_s into v_travel from public.plan_ops(v_s, v_at) where group_name = 'Sound' and t_s = 0;
  if v_travel is distinct from 120 then
    raise exception 'FAIL 3f: Sound''s standing leg is % s, expected 120', v_travel;
  end if;

  -- And it is not lateness: the clock is 90 s past T+0, so "now - t_s" would say 90 for the first moment and 30 for
  -- the active one. The read says the strip's number instead.
  select travel_s into v_travel from public.plan_ops(v_s, v_at) where group_name = 'Gate Crew' and t_s = 60;
  if v_travel is not distinct from 30 then
    raise exception 'FAIL 3g: travel_s is the clock''s lateness (30 s), not the strip''s interval';
  end if;
end $$;

-- ---------- 4. where a group really is ----------
-- Two Gate Crew ICs, 20 m apart. IC1 is 5 m accurate at the point the walk expects; IC2 is 20 m north and 20 m
-- accurate. weight = 1 / accuracy^2 puts the group 1.18 m from IC1 -- 16/17 of the way from IC2, not half way.
reset role;

insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3306513, 103.77400, 5, 'gps', now() - interval '20 seconds'),
  ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
   '00cd023b-0e26-4574-a635-760e782c8029', 1.33083096, 103.77400, 20, 'gps', now() - interval '10 seconds');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
  v_gp record;
begin
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Gate Crew' and t_s = 3600;
  if not found then
    raise exception 'FAIL 4a: no Gate Crew row to carry a position';
  end if;
  if v_r.actual_ics is distinct from 2 then
    raise exception 'FAIL 4b: % ICs sharing, expected 2', v_r.actual_ics;
  end if;
  if v_r.actual_accuracy is distinct from 5 then
    raise exception 'FAIL 4c: the position''s accuracy is %, expected 5', v_r.actual_accuracy;
  end if;
  -- 0.00017966 degrees of latitude is 20 m; the weighted step off IC1 is 20 * (1/400) / (1/25 + 1/400) = 1.176 m.
  if abs(v_r.actual_lat - 1.33066187) > 0.0000005 then
    raise exception 'FAIL 4d: the midpoint is %, expected 1.33066187 (1.18 m from the accurate IC)', v_r.actual_lat;
  end if;
  if abs(v_r.actual_lng - 103.77400) > 0.0000001 then
    raise exception 'FAIL 4e: longitude moved to %, expected 103.77400', v_r.actual_lng;
  end if;
  if v_r.off_m is distinct from 1 then
    raise exception 'FAIL 4f: the group is % m from the walk, expected 1 (nearer the accurate IC than the sloppy one)', v_r.off_m;
  end if;
  if v_r.actual_at is distinct from now() - interval '10 seconds' then
    raise exception 'FAIL 4g: the position''s reading time is %, expected 10 s ago', v_r.actual_at;
  end if;

  -- One rule, two callers: the live group_positions row that 021's trigger maintains, from the same two readings.
  select * into v_gp from public.group_positions where session_id = v_s and group_id = '0b000000-0000-4000-8000-00000000a001';
  if not found then
    raise exception 'FAIL 4h: the presence trigger wrote no group_positions row';
  end if;
  if abs(v_gp.lat - v_r.actual_lat) > 0.0000001 or abs(v_gp.lng - v_r.actual_lng) > 0.0000001 then
    raise exception 'FAIL 4i: group_positions says % / %, plan_ops says % / %',
      v_gp.lat, v_gp.lng, v_r.actual_lat, v_r.actual_lng;
  end if;
  if v_gp.ics_sharing is distinct from v_r.actual_ics then
    raise exception 'FAIL 4j: group_positions counts % ICs, plan_ops %', v_gp.ics_sharing, v_r.actual_ics;
  end if;
end $$;

-- Swap the two accuracies: the same two readings now put the group 18.82 m from the walk, near the other IC. An
-- average would answer 10 m both times and a "trust the best phone" rule 0 m or 20 m -- this is the assertion that
-- says which rule is in force.
reset role;
update public.locations
   set accuracy = case user_id
                    when 'ba04a00c-518f-4252-91d5-1081cecec1d2' then 20
                    else 5
                  end
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and group_id = '0b000000-0000-4000-8000-00000000a001'
   and recorded_at > now() - interval '1 minute';
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
begin
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Gate Crew' and t_s = 3600;
  if abs(v_r.actual_lat - 1.33082039) > 0.0000005 then
    raise exception 'FAIL 4k: with the accuracies swapped the midpoint is %, expected 1.33082039', v_r.actual_lat;
  end if;
  if v_r.off_m is distinct from 19 then
    raise exception 'FAIL 4l: with the accuracies swapped the group is % m from the walk, expected 19', v_r.off_m;
  end if;
end $$;

-- A third reading, worse than 100 m: still an IC who is sharing (so it is counted), never used to place the group.
reset role;
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
        '00cd023b-0e26-4574-a635-760e782c8029', 1.33100000, 103.77400, 150, 'gps', now() - interval '5 seconds');
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
begin
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Gate Crew' and t_s = 3600;
  if v_r.actual_ics is distinct from 2 then
    raise exception 'FAIL 4m: % ICs sharing, expected 2 (the rough one still shares)', v_r.actual_ics;
  end if;
  if v_r.actual_accuracy is distinct from 20 then
    raise exception 'FAIL 4n: the position''s accuracy is %, expected 20 (the 150 m reading is not usable)', v_r.actual_accuracy;
  end if;
  -- Only IC1's 20 m reading is usable now, so the group stands exactly on it: 0 m from the walk.
  if abs(v_r.actual_lat - 1.3306513) > 0.000000001 then
    raise exception 'FAIL 4o: the rough reading moved the group to %, expected IC1''s 1.3306513', v_r.actual_lat;
  end if;
  if v_r.off_m is distinct from 0 then
    raise exception 'FAIL 4p: the group is % m from the walk, expected 0', v_r.off_m;
  end if;
end $$;

-- Older than two minutes: not used at all. What is left is the rough 150 m reading, so the group has a sharing IC
-- and no position -- "1 IC" and "no signal" are different answers, and both are true here.
reset role;
update public.locations
   set recorded_at = now() - interval '3 minutes'
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and group_id = '0b000000-0000-4000-8000-00000000a001'
   and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2';
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
begin
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Gate Crew' and t_s = 3600;
  if v_r.actual_ics is distinct from 1 then
    raise exception 'FAIL 4q: % ICs sharing, expected 1 (the stale reading is gone)', v_r.actual_ics;
  end if;
  if v_r.actual_lat is not null or v_r.actual_lng is not null then
    raise exception 'FAIL 4r: a stale-only group has a position (% / %)', v_r.actual_lat, v_r.actual_lng;
  end if;
  if v_r.off_m is not null then
    raise exception 'FAIL 4s: a group with no position is % m from the walk, expected no answer', v_r.off_m;
  end if;
end $$;

-- A fresh, usable reading for the second IC, and then the stop row that ends it. "Stopped sharing" is a statement
-- about the phone, not a place: the group has no position, not a position at the phone's last spot.
reset role;
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
        '00cd023b-0e26-4574-a635-760e782c8029', 1.33083096, 103.77400, 20, 'gps', now());
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
begin
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Gate Crew' and t_s = 3600;
  if v_r.actual_ics is distinct from 1 or v_r.actual_accuracy is distinct from 20 then
    raise exception 'FAIL 4t: expected one usable 20 m reading, got % ICs at % m', v_r.actual_ics, v_r.actual_accuracy;
  end if;
  if v_r.off_m is null or v_r.off_m < 19 or v_r.off_m > 21 then
    raise exception 'FAIL 4u: the group is % m from the walk, expected about 20 (one IC, 20 m north)', v_r.off_m;
  end if;
end $$;

reset role;
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
        '00cd023b-0e26-4574-a635-760e782c8029', 1.33083096, 103.77400, 20, 'stop', now() + interval '1 second');
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_r record;
begin
  select * into v_r from public.plan_ops(v_s, now() + interval '1 second') where group_name = 'Gate Crew' and t_s = 3600;
  if v_r.actual_ics is distinct from 0 then
    raise exception 'FAIL 4v: % ICs sharing after Stop, expected 0', v_r.actual_ics;
  end if;
  if v_r.actual_lat is not null then
    raise exception 'FAIL 4w: after Stop the group still has a position at %', v_r.actual_lat;
  end if;
end $$;

-- ---------- 5. who reads it ----------
-- 040's rule, at the moment it matters: a member's own group only. testuser3 is Sound's administrator and nothing else.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_n integer;
  v_other integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  select count(*), count(*) filter (where group_name <> 'Sound') into v_n, v_other
    from public.plan_ops(v_s, v_t0 + interval '90 seconds');
  if v_n is distinct from 2 then
    raise exception 'FAIL 5a: a member sees % rows, expected 2 (their own group''s)', v_n;
  end if;
  if v_other is distinct from 0 then
    raise exception 'FAIL 5b: a member sees % rows of another group', v_other;
  end if;
end $$;

-- The same person, no group: the read answers nothing rather than another group's rows.
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
  select count(*) into v_n from public.plan_ops(v_s);
  if v_n is distinct from 0 then
    raise exception 'FAIL 5c: a member with no group sees % rows', v_n;
  end if;
end $$;

-- Somebody who is not in the event at all.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000dead","role":"authenticated"}';
do $$
begin
  perform public.plan_ops(current_setting('check.session')::uuid);
  raise exception 'FAIL 5d: an outsider read the ops board';
exception when sqlstate '42501' then null;
end $$;

-- A session that is not running a plan (the bench's own ended session), and one that does not exist.
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
do $$
begin
  perform public.plan_ops('0b000000-0000-4000-8000-00000000d001');
  raise exception 'FAIL 5e: a session with no plan answered';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.plan_ops('0b000000-0000-4000-8000-000000000000');
  raise exception 'FAIL 5f: an unknown session answered';
exception when sqlstate '42501' then null;
end $$;

-- The helper is not a door: authenticated may not call it, and anon may not call the read.
do $$
begin
  perform public.group_position_at('0b000000-0000-4000-8000-000000000e01',
                                   '0b000000-0000-4000-8000-00000000a001', now());
  raise exception 'FAIL 5g: authenticated could call the internal helper';
exception when insufficient_privilege then null;
end $$;

set local role anon;
do $$
begin
  perform public.plan_ops(current_setting('check.session')::uuid);
  raise exception 'FAIL 5h: anon could call plan_ops';
exception when insufficient_privilege then null;
end $$;

-- ---------- 6. off site has no distance ----------
-- Sound is off site at +2:00. Its phones are still on the map, and the read still says where they are -- but the walk
-- has no place to measure to, so off_m is null even though expected and actual are the same coordinate. Sound's last
-- moment is +2:00 and the read is now, 50 minutes later, so the walk's answer is that off-site statement.
reset role;
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002',
        '2906655b-33ad-4e9d-a608-f083e43e22d4', 1.3340000, 103.77300, 10, 'gps', now() - interval '10 seconds');
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_r record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  select * into v_r from public.plan_ops(v_s, now()) where group_name = 'Sound' and t_s = 120;
  if not found then
    raise exception 'FAIL 6a: Sound has no +2:00 moment';
  end if;
  if v_r.plan_state is distinct from 'off_site' or v_r.expected_state is distinct from 'off_site' then
    raise exception 'FAIL 6b: the moment is % and the walk says %, expected both off_site', v_r.plan_state, v_r.expected_state;
  end if;
  if v_r.actual_lat is null or abs(v_r.actual_lat - 1.3340000) > 0.0000001 then
    raise exception 'FAIL 6c: the phones are not where they are (%), though the group is off site', v_r.actual_lat;
  end if;
  if v_r.off_m is not null then
    raise exception 'FAIL 6d: an off-site group is % m from the walk, expected no distance', v_r.off_m;
  end if;
end $$;

rollback;

select 'step 20: one row per moment with pending/active/done flipping at each frame, travel time from the strip, and the multi-IC midpoint 1.18 m from the accurate IC on the ops read and in group_positions' as result;
