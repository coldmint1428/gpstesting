-- ============================================================
-- Tests for 032_people_search_by_name.sql: search_people by name (with email), add_event_member.
--
-- Run in the Supabase SQL Editor AFTER 032, or locally with `node tools/pgtest.mjs`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

-- A plans; B and B2 share a name; C is a stranger
insert into auth.users (id, email, raw_user_meta_data) values
  ('32000000-0000-0000-0000-000000000001', 'search-a@example.test', '{"username":"search_a","display_name":"Searcher Alpha"}'),
  ('32000000-0000-0000-0000-000000000002', 'search-b@example.test', '{"username":"search_b","display_name":"Sam Same"}'),
  ('32000000-0000-0000-0000-000000000003', 'search-b2@example.test', '{"username":"search_b2","display_name":"Sam Same"}'),
  ('32000000-0000-0000-0000-000000000004', 'search-c@example.test', '{"username":"search_c","display_name":"Stranger Charlie"}');
insert into public.events (id, name, created_by) values ('32000000-0000-0000-0000-0000000000e1', 'Search test', '32000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('32000000-0000-0000-0000-0000000000e1', '32000000-0000-0000-0000-000000000001', 'root')
  on conflict do nothing;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"32000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

do $$
declare
  v_found text;
begin
  -- 1. Two people with the same name both come back, each with their own email
  select string_agg(email, ',' order by email) into v_found from public.search_people('sam same');
  if v_found <> 'search-b2@example.test,search-b@example.test' then
    raise exception 'FAIL 1: "sam same" found % (expected both, with emails)', v_found;
  end if;
  -- 2. Usernames and emails are not searched any more; nor am I
  if exists (select 1 from public.search_people('search_b')) then raise exception 'FAIL 2: usernames are searched'; end if;
  if exists (select 1 from public.search_people('search-c@example.test')) then raise exception 'FAIL 2: emails are searched'; end if;
  if exists (select 1 from public.search_people('Searcher')) then raise exception 'FAIL 2: found myself'; end if;
  -- 3. Short terms and LIKE wildcards
  if exists (select 1 from public.search_people('s')) then raise exception 'FAIL 3: 1 character returns results'; end if;
  if exists (select 1 from public.search_people('%%')) or exists (select 1 from public.search_people('__')) then
    raise exception 'FAIL 3: LIKE wildcards match everyone';
  end if;
  -- 4. The root adds someone by id
  perform public.add_event_member('32000000-0000-0000-0000-0000000000e1', '32000000-0000-0000-0000-000000000003', null);
  if not exists (select 1 from public.event_roles where event_id = '32000000-0000-0000-0000-0000000000e1'
                 and user_id = '32000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL 4: add_event_member did not add';
  end if;
end $$;

-- 5. A stranger cannot add people
select set_config('request.jwt.claims', '{"sub":"32000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.add_event_member('32000000-0000-0000-0000-0000000000e1', '32000000-0000-0000-0000-000000000002', null);
    raise exception 'FAIL 5: a stranger added someone';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  raise notice 'people_search_test: all checks passed';
end $$;

rollback;
