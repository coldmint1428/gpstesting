-- Step 21, checked at the database: an auto-verified moment that closes itself, the pushes and ETAs computed from the
-- strip, and the hand-back log.
--
--     node tools/sql.mjs --file dev/checks/step21-push-handover.sql
--
-- (No fixture first: this check builds its own event, groups, plan, zones and session inside its transaction and rolls
-- the lot back. The bench event cannot carry it -- only three of its five people may be in a group, and this needs four
-- groups with four different behaviours.)
--
-- What the step asks for, and what is proved here:
--
--   1. AUTO IS REAL. 046's `verify = 'auto'` was a flag nothing read. A moment whose drawn point is inside an event
--      zone closes itself when one of its group's ICs is inside that same zone -- one plan_progress row, state
--      'arrived', marked_by null (the tick, not a person), marked_at the LATER of the planned time and the IC's entry.
--      Proved: an IC inside closes it; a presence by somebody who is not an IC of that group does not; a manual
--      position does not; an off-site moment does not; a point outside every zone does not, even with the IC standing in
--      a zone the group was at a moment ago; a second call closes nothing twice; and the late case is dated from the
--      entry (t0+80) and not from the moment (t0+60).
--   2. THE TICK KEEPS THE OLD JOB'S OTHER DUTIES. plan_push_tick() closes, queues the "now" nudge, still collects No-Go
--      pushes, and asks the sender to send. The nudge goes to the group's IC and admin, once per moment and person.
--   3. THE ETA IS ARITHMETIC, NOT A ROUTE. plan_eta_tick() turns the group's own speed and straight-line metres into
--      "leave now" and "running behind", once per moment and person; a group already at its next moment is not told to
--      leave; a group with no fix is not told anything.
--   4. THE HAND-BACK IS A CHAIN. Who had the board is read off the previous row (the caller cannot say it), the
--      session's plan revision is copied on, a plain member cannot take it, an ended show has no board, a member reads
--      it, anon cannot, and authenticated cannot write the table directly.
--   5. THE BOARD SEES THE MARKS. plan_ops gained marked_state / marked_at / marked_by, and an automatic close and a
--      hand tap are distinguishable there -- which is what the screen needs to render them differently.
--   6. THE JOBS SWAPPED. cron.job lists gps-plan-push and gps-plan-eta and neither gps-push-send nor gps-route-eta, and
--      none of the internal functions is executable by authenticated.
--
-- The clock: the plan's printed T+0 is 90 seconds ago, so "now" is T+1:30 -- Gate Crew's +1:00 moment is current and
-- its +2:00 moment is ahead. Every read below passes p_at explicitly (a check that compares a clock to a frame has to
-- say which clock it means), and "now" inside this transaction is frozen, which is why the plan's clock is a variable
-- and not `now()` at each assertion.
--
-- Everything runs in one transaction and is rolled back.

begin;

-- ---------- 1. the event, its groups, its plan, its zones ----------
insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e21', 'Push bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 21 (auto close, pushes, hand-back). Built and rolled back by dev/checks/step21-push-handover.sql.',
        'Bukit Timah', now() - interval '5 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a211', '0b000000-0000-4000-8000-000000000e21', 'Gate Crew', 'GATE',  '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a212', '0b000000-0000-4000-8000-000000000e21', 'Sound',     'SOUND', '#8a5a2b'),
  ('0b000000-0000-4000-8000-00000000a213', '0b000000-0000-4000-8000-000000000e21', 'Backstage', 'BACK',  '#3b5a8a'),
  ('0b000000-0000-4000-8000-00000000a214', '0b000000-0000-4000-8000-000000000e21', 'Security',  'SEC',   '#7a3742');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e21', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e21', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e21', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  ('0b000000-0000-4000-8000-000000000e21', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e21', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e21', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

-- Two ICs, in two groups. testuser3 is deliberately in no group until section 2: "an IC of that group" has to be a fact
-- about membership, and the check proves the difference rather than assuming it.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212', '00cd023b-0e26-4574-a635-760e782c8029', true, true);

