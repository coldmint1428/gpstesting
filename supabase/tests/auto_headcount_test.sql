-- ============================================================
-- Tests for 036_auto_headcount.sql: a group's headcount is the number of people in it.
--
-- Run in the Supabase SQL Editor AFTER 036, or locally with `node tools/pgtest.mjs`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

-- R root; U1, U2, U3; groups G and H
insert into auth.users (id, email, raw_user_meta_data) values
  ('36000000-0000-0000-0000-000000000001', 'hc-r@example.test', '{"username":"hc_r","display_name":"Hc Root"}'),
  ('36000000-0000-0000-0000-000000000002', 'hc-u1@example.test', '{"username":"hc_u1","display_name":"Hc One"}'),
  ('36000000-0000-0000-0000-000000000003', 'hc-u2@example.test', '{"username":"hc_u2","display_name":"Hc Two"}'),
  ('36000000-0000-0000-0000-000000000004', 'hc-u3@example.test', '{"username":"hc_u3","display_name":"Hc Three"}');
insert into public.events (id, name, created_by) values ('36000000-0000-0000-0000-0000000000e1', 'Headcount test', '36000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000001', 'root'),
  ('36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000002', 'participant'),
  ('36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000003', 'participant'),
  ('36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000004', 'participant')
  on conflict do nothing;

create function pg_temp.hc(p_group uuid) returns integer language sql as $$
  select headcount from public.groups where id = p_group
$$;

do $$
begin
  -- 1. A new group counts 0, whatever headcount it is given
  insert into public.groups (id, event_id, name, headcount) values
    ('36000000-0000-0000-0000-0000000000a1', '36000000-0000-0000-0000-0000000000e1', 'G', 40),
    ('36000000-0000-0000-0000-0000000000a2', '36000000-0000-0000-0000-0000000000e1', 'H', null);
  if pg_temp.hc('36000000-0000-0000-0000-0000000000a1') <> 0 or pg_temp.hc('36000000-0000-0000-0000-0000000000a2') <> 0 then
    raise exception 'FAIL 1: a new group does not count 0';
  end if;

  -- 2. People joining count up
  insert into public.group_members (group_id, event_id, user_id) values
    ('36000000-0000-0000-0000-0000000000a1', '36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000002'),
    ('36000000-0000-0000-0000-0000000000a1', '36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000003'),
    ('36000000-0000-0000-0000-0000000000a1', '36000000-0000-0000-0000-0000000000e1', '36000000-0000-0000-0000-000000000004');
  if pg_temp.hc('36000000-0000-0000-0000-0000000000a1') <> 3 then
    raise exception 'FAIL 2: G counts % after 3 joined', pg_temp.hc('36000000-0000-0000-0000-0000000000a1');
  end if;

  -- 3. Moving someone recounts both groups
  update public.group_members set group_id = '36000000-0000-0000-0000-0000000000a2'
  where user_id = '36000000-0000-0000-0000-000000000004';
  if pg_temp.hc('36000000-0000-0000-0000-0000000000a1') <> 2 or pg_temp.hc('36000000-0000-0000-0000-0000000000a2') <> 1 then
    raise exception 'FAIL 3: after a move G counts %, H %', pg_temp.hc('36000000-0000-0000-0000-0000000000a1'), pg_temp.hc('36000000-0000-0000-0000-0000000000a2');
  end if;

  -- 4. Leaving counts down
  delete from public.group_members where user_id = '36000000-0000-0000-0000-000000000003';
  if pg_temp.hc('36000000-0000-0000-0000-0000000000a1') <> 1 then
    raise exception 'FAIL 4: G counts % after one left', pg_temp.hc('36000000-0000-0000-0000-0000000000a1');
  end if;

  -- 5. A headcount typed in is replaced by the count
  update public.groups set headcount = 99 where id = '36000000-0000-0000-0000-0000000000a1';
  if pg_temp.hc('36000000-0000-0000-0000-0000000000a1') <> 1 then
    raise exception 'FAIL 5: a typed headcount was kept';
  end if;

  -- 6. Deleting a group with people in it still works
  delete from public.groups where id = '36000000-0000-0000-0000-0000000000a2';

  raise notice 'auto_headcount_test: all checks passed';
end $$;

rollback;
