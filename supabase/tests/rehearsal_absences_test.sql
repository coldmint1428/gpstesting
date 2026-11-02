-- ============================================================
-- Tests for 080_rehearsal_details_absences.sql: a rehearsal's end time and notes, and "not available" requests that the
-- root or a planner must decide.
--
-- Run in the Supabase SQL Editor AFTER 080, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner, A and B members; O is the root of another event
insert into auth.users (id, email, raw_user_meta_data) values
  ('80000000-0000-0000-0000-000000000001', 'ra-r@example.test', '{"username":"ra_r","display_name":"Ra Root"}'),
  ('80000000-0000-0000-0000-000000000002', 'ra-p@example.test', '{"username":"ra_p","display_name":"Ra Planner"}'),
  ('80000000-0000-0000-0000-000000000003', 'ra-a@example.test', '{"username":"ra_a","display_name":"Ra Ay"}'),
  ('80000000-0000-0000-0000-000000000004', 'ra-b@example.test', '{"username":"ra_b","display_name":"Ra Bee"}'),
  ('80000000-0000-0000-0000-000000000005', 'ra-o@example.test', '{"username":"ra_o","display_name":"Ra Other"}');
insert into public.events (id, name, created_by) values
  ('80000000-0000-0000-0000-0000000000e1', 'Absence test', '80000000-0000-0000-0000-000000000001'),
  ('80000000-0000-0000-0000-0000000000e2', 'Other event', '80000000-0000-0000-0000-000000000005');
insert into public.event_roles (event_id, user_id, role) values
  ('80000000-0000-0000-0000-0000000000e1', '80000000-0000-0000-0000-000000000001', 'root'),
  ('80000000-0000-0000-0000-0000000000e1', '80000000-0000-0000-0000-000000000002', 'planner'),
  ('80000000-0000-0000-0000-0000000000e1', '80000000-0000-0000-0000-000000000003', 'participant'),
  ('80000000-0000-0000-0000-0000000000e1', '80000000-0000-0000-0000-000000000004', 'participant'),
  ('80000000-0000-0000-0000-0000000000e2', '80000000-0000-0000-0000-000000000005', 'root')
  on conflict do nothing;
-- A rehearsal that has already started can only be put here, past the policy that refuses one in the past
insert into public.event_rehearsals (id, event_id, starts_at, created_by) values
  ('80000000-0000-0000-0000-0000000000f0', '80000000-0000-0000-0000-0000000000e1', now() - interval '1 hour', '80000000-0000-0000-0000-000000000001');

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

set local role authenticated;

do $$
declare
  v_rehearsal uuid;
  v_id uuid;
  n integer;
  v_status text;
  v_who uuid;
