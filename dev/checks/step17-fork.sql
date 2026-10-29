-- Step 17, checked at the database: a copy taken mid-walk starts where the walk already had everybody, and the past
-- cannot be written back into it.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step17-fork.sql
--
-- What has to be true, and why each one is here:
--
--   1. A PLAIN COPY IS STILL A PLAIN COPY. A plan nobody is running forks whole: every frame, every position, the
--      off-site / manual flags, and each new frame naming the frame it came from. The cut is null, because there is
--      no past to protect.
--   2. THE CUT. A plan copied while its session is running starts at the clock offset the session has reached, and
--      contains no frame at or before it except the anchor it writes there. The original keeps its own walk.
--   3. THE ANCHOR IS THE WALK, NOT A DOT. Each group's position at the cut is interpolated between the statements
--      that bracket it -- strictly between them, not equal to either -- and the copy's first frame carries it. A
--      group that is off site at the cut stays off site where it was last seen; a group that has not appeared yet
--      has no anchor at all; a group standing still keeps its last position.
--   4. plan_position_at() IS THAT ARITHMETIC, shared. It answers the same numbers the anchor was built from, by the
--      same read rule plan_positions has had since 040.
--   5. THE PAST IS REFUSED. Creating, moving, deleting or shifting a frame at or before the cut raises a sentence
--      naming the cut, through every door: frame_save, frame_move, frame_delete, frame_shift, a direct table write,
--      and a direct position write. A frame AFTER the cut is still an ordinary frame -- the plan is not frozen, only
--      its past is.
--   6. PUBLISHING CARRIES THE EVENT ACROSS. The running session moves onto the copy, keeps its clock, takes the new
--      revision, and the anchor reads "arrived at the cut" for every group it anchors (and "not required" for an
--      off-site one). This is what makes "republish" mean "the change reached the people following it".
--   7. THE POSITION AT THE CUT IS UNCHANGED. The done-when, as numbers: the copy's position at the cut equals the
--      original's, before and after the switch, and the timetable's first row is the cut at the same instant.
--   8. A SECOND PUBLISH DOES NOT REWRITE THE RECORD. Republishing the copy carries nobody twice and leaves an
--      outcome somebody recorded as it was.
--   9. WHO MAY DO IT. A plain member cannot copy or publish; an outsider cannot copy; the cut cannot be cleared.
--
-- The check builds its own plans and starts a real session through start_event(), then rolls the whole transaction
-- back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a clean event clock, and a bench to build on ----------
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e01';
delete from public.plan_positions where plan_id in ('0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000b72');
delete from public.plan_frames    where plan_id in ('0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000b72');
delete from public.plans          where id in ('0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000b72');

do $$
begin
  if not exists (select 1 from public.events where id = '0b000000-0000-4000-8000-000000000e01') then
    raise exception 'The bench is not there: run supabase/fixtures/plan_bench.sql first';
  end if;
end $$;

-- ---------- the plan that is running: T+0 seven minutes ago ----------
-- Five moments five minutes apart. Gate Crew walks 25 m north a frame; Sound stands, goes off site at the build and
-- comes back 25 m north at +15:00; Backstage only appears at +15:00. Legal, so the publish gate lets the session
-- start on it.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
select '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', 'Fork bench',
       (now() at time zone 'Asia/Singapore' - interval '7 minutes')::date,
       (now() at time zone 'Asia/Singapore' - interval '7 minutes')::time,
       'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1701', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01',    0, 'call',    'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1702', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01',  300, 'build',   'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1703', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01',  600, null,      'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1704', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01',  900, 'curtain', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1705', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', 1200, 'out',     'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f1701', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1702', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1703', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3304342, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1704', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3306513, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1705', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3308684, 103.77400),
  ('0b000000-0000-4000-8000-0000000f1701', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1702', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1703', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1704', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3342171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1705', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3342171, 103.77300),
  ('0b000000-0000-4000-8000-0000000f1704', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3320000, 103.77600),
  ('0b000000-0000-4000-8000-0000000f1705', '0b000000-0000-4000-8000-000000000b71', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3320000, 103.77600);

-- Sound is off site at +5:00 and +10:00, and the +5:00 row is a manual statement so the anchor has a flag to inherit.
update public.plan_positions set state = 'off_site' where frame_id = '0b000000-0000-4000-8000-0000000f1702'
  and group_id = '0b000000-0000-4000-8000-00000000a002';