-- Three boxes exactly 24 m deep around the +1:00 statement of each of the three groups that stand on the map. Gate
-- Crew's +0:00 and +2:00 statements are OUTSIDE its box (that is the point of section 2), and Backstage's is off site.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c211', '0b000000-0000-4000-8000-000000000e21', 'GATE_Z', 'Gate box', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77382 1.33010, 103.77418 1.33010, 103.77418 1.33034, 103.77382 1.33034, 103.77382 1.33010))'), false),
  ('0b000000-0000-4000-8000-00000000c212', '0b000000-0000-4000-8000-000000000e21', 'SOUND_Z', 'Sound box', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77282 1.33410, 103.77318 1.33410, 103.77318 1.33434, 103.77282 1.33434, 103.77282 1.33410))'), false),
  ('0b000000-0000-4000-8000-00000000c213', '0b000000-0000-4000-8000-000000000e21', 'SEC_Z', 'Security box', 'zone',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77485 1.33510, 103.77515 1.33510, 103.77515 1.33540, 103.77485 1.33540, 103.77485 1.33510))'), false);

-- Four moments. Gate Crew and Sound have a walk: +1:00 inside their box, +2:00 back outside it (24 m north). Backstage
-- is off site from +1:00, and Security's single moment is inside its box -- one statement, so its "current moment" from
-- +1:00 onwards is the only one it has.
-- ---------- the plan, as a draft the owner writes and the product publishes ----------
-- The printed T+0 is 90 seconds ago: every moment below is an offset from it, and the plan is published by the root
-- through plan_publish so the session's t0_at is the plan's own clock (039), not the button's.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', 'Push walk',
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::time,
       'draft', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select f.id, '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', f.t_s, f.note,
       'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from (values
    ('0b000000-0000-4000-8000-0000000f2111'::uuid,    0, 'call'),
    ('0b000000-0000-4000-8000-0000000f2112'::uuid,   60, 'stage'),
    ('0b000000-0000-4000-8000-0000000f2113'::uuid,  120, 'out'),
    ('0b000000-0000-4000-8000-0000000f2114'::uuid,  180, 'end')
  ) f(id, t_s, note);

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state) values
  -- Gate Crew: +0:00 outside its box, +1:00 inside, +2:00 back outside (24 m north each step).
  ('0b000000-0000-4000-8000-0000000f2111', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211', 1.3300000, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2112', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211', 1.3302171, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2113', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211', 1.3304342, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2114', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211', 1.3304342, 103.77400, 'on_site'),
  -- Sound: the same shape, in its own box, and left MANUAL until the end of the section.
  ('0b000000-0000-4000-8000-0000000f2111', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212', 1.3340000, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2112', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212', 1.3342171, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2113', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212', 1.3344342, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2114', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212', 1.3344342, 103.77300, 'on_site'),
  -- Backstage: off site from +1:00, standing inside the Security box's coordinates while it is.
  ('0b000000-0000-4000-8000-0000000f2111', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a213', 1.3350000, 103.77500, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2112', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a213', 1.3352171, 103.77500, 'off_site'),
  -- Security: one moment, inside its box.
  ('0b000000-0000-4000-8000-0000000f2111', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214', 1.3350000, 103.77500, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2112', '0b000000-0000-4000-8000-000000000b21', '0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214', 1.3352171, 103.77500, 'on_site');

update public.plan_positions set verify = 'manual'
 where group_id = '0b000000-0000-4000-8000-00000000a212';

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b21',
                              (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b21'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-000000000b21');
  perform set_config('check.session', v_s::text, true);
end $$;

reset role;

-- The presence trigger looks for the session whose starts_at covers a reading's time (021). start_event set starts_at
-- to now, and the readings below are minutes old, so the fixture moves it back -- t0_at is untouched.
update public.event_sessions set starts_at = now() - interval '5 minutes'
 where id = current_setting('check.session')::uuid;

-- ---------- the readings: who is inside which box, and when ----------
-- Gate Crew's IC is inside the Gate box from t0+20 (so the +1:00 moment closes with the group already there: an ON-TIME
-- close dated from the plan, not from the tick). Sound's IC is inside its box only from t0+80 (so if its moment ever
-- closes it is dated from the entry: the late case). Security's IC walks in from the west at 1.37 m/s: t0-30 outside
-- the box, t0+30 still outside (that is the position the ETA is computed from), t0+80 inside it.
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3302171, 103.77400, 5, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '20 seconds'),
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3302171, 103.77400, 5, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '30 seconds'),
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a211',
   'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3302171, 103.77400, 5, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '50 seconds'),
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a212',
   '00cd023b-0e26-4574-a635-760e782c8029', 1.3342171, 103.77300, 7, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '80 seconds');