begin
  -- 1. A rehearsal keeps its end time and notes; an end before the start and an overlong note are refused
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000002');
  insert into public.event_rehearsals (event_id, starts_at, ends_at, note)
    values ('80000000-0000-0000-0000-0000000000e1', now() + interval '1 day', now() + interval '1 day 2 hours', 'Bring water')
    returning id into v_rehearsal;
  if not exists (select 1 from public.event_rehearsals where id = v_rehearsal and ends_at is not null and note = 'Bring water') then
    raise exception 'FAIL 1a: the end time and note were not saved';
  end if;
  if pg_temp.zz_refused($q$insert into public.event_rehearsals (event_id, starts_at, ends_at)
       values ('80000000-0000-0000-0000-0000000000e1', now() + interval '2 days', now() + interval '1 day')$q$) = '' then
    raise exception 'FAIL 1b: a rehearsal ended before it started';
  end if;
  if pg_temp.zz_refused($q$insert into public.event_rehearsals (event_id, starts_at, note)
       values ('80000000-0000-0000-0000-0000000000e1', now() + interval '2 days', repeat('x', 501))$q$) = '' then
    raise exception 'FAIL 1c: an overlong note was saved';
  end if;

  -- 2. Someone in another event cannot ask, and nobody asks without a reason or for a rehearsal that has started
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000005');
  if pg_temp.zz_refused(format($q$select public.rehearsal_absence_request(%L, 'Busy')$q$, v_rehearsal)) = '' then
    raise exception 'FAIL 2a: an outsider asked';
  end if;
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000003');
  if pg_temp.zz_refused(format($q$select public.rehearsal_absence_request(%L, '   ')$q$, v_rehearsal)) = '' then
    raise exception 'FAIL 2b: a request without a reason was saved';
  end if;
  if pg_temp.zz_refused($q$select public.rehearsal_absence_request('80000000-0000-0000-0000-0000000000f0', 'Busy')$q$) = '' then
    raise exception 'FAIL 2c: a request was made for a rehearsal that has started';
  end if;

  -- 3. A member asks, and it waits for a decision
  perform public.rehearsal_absence_request(v_rehearsal, '  Exam that day  ');
  select id, status into v_id, v_status from public.rehearsal_absences where rehearsal_id = v_rehearsal;
  if v_status is distinct from 'pending' or not exists (select 1 from public.rehearsal_absences where id = v_id and reason = 'Exam that day') then
    raise exception 'FAIL 3: the request was not saved as waiting';
  end if;

  -- 4. Nobody writes the table directly, so nobody can approve themselves that way
  if pg_temp.zz_refused(format($q$update public.rehearsal_absences set status = 'approved' where id = %L$q$, v_id)) = '' then
    raise exception 'FAIL 4a: a member updated their request directly';
  end if;
  if pg_temp.zz_refused(format($q$insert into public.rehearsal_absences (rehearsal_id, event_id, user_id, reason, status)
       values (%L, '80000000-0000-0000-0000-0000000000e1', '80000000-0000-0000-0000-000000000003', 'x', 'approved')$q$, v_rehearsal)) = '' then
    raise exception 'FAIL 4b: a member inserted an approved request';
  end if;

  -- 5. A member cannot decide, even their own; nor can the root of another event
  if pg_temp.zz_refused(format($q$select public.rehearsal_absence_decide(%L, true)$q$, v_id)) = '' then
    raise exception 'FAIL 5a: a member decided a request';
  end if;
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000005');
  if pg_temp.zz_refused(format($q$select public.rehearsal_absence_decide(%L, true)$q$, v_id)) = '' then
    raise exception 'FAIL 5b: another event''s root decided a request';
  end if;

  -- 6. Another member and outsiders read nothing of it; the root and planners do
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000004');
  select count(*) into n from public.rehearsal_absences;
  if n <> 0 then
    raise exception 'FAIL 6a: another member read % requests', n;
  end if;
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000005');
  select count(*) into n from public.rehearsal_absences;
  if n <> 0 then
    raise exception 'FAIL 6b: an outsider read % requests', n;
  end if;
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000001');
  select count(*) into n from public.rehearsal_absences;
  if n <> 1 then
    raise exception 'FAIL 6c: the root read % requests, not 1', n;
  end if;

  -- 7. A planner rejects; the member can ask again, and that waits for a decision again
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000002');
  perform public.rehearsal_absence_decide(v_id, false);
  select status, decided_by into v_status, v_who from public.rehearsal_absences where id = v_id;
  if v_status <> 'rejected' or v_who <> '80000000-0000-0000-0000-000000000002' then
    raise exception 'FAIL 7a: the rejection was not recorded';
  end if;
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000003');
  perform public.rehearsal_absence_request(v_rehearsal, 'Exam moved, still busy');
  select status, decided_by into v_status, v_who from public.rehearsal_absences where id = v_id;
  if v_status <> 'pending' or v_who is not null then
    raise exception 'FAIL 7b: asking again did not go back to waiting';
  end if;

  -- 8. The root approves; an approved request cannot be rewritten, but can be withdrawn
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000001');
  perform public.rehearsal_absence_decide(v_id, true);
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000003');
  if pg_temp.zz_refused(format($q$select public.rehearsal_absence_request(%L, 'New reason')$q$, v_rehearsal)) = '' then
    raise exception 'FAIL 8a: an approved request was rewritten';
  end if;
  if not exists (select 1 from public.rehearsal_absences where id = v_id and status = 'approved' and reason = 'Exam moved, still busy') then
    raise exception 'FAIL 8b: the approved request changed';
  end if;

  -- 9. Withdrawing touches only your own
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000004');
  perform public.rehearsal_absence_withdraw(v_rehearsal);
  perform pg_temp.zz_as('80000000-0000-0000-0000-000000000003');
  select count(*) into n from public.rehearsal_absences;
  if n <> 1 then
    raise exception 'FAIL 9a: someone else''s withdrawal removed the request';
  end if;
  perform public.rehearsal_absence_withdraw(v_rehearsal);
  select count(*) into n from public.rehearsal_absences;
  if n <> 0 then
    raise exception 'FAIL 9b: the withdrawal did not remove the request';
  end if;

  raise notice 'rehearsal_absences_test: all checks passed';
end $$;

rollback;