update public.plan_positions set state = 'off_site' where frame_id = '0b000000-0000-4000-8000-0000000f1703'
  and group_id = '0b000000-0000-4000-8000-00000000a002';
update public.plan_positions set verify = 'manual' where frame_id = '0b000000-0000-4000-8000-0000000f1702'
  and group_id = '0b000000-0000-4000-8000-00000000a002';

-- ---------- the plan nobody is running: the plain-copy control ----------
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by)
values ('0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01', 'Plain copy bench',
        current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f1711', '0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01',   0, 'start', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f1712', '0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01', 600, 'finish', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f1711', '0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f1711', '0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3340000, 103.77300, 'off_site', 'manual'),
  ('0b000000-0000-4000-8000-0000000f1712', '0b000000-0000-4000-8000-000000000b72', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3330000, 103.77700, 'on_site', 'manual');

-- ---------- publish it and start the session, through the product's doors ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b71', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b71'));
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-000000000b71');
  perform set_config('check.session', v_s::text, true);
end $$;

-- ---------- 1. a plan nobody is running forks whole ----------
do $$
declare
  v_fork public.plans;
  v_n integer;
  v_src record;
  v_new record;
begin
  v_fork := public.plan_fork('0b000000-0000-4000-8000-000000000b72');
  perform set_config('check.fork_c', v_fork.id::text, true);

  if v_fork.fork_cut_s is not null then
    raise exception 'FAIL 1a: a plan nobody is running forked with a cut at %', v_fork.fork_cut_s;
  end if;

  select count(*) into v_n from public.plan_frames where plan_id = v_fork.id;
  if v_n <> 2 then
    raise exception 'FAIL 1b: the plain copy has % frames, expected 2', v_n;
  end if;

  select count(*) into v_n from public.plan_frames where plan_id = v_fork.id and origin_frame_id is null;
  if v_n <> 0 then
    raise exception 'FAIL 1c: % of the plain copy''s frames do not name the frame they came from', v_n;
  end if;

  -- Every link points at the source frame with the same time, and its note came with it.
  for v_src in
    select f.t_s, f.note, f.id from public.plan_frames f
     where f.plan_id = '0b000000-0000-4000-8000-000000000b72' order by f.t_s
  loop
    select f.id, f.note into v_new
      from public.plan_frames f
     where f.plan_id = v_fork.id and f.t_s = v_src.t_s;
    if not found then
      raise exception 'FAIL 1d: the plain copy is missing the frame at %', public.plan_clock(v_src.t_s);
    end if;
    if v_new.id is null then
      raise exception 'FAIL 1d: no row for the frame at %', public.plan_clock(v_src.t_s);
    end if;
    if v_new.note is distinct from v_src.note then
      raise exception 'FAIL 1e: the frame at % was copied with note "%", expected "%"',
        public.plan_clock(v_src.t_s), v_new.note, v_src.note;
    end if;
    if (select origin_frame_id from public.plan_frames where id = v_new.id) <> v_src.id then
      raise exception 'FAIL 1f: the frame at % does not name its original', public.plan_clock(v_src.t_s);
    end if;
  end loop;

  -- The flags came with the positions (046's rule, still true for a plain copy).
  select count(*) into v_n from public.plan_positions where plan_id = v_fork.id;
  if v_n <> 3 then
    raise exception 'FAIL 1g: the plain copy has % positions, expected 3', v_n;
  end if;
  if not exists (
    select 1 from public.plan_positions pp
      join public.plan_frames f on f.id = pp.frame_id
     where f.plan_id = v_fork.id and pp.group_id = '0b000000-0000-4000-8000-00000000a002'
       and pp.state = 'off_site' and pp.verify = 'manual'
  ) then
    raise exception 'FAIL 1h: the plain copy lost the off-site / manual pair';
  end if;
end $$;

-- ---------- 2. the cut, and the frames the copy refuses ----------
do $$
declare
  v_fork public.plans;
  v_cut integer;
  v_n integer;
begin
  v_fork := public.plan_fork('0b000000-0000-4000-8000-000000000b71');
  perform set_config('check.fork', v_fork.id::text, true);
  v_cut := v_fork.fork_cut_s;
  perform set_config('check.cut', v_cut::text, true);

  if v_cut is null then
    raise exception 'FAIL 2a: a plan copied mid-walk has no cut';
  end if;
  -- The session's clock is seven minutes old when the plan is published; the copy is taken a moment later, so the
  -- cut is the offset to the second, not the plan's T+0 and not now() as a wall-clock time.
  if v_cut < 410 or v_cut > 460 then
    raise exception 'FAIL 2b: the cut is at %, expected the seven-minute-old clock (~420)', v_cut;
  end if;
  if v_cut <= 300 or v_cut >= 600 then
    raise exception 'FAIL 2c: the cut (%) is not between the two statements this check interpolates (300 and 600)', v_cut;
  end if;

  -- The anchor, then the three frames after it. A frame at or before the cut is not in the copy.
  select count(*) into v_n from public.plan_frames where plan_id = v_fork.id;
  if v_n <> 4 then
    raise exception 'FAIL 2d: the copy has % frames, expected the anchor and the three after it', v_n;
  end if;
  select count(*) into v_n from public.plan_frames where plan_id = v_fork.id and t_s <= v_cut;
  if v_n <> 1 then
    raise exception 'FAIL 2e: % frames sit at or before the cut, expected only the anchor', v_n;
  end if;
  if not exists (select 1 from public.plan_frames where plan_id = v_fork.id and t_s = v_cut) then
    raise exception 'FAIL 2f: there is no anchor at the cut';
  end if;

  -- The later frames kept their times and now name their originals; the anchor is not a copy of anything.
  if (select count(*) from public.plan_frames
       where plan_id = v_fork.id and t_s > v_cut and origin_frame_id is null) <> 0 then
    raise exception 'FAIL 2g: a copied frame does not name its original';
  end if;
  if (select origin_frame_id from public.plan_frames where plan_id = v_fork.id and t_s = v_cut) is not null then
    raise exception 'FAIL 2h: the anchor claims to be a copy of a frame';
  end if;

  -- The original is untouched: the past is still there, with all five frames and all twelve positions.
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b71';
  if v_n <> 5 then
    raise exception 'FAIL 2i: the original has % frames, expected its own 5', v_n;
  end if;
  select count(*) into v_n from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b71';
  if v_n <> 12 then
    raise exception 'FAIL 2j: the original has % positions, expected its own 12', v_n;
  end if;
end $$;

-- ---------- 3. the anchor is the walk, not a dot ----------
do $$
declare
  v_fork uuid := current_setting('check.fork')::uuid;
  v_cut integer := current_setting('check.cut')::int;
  v_anchor uuid;
  v_lat double precision;
  v_lng double precision;
  v_state text;
  v_verify text;
  v_expected double precision;
  v_k double precision;
begin
  select id into v_anchor from public.plan_frames where plan_id = v_fork and t_s = v_cut;
  if not found then
    raise exception 'FAIL 3a: the copy has no anchor frame';
  end if;
  perform set_config('check.anchor', v_anchor::text, true);

  -- Gate Crew was between +5:00 and +10:00, so the anchor is on that straight line -- strictly between the two
  -- statements, and exactly the fraction of the way there that the clock says.
  v_k := (v_cut - 300)::double precision / 300;
  v_expected := 1.3302171 + (1.3304342 - 1.3302171) * v_k;

  select lat, lng, state, verify into v_lat, v_lng, v_state, v_verify
    from public.plan_positions where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a001';
  if not found then
    raise exception 'FAIL 3b: Gate Crew has no anchor position';
  end if;
  if abs(v_lat - v_expected) > 1e-9 then
    raise exception 'FAIL 3c: Gate Crew''s anchor is at %, expected % (the walk at %)',
      round(v_lat::numeric, 7), round(v_expected::numeric, 7), v_cut;
  end if;
  if v_lat <= 1.3302171 or v_lat >= 1.3304342 then
    raise exception 'FAIL 3d: the anchor is not strictly between the two statements it was interpolated from (%)',
      round(v_lat::numeric, 7);
  end if;
  if v_state <> 'on_site' or v_verify <> 'auto' then
    raise exception 'FAIL 3e: the anchor came out % / %, expected on_site / auto', v_state, v_verify;
  end if;

  -- Sound was off site at +5:00, so the anchor is where it was last seen, off site, with the manual flag it carried.
  select lat, lng, state, verify into v_lat, v_lng, v_state, v_verify
    from public.plan_positions where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a002';
  if not found then
    raise exception 'FAIL 3f: Sound has no anchor position';
  end if;
  if abs(v_lat - 1.3340000) > 1e-9 or abs(v_lng - 103.77300) > 1e-9 then
    raise exception 'FAIL 3g: Sound''s off-site anchor moved to %, % (expected where it was last seen)', v_lat, v_lng;
  end if;
  if v_state <> 'off_site' or v_verify <> 'manual' then
    raise exception 'FAIL 3h: Sound''s anchor came out % / %, expected off_site / manual', v_state, v_verify;
  end if;

  -- Backstage only appears at +15:00: the copy does not invent a position for it at the cut.
  if exists (select 1 from public.plan_positions where frame_id = v_anchor
               and group_id = '0b000000-0000-4000-8000-00000000a003') then
    raise exception 'FAIL 3i: a group that has not appeared yet got an anchor position';
  end if;
end $$;

-- ---------- 4. plan_position_at() is the same arithmetic ----------
do $$
declare
  v_cut integer := current_setting('check.cut')::int;
  v_fork uuid := current_setting('check.fork')::uuid;
  v_anchor uuid := current_setting('check.anchor')::uuid;
  v_a record;
  v_b record;
begin
  select * into v_a from public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                                '0b000000-0000-4000-8000-00000000a001', v_cut);
  if not found then
    raise exception 'FAIL 4a: plan_position_at answered nothing at the cut';
  end if;
  select * into v_b from public.plan_position_at(v_fork, '0b000000-0000-4000-8000-00000000a001', v_cut);
  if not found then
    raise exception 'FAIL 4b: plan_position_at answered nothing on the copy';
  end if;
  if abs(v_a.lat - v_b.lat) > 1e-12 or abs(v_a.lng - v_b.lng) > 1e-12 then
    raise exception 'FAIL 4c: the copy answers a different position at the cut (% vs %)',
      round(v_a.lat::numeric, 9), round(v_b.lat::numeric, 9);
  end if;
  if (select lat from public.plan_positions where frame_id = v_anchor
        and group_id = '0b000000-0000-4000-8000-00000000a001') <> v_a.lat then
    raise exception 'FAIL 4d: the anchor is not what plan_position_at says it is';
  end if;

  -- Before the group's first statement there is no position at all.
  select * into v_a from public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                                '0b000000-0000-4000-8000-00000000a003', v_cut);
  if found then
    raise exception 'FAIL 4e: a group that has not appeared yet has a position at %', v_cut;
  end if;
  select * into v_a from public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                                '0b000000-0000-4000-8000-00000000a003', 900);
  if not found then
    raise exception 'FAIL 4f: the group that appears at +15:00 has no position at +15:00';
  end if;