-- Security's IC: one reading, INSIDE the Security box at t0+80 -- so if its moment ever closes it is dated from that
-- entry (20 s after the plan), which is the late case and the only way to prove the `greatest()` in the close.
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214',
   '2906655b-33ad-4e9d-a608-f083e43e22d4', 1.3352171, 103.77500, 8, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '80 seconds');

-- A second phone walking with Security, tagged with Security's group: 82 m in 60 s = the 1.37 m/s the forecast divides
-- by. He is nobody's member (a planner, who may never be in a group -- 036), which is fine: group_position_at is about
-- the readings a group carries, and membership is the auto-close's own rule. Inserted after the IC's reading so the
-- last write of group_positions carries the measured speed -- the IC's single reading has no speed of its own.
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214',
   'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 1.3352171, 103.77150, 8, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) - interval '30 seconds'),
  ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214',
   'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 1.3352171, 103.77224, 8, 'gps',
   (select t0_at from public.event_sessions where id = current_setting('check.session')::uuid) + interval '30 seconds');

-- The speed the ETA section divides by, asserted here so a failed speed is not read as a failed forecast.
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_speed real;
begin
  select speed_mps into v_speed from public.group_positions
   where session_id = v_s and group_id = '0b000000-0000-4000-8000-00000000a214';
  if v_speed is null or v_speed < 1.2 or v_speed > 1.6 then
    raise exception 'FAIL 0a: Security''s measured speed is %, expected about 1.37 m/s', v_speed;
  end if;
end $$;

-- ============================================================
-- 1. what closes, and what does not
-- ============================================================
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_n integer;
  v_r record;
  v_id uuid;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  -- Gate Crew is the only one that may close: auto, on site, inside a zone, and an IC of that group is inside it.
  -- Sound is manual, Backstage is off site, and Security's IC is not yet an IC of Security.
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n is distinct from 1 then
    raise exception 'FAIL 1a: % moments closed, expected exactly 1 (Gate Crew)', v_n;
  end if;

  select * into v_r from public.plan_progress
   where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2112'
     and group_id = '0b000000-0000-4000-8000-00000000a211';
  if not found then
    raise exception 'FAIL 1b: Gate Crew''s +1:00 moment was not recorded';
  end if;
  if v_r.state is distinct from 'arrived' then
    raise exception 'FAIL 1c: the moment is %, expected arrived', v_r.state;
  end if;
  if v_r.marked_by is not null then
    raise exception 'FAIL 1d: the automatic close names % as the person, expected nobody', v_r.marked_by;
  end if;
  -- The group was inside before the moment, so the arrival is the moment: an ON-TIME close, not "when the tick looked".
  if v_r.marked_at is distinct from v_t0 + interval '60 seconds' then
    raise exception 'FAIL 1e: the close is dated %, expected the planned time % (the IC was already inside)',
      v_r.marked_at, v_t0 + interval '60 seconds';
  end if;

  -- Nothing else was recorded, and in particular not an earlier or a later moment of Gate Crew's own walk.
  select count(*) into v_n from public.plan_progress where session_id = v_s;
  if v_n is distinct from 1 then
    raise exception 'FAIL 1f: % progress rows, expected 1 (the tick closes the current moment only)', v_n;
  end if;

  -- A second look in the same moment closes nothing twice (one row per group per moment, and the read sees it).
  if public.plan_auto_close(v_s, v_at) is distinct from 0 then
    raise exception 'FAIL 1g: a second call closed something again';
  end if;

  -- Sound: a person has to confirm it (046), and nobody has. The IC is inside the box, so the flag is the only reason.
  if exists (select 1 from public.plan_progress where session_id = v_s
              and group_id = '0b000000-0000-4000-8000-00000000a212') then
    raise exception 'FAIL 1h: the manual moment closed itself';
  end if;

  -- Backstage is off site: there is no place to arrive at, whatever the phones say.
  if exists (select 1 from public.plan_progress where session_id = v_s
              and group_id = '0b000000-0000-4000-8000-00000000a213') then
    raise exception 'FAIL 1i: the off-site moment closed itself';
  end if;

  -- Security: its IC is standing inside the box, but he is not a member of Security, and membership is the rule.
  if exists (select 1 from public.plan_progress where session_id = v_s
              and group_id = '0b000000-0000-4000-8000-00000000a214') then
    raise exception 'FAIL 1j: a presence by somebody who is not an IC of the group closed it';
  end if;

  -- Make him Security's IC: the same presence, the same moment, now closes -- and it is dated from his ENTRY (t0+80,
  -- 20 s after the moment), not from the plan.
  insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin)
  values ('0b000000-0000-4000-8000-000000000e21', '0b000000-0000-4000-8000-00000000a214',
          '2906655b-33ad-4e9d-a608-f083e43e22d4', true, false);
  v_n := public.plan_auto_close(v_s, v_at);
  if v_n is distinct from 1 then
    raise exception 'FAIL 1k: % moments closed after making the man an IC, expected 1 (Security)', v_n;
  end if;
  select * into v_r from public.plan_progress
   where session_id = v_s and group_id = '0b000000-0000-4000-8000-00000000a214'
     and frame_id = '0b000000-0000-4000-8000-0000000f2112';
  if not found then
    raise exception 'FAIL 1l: Security''s moment was not recorded once its IC was a member';
  end if;
  if v_r.marked_at is distinct from v_t0 + interval '80 seconds' then
    raise exception 'FAIL 1m: the late close is dated %, expected the entry % and not the moment %',
      v_r.marked_at, v_t0 + interval '80 seconds', v_t0 + interval '60 seconds';
  end if;
