-- ============================================================
-- Tests for 084_delete_group.sql: the root or a planner deletes a group; its people stay in the event.
--
-- Run in the Supabase SQL Editor AFTER 084, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner, A admin of G, U member of G; groups G and H
insert into auth.users (id, email, raw_user_meta_data) values
  ('84000000-0000-0000-0000-000000000001', 'dg-r@example.test', '{"username":"dg_r","display_name":"Dg Root"}'),
  ('84000000-0000-0000-0000-000000000002', 'dg-p@example.test', '{"username":"dg_p","display_name":"Dg Planner"}'),
  ('84000000-0000-0000-0000-000000000003', 'dg-a@example.test', '{"username":"dg_a","display_name":"Dg Admin"}'),
  ('84000000-0000-0000-0000-000000000004', 'dg-u@example.test', '{"username":"dg_u","display_name":"Dg User"}');
insert into public.events (id, name, created_by) values ('84000000-0000-0000-0000-0000000000e1', 'Delete group test', '84000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000001', 'root'),
  ('84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000002', 'participant'),
  ('84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000002', 'planner'),
  ('84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000003', 'participant'),
  ('84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000004', 'participant')
  on conflict do nothing;
insert into public.groups (id, event_id, name, colour) values
  ('84000000-0000-0000-0000-0000000000a1', '84000000-0000-0000-0000-0000000000e1', 'G', '#0d6efd'),
  ('84000000-0000-0000-0000-0000000000a2', '84000000-0000-0000-0000-0000000000e1', 'H', '#198754');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('84000000-0000-0000-0000-0000000000a1', '84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000003', true, true),
  ('84000000-0000-0000-0000-0000000000a1', '84000000-0000-0000-0000-0000000000e1', '84000000-0000-0000-0000-000000000004', false, false);

set local role authenticated;

-- 1. A group admin (even of that group) and a member may not delete it
select set_config('request.jwt.claims', '{"sub":"84000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.delete_group('84000000-0000-0000-0000-0000000000a1')$q$) = '' then
    raise exception 'FAIL 1: a group admin deleted their group';
  end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"84000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.delete_group('84000000-0000-0000-0000-0000000000a1')$q$) = '' then
    raise exception 'FAIL 1: a member deleted a group';
  end if;
end $$;

-- 2. A planner deletes a group; its people stay in the event with no group
select set_config('request.jwt.claims', '{"sub":"84000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
do $$
begin
  perform public.delete_group('84000000-0000-0000-0000-0000000000a1');
  if exists (select 1 from public.groups where id = '84000000-0000-0000-0000-0000000000a1') then
    raise exception 'FAIL 2: the group is still there';
  end if;
  if exists (select 1 from public.group_members where group_id = '84000000-0000-0000-0000-0000000000a1') then
    raise exception 'FAIL 2: the group kept its people';
  end if;
  if (select count(*) from public.event_roles where event_id = '84000000-0000-0000-0000-0000000000e1') < 5 then
    raise exception 'FAIL 2: people left the event with their group';
  end if;
  if not exists (select 1 from public.groups where id = '84000000-0000-0000-0000-0000000000a2') then
    raise exception 'FAIL 2: another group went too';
  end if;
end $$;

-- 3. Deleting a group that is already gone is refused cleanly
do $$
begin
  if pg_temp.zz_refused($q$select public.delete_group('84000000-0000-0000-0000-0000000000a1')$q$) = '' then
    raise exception 'FAIL 3: deleting a missing group did not complain';
  end if;
end $$;

-- 4. Refused while the event is live; allowed again once it ends
reset role;
insert into public.event_sessions (event_id, starts_at, started_by) values
  ('84000000-0000-0000-0000-0000000000e1', now() - interval '1 hour', '84000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"84000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.delete_group('84000000-0000-0000-0000-0000000000a2')$q$) = '' then
    raise exception 'FAIL 4: a group was deleted while the event was live';
  end if;
end $$;
reset role;
update public.event_sessions set ended_at = now() where event_id = '84000000-0000-0000-0000-0000000000e1';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"84000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$
begin
  perform public.delete_group('84000000-0000-0000-0000-0000000000a2');
  if exists (select 1 from public.groups where id = '84000000-0000-0000-0000-0000000000a2') then
    raise exception 'FAIL 4: the root could not delete a group once the event ended';
  end if;
end $$;

rollback;
select 'delete_group_test: all checks passed' as result;