end $$;

-- ---------- 5. the past is refused, through every door ----------
do $$
declare
  v_fork uuid := current_setting('check.fork')::uuid;
  v_cut integer := current_setting('check.cut')::int;
  v_anchor uuid := current_setting('check.anchor')::uuid;
  v_frame uuid;
  v_try boolean;
  v_made public.plan_frames;
begin
  -- 5a. creating a frame before the cut
  v_try := false;
  begin
    perform public.frame_save(v_fork, jsonb_build_object('t_s', 0, 'note', 'before the cut'));
    v_try := true;
  exception when others then
    if sqlerrm !~ '\+0?7:0' then
      raise exception 'FAIL 5a: the refusal did not name the cut: %', sqlerrm;
    end if;
  end;
  if v_try then
    raise exception 'FAIL 5a: a frame was written before the cut';
  end if;

  -- 5b. the anchor's note is a label and can be written; its TIME is the copy's start and cannot move
  perform public.frame_save(v_fork, jsonb_build_object('id', v_anchor, 't_s', v_cut, 'rev', 1, 'note', 'where the copy starts'));
  if (select note from public.plan_frames where id = v_anchor) <> 'where the copy starts' then
    raise exception 'FAIL 5b: the anchor''s note could not be written';
  end if;
  v_try := false;
  begin
    perform public.frame_save(v_fork, jsonb_build_object('id', v_anchor, 't_s', v_cut + 60, 'rev', 2));
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5b2: the anchor was moved';
  end if;

  -- 5c. moving a later frame back across the cut
  select id into v_frame from public.plan_frames where plan_id = v_fork and t_s = 600;
  if not found then
    raise exception 'FAIL 5c: the copy has no frame at +10:00';
  end if;
  v_try := false;
  begin
    perform public.frame_move(v_frame, v_cut - 60, 1);
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5c: a frame was moved before the cut';
  end if;

  -- 5d. deleting the anchor
  v_try := false;
  begin
    perform public.frame_delete(v_anchor, 1);
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5d: the anchor was deleted';
  end if;

  -- 5e. shifting a stretch that starts at the cut (the anchor travels with it)
  v_try := false;
  begin
    perform public.frame_shift(v_fork, v_cut, 60);
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5e: a stretch including the anchor was shifted';
  end if;

  -- 5f. a direct write to the table the app never makes
  v_try := false;
  begin
    insert into public.plan_frames (plan_id, event_id, t_s, note)
    values (v_fork, '0b000000-0000-4000-8000-000000000e01', 10, 'straight in');
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5f: a direct insert put a frame before the cut';
  end if;

  -- 5g. a direct write to the anchor's positions
  v_try := false;
  begin
    update public.plan_positions set lat = lat + 0.001
     where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a001';
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5g: the anchor''s position was changed by a direct write';
  end if;

  -- 5h. and the plan cannot be talked out of its cut
  v_try := false;
  begin
    update public.plans set fork_cut_s = null where id = v_fork;
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 5h: the cut was cleared';
  end if;

  -- 5i. the plan is not frozen: a frame after the cut is an ordinary frame
  v_made := public.frame_save(v_fork, jsonb_build_object('t_s', 1500, 'note', 'after the cut',
                                                         'positions', jsonb_build_object(
                                                           '0b000000-0000-4000-8000-00000000a001',
                                                           jsonb_build_object('lat', 1.3308684, 'lng', 103.774))));
  if v_made.t_s <> 1500 then
    raise exception 'FAIL 5i: a frame after the cut was not written';
  end if;
  perform public.frame_delete(v_made.id, v_made.rev);
