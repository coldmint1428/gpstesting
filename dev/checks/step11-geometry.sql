-- Step 11, checked at the database: the two geometric rules plan_check learned (048) and the publish gate they feed.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step11-geometry.sql
--
-- The bench already carries the Done-when: Security walks 20 m east through the Stores no-go zone between +0:00 and
-- +1:00, with both ends outside it. What this file adds is "Geometry bench" (b12), three frames and four groups,
-- each group on a lane of its own so one case cannot affect another:
--
--   * Gate Crew  -- 20 m across the no-go zone "Lane (no-go)", both ends outside: one crossing error;
--   * Sound      -- 20 m across the obstacle "Barrier (obstacle)": the other zone kind, same rule;
--   * Backstage  -- 20 m in a minute with nothing in the way: the control, and it must stay silent;
--   * Security   -- 20 m between two frames a second apart: a legal distance and a 20 m/s pace.
--
-- What is asserted, in order:
--   0. the migration is applied (the body is the new one, extensions is on the search_path) and the benches are the
--      shape this file assumes;
--   1. the Done-when on the bench's own plan: exactly one error for the crossing, naming the zone, both ends outside
--      it -- with the geometric test itself checked, so a check that cannot see a zone cannot pass;
--   2. the other bench plans report exactly what they did before: no crossing and no sprint appeared anywhere;
--   3. publish refuses a crossing, says which rule it refused for, and leaves the plan a draft; a clean plan still
--      publishes (the positive control);
--   4. Geometry bench: one error per case, each naming the right thing, and the control silent;
--   5. the pace rule is about time, not distance: the same 20 m is legal once it takes four seconds, and the speed
--      error comes back when it takes one;
--   6. one error per pair, most basic first: a 30 m hop that also crosses a zone is reported as the 25 m rule;
--   7. an off-site row is still not an endpoint, so the crossing is not reported;
--   8. the doors, re-asserted because both functions were re-created;
--   9. a member's plan_check still sees only their own group -- and can still see the zones it must test against.
--
-- One transaction, rolled back: the bench is left as the fixture wrote it.
begin;

-- ---------- Geometry bench b12 and the two zones it is about ----------
-- Far north of every fixture plan (1.3400+ vs 1.3327), so adding them cannot change what any other plan reports.
insert into public.plans (id, event_id, name, for_date, t0_time, status, created_by, created_at) values
  ('0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01',
   'Geometry bench', current_date, '18:00', 'draft', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '10 hours');

