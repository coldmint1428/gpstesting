-- ============================================================
-- Tests for 034_planners_not_in_groups.sql: planners are never in a group.
--
-- Run in the Supabase SQL Editor AFTER 034, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner; group G: U1 (only IC), U2, U3
insert into auth.users (id, email, raw_user_meta_data) values
  ('34000000-0000-0000-0000-000000000001', 'pl-r@example.test', '{"username":"pl_r","display_name":"Pl Root"}'),
  ('34000000-0000-0000-0000-000000000002', 'pl-p@example.test', '{"username":"pl_p","display_name":"Pl Planner"}'),
  ('34000000-0000-0000-0000-000000000003', 'pl-u1@example.test', '{"username":"pl_u1","display_name":"Pl One"}'),
  ('34000000-0000-0000-0000-000000000004', 'pl-u2@example.test', '{"username":"pl_u2","display_name":"Pl Two"}'),
  ('34000000-0000-0000-0000-000000000005', 'pl-u3@example.test', '{"username":"pl_u3","display_name":"Pl Three"}');
insert into public.events (id, name, created_by) values ('34000000-0000-0000-0000-0000000000e1', 'Planners test', '34000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000001', 'root'),
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000002', 'participant'),
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000002', 'planner'),
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000003', 'participant'),
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000004', 'participant'),
  ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000005', 'participant')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values ('34000000-0000-0000-0000-0000000000a1', '34000000-0000-0000-0000-0000000000e1', 'G');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('34000000-0000-0000-0000-0000000000a1', '34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000003', false, true),
  ('34000000-0000-0000-0000-0000000000a1', '34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000004', false, false),
  ('34000000-0000-0000-0000-0000000000a1', '34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000005', false, false);

-- 1. Even the database owner cannot give someone in a group a planner row
do $$
begin
  if pg_temp.zz_refused($q$insert into public.event_roles (event_id, user_id, role)
                           values ('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000004', 'planner')$q$) = '' then
    raise exception 'FAIL 1: someone in a group got a planner row';
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"34000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

do $$
begin
  -- 2. A planner cannot be put in a group
  if pg_temp.zz_refused($q$select public.assign_group('34000000-0000-0000-0000-0000000000e1',
                           '34000000-0000-0000-0000-000000000002', '34000000-0000-0000-0000-0000000000a1')$q$) = '' then
    raise exception 'FAIL 2: a planner was put in a group';
  end if;

  -- 3. Making someone a planner takes them out of their group
  perform public.set_member_role('34000000-0000-0000-0000-0000000000e1', '34000000-0000-0000-0000-000000000004', 'planner');
  if exists (select 1 from public.group_members where user_id = '34000000-0000-0000-0000-000000000004')
     or not exists (select 1 from public.event_roles where user_id = '34000000-0000-0000-0000-000000000004' and role = 'planner') then
    raise exception 'FAIL 3: the new planner is still in a group, or is not a planner';
  end if;

  -- 4. ...but not the group's only IC while others are in it
  if pg_temp.zz_refused($q$select public.set_member_role('34000000-0000-0000-0000-0000000000e1',
                           '34000000-0000-0000-0000-000000000003', 'planner')$q$) = '' then
    raise exception 'FAIL 4: the only IC was made a planner';
  end if;
  if not exists (select 1 from public.group_members where user_id = '34000000-0000-0000-0000-000000000003' and is_ic) then
    raise exception 'FAIL 4: the only IC left the group';
  end if;

  -- 5. The wizard refuses a planner in a group
  if pg_temp.zz_refused($q$select public.create_event_with_setup(
       '{"name":"Wizard","starts_at":"2026-11-01T01:00:00Z","ends_at":"2026-11-01T09:00:00Z"}',
       '[{"user_id":"34000000-0000-0000-0000-000000000005","role":"planner"}]',
       '[{"name":"W","colour":"#0d6efd","members":[{"user_id":"34000000-0000-0000-0000-000000000005","is_admin":false,"is_ic":true}]}]')$q$) = '' then
    raise exception 'FAIL 5: the wizard put a planner in a group';
  end if;

  raise notice 'planners_test: all checks passed';
end $$;

rollback;