end $$;

-- ---------- 6. publishing carries the running event across ----------
do $$
declare
  v_fork uuid := current_setting('check.fork')::uuid;
  v_cut integer := current_setting('check.cut')::int;
  v_anchor uuid;
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_rev integer;
  v_n integer;
  v_state text;
  v_lateness interval;
  v_planned timestamptz;
  v_marked timestamptz;
  v_by uuid;
begin
  v_anchor := current_setting('check.anchor')::uuid;
  select t0_at into v_t0 from public.event_sessions where id = v_s;
  select rev into v_rev from public.plans where id = v_fork;

  perform public.plan_publish(v_fork, v_rev);

  if (select status from public.plans where id = v_fork) <> 'live' then
    raise exception 'FAIL 6a: the copy was not published';
  end if;
  if (select status from public.plans where id = '0b000000-0000-4000-8000-000000000b71') <> 'archived' then
    raise exception 'FAIL 6b: the original was not stood down';
  end if;

  -- The session follows the copy, on the clock it already had.
  if (select plan_id from public.event_sessions where id = v_s) <> v_fork then
    raise exception 'FAIL 6c: the session did not move onto the copy';
  end if;
  if (select t0_at from public.event_sessions where id = v_s) <> v_t0 then
    raise exception 'FAIL 6d: the session''s clock moved with the copy';
  end if;
  if (select plan_rev from public.event_sessions where id = v_s) <> v_rev + 1 then
    raise exception 'FAIL 6e: the session follows revision %, expected %',
      (select plan_rev from public.event_sessions where id = v_s), v_rev + 1;
  end if;

  -- The anchor reads as a hand-over, not as a missed appointment: arrived at the cut, on time, recorded by the
  -- planner who published it.
  select state, lateness, planned_at, marked_at, marked_by
    into v_state, v_lateness, v_planned, v_marked, v_by
    from public.session_timetable(v_s)
   where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a001';
  if not found then
    raise exception 'FAIL 6f: the timetable has no row for the anchor';
  end if;
  if v_state <> 'arrived' then
    raise exception 'FAIL 6g: the anchor reads "%" on the timetable, expected arrived', v_state;
  end if;
  if v_lateness <> interval '0' then
    raise exception 'FAIL 6h: the anchor reads late by %', v_lateness;
  end if;
  if v_planned <> v_t0 + make_interval(secs => v_cut) then
    raise exception 'FAIL 6i: the anchor is planned for %, expected the cut at %', v_planned, v_t0 + make_interval(secs => v_cut);
  end if;
  if v_by <> 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7' then
    raise exception 'FAIL 6j: the hand-over was recorded by %, expected the publisher', v_by;
  end if;

  -- An off-site group has nothing to arrive at, so its anchor is "not required" and no mark was invented.
  select state into v_state from public.session_timetable(v_s)
   where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a002';
  if not found then
    raise exception 'FAIL 6k: the off-site group has no anchor row';
  end if;
  if v_state <> 'not_required' then
    raise exception 'FAIL 6l: the off-site anchor reads "%", expected not_required', v_state;
  end if;
  if (select count(*) from public.plan_progress where session_id = v_s and frame_id = v_anchor) <> 1 then
    raise exception 'FAIL 6m: % anchor marks were recorded, expected the one on-site group',
      (select count(*) from public.plan_progress where session_id = v_s and frame_id = v_anchor);
  end if;

  -- The group that has not appeared yet is not on the anchor at all.
  if exists (select 1 from public.session_timetable(v_s)
              where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a003') then
    raise exception 'FAIL 6n: the timetable invented an anchor row for a group that has not appeared';
  end if;

  -- And the past marks stayed on the past: the original's frames are not in this timetable.
  select count(*) into v_n
    from public.session_timetable(v_s) tt
    join public.plan_frames f on f.id = tt.frame_id
   where f.plan_id <> v_fork;
  if v_n <> 0 then
    raise exception 'FAIL 6o: % timetable rows point at frames outside the copy', v_n;
  end if;
end $$;

-- ---------- 7. the done-when: the position at the cut is unchanged ----------
do $$
declare
  v_fork uuid := current_setting('check.fork')::uuid;
  v_cut integer := current_setting('check.cut')::int;
  v_s uuid := current_setting('check.session')::uuid;
  v_t0 timestamptz;
  v_before record;
  v_after record;
  v_n integer;
begin
  select t0_at into v_t0 from public.event_sessions where id = v_s;

  select * into v_before from public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                                     '0b000000-0000-4000-8000-00000000a001', v_cut);
  if not found then
    raise exception 'FAIL 7a: the original has no position at the cut';
  end if;
  select * into v_after from public.plan_position_at(v_fork, '0b000000-0000-4000-8000-00000000a001', v_cut);
  if not found then
    raise exception 'FAIL 7b: the copy has no position at the cut';
  end if;
  if abs(v_before.lat - v_after.lat) > 1e-12 or abs(v_before.lng - v_after.lng) > 1e-12 then
    raise exception 'FAIL 7c: the copy teleported Gate Crew at the cut (%, % -> %, %)',
      round(v_before.lat::numeric, 9), round(v_before.lng::numeric, 9),
      round(v_after.lat::numeric, 9), round(v_after.lng::numeric, 9);
  end if;

  -- The same instant on the timetable the members read: the clock time of the first row is the cut, and it is the
  -- same clock time the original's frames would have given.
  select count(*) into v_n from public.session_timetable(v_s)
   where planned_at < v_t0 + make_interval(secs => v_cut);
  if v_n <> 0 then
    raise exception 'FAIL 7d: % timetable rows are planned before the cut', v_n;
  end if;
  if not exists (select 1 from public.session_timetable(v_s)
                  where planned_at = v_t0 + make_interval(secs => v_cut)) then
    raise exception 'FAIL 7e: no timetable row is planned for the instant of the cut';
  end if;

  -- The copy's own frames after the cut are the original's, at the same times and in the same order.
  if (select count(*) from public.plan_frames f
        join public.plan_frames o on o.id = f.origin_frame_id
       where f.plan_id = v_fork and o.plan_id <> '0b000000-0000-4000-8000-000000000b71') <> 0 then
    raise exception 'FAIL 7f: a copied frame names an original outside the plan it was copied from';
  end if;
  if (select count(*) from public.plan_frames f
        join public.plan_frames o on o.id = f.origin_frame_id
       where f.plan_id = v_fork and o.t_s <> f.t_s) <> 0 then
    raise exception 'FAIL 7g: a copied frame was copied to a different time';
  end if;
