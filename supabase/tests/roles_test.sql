-- supabase/tests/roles_test.sql -- 031_people_and_roles.sql: profiles, the role hierarchy, IC and removing people.
--
-- Runs locally with `node tools/pgtest.mjs roles` (001, 002, 030 and 031 on an empty PGlite) and in the Supabase SQL Editor
-- after 031. One transaction that ends in ROLLBACK: the test accounts, event and groups disappear.
-- Each check raises 'FAIL n: ...'.
--
-- Event "Roles test": root R, planners P and P2, M (a member with the marshal duty), Group 1 (admin A, IC U1, member U2),
-- Group 2 (admin A2, IC U3), member U4 with no group; X is not in the event.
begin;

-- event_sessions comes from 007 (pg_cron, not available locally); my_event_membership only reads it
create table if not exists public.event_sessions (event_id uuid, starts_at timestamptz, ended_at timestamptz);

create function pg_temp.zz_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

-- the error a statement is refused with ('' when it runs)
create function pg_temp.zz_err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end $$;

do $test$
declare
  ev uuid := 'eeeeeeee-0000-0000-0000-000000000001';
  g1 uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  g2 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  r uuid := '10000000-0000-0000-0000-000000000001';
  p uuid := '10000000-0000-0000-0000-000000000002';
  p2 uuid := '10000000-0000-0000-0000-000000000003';
  m uuid := '10000000-0000-0000-0000-000000000004';
  a uuid := '10000000-0000-0000-0000-000000000005';
  a2 uuid := '10000000-0000-0000-0000-000000000006';
  u1 uuid := '10000000-0000-0000-0000-000000000007';
  u2 uuid := '10000000-0000-0000-0000-000000000008';
  u3 uuid := '10000000-0000-0000-0000-000000000009';
  u4 uuid := '10000000-0000-0000-0000-00000000000a';
  x uuid := '10000000-0000-0000-0000-00000000000b';
  e text;
  j jsonb;
  passed integer := 0;