insert into public.zones (id, event_id, code, name, kind, shape, is_circle) values
  ('0b000000-0000-4000-8000-00000000c012', '0b000000-0000-4000-8000-000000000e01',
   'LANE', 'Lane (no-go)', 'no_go',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.780080 1.339980, 103.780100 1.339980, 103.780100 1.340020, 103.780080 1.340020, 103.780080 1.339980))'),
   false),
  ('0b000000-0000-4000-8000-00000000c013', '0b000000-0000-4000-8000-000000000e01',
   'BARRIER', 'Barrier (obstacle)', 'obstacle',
   extensions.st_geogfromtext('SRID=4326;POLYGON((103.781080 1.340480, 103.781100 1.340480, 103.781100 1.340520, 103.781080 1.340520, 103.781080 1.340480))'),
   false);

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f0c01', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01',  0, 'start', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0c02', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', 60, 'step',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f0c03', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', 61, 'dash',  'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f0c01', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3400, 103.780000),
  ('0b000000-0000-4000-8000-0000000f0c01', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3405, 103.781000),
  ('0b000000-0000-4000-8000-0000000f0c01', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3420, 103.782000),
  ('0b000000-0000-4000-8000-0000000f0c01', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3440, 103.783000),
  ('0b000000-0000-4000-8000-0000000f0c02', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3400, 103.780180),
  ('0b000000-0000-4000-8000-0000000f0c02', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a002', 1.3405, 103.781180),
  ('0b000000-0000-4000-8000-0000000f0c02', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a003', 1.3420, 103.782180),
  ('0b000000-0000-4000-8000-0000000f0c02', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3440, 103.783000),
  ('0b000000-0000-4000-8000-0000000f0c03', '0b000000-0000-4000-8000-000000000b12', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a004', 1.3440, 103.783180);

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

-- ---------- 0. what this file assumes ----------
do $$
declare
  v_def text;
  v_cfg text;
  v_n integer;
  v_times integer[];
begin
  if to_regprocedure('public.plan_check(uuid)') is null then
    raise exception 'FAIL 0a: plan_check does not exist';
  end if;
  v_def := pg_get_functiondef('public.plan_check(uuid)'::regprocedure);
  if position('faster than running' in v_def) = 0 or position('extensions.st_intersects' in v_def) = 0 then
    raise exception 'FAIL 0b: plan_check is not the 048 body. Run node tools/migrate.mjs up.';
  end if;
  select coalesce(array_to_string(p.proconfig, ','), '') into v_cfg
    from pg_proc p where p.oid = 'public.plan_check(uuid)'::regprocedure;
  if position('extensions' in v_cfg) = 0 then
    raise exception 'FAIL 0c: plan_check''s search_path is "%", and it must name extensions (R1)', v_cfg;
  end if;

  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b01';
  if v_n <> 6 then
    raise exception 'FAIL 0d: Walkthrough holds % frames, expected 6. Run supabase/fixtures/plan_bench.sql first.', v_n;
  end if;
  select count(*) into v_n from public.zones where event_id = '0b000000-0000-4000-8000-000000000e01'
   and kind in ('no_go', 'obstacle');
  if v_n <> 4 then
    raise exception 'FAIL 0e: the event has % no-go/obstacle zones, expected 4 (Stores, Hoarding, + this file''s two)', v_n;
  end if;
  select array_agg(t_s order by t_s) into v_times from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b12';
  if v_times is distinct from array[0, 60, 61] then
    raise exception 'FAIL 0f: Geometry bench holds %, expected 0/60/61', v_times;
  end if;

  -- The two functions this check is about have to exist with the signatures the client calls.
  if to_regprocedure('public.plan_publish(uuid, integer)') is null then
    raise exception 'FAIL 0g: plan_publish does not exist';
  end if;
end $$;

-- ---------- 1. the Done-when: 20 m through a no-go zone, both ends outside it ----------
do $$
declare
  v_n integer;
  v_row record;
  v_inside integer;
  v_crosses boolean;
begin
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b01');
  if v_n <> 2 then
    raise exception 'FAIL 1a: Walkthrough reports % error(s), expected 2 (Sound''s 200 m and Security''s crossing): %',
      v_n, (select string_agg(c.message, ' | ') from public.plan_check('0b000000-0000-4000-8000-000000000b01') c);
  end if;

  select * into v_row
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a004';
  if not found then
    raise exception 'FAIL 1b: the crossing was not reported for Security at all';
  end if;
  if v_row.severity <> 'error' then
    raise exception 'FAIL 1c: the crossing reads severity %, expected error', v_row.severity;
  end if;
  if v_row.from_s <> 0 or v_row.to_s <> 60 then
    raise exception 'FAIL 1d: the crossing is reported between % and %, expected 0 and 60', v_row.from_s, v_row.to_s;
  end if;
  if v_row.metres < 19 or v_row.metres > 21 then
    raise exception 'FAIL 1e: the crossing reports % m, expected about 20', v_row.metres;
  end if;
  if position('Stores' in v_row.message) = 0 then
    raise exception 'FAIL 1f: the crossing does not name the zone: %', v_row.message;
  end if;
  if position('crosses' in v_row.message) = 0 then
    raise exception 'FAIL 1g: the crossing does not say what is wrong: %', v_row.message;
  end if;
  if position('no-go' in v_row.message) = 0 then
    raise exception 'FAIL 1h: the crossing does not say what kind of zone it is: %', v_row.message;
  end if;
  if position('25 m' in v_row.message) > 0 then
    raise exception 'FAIL 1i: a 20 m hop is reported as a 25 m break: %', v_row.message;
  end if;

  -- Exactly one error for the pair, even though the line is a zone crossing and a 20 m walk at the same time.
  select count(*) into v_n
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a004';
  if v_n <> 1 then
    raise exception 'FAIL 1j: Security has % error(s) on its one hop, expected exactly 1', v_n;
  end if;

  -- The endpoints are outside the zone. Without this the test would pass on a plan that simply stands inside it.
  select count(*) into v_inside
    from public.plan_positions p
    join public.zones z on z.id = '0b000000-0000-4000-8000-00000000c001'
   where p.frame_id in ('0b000000-0000-4000-8000-0000000f0001', '0b000000-0000-4000-8000-0000000f0002')
     and p.group_id = '0b000000-0000-4000-8000-00000000a004'
     and extensions.st_intersects(
           z.shape,
           extensions.st_setsrid(extensions.st_makepoint(p.lng, p.lat), 4326)::extensions.geography);
  if v_inside <> 0 then
    raise exception 'FAIL 1k: % of the two endpoints is inside the zone, so this is not a crossing', v_inside;
  end if;

  -- The geometric test itself, on the same two stored positions: the line does meet the zone, and it is not a
  -- near miss that the check above would have to guess about.
  select extensions.st_intersects(
           z.shape,
           extensions.st_setsrid(
             extensions.st_makeline(
               extensions.st_makepoint(p0.lng, p0.lat),
               extensions.st_makepoint(p1.lng, p1.lat)),
             4326)::extensions.geography)
    into v_crosses
    from public.zones z,
         public.plan_positions p0,
         public.plan_positions p1
   where z.id = '0b000000-0000-4000-8000-00000000c001'
     and p0.frame_id = '0b000000-0000-4000-8000-0000000f0001'
     and p1.frame_id = '0b000000-0000-4000-8000-0000000f0002'
     and p0.group_id = '0b000000-0000-4000-8000-00000000a004'
     and p1.group_id = '0b000000-0000-4000-8000-00000000a004';
  if v_crosses is not true then
    raise exception 'FAIL 1l: the stored line does not meet the zone, so the fixture is not the case this check means';
  end if;

  -- Sound's 200 m still reads as the distance rule: one budget per frame step (step 12 turned the flat 25 m into 25 m
  -- a step, and this walk spans two of them), and it does not mention a zone.
  select * into v_row
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a002';
  if v_row.metres <> 200 or position('the limit is 50 m' in v_row.message) = 0
     or position('2 steps' in v_row.message) = 0 then
    raise exception 'FAIL 1m: Sound''s break changed: % m, "%"', v_row.metres, v_row.message;
  end if;
  if position('crosses' in v_row.message) > 0 or position('m/s' in v_row.message) > 0 then
    raise exception 'FAIL 1n: Sound''s distance break picked up a geometric rule: %', v_row.message;
  end if;
end $$;

-- ---------- 2. the rest of the bench is exactly as it was ----------
do $$
declare
  v_n integer;
  v_msgs text;
begin
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b02');
  if v_n <> 0 then raise exception 'FAIL 2a: "Clean walk" reports % error(s): %', v_n,
    (select string_agg(c.message, ' | ') from public.plan_check('0b000000-0000-4000-8000-000000000b02') c); end if;
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b03');
  if v_n <> 0 then raise exception 'FAIL 2b: "Copy bench" reports % error(s)', v_n; end if;
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b05');
  if v_n <> 0 then raise exception 'FAIL 2c: "Push bench" reports % error(s)', v_n; end if;

  -- Twin gap: two 200 m hops over five minutes. Legal pace, no zone on the line -- the distance rule, twice.
  select count(*), string_agg(c.message, ' | ') into v_n, v_msgs
    from public.plan_check('0b000000-0000-4000-8000-000000000b04') c;
  if v_n <> 2 then
    raise exception 'FAIL 2d: "Twin gap" reports % error(s), expected 2', v_n;
  end if;
  if position('crosses' in v_msgs) > 0 or position('m/s' in v_msgs) > 0 then
    raise exception 'FAIL 2e: "Twin gap" picked up a geometric rule: %', v_msgs;
  end if;
end $$;

-- ---------- 3. publish refuses a crossing, and says which rule ----------
do $$
declare
  v_msg text;
  v_status text;
  v_rev integer;
  v_rev0 integer;
  v_published timestamptz;
begin
  select rev into v_rev0 from public.plans where id = '0b000000-0000-4000-8000-000000000b01';
  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b01', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b01'));
    raise exception 'FAIL 3a: a plan whose walk goes through a no-go zone was published';
  exception
    when sqlstate '22023' then v_msg := sqlerrm;
  end;
  if position('cannot be published' in v_msg) = 0 then
    raise exception 'FAIL 3b: the refusal does not say it refused: %', v_msg;
  end if;
  if position('Stores' in v_msg) = 0 or position('crosses' in v_msg) = 0 then
    raise exception 'FAIL 3c: the refusal does not name the crossing: %', v_msg;
  end if;
  if position('2 problems' in v_msg) = 0 then
    raise exception 'FAIL 3d: the refusal does not count the problems: %', v_msg;
  end if;

  select status, rev, published_at into v_status, v_rev, v_published
    from public.plans where id = '0b000000-0000-4000-8000-000000000b01';
  if v_status <> 'draft' or v_published is not null or v_rev <> v_rev0 then
    raise exception 'FAIL 3e: the refused publish changed the plan: status %, rev % (was %), published_at %',
      v_status, v_rev, v_rev0, v_published;
  end if;

  -- The positive control: a plan with no geometric problem still publishes, so the gate is not simply refusing
  -- everything now.
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b02', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b02'));
  select status, published_at into v_status, v_published
    from public.plans where id = '0b000000-0000-4000-8000-000000000b02';
  if v_status <> 'live' or v_published is null then
    raise exception 'FAIL 3f: a clean plan did not publish (status %, published_at %)', v_status, v_published;
  end if;

  -- Three problems on Geometry bench; the sentence names the first in time, which is Gate Crew's crossing.
  begin
    perform public.plan_publish('0b000000-0000-4000-8000-000000000b12', (select rev from public.plans where id = '0b000000-0000-4000-8000-000000000b12'));
    raise exception 'FAIL 3g: Geometry bench was published';
  exception
    when sqlstate '22023' then v_msg := sqlerrm;
  end;
  if position('3 problems' in v_msg) = 0 or position('Lane' in v_msg) = 0 then
    raise exception 'FAIL 3h: the refusal reads: %', v_msg;
  end if;
