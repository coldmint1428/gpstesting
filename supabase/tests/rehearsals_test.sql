-- ============================================================
-- Tests for 079_rehearsals.sql: everyone in an event reads its rehearsals; only the root and planners add or remove them.
--
-- Run in the Supabase SQL Editor AFTER 079, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner, M plain participant, A group admin, I IC, B member; O is in another event
insert into auth.users (id, email, raw_user_meta_data) values
  ('77000000-0000-0000-0000-000000000001', 're-r@example.test', '{"username":"re_r","display_name":"Re Root"}'),
  ('77000000-0000-0000-0000-000000000002', 're-p@example.test', '{"username":"re_p","display_name":"Re Planner"}'),
  ('77000000-0000-0000-0000-000000000003', 're-m@example.test', '{"username":"re_m","display_name":"Re Marshal"}'),
  ('77000000-0000-0000-0000-000000000004', 're-a@example.test', '{"username":"re_a","display_name":"Re Admin"}'),
  ('77000000-0000-0000-0000-000000000005', 're-i@example.test', '{"username":"re_i","display_name":"Re Ic"}'),
  ('77000000-0000-0000-0000-000000000006', 're-b@example.test', '{"username":"re_b","display_name":"Re Bee"}'),
  ('77000000-0000-0000-0000-000000000007', 're-o@example.test', '{"username":"re_o","display_name":"Re Other"}');
insert into public.events (id, name, created_by) values
  ('77000000-0000-0000-0000-0000000000e1', 'Rehearsal test', '77000000-0000-0000-0000-000000000001'),
  ('77000000-0000-0000-0000-0000000000e2', 'Other event', '77000000-0000-0000-0000-000000000007');
insert into public.event_roles (event_id, user_id, role) values
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000001', 'root'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000002', 'planner'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000003', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000004', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000005', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000006', 'participant'),
  ('77000000-0000-0000-0000-0000000000e2', '77000000-0000-0000-0000-000000000007', 'root')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', 'G');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000004', true, false),
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000005', false, true),
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000006', false, false);

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

set local role authenticated;

do $$
declare
  v_id uuid;
  v_who text;
  n integer;
  v_add constant text := $q$insert into public.event_rehearsals (event_id, starts_at)
    values ('77000000-0000-0000-0000-0000000000e1', now() + interval '3 days')$q$;
begin
  -- 1. Only the root and planners add one: not a participant, group admin, IC, member or someone from another event
  foreach v_who in array array['3', '4', '5', '6', '7'] loop
    perform pg_temp.zz_as('77000000-0000-0000-0000-00000000000' || v_who);
    if pg_temp.zz_refused(v_add) = '' then
      raise exception 'FAIL 1: user % added a rehearsal', v_who;
    end if;
  end loop;

  -- 2. A planner adds one, and it records who did
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000002');
  insert into public.event_rehearsals (event_id, starts_at)
    values ('77000000-0000-0000-0000-0000000000e1', now() + interval '1 day')
    returning id into v_id;
  if not exists (select 1 from public.event_rehearsals where id = v_id and created_by = '77000000-0000-0000-0000-000000000002') then
    raise exception 'FAIL 2: the planner''s rehearsal was not saved as theirs';
  end if;

  -- 3. A root adds one too
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000001');
  insert into public.event_rehearsals (event_id, starts_at)
    values ('77000000-0000-0000-0000-0000000000e1', now() + interval '2 days');

  -- 4. Nobody schedules one in the past, or in someone else's name
  if pg_temp.zz_refused($q$insert into public.event_rehearsals (event_id, starts_at)
       values ('77000000-0000-0000-0000-0000000000e1', now() - interval '1 hour')$q$) = '' then
    raise exception 'FAIL 4a: a rehearsal was scheduled in the past';
  end if;
  if pg_temp.zz_refused($q$insert into public.event_rehearsals (event_id, starts_at, created_by)
       values ('77000000-0000-0000-0000-0000000000e1', now() + interval '4 days', '77000000-0000-0000-0000-000000000006')$q$) = '' then
    raise exception 'FAIL 4b: a rehearsal was added in someone else''s name';
  end if;

  -- 5. Two at the same moment are refused
  if pg_temp.zz_refused(format($q$insert into public.event_rehearsals (event_id, starts_at)
       select event_id, starts_at from public.event_rehearsals where id = %L$q$, v_id)) = '' then
    raise exception 'FAIL 5: the same time was scheduled twice';
  end if;

  -- 6. Everyone in the event reads them; someone in another event reads nothing
  foreach v_who in array array['3', '4', '5', '6'] loop
    perform pg_temp.zz_as('77000000-0000-0000-0000-00000000000' || v_who);
    select count(*) into n from public.event_rehearsals;
    if n <> 2 then
      raise exception 'FAIL 6a: user % read % rehearsals, not 2', v_who, n;
    end if;
  end loop;
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000007');
  select count(*) into n from public.event_rehearsals;
  if n <> 0 then
    raise exception 'FAIL 6b: an outsider read % rehearsals', n;
  end if;

  -- 7. Nobody else removes one (RLS answers by removing no rows), and nobody changes one
  foreach v_who in array array['3', '4', '5', '6', '7'] loop
    perform pg_temp.zz_as('77000000-0000-0000-0000-00000000000' || v_who);
    delete from public.event_rehearsals where id = v_id;
    get diagnostics n = row_count;
    if n <> 0 then
      raise exception 'FAIL 7a: user % removed a rehearsal', v_who;
    end if;
  end loop;
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000002');
  if pg_temp.zz_refused(format($q$update public.event_rehearsals set starts_at = now() + interval '9 days' where id = %L$q$, v_id)) = '' then
    raise exception 'FAIL 7b: a rehearsal was changed in place';
  end if;

  -- 8. A planner removes one
  delete from public.event_rehearsals where id = v_id;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL 8: the planner could not remove the rehearsal';
  end if;

  raise notice 'rehearsals_test: all checks passed';
end $$;

rollback;
