-- ============================================================
-- Tests for 074_marshals_are_users.sql: a marshal sees what any other user sees.
--
-- Run in the Supabase SQL Editor AFTER 074, or locally with `node tools/pgtest.mjs`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

create function pg_temp.zz_refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end $$;

-- R root, P planner; group G: A (admin), M (marshal + IC), U; group H: V (IC); N marshal without a group
insert into auth.users (id, email, raw_user_meta_data) values
  ('74000000-0000-0000-0000-000000000001', 'mu-r@example.test', '{"username":"mu_r","display_name":"Mu Root"}'),
  ('74000000-0000-0000-0000-000000000002', 'mu-p@example.test', '{"username":"mu_p","display_name":"Mu Planner"}'),
  ('74000000-0000-0000-0000-000000000003', 'mu-a@example.test', '{"username":"mu_a","display_name":"Mu Admin"}'),
  ('74000000-0000-0000-0000-000000000004', 'mu-m@example.test', '{"username":"mu_m","display_name":"Mu Marshal"}'),
  ('74000000-0000-0000-0000-000000000005', 'mu-u@example.test', '{"username":"mu_u","display_name":"Mu User"}'),
  ('74000000-0000-0000-0000-000000000006', 'mu-v@example.test', '{"username":"mu_v","display_name":"Mu Vee"}'),
  ('74000000-0000-0000-0000-000000000007', 'mu-n@example.test', '{"username":"mu_n","display_name":"Mu None"}');
insert into public.events (id, name, created_by) values ('74000000-0000-0000-0000-0000000000e1', 'Marshal test', '74000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000001', 'root'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000002', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000002', 'planner'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000003', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000004', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000004', 'marshal'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000005', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000006', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000007', 'participant'),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000007', 'marshal')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('74000000-0000-0000-0000-0000000000a1', '74000000-0000-0000-0000-0000000000e1', 'G'),
  ('74000000-0000-0000-0000-0000000000a2', '74000000-0000-0000-0000-0000000000e1', 'H');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('74000000-0000-0000-0000-0000000000a1', '74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000003', true, false),
  ('74000000-0000-0000-0000-0000000000a1', '74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000004', false, true),
  ('74000000-0000-0000-0000-0000000000a1', '74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000005', false, false),
  ('74000000-0000-0000-0000-0000000000a2', '74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-000000000006', false, true);
-- One location in each group
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-0000000000a1', '74000000-0000-0000-0000-000000000004', 1.29, 103.85, 5, 'gps', now()),
  ('74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-0000000000a2', '74000000-0000-0000-0000-000000000006', 1.30, 103.86, 5, 'gps', now());
-- A roll call in the other group
insert into public.attendance_rollcalls (id, event_id, group_id, title, closes_at)
  values ('74000000-0000-0000-0000-0000000000c1', '74000000-0000-0000-0000-0000000000e1', '74000000-0000-0000-0000-0000000000a2', 'H only', now() + interval '10 minutes');

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;
-- "people / group rows / groups / names / locations / roll calls"
create function pg_temp.zz_sees(p_user text) returns text language plpgsql as $$
begin
  perform pg_temp.zz_as(p_user);
  return (select count(distinct user_id) from public.event_roles where event_id = '74000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.group_members where event_id = '74000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.groups where event_id = '74000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.profiles where username like 'mu\_%') || '/' ||
         (select count(*) from public.locations where event_id = '74000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.attendance_rollcalls where event_id = '74000000-0000-0000-0000-0000000000e1');
end $$;

set local role authenticated;

do $$
declare
  t text;
  v_id bigint;
begin
  -- 1. A marshal in a group sees exactly what the plain member beside them sees: that group only
  t := pg_temp.zz_sees('74000000-0000-0000-0000-000000000004');
  if t <> '3/3/1/3/1/0' then raise exception 'FAIL 1: a marshal in a group sees %', t; end if;
  if t <> pg_temp.zz_sees('74000000-0000-0000-0000-000000000005') then
    raise exception 'FAIL 1: a marshal and a member of the same group see different things';
  end if;

  -- 2. A marshal without a group sees only themselves
  t := pg_temp.zz_sees('74000000-0000-0000-0000-000000000007');
  if t <> '1/0/0/1/0/0' then raise exception 'FAIL 2: a marshal without a group sees %', t; end if;

  -- 3. The root and planners still see the whole event; a group admin still has the people and groups (not other
  --    groups' locations or roll calls)
  t := pg_temp.zz_sees('74000000-0000-0000-0000-000000000001');
  if t <> '7/4/2/7/2/1' then raise exception 'FAIL 3: the root sees %', t; end if;
  t := pg_temp.zz_sees('74000000-0000-0000-0000-000000000002');
  if t <> '7/4/2/7/2/1' then raise exception 'FAIL 3: a planner sees %', t; end if;
  t := pg_temp.zz_sees('74000000-0000-0000-0000-000000000003');
  if t <> '7/4/2/7/1/0' then raise exception 'FAIL 3: a group admin sees %', t; end if;

  -- 4. A role check that lists marshals says no to one, and yes to a planner
  perform pg_temp.zz_as('74000000-0000-0000-0000-000000000004');
  if public.has_event_role('74000000-0000-0000-0000-0000000000e1', array['root', 'planner', 'marshal']) then
    raise exception 'FAIL 4: being a marshal still passes a role check';
  end if;
  if public.has_event_role('74000000-0000-0000-0000-0000000000e1', array['marshal']) then
    raise exception 'FAIL 4: being a marshal passes a check for marshals';
  end if;
  perform pg_temp.zz_as('74000000-0000-0000-0000-000000000002');
  if not public.has_event_role('74000000-0000-0000-0000-0000000000e1', array['root', 'planner', 'marshal']) then
    raise exception 'FAIL 4: a planner no longer passes a role check';
  end if;

  -- 5. A marshal still sees every SOS, with the sender's name, and can end one in another group; a plain member cannot
  perform pg_temp.zz_as('74000000-0000-0000-0000-000000000006');
  v_id := public.raise_sos('74000000-0000-0000-0000-0000000000e1', 1.3, 103.8, 10, null);
  perform pg_temp.zz_as('74000000-0000-0000-0000-000000000005');
  if pg_temp.zz_refused(format('select public.resolve_sos(%s)', v_id)) = '' then
    raise exception 'FAIL 5: a plain member ended an SOS in another group';
  end if;
  perform pg_temp.zz_as('74000000-0000-0000-0000-000000000007');
  if not exists (select 1 from public.sos_alerts where id = v_id and sender_name = 'Mu Vee') then
    raise exception 'FAIL 5: a marshal cannot read who sent the SOS';
  end if;
  perform public.resolve_sos(v_id);
  if (select resolution from public.sos_alerts where id = v_id) is distinct from 'handled' then
    raise exception 'FAIL 5: a marshal could not end the SOS';
  end if;

  raise notice 'marshal_user_test: all checks passed';
end $$;

rollback;