end $$;

-- ---------- 4. Geometry bench: one error per case ----------
do $$
declare
  v_n integer;
  v_row record;
  v_msgs text;
begin
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b12');
  if v_n <> 3 then
    raise exception 'FAIL 4a: Geometry bench reports % error(s), expected 3: %', v_n,
      (select string_agg(c.message, ' | ') from public.plan_check('0b000000-0000-4000-8000-000000000b12') c);
  end if;

  select * into v_row from public.plan_check('0b000000-0000-4000-8000-000000000b12') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a001';
  if position('Lane (no-go)' in v_row.message) = 0 or position('crosses' in v_row.message) = 0 then
    raise exception 'FAIL 4b: the no-go crossing reads: %', v_row.message;
  end if;

  select * into v_row from public.plan_check('0b000000-0000-4000-8000-000000000b12') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a002';
  if position('Barrier' in v_row.message) = 0 or position('obstacle' in v_row.message) = 0 then
    raise exception 'FAIL 4c: the obstacle crossing reads: %', v_row.message;
  end if;
  if position('crosses' in v_row.message) = 0 then
    raise exception 'FAIL 4d: the obstacle crossing does not say what is wrong: %', v_row.message;
  end if;

  -- Security: 20 m in one second -- the distance is legal, the pace is not.
  select * into v_row from public.plan_check('0b000000-0000-4000-8000-000000000b12') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a004';
  if v_row.from_s <> 60 or v_row.to_s <> 61 then
    raise exception 'FAIL 4e: the pace error runs % to %, expected 60 to 61', v_row.from_s, v_row.to_s;
  end if;
  if position('m/s' in v_row.message) = 0 or position('faster than running' in v_row.message) = 0 then
    raise exception 'FAIL 4f: the pace error reads: %', v_row.message;
  end if;
  if position('25 m' in v_row.message) > 0 then
    raise exception 'FAIL 4g: a 20 m hop is reported as a distance break: %', v_row.message;
  end if;

  -- The control. Backstage walked the same 20 m in a minute with nothing in the way.
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b12') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a003';
  if v_n <> 0 then
    raise exception 'FAIL 4h: the control group reports % error(s), expected none', v_n;
  end if;

  select string_agg(c.message, ' | ') into v_msgs from public.plan_check('0b000000-0000-4000-8000-000000000b12') c;
  if position('Lane' in v_msgs) = 0 or position('Barrier' in v_msgs) = 0 then
    raise exception 'FAIL 4i: the two zones are not both named: %', v_msgs;
  end if;
