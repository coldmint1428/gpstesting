-- Step 27, checked at the database: a moment closes when the IC's phone is close enough -- and only when the moment
-- is somewhere to arrive at.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step27-tolerance.sql
--
-- One transaction, rolled back. It builds its own plan on the bench event (eight frames, a walk due east in 20 m
-- steps, so every step is legal and nothing crosses), publishes it through the product's gate, starts a real session
-- through start_event(), and then stands at chosen seconds with readings it wrote itself.
--
-- WHAT HAS TO BE TRUE, and why each assertion is here:
--
-- A. THE NUMBER. Every membership row carries a radius, 30 m unless somebody says otherwise, and the column's CHECK
--    refuses 4 and 101 (5..100). A band nobody can leave is worth one assertion each end.
--
-- B. THE DOOR. `group_members` has no write policy, so the radius is set through `set_arrival_tolerance`. It admits the
--    person themself, the event's root or planner, and the group's own admin -- and nobody else: an IC of another
--    group is refused, a group admin whose IC is in another group is refused, an outsider is refused, the anon key
--    cannot execute it at all. A person who is not an IC is refused even by themselves: only an IC shares a phone, so
--    only an IC has a radius anything would read.
--
-- C. THE RADIUS IS WHAT CLOSES A MOMENT. An IC standing 25 m from the point, outside the zone that contains it, closes
--    it at 30 m and not at 5 m -- the same reading, the same second, one changed number. `marked_at` is the reading's
--    own time, and `marked_by` is null (the tick said it, nobody did).
--
-- D. A READING FROM BEFORE THE SESSION IS NOT EVIDENCE. The same IC at distance 0, thirty seconds before T+0, closes
--    nothing: `locations` has no session id, so the tick bounds its window by the session's own start. Without that
--    bound this assertion would already be an arrival, which is exactly what makes it worth having.
--
-- E. A ROUTE POINT NEVER CLOSES ITSELF, however close the phone is. The point is proved to stand in NO zone first, so
--    the refusal is the gate's and not a coincidence of geometry.
--
-- F. THE RADIUS IS THE IC'S OWN, NOT THE GROUP'S. Two ICs of one group, one at 30 m and one at 100 m: the same 60 m
--    reading is refused for the first and closes the moment for the second. The first IC's number is re-read in the
--    same breath, so "his 30 m would have refused" is not an assumption.
--
-- G. A READING TOO OLD, OR TOO BAD, IS NOT EVIDENCE -- and one that is merely imprecise counts for its error. Five
--    minutes old: refused. Accuracy 200 m: refused (worse than the 100 m line 021 draws). Accuracy 20 m at 40 m with a
--    30 m radius: closes, because 021's rule widens the test by min(accuracy, 15) -- without that buffer 40 > 30 and
--    the moment would be left late.
--
-- H. THE ZONE BRANCH OF 057 IS STILL THERE, and `marked_at` is the earlier of plan and evidence: an IC who entered the
--    zone a minute BEFORE the moment closes it, dated to the plan, not to their early arrival.
--
-- I. `verify = 'manual'` IS NOT A SUGGESTION. An IC standing exactly on the point closes nothing: somebody has to tap.
--
-- J. ONLY AN IC. The same person at the same distance, no longer an IC, closes nothing.
--
-- K. A NO-GO AREA IS NOT A PLACE TO HAVE ARRIVED AT. The point stands in exactly one zone and that zone is a cordon, so
--    the moment waits for a tap -- the same kinds 062 names a place, so the read and the tick agree.
--
-- The bench is left exactly as the fixture wrote it (the transaction is rolled back).

begin;

-- ---------- a bench of its own ----------
delete from public.plans where id = '0b000000-0000-4000-8000-000000000b27';
delete from public.zones where id in (
  '0b000000-0000-4000-8000-00000000c270', '0b000000-0000-4000-8000-00000000c271',
  '0b000000-0000-4000-8000-00000000c272');
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;
delete from public.push_queue where event_id = '0b000000-0000-4000-8000-000000000e01';
-- No stray reading from an earlier run may be evidence for this one.
delete from public.locations where event_id = '0b000000-0000-4000-8000-000000000e01';