end $$;

-- ============================================================
-- 2. the clock moves: a moment whose point is outside every zone never closes by itself
-- ============================================================
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '190 seconds';

  -- Everyone's current moment is now +2:00 (or, for the single-moment groups, still +1:00). Gate Crew's +2:00 point is
  -- 24 m outside its box while its IC has not moved: "inside its zone" is about the DRAWN POINT, not about the phones.
  if public.plan_auto_close(v_s, v_at) is distinct from 0 then
    raise exception 'FAIL 2a: a moment outside every zone closed itself';
  end if;

  if exists (select 1 from public.plan_progress where session_id = v_s
              and group_id = '0b000000-0000-4000-8000-00000000a211'
              and frame_id = '0b000000-0000-4000-8000-0000000f2113') then
    raise exception 'FAIL 2b: Gate Crew''s +2:00 point is outside its box and it closed anyway';
  end if;
end $$;

-- ============================================================
-- 3. the pushes and the forecast
-- ============================================================
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_at timestamptz;
  v_n integer;
  v_r record;
  v_metres integer;
  v_due integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_at := v_t0 + interval '90 seconds';

  -- The heartbeat. Closing happens first (nothing new here: Gate Crew and Security are recorded and Sound is manual),
  -- then the nudges: Sound's current moment is unrecorded and 30 s old, so its IC is told once.
  v_n := public.plan_push_tick(v_s, v_at);
  if v_n is distinct from 1 then
    raise exception 'FAIL 3a: the tick queued % pushes, expected 1 (Sound''s "now")', v_n;
  end if;

  select * into v_r from public.push_queue
   where session_id = v_s and kind = 'plan_due' order by id desc limit 1;
  if not found then
    raise exception 'FAIL 3b: no "now" push was queued';
  end if;
  if v_r.user_id is distinct from '00cd023b-0e26-4574-a635-760e782c8029'::uuid then
    raise exception 'FAIL 3c: the "now" push went to %, expected Sound''s IC', v_r.user_id;
  end if;
  if v_r.title is distinct from 'Now: stage' then
    raise exception 'FAIL 3d: the push title is %, expected "Now: stage"', v_r.title;
  end if;
  if v_r.body not like '%Sound is due at +1:00%' or v_r.body not like '%Sound box%' then
    raise exception 'FAIL 3e: the push body is not the sentence expected: %', v_r.body;
  end if;
  if v_r.data ->> 'frameId' is distinct from '0b000000-0000-4000-8000-0000000f2112'
     or v_r.data ->> 'kind' is distinct from 'plan_due' then
    raise exception 'FAIL 3f: the push does not say what a tap opens: %', v_r.data;
  end if;

  -- Once per moment and person: a second tick in the same second queues nothing.
  if public.plan_push_tick(v_s, v_at) is distinct from 0 then
    raise exception 'FAIL 3g: a second tick queued the same nudge again';
  end if;

  -- The old job's No-Go duty is still in this tick: a fresh No-Go entry becomes a push.
  insert into public.zone_alerts (event_id, session_id, zone_id, user_id, group_id, kind, at)
  values ('0b000000-0000-4000-8000-000000000e21', v_s, '0b000000-0000-4000-8000-00000000c213',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', '0b000000-0000-4000-8000-00000000a211', 'no_go_entered', now());
  perform public.plan_push_tick(v_s, v_at);
  if not exists (select 1 from public.push_queue where session_id = v_s and kind = 'nogo') then
    raise exception 'FAIL 3h: the tick no longer collects No-Go pushes';
  end if;

  -- The forecast, half a minute before everyone's +1:00 moment. Security's IC is 300 m west and walking; Gate Crew's is
  -- standing on its +1:00 point; Sound's newest reading is in the future (no fix at this instant).
  v_n := public.plan_eta_tick(v_s, v_t0 + interval '30 seconds');
  if v_n is distinct from 2 then
    raise exception 'FAIL 3i: the forecast queued % pushes, expected 2 (Security: leave + late)', v_n;
  end if;

  if exists (select 1 from public.push_queue
              where session_id = v_s and kind like 'plan_%' and (data ->> 'groupId') is null) then
    raise exception 'FAIL 3j: a plan push does not say which group';
  end if;
  if not exists (select 1 from public.push_queue
                  where session_id = v_s and kind = 'plan_leave'
                    and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4'
                    and title like 'Leave now for%' and body like '% m · about %') then
    raise exception 'FAIL 3k: Security was not told to leave';
  end if;
  if not exists (select 1 from public.push_queue
                  where session_id = v_s and kind = 'plan_late'
                    and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4'
                    and body like '%after the plan%' and title like 'Running behind for%') then
    raise exception 'FAIL 3l: Security was not told it is behind';
  end if;

  -- The metres in the "leave now" push are the distance the database measures, not a number the body invented.
  select round(extensions.st_distance(
           extensions.st_setsrid(extensions.st_makepoint(103.77224, 1.3352171), 4326)::extensions.geography,
           extensions.st_setsrid(extensions.st_makepoint(103.77500, 1.3352171), 4326)::extensions.geography))::int
    into v_metres;
  select id into v_due from public.push_queue
   where session_id = v_s and kind = 'plan_leave' limit 1;
  if not exists (select 1 from public.push_queue
                  where id = v_due and body like v_metres || ' m%') then
    raise exception 'FAIL 3m: the "leave now" push does not carry the % m the database measures: %',
      v_metres, (select body from public.push_queue where id = v_due);
  end if;

  -- A group standing on its next moment is not told to leave, and a group with no fix is not told anything.
  if exists (select 1 from public.push_queue
              where session_id = v_s and kind in ('plan_leave', 'plan_late')
                and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2') then
    raise exception 'FAIL 3n: Gate Crew (standing on its moment, 0 m away) was told to leave';
  end if;
  if exists (select 1 from public.push_queue
              where session_id = v_s and kind in ('plan_leave', 'plan_late')
                and data ->> 'groupId' = '0b000000-0000-4000-8000-00000000a212') then
    raise exception 'FAIL 3o: Sound had no fix at that instant and was still given a forecast';
  end if;
  -- Backstage is off site at its only moment: there is nowhere to arrive, so there is nothing to forecast.
  if exists (select 1 from public.push_queue
              where session_id = v_s and data ->> 'groupId' = '0b000000-0000-4000-8000-00000000a213') then
    raise exception 'FAIL 3p: an off-site group was given a forecast';
  end if;

  -- Once per moment and person, again.
  if public.plan_eta_tick(v_s, v_t0 + interval '30 seconds') is distinct from 0 then
    raise exception 'FAIL 3q: the forecast queued the same pushes twice';
  end if;
end $$;

-- ============================================================
-- 4. the hand-back chain
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.handover_log;
  v_rev integer;
  v_n integer;
begin
  select plan_rev into v_rev from public.event_sessions where id = v_s;

  v_row := public.handover_take(v_s, '  Took the board at the interval  ');
  if v_row.to_user is distinct from 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'::uuid then
    raise exception 'FAIL 4a: the row names % as the taker, expected the caller', v_row.to_user;
  end if;
  if v_row.from_user is not null then
    raise exception 'FAIL 4b: the first hand-back names a previous holder (%)', v_row.from_user;
  end if;
  if v_row.plan_rev is distinct from v_rev or v_rev is not distinct from 0 then
    raise exception 'FAIL 4c: the row records revision % and the session is on %, expected the same non-zero one',
      v_row.plan_rev, v_rev;
  end if;
  if v_row.note is distinct from 'Took the board at the interval' then
    raise exception 'FAIL 4d: the note is not trimmed: %', v_row.note;
  end if;
  if v_row.plan_id is distinct from (select plan_id from public.event_sessions where id = v_s) then
    raise exception 'FAIL 4e: the row does not name the plan the session is running';
  end if;
end $$;

-- The next person takes it: who had it is read off the log, not sent by the caller.
set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.handover_log;
  v_n integer;
  v_name text;
begin
  v_row := public.handover_take(v_s, null);
  if v_row.to_user is distinct from 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5'::uuid then
    raise exception 'FAIL 4f: the second row names % as the taker, expected the caller', v_row.to_user;
  end if;
  if v_row.from_user is distinct from 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'::uuid then
    raise exception 'FAIL 4g: the chain lost the previous holder: %', v_row.from_user;
  end if;
  if v_row.note is not null then
    raise exception 'FAIL 4h: an empty note became %', v_row.note;
  end if;

  -- The list: two rows, newest first, with names. The names come from profiles, so a person with neither a display name
  -- nor a username reads as "someone"; the first hand-back, however, has NO previous holder, and that must read as
  -- null -- a screen that says "handed from someone" on the first row is inventing a person.
  select count(*) into v_n from public.handover_log_list(v_s);
  if v_n is distinct from 2 then
    raise exception 'FAIL 4i: the list has % rows, expected 2', v_n;
  end if;
  if (select to_user from public.handover_log_list(v_s) limit 1) is distinct from 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5'::uuid then
    raise exception 'FAIL 4j: the list is not newest first';
  end if;
  if (select from_name from public.handover_log_list(v_s) limit 1) is distinct from 'testuser1'
     or (select to_name from public.handover_log_list(v_s) limit 1) is distinct from 'testuser2' then
    raise exception 'FAIL 4k: the newest row reads % -> %, expected testuser1 -> testuser2',
      (select from_name from public.handover_log_list(v_s) limit 1),
      (select to_name from public.handover_log_list(v_s) limit 1);
  end if;
  if (select from_name from public.handover_log_list(v_s) order by handed_at limit 1) is not null then
    raise exception 'FAIL 4l: the first hand-back names a previous holder (%)',
      (select from_name from public.handover_log_list(v_s) order by handed_at limit 1);
  end if;
end $$;

-- A plain member is in the event and can read the log, but cannot take the board (it is an ops action).
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.handover_log where session_id = v_s;
  if v_n is distinct from 2 then
    raise exception 'FAIL 4m: a member reads % rows of the log, expected 2', v_n;
  end if;
  begin
    perform public.handover_take(v_s, null);
    raise exception 'FAIL 4n: a plain member took the board';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- An ended show has no board to take. The session is built here rather than borrowed from the bench: this check owns its
-- whole fixture.
reset role;

insert into public.event_sessions (id, event_id, starts_at, ended_at, started_by, end_reason)
values ('0b000000-0000-4000-8000-00000000d211', '0b000000-0000-4000-8000-000000000e21',
        now() - interval '2 hours', now() - interval '1 hour', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'ended');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_ended uuid := '0b000000-0000-4000-8000-00000000d211';
begin
  begin
    perform public.handover_take(v_ended, null);
    raise exception 'FAIL 4o: the board of an ended show was taken';
  exception when sqlstate '42501' then
    raise exception 'FAIL 4o: an ended show answered "not allowed" instead of "no board to take"';
  when sqlstate '22023' then null;
  end;
end $$;

set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- R3: the table is read-only to authenticated -- no insert, whatever the policy says.
do $$
begin
  begin
    insert into public.handover_log (event_id, session_id, to_user)
    values ('0b000000-0000-4000-8000-000000000e21', current_setting('check.session')::uuid,
            'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');
    raise exception 'FAIL 4p: authenticated could write the hand-back log directly';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ============================================================
-- 5. the board sees both kinds of mark
-- ============================================================
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_r record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  -- The automatic close: state set, nobody named.
  select * into v_r from public.plan_ops(v_s, v_t0 + interval '90 seconds')
   where group_id = '0b000000-0000-4000-8000-00000000a211' and t_s = 60;
  if v_r.marked_state is distinct from 'arrived' or v_r.marked_at is null or v_r.marked_by is not null then
    raise exception 'FAIL 5a: the board reads the automatic close as state % / at % / by %',
      v_r.marked_state, v_r.marked_at, v_r.marked_by;
  end if;

  -- Nothing recorded reads as nothing, and the moment the plan has not reached is not marked either.
  select * into v_r from public.plan_ops(v_s, v_t0 + interval '90 seconds')
   where group_id = '0b000000-0000-4000-8000-00000000a211' and t_s = 120;
  if v_r.marked_state is not null or v_r.marked_at is not null then
    raise exception 'FAIL 5b: an unrecorded moment reads as % / %', v_r.marked_state, v_r.marked_at;
  end if;
end $$;

-- A hand tap, through 050's own door, by the group's IC: the board reads a person's name against it.
set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_row public.plan_progress;
  v_r record;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2112',
                                '0b000000-0000-4000-8000-00000000a212', 'arrived', v_t0 + interval '90 seconds');
  if v_row.marked_by is distinct from '00cd023b-0e26-4574-a635-760e782c8029'::uuid then
    raise exception 'FAIL 5c: the hand mark does not name its caller';
  end if;
  select * into v_r from public.plan_ops(v_s, v_t0 + interval '90 seconds')
   where group_id = '0b000000-0000-4000-8000-00000000a212' and t_s = 60;
  if v_r.marked_state is distinct from 'arrived'
     or v_r.marked_by is distinct from '00cd023b-0e26-4574-a635-760e782c8029'::uuid then
    raise exception 'FAIL 5d: the board does not read the hand mark (% / %)', v_r.marked_state, v_r.marked_by;
  end if;
end $$;

-- ============================================================
-- 6. the jobs, and the doors
-- ============================================================
reset role;

do $$
declare
  v_n integer;
begin
  select count(*) into v_n from cron.job where jobname in ('gps-plan-push', 'gps-plan-eta');
  if v_n is distinct from 2 then
    raise exception 'FAIL 6a: cron.job lists % of the two new jobs', v_n;
  end if;
  if exists (select 1 from cron.job where jobname in ('gps-push-send', 'gps-route-eta')) then
    raise exception 'FAIL 6b: a retired job is still scheduled';
  end if;
  select count(*) into v_n from cron.job
   where (jobname = 'gps-plan-push' and command = 'select public.plan_push_tick()')
      or (jobname = 'gps-plan-eta'  and command = 'select public.plan_eta_tick()');
  if v_n is distinct from 2 then
    raise exception 'FAIL 6c: % of the two new jobs run the function expected', v_n;
  end if;
end $$;

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
begin
  -- The four internal functions are the cron's, not a client's.
  begin
    perform public.plan_auto_close(v_s, now());
    raise exception 'FAIL 6d: authenticated could close moments by hand';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.plan_push_tick(v_s, now());
    raise exception 'FAIL 6e: authenticated could run the push tick';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.plan_eta_tick(v_s, now());
    raise exception 'FAIL 6f: authenticated could run the forecast tick';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
set local role anon;

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
begin
  begin
    perform public.plan_ops(v_s, now());
    raise exception 'FAIL 6g: anon could read the ops board';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.handover_take(v_s, null);
    raise exception 'FAIL 6h: anon could take the board';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

rollback;

select 'step 21: an auto-verified moment closes itself when an IC is inside the zone its point stands in (dated from the entry, not from the tick), manual stays manual, the tick keeps No-Go pushes and nudges once per moment, the forecast says leave-now and running-behind from straight-line metres and the group''s own speed, and the hand-back chain reads who had the board off the previous row' as result;