end $$;

-- ---------- 8. a second publish does not rewrite the record ----------
do $$
declare
  v_fork uuid := current_setting('check.fork')::uuid;
  v_anchor uuid := current_setting('check.anchor')::uuid;
  v_s uuid := current_setting('check.session')::uuid;
  v_state text;
  v_n integer;
begin
  -- The group's IC says "they missed that moment" after the hand-over.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';
  perform public.progress_mark(v_s, v_anchor, '0b000000-0000-4000-8000-00000000a001', 'missed');

  set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';
  perform public.plan_publish(v_fork, (select rev from public.plans where id = v_fork));

  select state into v_state from public.session_timetable(v_s)
   where frame_id = v_anchor and group_id = '0b000000-0000-4000-8000-00000000a001';
  if not found then
    raise exception 'FAIL 8a: the anchor row disappeared after a republish';
  end if;
  if v_state <> 'missed' then
    raise exception 'FAIL 8b: a republish rewrote a recorded outcome to "%"', v_state;
  end if;
  select count(*) into v_n from public.plan_progress
   where session_id = v_s and frame_id = v_anchor
     and group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_n <> 1 then
    raise exception 'FAIL 8c: % anchor marks after two publishes, expected 1', v_n;
  end if;
end $$;

-- ---------- 9. who may copy, and who may not ----------
do $$
declare
  v_try boolean;