-- T+0 is seventy-five minutes ago, so every moment of the plan has passed and each is judged at a chosen second.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 'Radius bench',
       (now() at time zone 'Asia/Singapore' - interval '75 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '75 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

-- Eight frames, ten minutes apart, Gate Crew walking due east 20 m a step (20.59 m: 0.0001850 degrees of longitude at
-- this latitude). Ten minutes for 20 m is slow, never fast, and no pair of adjacent frames is more than 25 m apart, so
-- the strip is legal and the only thing any assertion below can be about is the tick.
insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2751', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01',    0, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2752', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01',  600, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2753', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 1200, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2754', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 1800, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2755', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 2400, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2756', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 3000, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2757', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 3600, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2758', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', 4200, null, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, verify) values
  ('0b000000-0000-4000-8000-0000000f2751', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7738000, 'auto'),
  ('0b000000-0000-4000-8000-0000000f2752', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7739850, 'auto'),
  ('0b000000-0000-4000-8000-0000000f2753', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7741700, 'auto'),
  ('0b000000-0000-4000-8000-0000000f2754', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7743550, 'auto'),
  ('0b000000-0000-4000-8000-0000000f2755', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7745400, 'auto'),
  -- H: the manual moment.
  ('0b000000-0000-4000-8000-0000000f2756', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7747250, 'manual'),
  ('0b000000-0000-4000-8000-0000000f2757', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7749100, 'auto'),
  ('0b000000-0000-4000-8000-0000000f2758', '0b000000-0000-4000-8000-000000000b27', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3312000, 103.7750950, 'auto');

-- ---------- two zones, and the gap between them ----------
-- Gate: 22 m square around the first moment, so an IC 25 m east of the point is OUTSIDE it (assertion C needs that).
-- Crossing: a lane 100 m long covering the third to the seventh moments, all of them somewhere to stand.
-- Between them (the second moment, 103.7739850) there is deliberately no zone at all: a route point.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c270', '0b000000-0000-4000-8000-000000000e01', 'GATE', 'Gate', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77370 1.33110, 103.77390 1.33110, 103.77390 1.33130, 103.77370 1.33130, 103.77370 1.33110))'), false),
  ('0b000000-0000-4000-8000-00000000c271', '0b000000-0000-4000-8000-000000000e01', 'CROSSING', 'Crossing', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77410 1.33110, 103.77500 1.33110, 103.77500 1.33130, 103.77410 1.33130, 103.77410 1.33110))'), false);

-- ---------- open the session through the product's door ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b27',
                              (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b27'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b27');
  perform set_config('check.session', v_s::text, true);
end $$;

reset role;

-- ============================================================
-- A. The number, and the band around it
-- ============================================================
do $$
declare
  v_n integer;
  v_min integer;
  v_max integer;
begin
  select count(*), min(ic_tolerance_m), max(ic_tolerance_m) into v_n, v_min, v_max
    from public.group_members
   where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 3 then
    raise exception 'FAIL A1: the bench has % membership rows, expected 3', v_n;
  end if;
  if v_min <> 30 or v_max <> 30 then
    raise exception 'FAIL A2: the default radius is %..% m, expected 30 for every row', v_min, v_max;
  end if;

  begin
    update public.group_members set ic_tolerance_m = 4
     where event_id = '0b000000-0000-4000-8000-000000000e01';
    raise exception 'FAIL A3: a 4 m radius was stored, expected the CHECK to refuse it';
  exception when check_violation then
    null;
  end;

  begin
    update public.group_members set ic_tolerance_m = 101
     where event_id = '0b000000-0000-4000-8000-000000000e01';
    raise exception 'FAIL A4: a 101 m radius was stored, expected the CHECK to refuse it';
  exception when check_violation then
    null;
  end;
end $$;

-- ============================================================
-- B. The door
-- ============================================================
-- The IC sets their own.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';
do $$
declare
  v_m integer;
begin
  v_m := public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 45);
  if v_m <> 45 then
    raise exception 'FAIL B1: setting my own radius answered %, expected 45', v_m;
  end if;
end $$;
reset role;

do $$
begin
  if (select ic_tolerance_m from public.group_members
       where event_id = '0b000000-0000-4000-8000-000000000e01'
         and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2') <> 45 then
    raise exception 'FAIL B2: the row does not say 45 after the call answered 45';
  end if;
end $$;

-- The IC cannot leave the band, even through the function.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';
do $$
begin
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 4);
    raise exception 'FAIL B3: a 4 m radius was accepted';
  exception when sqlstate '22023' then
    null;
  end;
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 101);
    raise exception 'FAIL B4: a 101 m radius was accepted';
  exception when sqlstate '22023' then
    null;
  end;
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', null);
    raise exception 'FAIL B5: a null radius was accepted';
  exception when sqlstate '22023' then
    null;
  end;
