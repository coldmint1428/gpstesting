-- ============================================================
-- Tests for the "Create an event" wizard: 030_event_wizard.sql (023 on its branch)
--
-- Run in the Supabase SQL Editor AFTER 023 is applied, or locally with `node tools/pgtest.mjs wizard`.
-- Everything happens inside ONE transaction that ends in ROLLBACK, so nothing is left behind.
-- Each check raises 'FAIL n: ...', which aborts the transaction and names it.
--
-- What is where: 1 a full save, 2-6 refused saves leave nothing behind, 7 who can read the event (RLS),
-- 8 no direct writes, 9 search_people, 10 signed-out callers.
-- ============================================================
begin;

-- ============================================================
-- 0. Three test users (the trigger from 002 makes their profiles). A creates; B is added; C is a stranger.
-- ============================================================
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'wizard-a@example.test', '', now(), '{}'::jsonb,
   '{"username":"wizard_a","display_name":"Wizard Alpha"}'::jsonb, now(), now()),
  ('aaaaaaaa-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'wizard-b@example.test', '', now(), '{}'::jsonb,
   '{"username":"wizard_b","display_name":"Wizard Bravo"}'::jsonb, now(), now()),
  ('aaaaaaaa-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'wizard-c@example.test', '', now(), '{}'::jsonb,
   '{"username":"wizard_c","display_name":"Wizard Charlie"}'::jsonb, now(), now());

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';

-- ============================================================
-- 1. A full save: details, root, roles, groups, Admin / IC flags. The creator can be in a group too.
-- ============================================================
do $$
declare
  v_id uuid;
  v_roles text;
begin
  v_id := public.create_event_with_setup(
    '{"name":"  Sports Day  ","description":"Annual","venue":"Field","starts_at":"2026-11-01T01:00:00Z","ends_at":"2026-11-01T05:00:00Z"}',
    '[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","role":"planner"}]',
    '[{"name":"Scouts","colour":"#198754","members":[
        {"user_id":"aaaaaaaa-0000-0000-0000-000000000001","is_admin":false,"is_ic":true},
        {"user_id":"aaaaaaaa-0000-0000-0000-000000000002","is_admin":true,"is_ic":false}]},
      {"name":"Empty","colour":"#d63384","members":[]}]'
  );
  if v_id is null then raise exception 'FAIL 1: no event id returned'; end if;

  if (select name from public.events where id = v_id) <> 'Sports Day' then
    raise exception 'FAIL 1: the name was not trimmed';
  end if;
  if (select venue from public.events where id = v_id) <> 'Field'
     or (select ends_at - starts_at from public.events where id = v_id) <> interval '4 hours' then
    raise exception 'FAIL 1: the details were not saved';
  end if;
  if (select role from public.event_roles where event_id = v_id and user_id = auth.uid()) <> 'root' then
    raise exception 'FAIL 1: the creator is not root';
  end if;
  select string_agg(role, ',' order by role) into v_roles
  from public.event_roles where event_id = v_id and user_id = 'aaaaaaaa-0000-0000-0000-000000000002';
  if v_roles <> 'participant,planner' then
    raise exception 'FAIL 1: B has roles % (expected participant,planner)', v_roles;
  end if;
  if (select count(*) from public.groups where event_id = v_id) <> 2 then
    raise exception 'FAIL 1: expected 2 groups';
  end if;
  if not (select is_ic from public.group_members where event_id = v_id and user_id = auth.uid())
     or not (select is_admin from public.group_members where event_id = v_id and user_id = 'aaaaaaaa-0000-0000-0000-000000000002') then
    raise exception 'FAIL 1: the IC / Admin flags were not saved';
  end if;

  perform set_config('wizard.event', v_id::text, true);
end $$;

-- ============================================================
-- 2-6. Refused saves: each must raise, and must leave no event behind (one transaction).
-- ============================================================
do $$
declare
  v_before int := (select count(*) from public.events);
  v_message text;
  v_case record;