begin
  -- A plain Sound member (testuser3) is in the event but may not copy or publish a plan.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

  v_try := false;
  begin
    perform public.plan_fork('0b000000-0000-4000-8000-000000000b71');
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 9a: a plain member copied a plan';
  end if;
  v_try := false;
  begin
    perform public.plan_publish(current_setting('check.fork')::uuid,
                                (select rev from public.plans where id = current_setting('check.fork')::uuid));
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 9b: a plain member published a plan';
  end if;

  -- The read rule on plan_position_at: their own group answers, another group does not.
  if not exists (select 1 from public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                                       '0b000000-0000-4000-8000-00000000a002',
                                                       current_setting('check.cut')::int)) then
    raise exception 'FAIL 9c: a Sound member cannot read Sound''s own position at the cut';
  end if;
  v_try := false;
  begin
    perform public.plan_position_at('0b000000-0000-4000-8000-000000000b71',
                                    '0b000000-0000-4000-8000-00000000a001',
                                    current_setting('check.cut')::int);
    v_try := true;
  exception when others then
    if sqlerrm !~ 'own group' then
      raise exception 'FAIL 9d: the refusal for another group''s position said: %', sqlerrm;
    end if;
  end;
  if v_try then
    raise exception 'FAIL 9d: a Sound member read Gate Crew''s position';
  end if;

  -- An outsider: no role in this event at all.
  set local request.jwt.claims = '{"sub":"0b000000-0000-4000-8000-000000000099","role":"authenticated"}';
  v_try := false;
  begin
    perform public.plan_fork('0b000000-0000-4000-8000-000000000b71');
    v_try := true;
  exception when others then
    null;
  end;
  if v_try then
    raise exception 'FAIL 9e: an outsider copied a plan';
  end if;