end $$;
reset role;

-- Sound's admin: she is an admin, but of a group with no IC in it -- and she is not one herself.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';
do $$
begin
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40);
    raise exception 'FAIL B6: a person who is not an IC set their own radius';
  exception when sqlstate '42501' then
    null;
  end;
  -- ... and she cannot reach Gate Crew's IC either: not her group, and she is not the event's ops.
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40,
                                         'ba04a00c-518f-4252-91d5-1081cecec1d2');
    raise exception 'FAIL B7: an admin of another group set an IC''s radius';
  exception when sqlstate '42501' then
    null;
  end;
end $$;
reset role;

-- Gate Crew's other IC: not an admin, not ops, and not the person.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
do $$
begin
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40,
                                         'ba04a00c-518f-4252-91d5-1081cecec1d2');
    raise exception 'FAIL B8: one IC set another IC''s radius';
  exception when sqlstate '42501' then
    null;
  end;
end $$;
reset role;

-- Make him Gate Crew's admin, and the same call now goes through: the admin door is a fact about the caller.
update public.group_members set is_admin = true
 where event_id = '0b000000-0000-4000-8000-000000000e01'
   and user_id = '00cd023b-0e26-4574-a635-760e782c8029';

set local role authenticated;
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
do $$
declare
  v_m integer;
begin
  v_m := public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40,
                                      'ba04a00c-518f-4252-91d5-1081cecec1d2');
  if v_m <> 40 then
    raise exception 'FAIL B9: a group admin setting an IC''s radius answered %, expected 40', v_m;
  end if;
end $$;

reset role;

-- An outsider -- a signed-in account with no membership in this event at all -- cannot reach an IC's radius.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000dead","role":"authenticated"}';
do $$
begin
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40,
                                         'ba04a00c-518f-4252-91d5-1081cecec1d2');
    raise exception 'FAIL B10: an outsider set an IC''s radius';
  exception when sqlstate '42501' then
    null;
  end;
end $$;
reset role;

-- The plan's own tick is not a client's to call (R4): only `plan_push_tick` runs it, as its definer.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
do $$
begin
  begin
    perform public.plan_auto_close(current_setting('check.session')::uuid);
    raise exception 'FAIL B11: a client called the tick';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- The planner sets the two numbers this check then stands on.
do $$
declare
  v_a integer;
  v_b integer;
begin
  v_a := public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 30,
                                      'ba04a00c-518f-4252-91d5-1081cecec1d2');
  v_b := public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 100,
                                      '00cd023b-0e26-4574-a635-760e782c8029');
  if v_a <> 30 or v_b <> 100 then
    raise exception 'FAIL B12: the planner set %, expected 30 and 100', v_a || ' / ' || v_b;
  end if;
end $$;
reset role;

-- The anon key cannot execute the function at all.
set local role anon;
do $$
begin
  begin
    perform public.set_arrival_tolerance('0b000000-0000-4000-8000-000000000e01', 40);
    raise exception 'FAIL B13: anon executed set_arrival_tolerance';
  exception when sqlstate '42501' then
    null;
  end;
end $$;
reset role;