end $$;

-- ---------- 5. the pace rule is about time, not distance; one error per pair; off site still skipped ----------
do $$
declare
  v_rev integer;
  v_n integer;
  v_msg text;
  v_row record;
begin
  -- (a) The same 20 m takes four seconds: 5 m/s. Legal, and the speed error goes.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0c03';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b12',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0c03', 't_s', 64, 'rev', v_rev));
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b12');
  if v_n <> 2 then
    raise exception 'FAIL 5a: 20 m in four seconds still reports % error(s), expected 2 (the crossings only)', v_n;
  end if;

  -- (b) Back to one second: the pace error returns, same pair, same words.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0c03';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b12',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0c03', 't_s', 61, 'rev', v_rev));
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b12') c;
  if v_n <> 3 or position('faster than running' in v_msg) = 0 then
    raise exception 'FAIL 5b: the pace error did not come back (% error(s): %)', v_n, v_msg;
  end if;

  -- (c) Gate Crew 30 m east instead of 20: still straight through the zone, but the distance rule is the more basic
  --     problem and it is the one reported. One error per pair, not two for the same walk.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0c02';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b12',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0c02', 't_s', 60, 'rev', v_rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3400, 'lng', 103.780270, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3405, 'lng', 103.781180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3420, 'lng', 103.782180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a004', jsonb_build_object('lat', 1.3440, 'lng', 103.783000, 'state', 'on_site'))));
  select * into v_row from public.plan_check('0b000000-0000-4000-8000-000000000b12') c
   where c.group_id = '0b000000-0000-4000-8000-00000000a001';
  if v_row.metres <> 30 or position('the limit is 25 m' in v_row.message) = 0 then
    raise exception 'FAIL 5c: the 30 m crossing reports % m / "%"', v_row.metres, v_row.message;
  end if;
  if position('crosses' in v_row.message) > 0 then
    raise exception 'FAIL 5d: the 30 m walk is reported as a crossing as well: %', v_row.message;
  end if;

  -- (d) Off site: the row is not an endpoint, so the crossing is not reported. The coordinates still cross; only
  --     the claim that anybody walked them has gone.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0c02';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b12',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0c02', 't_s', 60, 'rev', v_rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3400, 'lng', 103.780180, 'state', 'off_site'),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3405, 'lng', 103.781180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3420, 'lng', 103.782180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a004', jsonb_build_object('lat', 1.3440, 'lng', 103.783000, 'state', 'on_site'))));
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b12');
  if v_n <> 2 then
    raise exception 'FAIL 5e: with the crossing group off site the plan reports % error(s), expected 2', v_n;
  end if;

  -- (e) Back on site at the same place: the crossing returns.
  select f.rev into v_rev from public.plan_frames f where f.id = '0b000000-0000-4000-8000-0000000f0c02';
  perform public.frame_save('0b000000-0000-4000-8000-000000000b12',
    jsonb_build_object('id', '0b000000-0000-4000-8000-0000000f0c02', 't_s', 60, 'rev', v_rev,
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.3400, 'lng', 103.780180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a002', jsonb_build_object('lat', 1.3405, 'lng', 103.781180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a003', jsonb_build_object('lat', 1.3420, 'lng', 103.782180, 'state', 'on_site'),
        '0b000000-0000-4000-8000-00000000a004', jsonb_build_object('lat', 1.3440, 'lng', 103.783000, 'state', 'on_site'))));
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b12') c;
  if v_n <> 3 or position('Lane (no-go)' in v_msg) = 0 then
    raise exception 'FAIL 5f: back on site the crossing did not return (% error(s): %)', v_n, v_msg;
  end if;
