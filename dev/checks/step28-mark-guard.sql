-- Step 28, checked at the database: a mark belongs to the person who made it.
--
--     node tools/sql.mjs --file dev/checks/step28-mark-guard.sql
--
-- The screen half of this step is the IC's own "We're here" press (dev/checks/step28-here.mjs). This file is the door
-- it presses: `progress_mark` (050, re-created in 064) now refuses to let one person silently replace another's mark,
-- and `plan_progress.marked_auto` says which writer closed a moment so a deleted profile does not turn a hand-made
-- mark into the tick's.
--
-- The check builds its own event, plan and session and rolls the lot back. What has to be true:
--
--   A. `marked_auto` exists, is not null, and defaults to false.
--   B. The group's IC can record their own moment, and the row says it was a person.
--   C. A second IC of the same group is refused, with a sentence naming who marked it and when, and the row is
--      unchanged. This is the assertion the step exists for.
--   D. The person who made it may correct their own (a different state, a different instant).
--   E. The group's admin may record their own group (the admin half of 050's door).
--   F. An IC of another group is still refused by the role check, not by the guard.
--   G. The tick's close can be corrected by a hand: a phone's guess loses to a person who was there.
--   H. A person's mark whose profile is gone (`marked_by` null, `marked_auto` false) is still a person's: another IC
--      is refused and the sentence says "someone". This is the bug `marked_auto` fixes.
--   I. The event's ops may correct anything, and the row then says it was them.
--   J. `plan_ops` answers `marked_auto`, so the board can say "the phone was there" for the tick and "by hand" for a
--      person without reading a missing name.
--   K. The timetable read carries the mark that is in force.
--
-- Two assertions deliberately pin the *order* of the checks: a mark for a moment that is off site is refused before
-- the guard is consulted (step 14's sentence), and the role check runs before the guard (so an outsider gets the
-- role sentence, not the "somebody marked it" sentence).

begin;

-- ---------- the bench ----------
delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.plans          where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.locations      where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.event_sessions where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.zones          where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.group_members  where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.event_roles    where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.groups         where event_id = '0b000000-0000-4000-8000-000000000e28';
delete from public.events         where id       = '0b000000-0000-4000-8000-000000000e28';

insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e28', 'Mark owner bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 28 (who may replace a mark). Rebuilt by dev/checks/step28-mark-guard.sql; safe to delete.',
        'Bukit Timah', now() - interval '3 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour, category) values
  ('0b000000-0000-4000-8000-00000000a281', '0b000000-0000-4000-8000-000000000e28', 'Gate Crew', 'G28', '#244f3f', 'crew'),
  ('0b000000-0000-4000-8000-00000000a282', '0b000000-0000-4000-8000-000000000e28', 'Sound',     'S28', '#8a5a2b', 'crew');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e28', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e28', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e28', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e28', '00cd023b-0e26-4574-a635-760e782c8029', 'participant'),
  ('0b000000-0000-4000-8000-000000000e28', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');

-- Two ICs in one group, and a group admin (not an IC) in the other: the three halves of the door at once.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true,  false),
  ('0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281', '00cd023b-0e26-4574-a635-760e782c8029', true,  false),
  ('0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a282', '2906655b-33ad-4e9d-a608-f083e43e22d4', false, true);

-- A plan whose printed T+0 is 70 seconds ago, so +0:00 and +1:00 are due and +2:00 is not. Two lanes, 24 m a step.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', 'Mark walk',
       (now() at time zone 'Asia/Singapore' - interval '70 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '70 seconds')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f2801', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28',   0, 'call',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2802', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28',  60, 'stage', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f2803', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', 120, 'out',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f2801', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281', 1.3310000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2802', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281', 1.3312171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2803', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281', 1.3314342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f2801', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a282', 1.3350000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2802', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a282', 1.3352171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f2803', '0b000000-0000-4000-8000-000000000b28', '0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a282', 1.3354342, 103.77300);

-- A zone around Gate Crew's +1:00 point: the place gate the tick needs (063). Not a no-go, so nothing crosses.
insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c281', '0b000000-0000-4000-8000-000000000e28', 'STAGE28', 'Stage', 'stage',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.77370 1.33110, 103.77430 1.33110, 103.77430 1.33140, 103.77370 1.33140, 103.77370 1.33110))'),
   false);

-- Publish and open the session through the product's own doors.
-- The marker's display name and the clock format are captured as the owner first: `show_who` is a definer helper
-- with no execute grant (026), so the check may not call it as the IC -- the function under test does, which is the
-- point.
do $$
begin
  perform set_config('check.who4', public.show_who('ba04a00c-518f-4252-91d5-1081cecec1d2'), true);
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b28', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b28'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-000000000b28');
  perform set_config('check.session', v_s::text, true);
end $$;

-- ---------- A. the column ----------
do $$
declare
  v_row record;
