-- Step 18, checked at the database: publishing names the revision it is publishing, a stale one is refused, and every
-- publish leaves a version behind.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step18-publish.sql
--
-- What has to be true, and why each one is here:
--
--   1. A PUBLISH HAS TO SAY WHAT IT IS PUBLISHING. A null revision is refused with a sentence saying so, and writes
--      nothing at all. This is the door the client used to walk through without saying anything: "which revision do
--      you hold" was a question the database never asked, so compare-and-set could not exist yet.
--   2. A STALE REVISION IS REFUSED. Two planners on one plan: the first publishes at revision 1, the second's
--      attempt at revision 1 is refused as stale -- naming both numbers -- and changes nothing: no version, no bump,
--      no archived plan, no session touched.
--   3. THE REVISION THE CALLER HOLDS PUBLISHES. The second planner, now holding 2, publishes: revision 3, and the
--      version says it was them.
--   4. THE VERSION IS THE PLAN. Its frames, times, notes and positions are the ones the plan had when it went out,
--      in a fixed order; the name, date and printed T+0 went with them; published_by/published_at say who and when.
--   5. A VERSION IS A COPY. Editing a frame after the publish does not change the version: the snapshot is what
--      people were shown.
--   6. A REFUSED PUBLISH WRITES NO VERSION. A plan that breaks the 25 m rule is refused by the gate and leaves the
--      revision -- and the version count -- where it was. A plan with no frames still leaves a version (an empty
--      walk somebody published is still a publish), which is why the snapshot is a scalar aggregate.
--   7. THE COPY'S VERSION REMEMBERS THE CUT, AND A REFUSED PUBLISH HANDS NOBODY OVER. Publishing a copy taken
--      mid-walk moves the session onto it (step 17) and records fork_of/fork_cut_s on the version; a stale attempt
--      leaves the session on the original and the copy a draft.
--   8. WHERE A VERSION LIVES. Ops staff read every version of the event; a member and an outsider read none; anon
--      has no table privilege at all; authenticated has SELECT and no write grant; RLS is on with one read policy.
--   9. A PLAN'S DEATH TAKES ITS VERSIONS, and deleting the plan a copy was cut from only nulls the link on the
--      copy's version -- it does not take the copy's history with it.
--  10. THE OLD DOOR IS GONE. plan_publish(uuid) does not exist any more; the two-argument function is executable by
--      authenticated, not by anon, and not by PUBLIC.
--
-- The check builds its own plans inside one transaction, runs a real session through start_event(), and rolls the
-- whole thing back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a clean event clock, and two benches to build on ----------
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.plan_positions where plan_id in ('0b000000-0000-4000-8000-000000000b81',
                                                   '0b000000-0000-4000-8000-000000000b82',
                                                   '0b000000-0000-4000-8000-000000000b83');
delete from public.plan_frames    where plan_id in ('0b000000-0000-4000-8000-000000000b81',
                                                   '0b000000-0000-4000-8000-000000000b82',
                                                   '0b000000-0000-4000-8000-000000000b83');
delete from public.plans          where id in ('0b000000-0000-4000-8000-000000000b81',
                                               '0b000000-0000-4000-8000-000000000b82',
                                               '0b000000-0000-4000-8000-000000000b83');

do $$
begin
  if not exists (select 1 from public.events where id = '0b000000-0000-4000-8000-000000000e01') then
    raise exception 'The bench is not there: run supabase/fixtures/plan_bench.sql first';
  end if;
end $$;

-- The event's third ops role: the read policy names marshals, so the check has to have one. testuser5 is a Gate Crew
-- IC on the bench, and only planners are kept out of groups (036), so a marshal row is legal.
insert into public.event_roles (event_id, user_id, role)
values ('0b000000-0000-4000-8000-000000000e01', '00cd023b-0e26-4574-a635-760e782c8029', 'marshal');