end $$;

-- ---------- 6. the doors, re-asserted after both functions were re-created ----------
do $$
declare
  v_n integer;
begin
  if has_function_privilege('anon', 'public.plan_check(uuid)', 'execute') then
    raise exception 'FAIL 6a: anon can execute plan_check';
  end if;
  if has_function_privilege('anon', 'public.plan_publish(uuid, integer)', 'execute') then
    raise exception 'FAIL 6b: anon can execute plan_publish';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_check(uuid)', 'execute') then
    raise exception 'FAIL 6c: authenticated cannot execute plan_check';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_publish(uuid, integer)', 'execute') then
    raise exception 'FAIL 6d: authenticated cannot execute plan_publish';
  end if;

  -- Grantee 0 is PUBLIC. A regex on the ACL text is easy to write so it cannot match (the array starts with "{").
  select count(*) into v_n
    from pg_proc p,
         lateral aclexplode(coalesce(p.proacl, '{}'::aclitem[])) a
   where p.oid = 'public.plan_check(uuid)'::regprocedure
     and a.grantee = 0
     and a.privilege_type = 'EXECUTE';
  if v_n > 0 then
    raise exception 'FAIL 6e: plan_check is still granted to PUBLIC: 042''s mistake';
  end if;
  select count(*) into v_n
    from pg_proc p,
         lateral aclexplode(coalesce(p.proacl, '{}'::aclitem[])) a
   where p.oid = 'public.plan_publish(uuid, integer)'::regprocedure
     and a.grantee = 0
     and a.privilege_type = 'EXECUTE';
  if v_n > 0 then
    raise exception 'FAIL 6f: plan_publish is still granted to PUBLIC: 042''s mistake';
  end if;