end $$;

-- ---------- 10. grants (R4) ----------
do $$
declare
  v_n integer;
begin
  reset role;
  if has_function_privilege('anon', 'public.plan_position_at(uuid, uuid, integer)', 'EXECUTE') then
    raise exception 'FAIL 10a: anon can execute plan_position_at';
  end if;
  if has_function_privilege('anon', 'public.plan_fork(uuid)', 'EXECUTE') then
    raise exception 'FAIL 10b: anon can execute plan_fork';
  end if;
  if has_function_privilege('anon', 'public.plan_publish(uuid, integer)', 'EXECUTE') then
    raise exception 'FAIL 10c: anon can execute plan_publish';
  end if;
  if has_function_privilege('anon', 'public.plan_list(uuid)', 'EXECUTE') then
    raise exception 'FAIL 10d: anon can execute plan_list';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_position_at(uuid, uuid, integer)', 'EXECUTE') then
    raise exception 'FAIL 10e: authenticated cannot execute plan_position_at';
  end if;

  -- The triggers are not callable doors. `anon` has nothing; `authenticated` keeps the schema's default EXECUTE grant,
  -- the same shape 040's trigger functions have, and Postgres refuses a trigger function that is called directly
  -- ("trigger functions can only be called as triggers"), so the grant is not a way in.
  if has_function_privilege('anon', 'public.plan_frames_guard_cut()', 'EXECUTE') then
    raise exception 'FAIL 10f: anon can execute the cut guard';
  end if;
  select count(*) into v_n from public.plan_frames where plan_id = current_setting('check.fork')::uuid;
  if v_n <> 4 then
    raise exception 'FAIL 10g: the copy ended with % frames, expected 4', v_n;
  end if;
end $$;

rollback;

select 'step 17: a copy taken mid-walk -- the anchor is the walk, the past is refused, publishing carries the event across, and the position at the cut is unchanged' as result;
