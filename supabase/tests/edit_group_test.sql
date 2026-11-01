-- ============================================================
-- Tests for 035_edit_group.sql: the root or a planner renames a group and changes its colour.
--
-- Run in the Supabase SQL Editor AFTER 035, or locally with `node tools/pgtest.mjs`.
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
  ('35000000-0000-0000-0000-000000000001', 'eg-r@example.test', '{"username":"eg_r","display_name":"Eg Root"}'),
  ('35000000-0000-0000-0000-000000000002', 'eg-p@example.test', '{"username":"eg_p","display_name":"Eg Planner"}'),
  ('35000000-0000-0000-0000-000000000003', 'eg-a@example.test', '{"username":"eg_a","display_name":"Eg Admin"}'),
  ('35000000-0000-0000-0000-000000000004', 'eg-u@example.test', '{"username":"eg_u","display_name":"Eg User"}');
insert into public.events (id, name, created_by) values ('35000000-0000-0000-0000-0000000000e1', 'Edit group test', '35000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000001', 'root'),
  ('35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000002', 'participant'),
  ('35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000002', 'planner'),
  ('35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000003', 'participant'),
  ('35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000004', 'participant')
  on conflict do nothing;
insert into public.groups (id, event_id, name, colour) values
  ('35000000-0000-0000-0000-0000000000a1', '35000000-0000-0000-0000-0000000000e1', 'G', '#0d6efd'),
  ('35000000-0000-0000-0000-0000000000a2', '35000000-0000-0000-0000-0000000000e1', 'H', '#198754');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('35000000-0000-0000-0000-0000000000a1', '35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000003', true, true),
  ('35000000-0000-0000-0000-0000000000a1', '35000000-0000-0000-0000-0000000000e1', '35000000-0000-0000-0000-000000000004', false, false);

set local role authenticated;

-- As the root
select set_config('request.jwt.claims', '{"sub":"35000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$
begin
  -- 1. The root renames and recolours a group (name trimmed, colour stored in lower case)
  perform public.update_group('35000000-0000-0000-0000-0000000000a1', '  Gold  ', '#FFC107');
  if not exists (select 1 from public.groups where id = '35000000-0000-0000-0000-0000000000a1' and name = 'Gold' and colour = '#ffc107') then
    raise exception 'FAIL 1: the group was not renamed / recoloured';
  end if;

  -- 2. Two groups cannot share a name (case does not matter)
  if pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a2', 'gold', '#198754')$q$) = '' then
    raise exception 'FAIL 2: two groups got the same name';
  end if;

  -- 3. Empty or too-long names, and a colour that is not #rrggbb, are refused
  if pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a2', '   ', '#198754')$q$) = ''
     or pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a2', repeat('x', 51), '#198754')$q$) = ''
     or pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a2', 'H', 'red')$q$) = '' then
    raise exception 'FAIL 3: a bad name or colour was saved';
  end if;

  -- 4. Keeping its own name (only the colour changes) is fine
  perform public.update_group('35000000-0000-0000-0000-0000000000a2', 'H', '#dc3545');
  if not exists (select 1 from public.groups where id = '35000000-0000-0000-0000-0000000000a2' and colour = '#dc3545') then
    raise exception 'FAIL 4: the colour alone did not change';
  end if;
end $$;

-- 5. A planner may too
select set_config('request.jwt.claims', '{"sub":"35000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
do $$
begin
  perform public.update_group('35000000-0000-0000-0000-0000000000a2', 'Harbour', '#dc3545');
  if not exists (select 1 from public.groups where id = '35000000-0000-0000-0000-0000000000a2' and name = 'Harbour') then
    raise exception 'FAIL 5: a planner could not rename a group';
  end if;
end $$;

-- 6. A group admin (even of that group) and a member may not
select set_config('request.jwt.claims', '{"sub":"35000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a1', 'Mine', '#000000')$q$) = '' then
    raise exception 'FAIL 6: a group admin renamed their group';
  end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"35000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.update_group('35000000-0000-0000-0000-0000000000a1', 'Mine', '#000000')$q$) = '' then
    raise exception 'FAIL 6: a member renamed their group';
  end if;

  raise notice 'edit_group_test: all checks passed';
end $$;

rollback;