-- ============================================================
-- C..K. The tick, one moment at a time
-- ============================================================
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_n integer;
  v_at timestamptz;
  v_marked timestamptz;
  v_by uuid;
  v_frame uuid;
  v_nz integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  -- ------------------------------------------------ C and D. the radius closes it; a reading before T+0 does not
  -- D first: the IC stands exactly on the first moment, ten seconds before the session's own T+0 -- inside the two
  -- minutes the tick looks back over, and before the clock the group was told.
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7738000, 5, 'gps', v_t0 - interval '10 seconds');

  v_n := public.plan_auto_close(v_s, v_t0 + interval '90 seconds');
  if v_n <> 0 then
    raise exception 'FAIL D1: a reading from before T+0 closed % moment(s), expected none', v_n;
  end if;
  if exists (select 1 from public.plan_progress where session_id = v_s) then
    raise exception 'FAIL D2: a progress row was written for a reading from before T+0';
  end if;

  -- C: at 5 m the same 25 m reading is too far. (The planner set this IC to 30 m in B; the door is proved there, so the
  -- block below moves the number as the owner and does not pretend to be a caller.)
  update public.group_members set ic_tolerance_m = 5
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2';
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7740246, 5, 'gps', v_t0 + interval '90 seconds');

  v_n := public.plan_auto_close(v_s, v_t0 + interval '90 seconds');
  if v_n <> 0 then
    raise exception 'FAIL C1: a 25 m reading closed % moment(s) through a 5 m radius (5 + 5 m accuracy), expected none', v_n;
  end if;

  -- 30 m: the same reading, the same second, one changed number.
  update public.group_members set ic_tolerance_m = 30
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2';
  v_n := public.plan_auto_close(v_s, v_t0 + interval '90 seconds');
  if v_n <> 1 then
    raise exception 'FAIL C2: a 25 m reading closed % moment(s) through a 30 m radius, expected 1', v_n;
  end if;

  select marked_at, marked_by, frame_id into v_marked, v_by, v_frame
    from public.plan_progress where session_id = v_s and group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_frame is distinct from '0b000000-0000-4000-8000-0000000f2751' then
    raise exception 'FAIL C3: the wrong moment was closed (%)', v_frame;
  end if;
  if v_marked is distinct from v_t0 + interval '90 seconds' then
    raise exception 'FAIL C4: the arrival is dated %, expected the reading''s own instant %',
      v_marked, v_t0 + interval '90 seconds';
  end if;
  if v_by is not null then
    raise exception 'FAIL C5: the tick named % as the marker, expected nobody', v_by;
  end if;

  -- ------------------------------------------------ E. a route point never closes itself
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7739850, 5, 'gps', v_t0 + interval '630 seconds');

  select count(*) into v_nz
    from public.zones z
   where z.event_id = '0b000000-0000-4000-8000-000000000e01'
     and extensions.st_dwithin(z.shape,
           extensions.st_setsrid(extensions.st_makepoint(103.7739850, 1.3312000), 4326)::extensions.geography, 0);
  if v_nz <> 0 then
    raise exception 'FAIL E1: the second moment stands in % zone(s), expected none -- the check would be vacuous', v_nz;
  end if;

  v_n := public.plan_auto_close(v_s, v_t0 + interval '630 seconds');
  if v_n <> 0 then
    raise exception 'FAIL E2: an IC standing exactly on a route point closed % moment(s), expected none', v_n;
  end if;

  -- ------------------------------------------------ F. the radius is the IC's own
  v_at := v_t0 + interval '1320 seconds'; -- the third moment, 120 s after its planned time
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7747091, 10, 'gps', v_at);

  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL F1: a 60 m reading closed % moment(s) through this IC''s 30 m radius, expected none', v_n;
  end if;

  -- ... and the same IC still says 30, so the refusal above is his number and not a stale one.
  if (select ic_tolerance_m from public.group_members
       where event_id = '0b000000-0000-4000-8000-000000000e01'
         and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2') <> 30 then
    raise exception 'FAIL F2: the first IC''s radius moved between the two calls';
  end if;

  -- The other IC, 60 m away too, but his own radius is 100.
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          '00cd023b-0e26-4574-a635-760e782c8029', 1.3312000, 103.7747091, 10, 'gps', v_at);

  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 1 then
    raise exception 'FAIL F3: the same 60 m reading closed % moment(s) through the second IC''s 100 m radius, expected 1', v_n;
  end if;
  if (select marked_at from public.plan_progress
       where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2753') is distinct from v_at then
    raise exception 'FAIL F4: the third moment is dated %, expected the reading at %',
      (select marked_at from public.plan_progress
        where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2753'), v_at;
  end if;

  -- ------------------------------------------------ G. too old, too bad, and merely imprecise
  v_at := v_t0 + interval '2460 seconds'; -- the fifth moment, 60 s late

  -- Five minutes old: not evidence.
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7745400, 10, 'gps', v_at - interval '300 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL G1: a five-minute-old reading closed % moment(s), expected none', v_n;
  end if;

  -- A fix worse than 100 m is not evidence either, even standing on the point.
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7745400, 200, 'gps', v_at - interval '60 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL G2: a 200 m fix closed % moment(s), expected none', v_n;
  end if;

  -- 40 m away with a 20 m accuracy and a 30 m radius: 30 + min(20, 15) = 45, so it counts.
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7748994, 20, 'gps', v_at - interval '30 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 1 then
    raise exception 'FAIL G3: a 40 m reading with a 30 m radius and 20 m accuracy closed % moment(s), expected 1', v_n;
  end if;
  if (select marked_at from public.plan_progress
       where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2755') is distinct from v_at - interval '30 seconds' then
    raise exception 'FAIL G4: the fifth moment is dated %, expected %',
      (select marked_at from public.plan_progress
        where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2755'), v_at - interval '30 seconds';
  end if;

  -- ------------------------------------------------ H. 057's zone branch is still there, and dated from the plan
  -- An IC who entered the zone a minute BEFORE the fourth moment: no phone reading at all (the tick's own zone test is
  -- what must close it), and the arrival is dated to the plan, not to the early entry.
  v_at := v_t0 + interval '1860 seconds';
  insert into public.zone_presence (event_id, session_id, zone_id, user_id, group_id, entered_at, last_inside_at)
  values ('0b000000-0000-4000-8000-000000000e01', v_s, '0b000000-0000-4000-8000-00000000c271',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', '0b000000-0000-4000-8000-00000000a001',
          v_t0 + interval '1740 seconds', v_t0 + interval '1740 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 1 then
    raise exception 'FAIL H1: an IC standing inside the moment''s zone closed % moment(s), expected 1', v_n;
  end if;
  if (select marked_at from public.plan_progress
       where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2754') is distinct from v_t0 + interval '1800 seconds' then
    raise exception 'FAIL H2: the fourth moment is dated %, expected the plan''s own time %',
      (select marked_at from public.plan_progress
        where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2754'), v_t0 + interval '1800 seconds';
  end if;

  -- ------------------------------------------------ I. a manual moment waits for a tap
  v_at := v_t0 + interval '3060 seconds';
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7747250, 5, 'gps', v_at - interval '30 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL I1: a manual moment closed itself (% moment(s)), expected none', v_n;
  end if;

  -- ------------------------------------------------ J. only an IC of this group
  -- The same person, the same distance, no longer an IC.
  update public.group_members set is_ic = false
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2';
  v_at := v_t0 + interval '3660 seconds';
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312000, 103.7749100, 5, 'gps', v_at - interval '30 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL J1: a member who is not an IC closed % moment(s), expected none', v_n;
  end if;
  update public.group_members set is_ic = true
   where event_id = '0b000000-0000-4000-8000-000000000e01'
     and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2';

  -- ------------------------------------------------ K. a cordon is not a place to have arrived at
  -- The no-go area is added AFTER the publish, because a walk that ends inside a cordon is a crossing the publish
  -- gate refuses -- and this assertion is about the tick, not about the gate.
  insert into public.zones (id, event_id, code, name, kind, shape, is_circle)
  values ('0b000000-0000-4000-8000-00000000c272', '0b000000-0000-4000-8000-000000000e01', 'CORDON', 'Cordon (no-go)', 'no_go',
          extensions.st_geogfromtext('SRID=4326;POLYGON((103.77500 1.33110, 103.77520 1.33110, 103.77520 1.33130, 103.77500 1.33130, 103.77500 1.33110))'), false);

  select count(*) into v_nz
    from public.zones z
   where z.event_id = '0b000000-0000-4000-8000-000000000e01'
     and extensions.st_dwithin(z.shape,
           extensions.st_setsrid(extensions.st_makepoint(103.7750950, 1.3312000), 4326)::extensions.geography, 0);
  if v_nz <> 1 then
    raise exception 'FAIL K1: the eighth moment stands in % zone(s), expected exactly the cordon', v_nz;
  end if;

  v_at := v_t0 + interval '4260 seconds';
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001',
          '00cd023b-0e26-4574-a635-760e782c8029', 1.3312000, 103.7750950, 5, 'gps', v_at - interval '30 seconds');
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n <> 0 then
    raise exception 'FAIL K2: an IC standing in a no-go area closed % moment(s), expected none', v_n;
  end if;

  -- ------------------------------------------------ and the ledger of what did close
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n <> 4 then
    raise exception 'FAIL L1: % moments closed in all, expected 4 (the first, third and fifth by a phone, the fourth by the zone)', v_n;
  end if;
end $$;

rollback;
