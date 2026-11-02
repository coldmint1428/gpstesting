-- ============================================================
-- Tests for 073_members_see_own_group.sql: ICs and members see only themselves and their own group.
--
-- Run in the Supabase SQL Editor AFTER 073, or locally with `node tools/pgtest.mjs`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

-- R root, M marshal; group G: A (admin), I (IC), U; group H: V; N has no group
insert into auth.users (id, email, raw_user_meta_data) values
  ('39000000-0000-0000-0000-000000000001', 'og-r@example.test', '{"username":"og_r","display_name":"Og Root"}'),
  ('39000000-0000-0000-0000-000000000002', 'og-m@example.test', '{"username":"og_m","display_name":"Og Marshal"}'),
  ('39000000-0000-0000-0000-000000000003', 'og-a@example.test', '{"username":"og_a","display_name":"Og Admin"}'),
  ('39000000-0000-0000-0000-000000000004', 'og-i@example.test', '{"username":"og_i","display_name":"Og Ic"}'),
  ('39000000-0000-0000-0000-000000000005', 'og-u@example.test', '{"username":"og_u","display_name":"Og User"}'),
  ('39000000-0000-0000-0000-000000000006', 'og-v@example.test', '{"username":"og_v","display_name":"Og Vee"}'),
  ('39000000-0000-0000-0000-000000000007', 'og-n@example.test', '{"username":"og_n","display_name":"Og None"}');
insert into public.events (id, name, created_by) values ('39000000-0000-0000-0000-0000000000e1', 'Own group test', '39000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000001', 'root'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000002', 'participant'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000002', 'marshal'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000003', 'participant'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000004', 'participant'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000005', 'participant'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000006', 'participant'),
  ('39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000007', 'participant')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('39000000-0000-0000-0000-0000000000a1', '39000000-0000-0000-0000-0000000000e1', 'G'),
  ('39000000-0000-0000-0000-0000000000a2', '39000000-0000-0000-0000-0000000000e1', 'H');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('39000000-0000-0000-0000-0000000000a1', '39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000003', true, false),
  ('39000000-0000-0000-0000-0000000000a1', '39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000004', false, true),
  ('39000000-0000-0000-0000-0000000000a1', '39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000005', false, false),
  ('39000000-0000-0000-0000-0000000000a2', '39000000-0000-0000-0000-0000000000e1', '39000000-0000-0000-0000-000000000006', false, false);

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;
-- What this person can read: "people in the event / group rows / groups / names"
create function pg_temp.zz_sees(p_user text) returns text language plpgsql as $$
begin
  perform pg_temp.zz_as(p_user);
  return (select count(distinct user_id) from public.event_roles where event_id = '39000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.group_members where event_id = '39000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.groups where event_id = '39000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.profiles where username like 'og\_%');
end $$;

set local role authenticated;

do $$
declare
  t text;
begin
  -- 1. Everyone in the event for the root, a marshal and a group admin: 7 people, 4 group rows, 2 groups, 7 names
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000001');
  if t <> '7/4/2/7' then raise exception 'FAIL 1: the root sees %', t; end if;
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000002');
  if t <> '7/4/2/7' then raise exception 'FAIL 1: a marshal sees %', t; end if;
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000003');
  if t <> '7/4/2/7' then raise exception 'FAIL 1: a group admin sees %', t; end if;

  -- 2. A member and an IC: their group's 3 people, its 3 group rows, 1 group, 3 names
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000005');
  if t <> '3/3/1/3' then raise exception 'FAIL 2: a member sees %', t; end if;
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000004');
  if t <> '3/3/1/3' then raise exception 'FAIL 2: an IC sees %', t; end if;

  -- 3. A member of the other group sees only that group
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000006');
  if t <> '1/1/1/1' then raise exception 'FAIL 3: a member of H sees %', t; end if;
  if exists (select 1 from public.groups where name = 'G') then
    raise exception 'FAIL 3: a member of H sees group G';
  end if;

  -- 4. Someone without a group sees only themselves, and no group
  t := pg_temp.zz_sees('39000000-0000-0000-0000-000000000007');
  if t <> '1/0/0/1' then raise exception 'FAIL 4: someone without a group sees %', t; end if;

  raise notice 'own_group_test: visibility checks passed';
end $$;

-- 5. An SOS reaches people outside the sender's group, with the sender's name and group
do $$
declare
  v_id bigint;
begin
  perform pg_temp.zz_as('39000000-0000-0000-0000-000000000005');
  v_id := public.raise_sos('39000000-0000-0000-0000-0000000000e1', 1.29, 103.85, 10, null);
  perform pg_temp.zz_as('39000000-0000-0000-0000-000000000006');
  if not exists (select 1 from public.sos_alerts where id = v_id and sender_name = 'Og User' and group_name = 'G') then
    raise exception 'FAIL 5: someone in another group cannot read who sent the SOS';
  end if;
  if exists (select 1 from public.profiles where username = 'og_u') then
    raise exception 'FAIL 5: reading the SOS opened the sender''s profile';
  end if;
  raise notice 'own_group_test: all checks passed';
end $$;

rollback;