end $$;

-- ---------- 7. a member still sees only their own group -- and their own zones ----------
do $$
declare
  v_n integer;
  v_msg text;
begin
  -- testuser3 administers Sound, which is the group crossing the obstacle on Geometry bench. Until step 16 their
  -- plan_check computed from the rows they could see, and this section proved the zone query read public.zones
  -- under RLS (a member who could not read the zones would silently see no crossing). 052 closed the plan's frames
  -- to everyone but ops staff, so a member's call now walks nothing -- it still cannot leak another group's crossing,
  -- which is what this asserts, and the planner's count below is the positive control.
  perform set_config('request.jwt.claims', '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}', true);
  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b12') c;
  if v_n <> 0 then
    raise exception 'FAIL 7a: a member''s plan_check returned % error(s), expected none since 052: %', v_n, v_msg;
  end if;

  select count(*), string_agg(c.message, ' | ') into v_n, v_msg
    from public.plan_check('0b000000-0000-4000-8000-000000000b01') c;
  if v_n <> 0 then
    raise exception 'FAIL 7c: the member''s Walkthrough check reads % error(s), expected none since 052: %', v_n, v_msg;
  end if;

  -- And the planner's view is not narrowed by the member's: set back and count again.
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b12');
  if v_n <> 3 then
    raise exception 'FAIL 7d: the planner''s check reads % error(s) after the member''s, expected 3', v_n;
  end if;
end $$;

rollback;

select 'step 11: a walk that clips a no-go zone and a pace faster than running are errors in words, and publishing refuses them' as result;