begin
  select is_nullable, column_default into v_row
    from information_schema.columns
   where table_schema = 'public' and table_name = 'plan_progress' and column_name = 'marked_auto';
  if not found then
    raise exception 'FAIL A1: plan_progress has no marked_auto column';
  end if;
  if v_row.is_nullable <> 'NO' then
    raise exception 'FAIL A2: marked_auto is nullable';
  end if;
  if v_row.column_default is distinct from 'false' then
    raise exception 'FAIL A3: marked_auto defaults to %, expected false', v_row.column_default;
  end if;
end $$;

-- ---------- B. the IC's own press ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.plan_progress;
  v_u4 uuid := 'ba04a00c-518f-4252-91d5-1081cecec1d2';
begin
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2801',
                               '0b000000-0000-4000-8000-00000000a281', 'arrived');
  if v_row.marked_by is distinct from v_u4 then
    raise exception 'FAIL B1: the IC''s own press names % as the marker, expected the IC', v_row.marked_by;
  end if;
  if v_row.marked_auto then
    raise exception 'FAIL B2: a person''s press was flagged automatic';
  end if;
  perform set_config('check.marked_at', v_row.marked_at::text, true);
end $$;

-- ---------- C. a second IC is refused, and told who marked it ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_at timestamptz := current_setting('check.marked_at')::timestamptz;
  v_row public.plan_progress;
  v_msg text;
begin
  perform set_config('request.jwt.claims', '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}', true);
  begin
    v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2801',
                                 '0b000000-0000-4000-8000-00000000a281', 'missed');
    raise exception 'FAIL C1: a second IC replaced the first IC''s mark';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%recorded that moment already%' then
      raise exception 'FAIL C2: the refusal reads "%"', v_msg;
    end if;
    if v_msg not like '%' || current_setting('check.who4') || '%' then
      raise exception 'FAIL C3: the refusal does not name the marker: "%"', v_msg;
    end if;
    if v_msg not like '%' || to_char(v_at at time zone 'Asia/Singapore', 'HH24:MI:SS') || '%' then
      raise exception 'FAIL C4: the refusal does not say when (%): "%"',
        to_char(v_at at time zone 'Asia/Singapore', 'HH24:MI:SS'), v_msg;
    end if;
  end;

  select * into v_row from public.plan_progress
   where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2801'
     and group_id = '0b000000-0000-4000-8000-00000000a281';
  if v_row.state <> 'arrived' or v_row.marked_by is distinct from 'ba04a00c-518f-4252-91d5-1081cecec1d2' then
    raise exception 'FAIL C5: the refused call changed the row (% / %)', v_row.state, v_row.marked_by;
  end if;
end $$;

-- ---------- D. the maker may correct their own ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_row public.plan_progress;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2801',
                               '0b000000-0000-4000-8000-00000000a281', 'missed', v_t0 + interval '10 seconds');
  if v_row.state <> 'missed' then
    raise exception 'FAIL D1: the maker''s own correction did not take (state %)', v_row.state;
  end if;
  if v_row.marked_at <> v_t0 + interval '10 seconds' then
    raise exception 'FAIL D2: the correction is dated %, expected the instant given', v_row.marked_at;
  end if;
end $$;

-- ---------- E. the group's admin may record its own group ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.plan_progress;
begin
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2801',
                               '0b000000-0000-4000-8000-00000000a282', 'arrived');
  if v_row.marked_by is distinct from '2906655b-33ad-4e9d-a608-f083e43e22d4' then
    raise exception 'FAIL E1: the admin''s mark does not name them';
  end if;
end $$;

-- ---------- F. an IC of another group is refused by the role check ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_msg text;
begin
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  begin
    perform public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2802',
                                 '0b000000-0000-4000-8000-00000000a282', 'arrived');
    raise exception 'FAIL F1: an IC of another group recorded a moment';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%group''s IC or admin%' then
      raise exception 'FAIL F2: the role refusal reads "%"', v_msg;
    end if;
  end;
end $$;

-- ---------- G. the tick closes Gate Crew's +1:00, and the row says it was the phone ----------
-- The tick is internal (057 revoked it from everybody and `plan_push_tick` calls it as its definer), so this section
-- runs as the owner.
reset role;

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_row public.plan_progress;
begin
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('0b000000-0000-4000-8000-000000000e28', '0b000000-0000-4000-8000-00000000a281',
          'ba04a00c-518f-4252-91d5-1081cecec1d2', 1.3312171, 103.77400, 5, 'gps', now());

  v_n := public.plan_auto_close(v_s);
  if v_n <> 1 then
    raise exception 'FAIL G1: the tick closed % moment(s), expected 1 (Gate Crew''s +1:00)', v_n;
  end if;
  select * into v_row from public.plan_progress
   where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2802'
     and group_id = '0b000000-0000-4000-8000-00000000a281';
  if not v_row.marked_auto then
    raise exception 'FAIL G2: the tick''s close is not flagged automatic';
  end if;
  if v_row.marked_by is not null then
    raise exception 'FAIL G3: the tick''s close names a person (%)', v_row.marked_by;
  end if;