-- ---------- the plan sections 1-6 are about: two moments, every step legal ----------
-- Gate Crew walks 24 m north between +0:00 and +1:00; Sound stands still, and is off site at +1:00 with a manual
-- flag, so the version has flags to carry. Nothing here trips the 25 m rule, so the gate lets every publish through
-- until section 6 breaks it on purpose.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
values ('0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', 'Publish bench',
        current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1801', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01',  0, 'call', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1802', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', 60, 'step', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f1801', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f1802', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f1801', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f1802', '0b000000-0000-4000-8000-000000000b81', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300, 'off_site', 'manual');

-- ---------- the plan section 7 forks: a walk seven minutes along ----------
-- Five moments five minutes apart, Gate Crew 24 m north a frame and Sound standing. The printed T+0 is seven minutes
-- ago, so the fork cuts between +5:00 and +10:00 and the copy is the anchor plus three frames.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', 'Two-planner bench',
       (now() at time zone 'Asia/Singapore' - interval '7 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '7 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1811', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1812', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1813', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01',  600, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1814', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01',  900, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1815', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', 1200, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f1811', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1812', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1813', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1814', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1815', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1811', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1815', '0b000000-0000-4000-8000-000000000b82', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300);

-- ---------- 1. a publish has to say which revision it is publishing ----------
do $$
declare
  v_ok boolean := false;
  v_state text;
  v_msg text;
  v_rev integer;
  v_status text;
  v_n integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', null);
    v_ok := true;
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  if v_ok then
    raise exception 'FAIL 1a: a publish with no revision was accepted';
  end if;
  if v_state <> '22023' then
    raise exception 'FAIL 1b: a publish with no revision raised % (%), expected 22023', v_state, v_msg;
  end if;
  if v_msg !~ 'which revision' then
    raise exception 'FAIL 1c: the refusal for a missing revision says: %', v_msg;
  end if;

  select rev, status into v_rev, v_status from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 1 or v_status <> 'draft' then
    raise exception 'FAIL 1d: the refused publish left the plan at revision % and "%"', v_rev, v_status;
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b81';
  if v_n <> 0 then
    raise exception 'FAIL 1e: a refused publish wrote % version(s)', v_n;
  end if;
end $$;

-- ---------- 2. a stale revision is refused, and changes nothing ----------
do $$
declare
  v_ok boolean;
  v_state text;
  v_msg text;
  v_rev integer;
  v_n integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

  -- The first planner publishes the plan as they read it: revision 1 goes out, and the plan is now 2.
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', 1);
  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 2 then
    raise exception 'FAIL 2a: publishing at revision 1 left the plan at %', v_rev;
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b81';
  if v_n <> 1 then
    raise exception 'FAIL 2b: the first publish wrote % versions, expected 1', v_n;
  end if;

  -- The second planner still holds 1: that picture is out of date, and publishing it would announce it over the
  -- first planner's publish.
  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';
  v_ok := false;
  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', 1);
    v_ok := true;
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  if v_ok then
    raise exception 'FAIL 2c: a publish from a stale revision was accepted';
  end if;
  if v_state <> 'PT409' then
    raise exception 'FAIL 2d: a stale publish raised % (%), expected PT409', v_state, v_msg;
  end if;
  if v_msg !~ 'had version 1 on it' or v_msg !~ 'now version 2' then
    raise exception 'FAIL 2e: the stale refusal does not name both revisions: %', v_msg;
  end if;
  if v_msg !~ 'Nothing was published' then
    raise exception 'FAIL 2f: the stale refusal does not say nothing happened: %', v_msg;
  end if;

  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 2 then
    raise exception 'FAIL 2g: the refused publish bumped the plan to %', v_rev;
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b81';
  if v_n <> 1 then
    raise exception 'FAIL 2h: the refused publish wrote a version (% now, expected 1)', v_n;
  end if;
end $$;

-- ---------- 3. the revision the caller holds publishes ----------
do $$
declare
  v_rev integer;
  v_by uuid;
  v_updated uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

  -- The same second planner, now on 2: this is the publish the strip was telling them to make.
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', 2);
  select rev, updated_by into v_rev, v_updated from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 3 then
    raise exception 'FAIL 3a: the publish at revision 2 left the plan at %', v_rev;
  end if;
  if v_updated <> 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5' then
    raise exception 'FAIL 3b: the plan was last written by %, expected the second planner', v_updated;
  end if;
  select published_by into v_by from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b81' and rev = 3;
  if not found then
    raise exception 'FAIL 3c: the publish at revision 2 wrote no version 3';
  end if;
  if v_by <> 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5' then
    raise exception 'FAIL 3d: version 3 was published by %, expected the second planner', v_by;
  end if;
end $$;

-- ---------- 4. the version is the plan that was published ----------
do $$
declare
  v_row record;
  v_n integer;
  v_num double precision;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

  select * into v_row from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b81' and rev = 3;
  if not found then
    raise exception 'FAIL 4a: there is no version 3 to read';
  end if;

  if v_row.name <> 'Publish bench' then
    raise exception 'FAIL 4b: the version is named "%"', v_row.name;
  end if;
  if v_row.for_date is distinct from current_date then
    raise exception 'FAIL 4c: the version''s date is %, expected %', v_row.for_date, current_date;
  end if;
  if v_row.t0_time::text <> '18:00:00' then
    raise exception 'FAIL 4d: the version''s printed T+0 is %', v_row.t0_time;
  end if;
  if v_row.fork_of is not null or v_row.fork_cut_s is not null then
    raise exception 'FAIL 4e: a plan published as itself has a cut on its version';
  end if;
  if abs(extract(epoch from (now() - v_row.published_at))) > 300 then
    raise exception 'FAIL 4f: the version is dated %', v_row.published_at;
  end if;

  v_n := jsonb_array_length(v_row.frames);
  if v_n <> 2 then
    raise exception 'FAIL 4g: the version holds % frames, expected 2', v_n;
  end if;

  -- t_s order, and the notes: what the strip showed, in the order it showed it.
  if (v_row.frames -> 0 ->> 't_s')::int <> 0 or (v_row.frames -> 1 ->> 't_s')::int <> 60 then
    raise exception 'FAIL 4h: the version''s frames are not in time order: %', v_row.frames;
  end if;
  if v_row.frames -> 0 ->> 'note' <> 'call' or v_row.frames -> 1 ->> 'note' <> 'step' then
    raise exception 'FAIL 4i: the version lost the frames'' notes: %', v_row.frames;
  end if;
  if v_row.frames -> 0 ->> 'id' <> '0b000000-0000-4000-8000-0000000f1801' then
    raise exception 'FAIL 4j: the version names a different first frame: %', v_row.frames -> 0 ->> 'id';
  end if;

  -- Positions: both groups at the call, ordered by group id, with their flags.
  if jsonb_array_length(v_row.frames -> 0 -> 'positions') <> 2 then
    raise exception 'FAIL 4k: the version''s first frame holds % positions, expected 2',
      jsonb_array_length(v_row.frames -> 0 -> 'positions');
  end if;
  if v_row.frames -> 0 -> 'positions' -> 0 ->> 'group_id' <> '0b000000-0000-4000-8000-00000000a001'
     or v_row.frames -> 0 -> 'positions' -> 1 ->> 'group_id' <> '0b000000-0000-4000-8000-00000000a002' then
    raise exception 'FAIL 4l: the version''s positions are not ordered by group: %', v_row.frames -> 0 -> 'positions';
  end if;
  if v_row.frames -> 1 -> 'positions' -> 1 ->> 'state' <> 'off_site'
     or v_row.frames -> 1 -> 'positions' -> 1 ->> 'verify' <> 'manual' then
    raise exception 'FAIL 4m: the version lost the off-site/manual flags: %', v_row.frames -> 1 -> 'positions';
  end if;

  -- The numbers travel as numbers: a lat that came back as a string would print in quotes.
  v_num := (v_row.frames -> 1 -> 'positions' -> 0 ->> 'lat')::double precision;
  if abs(v_num - 1.3302171) > 1e-9 then
    raise exception 'FAIL 4n: the version''s latitude at +1:00 is %, expected 1.3302171', v_num;
  end if;
  if jsonb_typeof(v_row.frames -> 1 -> 'positions' -> 0 -> 'lng') <> 'number' then
    raise exception 'FAIL 4o: a coordinate was stored as %', jsonb_typeof(v_row.frames -> 1 -> 'positions' -> 0 -> 'lng');
  end if;
end $$;

-- ---------- 5. a version is a copy ----------
-- Keep the snapshot, change the plan, and the snapshot must not have moved with it.
reset role;

create temp table v3_before on commit drop as
  select frames from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b81' and rev = 3;

do $$
declare
  v_before jsonb;
  v_after jsonb;
  v_lng double precision;
begin
  reset role;
  -- Sound's call position moves two metres east. Its +1:00 row is off site, so no pair is measured and the plan
  -- stays publishable -- the edit is here to change the plan, not to break it.
  update public.plan_positions
     set lng = lng + 0.00002
   where frame_id = '0b000000-0000-4000-8000-0000000f1801'
     and group_id = '0b000000-0000-4000-8000-00000000a002';

  select frames into v_before from pg_temp.v3_before;
  select frames into v_after from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b81' and rev = 3;
  if v_before is distinct from v_after then
    raise exception 'FAIL 5a: editing a frame changed the published version';
  end if;

  -- The edit really happened: the plan moved, the version did not.
  select lng into v_lng from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f1801'
     and group_id = '0b000000-0000-4000-8000-00000000a002';
  if abs(v_lng - 103.77302) > 1e-9 then
    raise exception 'FAIL 5b: the edit did not land (lng %), so 5a proved nothing', v_lng;
  end if;
end $$;

-- ---------- 6. a refused publish writes no version ----------
-- Put a 200 m step into the plan: the 25 m rule refuses it at the gate, so the revision it was publishing at must not
-- move and no version may be written.
do $$
begin
  reset role;
  update public.plan_positions
     set lat = 1.3320
   where frame_id = '0b000000-0000-4000-8000-0000000f1802'
     and group_id = '0b000000-0000-4000-8000-00000000a001';
end $$;

do $$
declare
  v_ok boolean := false;
  v_state text;
  v_msg text;
  v_rev integer;
  v_n integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', 3);
    v_ok := true;
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  if v_ok then
    raise exception 'FAIL 6a: a plan with a 200 m step was published';
  end if;
  if v_state <> '22023' or v_msg !~ 'cannot be published yet' then
    raise exception 'FAIL 6b: the gate refused with % (%): expected 22023 and "cannot be published yet"', v_state, v_msg;
  end if;

  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 3 then
    raise exception 'FAIL 6c: the refused publish left the plan at revision %', v_rev;
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b81';
  if v_n <> 2 then
    raise exception 'FAIL 6d: a refused publish wrote a version (% now, expected 2)', v_n;
  end if;
end $$;

-- Put the plan back the way section 5 left it, and prove it is publishable again -- the refusal was about the plan,
-- not about the revision the section is holding.
do $$
begin
  reset role;
  update public.plan_positions
     set lat = 1.3302171
   where frame_id = '0b000000-0000-4000-8000-0000000f1802'
     and group_id = '0b000000-0000-4000-8000-00000000a001';
end $$;

do $$
declare
  v_rev integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b81', 3);
  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b81';
  if v_rev <> 4 then
    raise exception 'FAIL 6e: after the fix the plan is at %, expected 4', v_rev;
  end if;
end $$;

-- ---------- 6b. a plan with no frames still leaves a version ----------
do $$
declare
  v_frames jsonb;
  v_rev integer;
begin
  reset role;
  insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
  values ('0b000000-0000-4000-8000-000000000b83', '0b000000-0000-4000-8000-000000000e01', 'Empty bench',
          current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b83', 1);

  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b83';
  if v_rev <> 2 then
    raise exception 'FAIL 6f: the empty plan is at %, expected 2', v_rev;
  end if;
  select frames into v_frames from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b83' and rev = 2;
  if not found then
    raise exception 'FAIL 6g: publishing an empty plan wrote no version';
  end if;
  if jsonb_typeof(v_frames) <> 'array' or jsonb_array_length(v_frames) <> 0 then
    raise exception 'FAIL 6h: the empty plan''s version holds %', v_frames;
  end if;
end $$;

-- ---------- 7. the copy's version remembers the cut, and a refused publish hands nobody over ----------
do $$
declare
  v_ok boolean;
  v_state text;
  v_msg text;
  v_src_rev integer;
  v_copy public.plans;
  v_cut integer;
  v_n integer;
  v_rev integer;
  v_session record;
  v_session_id uuid;
  v_t0 timestamptz;
  v_frames jsonb;
  v_v record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

  -- Publish the plan the copy will be cut from, then start the event on its own clock (seven minutes along).
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b82', 1);
  select rev into v_src_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b82';
  if v_src_rev <> 2 then
    raise exception 'FAIL 7a: the original is at %, expected 2', v_src_rev;
  end if;

  perform public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b82');

  v_copy := public.plan_fork('0b000000-0000-4000-8000-000000000b82');
  perform set_config('check.copy', v_copy.id::text, true);
  if v_copy.fork_cut_s is null then
    raise exception 'FAIL 7b: the copy of a running plan has no cut';
  end if;
  v_cut := v_copy.fork_cut_s;

  select s.id, s.plan_id, s.plan_rev, s.t0_at into v_session
    from public.event_sessions s
   where s.event_id = '0b000000-0000-4000-8000-000000000e01' and s.ended_at is null
   order by s.starts_at desc limit 1;
  if not found then
    raise exception 'FAIL 7c: start_event() left no open session';
  end if;
  v_session_id := v_session.id;
  v_t0 := v_session.t0_at;

  -- The second planner holds revision 1 of the copy -- the only revision it has ever had -- so 1 is not stale. Read
  -- a wrong number instead: the copy is at 1, so 99 is the stale picture, and a refused publish must not hand the
  -- session over.
  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';
  v_ok := false;
  begin
    perform public.plan_publish(v_copy.id, 99);
    v_ok := true;
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  if v_ok then
    raise exception 'FAIL 7d: a publish at a revision that never existed was accepted';
  end if;
  if v_state <> 'PT409' then
    raise exception 'FAIL 7e: a publish at revision 99 raised % (%)', v_state, v_msg;
  end if;

  select s.plan_id, s.plan_rev into v_session from public.event_sessions s where s.id = v_session_id;
  if v_session.plan_id <> '0b000000-0000-4000-8000-000000000b82' then
    raise exception 'FAIL 7f: the refused publish moved the session onto %', v_session.plan_id;
  end if;
  if (select status from public.plans where id = v_copy.id) <> 'draft' then
    raise exception 'FAIL 7g: the refused publish made the copy "%"', (select status from public.plans where id = v_copy.id);
  end if;
  if (select status from public.plans where id = '0b000000-0000-4000-8000-000000000b82') <> 'live' then
    raise exception 'FAIL 7h: the refused publish stood the original down';
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = v_copy.id;
  if v_n <> 0 then
    raise exception 'FAIL 7i: the refused publish wrote % version(s) for the copy', v_n;
  end if;

  -- Now the publish the planner actually meant: revision 1 of the copy.
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
  perform public.plan_publish(v_copy.id, 1);

  select rev into v_rev from public.plans where id = v_copy.id;
  if v_rev <> 2 then
    raise exception 'FAIL 7j: the copy is at %, expected 2', v_rev;
  end if;

  -- The hand-over (step 17) still happens, and the version records where the copy was cut from.
  select s.plan_id, s.plan_rev, s.t0_at into v_session from public.event_sessions s where s.id = v_session_id;
  if v_session.plan_id <> v_copy.id then
    raise exception 'FAIL 7k: the session is on %, expected the copy', v_session.plan_id;
  end if;
  if v_session.t0_at <> v_t0 then
    raise exception 'FAIL 7l: the clock moved with the plan (% -> %)', v_t0, v_session.t0_at;
  end if;
  if v_session.plan_rev <> 2 then
    raise exception 'FAIL 7m: the session follows revision %, expected 2', v_session.plan_rev;
  end if;

  select * into v_v from public.plan_versions where plan_id = v_copy.id and rev = 2;
  if not found then
    raise exception 'FAIL 7n: publishing the copy wrote no version';
  end if;
  if v_v.fork_of <> '0b000000-0000-4000-8000-000000000b82' then
    raise exception 'FAIL 7o: the copy''s version does not name the plan it was cut from (%)', v_v.fork_of;
  end if;
  if v_v.fork_cut_s <> v_cut then
    raise exception 'FAIL 7p: the copy''s version says the cut is %, the plan says %', v_v.fork_cut_s, v_cut;
  end if;
  v_frames := v_v.frames;
  if jsonb_array_length(v_frames) <> 4 then
    raise exception 'FAIL 7q: the copy''s version holds % frames, expected the anchor and three', jsonb_array_length(v_frames);
  end if;
  if (v_frames -> 0 ->> 't_s')::int <> v_cut then
    raise exception 'FAIL 7r: the copy''s version starts at %, the cut is %', v_frames -> 0 ->> 't_s', v_cut;
  end if;

  -- And the second planner, still holding the copy's old revision 1, is refused -- with the session staying on the
  -- copy this time.
  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';
  v_ok := false;
  begin
    perform public.plan_publish(v_copy.id, 1);
    v_ok := true;
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  if v_ok then
    raise exception 'FAIL 7s: a second publish from the copy''s old revision was accepted';
  end if;
  if v_state <> 'PT409' or v_msg !~ 'now version 2' then
    raise exception 'FAIL 7t: the second stale publish raised % (%): %', v_state, v_msg, v_msg;
  end if;
  select s.plan_id, s.plan_rev into v_session from public.event_sessions s where s.id = v_session_id;
  if v_session.plan_id <> v_copy.id or v_session.plan_rev <> 2 then
    raise exception 'FAIL 7u: the refused publish moved the session (% -> version %)', v_session.plan_id, v_session.plan_rev;
  end if;
  select count(*) into v_n from public.plan_versions where plan_id = v_copy.id;
  if v_n <> 1 then
    raise exception 'FAIL 7v: the copy has % versions after a refused publish, expected 1', v_n;
  end if;
end $$;

-- ---------- 8. where a version lives ----------
do $$
declare
  v_n integer;
  v_policies integer;
begin
  -- Ops staff read every version of the event: root, the other planner, and the marshal the fixture added. There are
  -- six: the plan published four times (revisions 2, 3, 4), the empty plan once, the fork's original once, and the
  -- copy once. The count is scoped to this event: ops staff are staff of every event on the machine, and the other
  -- benches' versions are not this check's business (the row's own event_id is what the policy reads).
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
  select count(*) into v_n from public.plan_versions where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 6 then
    raise exception 'FAIL 8a: the root user reads % versions, expected 6', v_n;
  end if;

  set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';
  select count(*) into v_n from public.plan_versions where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 6 then
    raise exception 'FAIL 8b: the second planner reads % versions, expected 6', v_n;
  end if;

  set local request.jwt.claims = '{"sub":"00cd023b-0e26-4574-a635-760e782c8029","role":"authenticated"}';
  select count(*) into v_n from public.plan_versions where event_id = '0b000000-0000-4000-8000-000000000e01';
  if v_n <> 6 then
    raise exception 'FAIL 8c: a marshal reads % versions, expected 6', v_n;
  end if;

  -- A plain member of Sound: their copy of the plan is their own timetable (052), not every group's walk.
  set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';
  select count(*) into v_n from public.plan_versions;
  if v_n <> 0 then
    raise exception 'FAIL 8d: a plain member reads % versions', v_n;
  end if;

  -- Somebody with no role in the event at all.
  set local request.jwt.claims = '{"sub":"0b000000-0000-4000-8000-000000000099","role":"authenticated"}';
  select count(*) into v_n from public.plan_versions;
  if v_n <> 0 then
    raise exception 'FAIL 8e: an outsider reads % versions', v_n;
  end if;

  reset role;

  -- anon may not even reach the table (finding 1's default ACL, revoked here), and authenticated may read it and
  -- nothing else. A row somebody can edit is not a version.
  if has_table_privilege('anon', 'public.plan_versions', 'select') then
    raise exception 'FAIL 8f: anon can select from plan_versions';
  end if;
  if not has_table_privilege('authenticated', 'public.plan_versions', 'select') then
    raise exception 'FAIL 8g: authenticated cannot select from plan_versions';
  end if;
  if has_table_privilege('authenticated', 'public.plan_versions', 'insert')
     or has_table_privilege('authenticated', 'public.plan_versions', 'update')
     or has_table_privilege('authenticated', 'public.plan_versions', 'delete') then
    raise exception 'FAIL 8h: authenticated can write plan_versions';
  end if;

  select count(*) into v_policies
    from pg_policies
   where schemaname = 'public' and tablename = 'plan_versions';
  if v_policies <> 1 then
    raise exception 'FAIL 8i: plan_versions has % policies, expected one read policy', v_policies;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'plan_versions' and cmd = 'SELECT') then
    raise exception 'FAIL 8j: plan_versions'' one policy is not a read policy';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.plan_versions'::regclass) then
    raise exception 'FAIL 8k: row-level security is off on plan_versions';
  end if;

  -- One version per (plan, revision), enforced rather than assumed.
  if exists (select 1 from public.plan_versions group by plan_id, rev having count(*) > 1) then
    raise exception 'FAIL 8l: a plan has two versions at the same revision';
  end if;
end $$;

-- ---------- 9. a plan's death takes its versions ----------
do $$
declare
  v_copy uuid := current_setting('check.copy')::uuid;
  v_n integer;
  v_fork_of uuid;
  v_cut integer;
begin
  reset role;

  -- Deleting the plan a copy was cut from takes that plan's own versions, and nulls the link on the copy's version:
  -- the copy's history is about the copy, not about its parent.
  delete from public.plans where id = '0b000000-0000-4000-8000-000000000b82';

  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b82';
  if v_n <> 0 then
    raise exception 'FAIL 9a: deleting a plan left % of its versions behind', v_n;
  end if;
  select fork_of into v_fork_of from public.plan_versions where plan_id = v_copy and rev = 2;
  if not found then
    raise exception 'FAIL 9b: deleting the original took the copy''s version with it';
  end if;
  if v_fork_of is not null then
    raise exception 'FAIL 9c: the copy''s version still names the deleted plan (%)', v_fork_of;
  end if;
  select fork_cut_s into v_cut from public.plans where id = v_copy;
  if not found or v_cut is null then
    raise exception 'FAIL 9d: deleting the original removed the copy''s cut';
  end if;

  -- The copy's own death takes its version too.
  delete from public.plans where id = v_copy;
  select count(*) into v_n from public.plan_versions where plan_id = v_copy;
  if v_n <> 0 then
    raise exception 'FAIL 9e: deleting the copy left % of its versions behind', v_n;
  end if;
end $$;

-- ---------- 10. the old door is gone, and the new one is granted the way the plan surface is ----------
do $$
declare
  v_n integer;
begin
  reset role;

  if to_regprocedure('public.plan_publish(uuid)') is not null then
    raise exception 'FAIL 10a: the one-argument plan_publish still exists';
  end if;
  if to_regprocedure('public.plan_publish(uuid, integer)') is null then
    raise exception 'FAIL 10b: plan_publish(uuid, integer) does not exist';
  end if;

  if has_function_privilege('anon', 'public.plan_publish(uuid, integer)', 'EXECUTE') then
    raise exception 'FAIL 10c: anon can execute plan_publish';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_publish(uuid, integer)', 'EXECUTE') then
    raise exception 'FAIL 10d: authenticated cannot execute plan_publish';
  end if;

  select count(*) into v_n
    from pg_proc p,
         lateral aclexplode(coalesce(p.proacl, '{}'::aclitem[])) a
   where p.oid = 'public.plan_publish(uuid, integer)'::regprocedure
     and a.grantee = 0
     and a.privilege_type = 'EXECUTE';
  if v_n > 0 then
    raise exception 'FAIL 10e: plan_publish is still granted to PUBLIC: 042''s mistake';
  end if;
end $$;

rollback;

select 'step 18: publishing is compare-and-set -- a missing revision and a stale one are refused without writing anything, the revision the caller holds publishes, and every publish leaves an immutable version behind' as result;