begin
  -- ---------- setup (as the owner) ----------
  insert into auth.users (id, email, raw_user_meta_data)
  select id, uname || '@example.test', jsonb_build_object('username', uname, 'first_name', fname, 'last_name', 'Test')
  from (values (r, 'roles_root', 'Rita'), (p, 'roles_planner', 'Pat'), (p2, 'roles_planner2', 'Pam'),
               (m, 'roles_marshal', 'Max'), (a, 'roles_admin', 'Ada'), (a2, 'roles_admin2', 'Abe'),
               (u1, 'roles_u1', 'Uma'), (u2, 'roles_u2', 'Ugo'), (u3, 'roles_u3', 'Uli'), (u4, 'roles_u4', 'Una'),
               (x, 'roles_outsider', 'Xan')) v (id, uname, fname);
  -- an older client sends display_name only
  insert into auth.users (id, email, raw_user_meta_data)
  values ('10000000-0000-0000-0000-0000000000ff', 'old@example.test', '{"username":"Roles_Old","display_name":"Old Client"}');

  insert into public.events (id, name, created_by) values (ev, 'Roles test', r);
  insert into public.event_roles (event_id, user_id, role) values
    (ev, r, 'root'), (ev, p, 'planner'), (ev, p, 'participant'), (ev, p2, 'planner'),
    (ev, m, 'marshal'), (ev, m, 'participant'), (ev, a, 'participant'), (ev, a2, 'participant'),
    (ev, u1, 'participant'), (ev, u2, 'participant'), (ev, u3, 'participant'), (ev, u4, 'participant');
  insert into public.groups (id, event_id, name) values (g1, ev, 'Group 1'), (g2, ev, 'Group 2');
  insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
    (g1, ev, a, true, false), (g1, ev, u1, false, true), (g1, ev, u2, false, false),
    (g2, ev, a2, true, false), (g2, ev, u3, false, true);

  -- ---------- 1. profiles ----------
  if (select display_name || '|' || first_name || '|' || last_name from public.profiles where id = r) <> 'Rita Test|Rita|Test' then
    raise exception 'FAIL 1: sign-up did not save first / last name and display name';
  end if;
  if (select username || '|' || display_name from public.profiles where id = '10000000-0000-0000-0000-0000000000ff')
     <> 'roles_old|Old Client' then
    raise exception 'FAIL 1: an old client''s display_name sign-up changed';
  end if;
  passed := passed + 1;

  if public.login_email(' ROLES_U1 ') <> 'roles_u1@example.test' or public.login_email('nobody_here') is not null then
    raise exception 'FAIL 2: login_email';
  end if;
  passed := passed + 1;

  perform pg_temp.zz_as(u1);
  update public.profiles set first_name = ' Zed ', last_name = 'Q' where id = u1;
  update public.profiles set first_name = 'Hacker' where id = u2; -- someone else's row: RLS, nothing changes
  e := pg_temp.zz_err($$update public.profiles set created_at = now() where id = '10000000-0000-0000-0000-000000000007'$$);
  if e not like '%permission denied%' then raise exception 'FAIL 3: created_at could be changed (%)', e; end if;
  e := pg_temp.zz_err($$update public.profiles set username = 'Bad Name!' where id = '10000000-0000-0000-0000-000000000007'$$);
  if e = '' then raise exception 'FAIL 3: an invalid username was saved'; end if;
  reset role;
  if (select display_name from public.profiles where id = u1) <> 'Zed Q'
     or (select first_name from public.profiles where id = u2) <> 'Ugo' then
    raise exception 'FAIL 3: profile edit (own row, names, display name)';
  end if;
  passed := passed + 1;

  -- ---------- 2. top roles ----------
  if public.member_top_role(ev, r) <> 'root' or public.member_top_role(ev, p) <> 'planner'
     or public.member_top_role(ev, m) <> 'member' or public.member_top_role(ev, a) <> 'admin'
     or public.member_top_role(ev, u1) <> 'member' or public.member_top_role(ev, x) is not null then
    raise exception 'FAIL 4: member_top_role';
  end if;
  perform pg_temp.zz_as(a);
  j := public.my_event_membership(ev);
  if j ->> 'role' <> 'admin' or (j ->> 'group_id')::uuid <> g1 or (j ->> 'live')::boolean then
    raise exception 'FAIL 4: my_event_membership as admin: %', j;
  end if;
  perform pg_temp.zz_as(x);
  if public.my_event_membership(ev) is not null then raise exception 'FAIL 4: an outsider got a membership'; end if;
  reset role;
  passed := passed + 1;

  -- ---------- 3. set_member_role ----------
  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u2, 'planner'));
  if e <> 'You can only give roles below your own' then raise exception 'FAIL 5: planner made a planner (%)', e; end if;
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, p2, 'member'));
  if e <> 'You can only change the role of people below you' then raise exception 'FAIL 5: planner demoted a planner (%)', e; end if;
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, r, 'member'));
  if e <> 'You can only change the role of people below you' then raise exception 'FAIL 5: planner touched the root (%)', e; end if;
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, p, 'member'));
  if e <> 'You cannot change your own role' then raise exception 'FAIL 5: own role (%)', e; end if;
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u4, 'admin'));
  if e not like 'Put them in a group first%' then raise exception 'FAIL 5: admin without a group (%)', e; end if;
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u2, 'root'));
  if e not like 'Role must be%' then raise exception 'FAIL 5: made a root (%)', e; end if;
  perform public.set_member_role(ev, u2, 'admin');
  reset role;
  if public.member_top_role(ev, u2) <> 'admin' then raise exception 'FAIL 5: u2 is not admin'; end if;
  passed := passed + 1;

  -- marshal is a duty, not a role: on / off by root / planners, kept when the role changes below planner
  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u2, 'marshal'));
  if e not like 'Role must be%' then raise exception 'FAIL 6: marshal given as a role (%)', e; end if;
  perform public.set_marshal(ev, u2, true);
  perform public.set_member_role(ev, u2, 'member');
  reset role;
  if public.member_top_role(ev, u2) <> 'member'
     or (select is_admin from public.group_members where user_id = u2)
     or not exists (select 1 from public.event_roles where event_id = ev and user_id = u2 and role = 'marshal') then
    raise exception 'FAIL 6: admin -> member kept the admin flag, or lost the marshal duty';
  end if;
  perform pg_temp.zz_as(a);
  e := pg_temp.zz_err(format('select public.set_marshal(%L, %L, false)', ev, u2));
  if e <> 'Only the root and planners can make marshals' then raise exception 'FAIL 6: admin unset marshal (%)', e; end if;
  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.set_marshal(%L, %L, true)', ev, p2));
  if e <> 'You can only change people below you' then raise exception 'FAIL 6: planner made a planner marshal (%)', e; end if;
  perform public.set_marshal(ev, u2, false);
  perform public.set_marshal(ev, m, true);
  perform pg_temp.zz_as(r);
  perform public.set_member_role(ev, m, 'planner'); -- a planner is no longer also a marshal
  reset role;
  if exists (select 1 from public.event_roles where event_id = ev and user_id = m and role = 'marshal') then
    raise exception 'FAIL 6: a new planner kept the marshal row';
  end if;
  perform pg_temp.zz_as(r);
  perform public.set_member_role(ev, m, 'member');
  perform public.set_marshal(ev, m, true);
  perform pg_temp.zz_as(m);
  j := public.my_event_membership(ev);
  reset role;
  if exists (select 1 from public.event_roles where event_id = ev and user_id = u2 and role = 'marshal')
     or j ->> 'role' <> 'member' or not (j ->> 'is_marshal')::boolean then
    raise exception 'FAIL 6: marshal off / back on: %', j;
  end if;
  passed := passed + 1;

  -- root demotes a planner who had no participant row: still in the event
  perform pg_temp.zz_as(r);
  perform public.set_member_role(ev, p2, 'member');
  reset role;
  if public.member_top_role(ev, p2) <> 'member' then raise exception 'FAIL 7: demoted planner left the event'; end if;
  passed := passed + 1;

  -- admins and marshals give no roles
  perform pg_temp.zz_as(a);
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u2, 'member'));
  if e <> 'Only the root and planners can change roles' then raise exception 'FAIL 8: admin changed a role (%)', e; end if;
  perform pg_temp.zz_as(m);
  e := pg_temp.zz_err(format('select public.set_member_role(%L, %L, %L)', ev, u2, 'member'));
  if e <> 'Only the root and planners can change roles' then raise exception 'FAIL 8: marshal changed a role (%)', e; end if;
  reset role;
  passed := passed + 1;

  -- ---------- 4. set_group_ic ----------
  perform pg_temp.zz_as(a);
  perform public.set_group_ic(g1, u2, true);
  e := pg_temp.zz_err(format('select public.set_group_ic(%L, %L, false)', g2, u3));
  if e <> 'Admins can only manage their own group' then raise exception 'FAIL 9: admin in another group (%)', e; end if;
  perform pg_temp.zz_as(u1);
  e := pg_temp.zz_err(format('select public.set_group_ic(%L, %L, false)', g1, u2));
  if e not like 'Only the root, planners and group admins%' then raise exception 'FAIL 9: member set IC (%)', e; end if;
  reset role;
  if not (select is_ic from public.group_members where user_id = u2) then raise exception 'FAIL 9: u2 is not IC'; end if;
  passed := passed + 1;

  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.set_group_ic(%L, %L, false)', g2, u3));
  if e <> 'Each group needs at least one IC. Make someone else IC first.' then raise exception 'FAIL 10: last IC unset (%)', e; end if;
  perform public.set_group_ic(g2, a2, true); -- an admin may be IC too (repo rule)
  perform public.set_group_ic(g2, u3, false);
  perform public.set_group_ic(g2, u3, false); -- already not IC: fine
  reset role;
  passed := passed + 1;

  -- ---------- 5. removing people ----------
  perform pg_temp.zz_as(a);
  e := pg_temp.zz_err(format('select public.remove_event_member(%L, %L)', ev, u3));
  if e <> 'Admins can only manage their own group' then raise exception 'FAIL 11: admin removed from another group (%)', e; end if;
  e := pg_temp.zz_err(format('select public.remove_event_member(%L, %L)', ev, a));
  if e <> 'You cannot remove yourself here' then raise exception 'FAIL 11: removed self (%)', e; end if;
  perform public.remove_event_member(ev, u2);
  perform pg_temp.zz_as(m);
  e := pg_temp.zz_err(format('select public.remove_event_member(%L, %L)', ev, u1));
  if e <> 'You can only remove people below you' then raise exception 'FAIL 11: marshal removed someone (%)', e; end if;
  reset role;
  if public.member_top_role(ev, u2) is not null then raise exception 'FAIL 11: u2 still in the event'; end if;
  passed := passed + 1;

  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.remove_event_member(%L, %L)', ev, u1));
  if e <> 'That person is the group''s only IC. Make someone else IC first.' then raise exception 'FAIL 12: only IC removed (%)', e; end if;
  -- the old remove_member follows the same rules for someone else
  e := pg_temp.zz_err(format('select public.remove_member(%L, %L)', ev, r));
  if e <> 'You can only remove people below you' then raise exception 'FAIL 12: planner removed the root (%)', e; end if;
  perform public.remove_member(ev, u4);
  -- leaving yourself still works
  perform pg_temp.zz_as(m);
  perform public.remove_member(ev, m);
  perform pg_temp.zz_as(r);
  e := pg_temp.zz_err(format('select public.remove_member(%L, %L)', ev, r));
  if e not like 'The root cannot leave%' then raise exception 'FAIL 12: root left (%)', e; end if;
  reset role;
  if public.member_top_role(ev, u4) is not null or public.member_top_role(ev, m) is not null then
    raise exception 'FAIL 12: remove / leave';
  end if;
  passed := passed + 1;

  -- ---------- 6. the old set_group_flags follows the rules ----------
  perform pg_temp.zz_as(a);
  e := pg_temp.zz_err(format('select public.set_group_flags(%L, %L, true, true)', g1, u1));
  if e <> 'Only the root and planners can change roles' then raise exception 'FAIL 13: admin made an admin (%)', e; end if;
  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.set_group_flags(%L, %L, false, false)', g1, u1));
  if e <> 'Each group needs at least one IC. Make someone else IC first.' then raise exception 'FAIL 13: flags unset last IC (%)', e; end if;
  reset role;
  passed := passed + 1;

  -- ---------- 7. event details ----------
  perform pg_temp.zz_as(p);
  e := pg_temp.zz_err(format('select public.delete_event(%L)', ev));
  if e <> 'Only the root can delete the event' then raise exception 'FAIL 14: planner deleted (%)', e; end if;
  e := pg_temp.zz_err(format('select public.rename_event(%L, %L)', ev, 'Nope'));
  if e not like 'Only the root%' then raise exception 'FAIL 14: planner renamed (%)', e; end if;
  perform pg_temp.zz_as(r);
  perform public.rename_event(ev, '  Renamed  ');
  reset role;
  if (select name from public.events where id = ev) <> 'Renamed' then raise exception 'FAIL 14: rename'; end if;
  perform pg_temp.zz_as(r);
  perform public.delete_event(ev);
  reset role;
  if exists (select 1 from public.events where id = ev) or exists (select 1 from public.group_members where event_id = ev) then
    raise exception 'FAIL 14: delete';
  end if;
  passed := passed + 1;

  raise notice 'roles_test: all % checks passed', passed;
end $test$;

rollback;