end $$;

set local role authenticated;

-- ---------- H. a hand may correct the phone's close ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.plan_progress;
begin
  perform set_config('request.jwt.claims', '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}', true);
  v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2802',
                               '0b000000-0000-4000-8000-00000000a281', 'missed');
  if v_row.marked_auto then
    raise exception 'FAIL H1: the row still reads as the tick''s after a person corrected it';
  end if;
  if v_row.marked_by is distinct from '00cd023b-0e26-4574-a635-760e782c8029' then
    raise exception 'FAIL H2: the correction does not name the person who made it';
  end if;
end $$;

-- ---------- I. a deleted author's mark is still a person's ----------
-- The FK is `on delete set null`, so this is exactly what the database looks like after the maker's account is gone:
-- a null name and marked_auto false. Another IC must still be refused.
reset role;
update public.plan_progress set marked_by = null
 where session_id = current_setting('check.session')::uuid
   and frame_id = '0b000000-0000-4000-8000-0000000f2802'
   and group_id = '0b000000-0000-4000-8000-00000000a281';
set local role authenticated;

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_msg text;
  v_row public.plan_progress;
begin
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  begin
    v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2802',
                                  '0b000000-0000-4000-8000-00000000a281', 'arrived');
    raise exception 'FAIL I1: a mark whose author is gone was treated as the tick''s and replaced';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%someone recorded that moment already%' then
      raise exception 'FAIL I2: the refusal reads "%"', v_msg;
    end if;
  end;

  select * into v_row from public.plan_progress
   where session_id = v_s and frame_id = '0b000000-0000-4000-8000-0000000f2802'
     and group_id = '0b000000-0000-4000-8000-00000000a281';
  if v_row.state <> 'missed' then
    raise exception 'FAIL I3: the refused call changed the row to %', v_row.state;
  end if;
end $$;

-- ---------- J. the event's ops may correct anything ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row public.plan_progress;
begin
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  -- Converted to a labelled failure so a bite that removes the ops bypass reports which promise broke, rather than
  -- aborting on a raw 42501 somewhere below.
  begin
    v_row := public.progress_mark(v_s, '0b000000-0000-4000-8000-0000000f2802',
                                 '0b000000-0000-4000-8000-00000000a281', 'arrived');
  exception when others then
    raise exception 'FAIL J1: the ops correction was refused: %', sqlerrm;
  end;
  if v_row.marked_by is distinct from 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7' then
    raise exception 'FAIL J2: the ops correction does not name the ops person';
  end if;
  if v_row.marked_auto then
    raise exception 'FAIL J3: the ops correction is flagged automatic';
  end if;
end $$;

-- ---------- K. the ops read says which writer closed it ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row record;
begin
  -- After J the row is a person's mark, so "the phone was there" cannot be read off a null name anywhere: the read
  -- itself answers the flag, and the board's words are a mapping of it (PlanOps.markText).
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select * into v_row from public.plan_ops(v_s, now() + interval '1 hour')
   where group_id = '0b000000-0000-4000-8000-00000000a281' and t_s = 60;
  if not found then
    raise exception 'FAIL K1: plan_ops has no row for Gate Crew at +1:00';
  end if;
  if v_row.marked_auto is distinct from false then
    raise exception 'FAIL K2: plan_ops answers marked_auto % for a person''s mark', v_row.marked_auto;
  end if;
  if v_row.marked_state <> 'arrived' or v_row.marked_by is distinct from 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7' then
    raise exception 'FAIL K3: plan_ops answers the mark as % / %', v_row.marked_state, v_row.marked_by;
  end if;
end $$;

-- ---------- L. the timetable carries the mark in force ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_row record;
begin
  perform set_config('request.jwt.claims', '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}', true);
  select * into v_row from public.session_timetable(v_s)
   where frame_id = '0b000000-0000-4000-8000-0000000f2802' and group_id = '0b000000-0000-4000-8000-00000000a281';
  if not found then
    raise exception 'FAIL L1: the timetable has no Gate Crew row at +1:00';
  end if;
  if v_row.state <> 'arrived'
     or v_row.marked_by is distinct from 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7' then
    raise exception 'FAIL L2: the timetable reads % / %, expected the ops correction', v_row.state, v_row.marked_by;
  end if;
  -- And the IC sees only their own group, as 051 decided: the Sound row is not theirs.
  if exists (select 1 from public.session_timetable(v_s) where group_id = '0b000000-0000-4000-8000-00000000a282') then
    raise exception 'FAIL L3: the IC''s timetable shows another group';
  end if;
end $$;

select 'step 28: a mark belongs to the person who made it — a second IC is refused with who and when, the maker may correct their own, the tick''s close may be corrected by a hand, a deleted author''s mark stays a person''s, and the ops read says which writer closed it' as result;

rollback;