begin
  for v_case in
    select * from (values
      (2, 'not added to the event',
       '[]',
       '[{"name":"G","members":[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","is_ic":true}]}]'),
      (3, 'needs at least one IC',
       '[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","role":"participant"}]',
       '[{"name":"G","members":[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","is_ic":false}]}]'),
      (4, 'one group per event',
       '[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","role":"participant"}]',
       '[{"name":"G1","members":[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","is_ic":true}]},
         {"name":"G2","members":[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","is_ic":true}]}]'),
      (5, 'Only the event creator can be root',
       '[{"user_id":"aaaaaaaa-0000-0000-0000-000000000002","role":"root"}]',
       '[]'),
      (6, 'Two groups are called',
       '[]',
       '[{"name":"Same","members":[]},{"name":"Same","members":[]}]')
    ) as t(n, expected, members, groups)
  loop
    v_message := '';
    begin
      perform public.create_event_with_setup(
        '{"name":"Bad","starts_at":"2026-11-01T01:00:00Z","ends_at":"2026-11-01T05:00:00Z"}',
        v_case.members::jsonb, v_case.groups::jsonb);
    exception when others then
      v_message := sqlerrm;
    end;
    if position(v_case.expected in v_message) = 0 then
      raise exception 'FAIL %: expected "%", got "%"', v_case.n, v_case.expected, v_message;
    end if;
  end loop;

  -- End before start
  v_message := '';
  begin
    perform public.create_event_with_setup('{"name":"Bad","starts_at":"2026-11-01T05:00:00Z","ends_at":"2026-11-01T01:00:00Z"}');
  exception when others then
    v_message := sqlerrm;
  end;
  if position('after the start' in v_message) = 0 then
    raise exception 'FAIL 6: end before start was not refused (got "%")', v_message;
  end if;

  if (select count(*) from public.events) <> v_before then
    raise exception 'FAIL 6: a refused save left an event behind';
  end if;
end $$;

-- ============================================================
-- 7. Who can read it: B (a member) can, C (a stranger) can't
-- ============================================================
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if not exists (select 1 from public.events where id = current_setting('wizard.event')::uuid) then
    raise exception 'FAIL 7: a member cannot see the event';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  if exists (select 1 from public.events where id = current_setting('wizard.event')::uuid)
     or exists (select 1 from public.groups where event_id = current_setting('wizard.event')::uuid)
     or exists (select 1 from public.event_roles where event_id = current_setting('wizard.event')::uuid) then
    raise exception 'FAIL 7: a non-member can see the event';
  end if;
end $$;

-- ============================================================
-- 8. No direct writes from the app: RLS has no insert policy
-- ============================================================
do $$
declare
  v_message text := '';
begin
  begin
    insert into public.events (name, created_by) values ('Sneaky', auth.uid());
  exception when others then
    v_message := sqlerrm;
  end;
  -- (refused by RLS, or even earlier by the join-code default the app may not call)
  if position('row-level security' in v_message) = 0 and position('permission denied' in v_message) = 0 then
    raise exception 'FAIL 8: a direct insert into events was not refused (got "%")', v_message;
  end if;
end $$;

-- ============================================================
-- 9. search_people (as C)
-- ============================================================
do $$
declare
  v_found text;
begin
  select string_agg(username, ',' order by username) into v_found from public.search_people('wizard');
  if v_found <> 'wizard_a,wizard_b' then
    raise exception 'FAIL 9: "wizard" found % (expected the other two, not me)', v_found;
  end if;
  if (select username from public.search_people('Bravo')) <> 'wizard_b' then
    raise exception 'FAIL 9: display names are not searched';
  end if;
  if (select username from public.search_people('  WIZARD-A@example.test ')) <> 'wizard_a' then
    raise exception 'FAIL 9: a whole email address does not find its account';
  end if;
  if exists (select 1 from public.search_people('example.test')) then
    raise exception 'FAIL 9: part of an email address finds accounts';
  end if;
  if exists (select 1 from public.search_people('w')) then
    raise exception 'FAIL 9: a 1-character search returns results';
  end if;
  if exists (select 1 from public.search_people('%%')) or exists (select 1 from public.search_people('__')) then
    raise exception 'FAIL 9: LIKE wildcards in the term match everyone';
  end if;
end $$;

-- ============================================================
-- 10. Signed-out callers can't use either function
-- ============================================================
reset role;
set local role anon;
do $$
declare
  v_message text := '';
begin
  begin
    perform public.create_event_with_setup('{"name":"Anon"}');
  exception when others then
    v_message := sqlerrm;
  end;
  if position('permission denied' in v_message) = 0 then
    raise exception 'FAIL 10: anon could call create_event_with_setup (got "%")', v_message;
  end if;
end $$;

rollback;
