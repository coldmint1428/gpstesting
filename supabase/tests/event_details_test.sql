-- ============================================================
-- Tests for 033_event_details.sql: update_event_details (root only, the wizard's rules).
--
-- Run in the Supabase SQL Editor AFTER 033, or locally with `node tools/pgtest.mjs`.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

-- R is the root, P a planner
insert into auth.users (id, email, raw_user_meta_data) values
  ('33000000-0000-0000-0000-000000000001', 'details-r@example.test', '{"username":"details_r","display_name":"Details Root"}'),
  ('33000000-0000-0000-0000-000000000002', 'details-p@example.test', '{"username":"details_p","display_name":"Details Planner"}');
insert into public.events (id, name, created_by) values ('33000000-0000-0000-0000-0000000000e1', 'Before', '33000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('33000000-0000-0000-0000-0000000000e1', '33000000-0000-0000-0000-000000000001', 'root'),
  ('33000000-0000-0000-0000-0000000000e1', '33000000-0000-0000-0000-000000000002', 'planner')
  on conflict do nothing;

set local role authenticated;

create function pg_temp.zz_refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end $$;

-- 1. The root saves every field (blank description / venue are stored as null)
select set_config('request.jwt.claims', '{"sub":"33000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$
begin
  perform public.update_event_details('33000000-0000-0000-0000-0000000000e1', '  After  ', ' A run ', '  ',
    '2026-11-01 09:00+08', '2026-11-01 17:00+08');
  if not exists (select 1 from public.events where id = '33000000-0000-0000-0000-0000000000e1'
                 and name = 'After' and description = 'A run' and venue is null
                 and starts_at = '2026-11-01 09:00+08' and ends_at = '2026-11-01 17:00+08') then
    raise exception 'FAIL 1: the details were not saved as given';
  end if;

  -- 2. The wizard's rules
  if pg_temp.zz_refused($q$select public.update_event_details('33000000-0000-0000-0000-0000000000e1', ' ', null, null, null, null)$q$) = '' then
    raise exception 'FAIL 2: a blank name was saved';
  end if;
  if pg_temp.zz_refused($q$select public.update_event_details('33000000-0000-0000-0000-0000000000e1', 'X', null, null, '2026-11-01 09:00+08', null)$q$) = '' then
    raise exception 'FAIL 2: a start without an end was saved';
  end if;
  if pg_temp.zz_refused($q$select public.update_event_details('33000000-0000-0000-0000-0000000000e1', 'X', null, null, '2026-11-01 09:00+08', '2026-11-01 08:00+08')$q$) = '' then
    raise exception 'FAIL 2: an end before the start was saved';
  end if;
  if pg_temp.zz_refused(format($q$select public.update_event_details('33000000-0000-0000-0000-0000000000e1', 'X', null, %L, null, null)$q$, repeat('v', 121))) = '' then
    raise exception 'FAIL 2: a 121-character venue was saved';
  end if;
end $$;

-- 3. A planner may not
select set_config('request.jwt.claims', '{"sub":"33000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.update_event_details('33000000-0000-0000-0000-0000000000e1', 'Planner was here', null, null, null, null)$q$) = '' then
    raise exception 'FAIL 3: a planner changed the details';
  end if;
  raise notice 'event_details_test: all checks passed';
end $$;

rollback;
