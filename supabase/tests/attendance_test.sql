-- ============================================================
-- Tests for 037_attendance.sql: roll calls taken by hand (manual) or by scanning a QR that changes every 5 s (qr).
--
-- Run in the Supabase SQL Editor AFTER 037, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner; group G: A (IC), B, C; group H: D (IC)
insert into auth.users (id, email, raw_user_meta_data) values
  ('37000000-0000-0000-0000-000000000001', 'at-r@example.test', '{"username":"at_r","display_name":"At Root"}'),
  ('37000000-0000-0000-0000-000000000002', 'at-p@example.test', '{"username":"at_p","display_name":"At Planner"}'),
  ('37000000-0000-0000-0000-000000000003', 'at-a@example.test', '{"username":"at_a","display_name":"At Ic"}'),
  ('37000000-0000-0000-0000-000000000004', 'at-b@example.test', '{"username":"at_b","display_name":"At Bee"}'),
  ('37000000-0000-0000-0000-000000000005', 'at-c@example.test', '{"username":"at_c","display_name":"At Cee"}'),
  ('37000000-0000-0000-0000-000000000006', 'at-d@example.test', '{"username":"at_d","display_name":"At Dee"}');
insert into public.events (id, name, created_by) values ('37000000-0000-0000-0000-0000000000e1', 'Attendance test', '37000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000001', 'root'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000002', 'participant'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000002', 'planner'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000003', 'participant'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000004', 'participant'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000005', 'participant'),
  ('37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000006', 'participant')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('37000000-0000-0000-0000-0000000000a1', '37000000-0000-0000-0000-0000000000e1', 'G'),
  ('37000000-0000-0000-0000-0000000000a2', '37000000-0000-0000-0000-0000000000e1', 'H');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('37000000-0000-0000-0000-0000000000a1', '37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000003', false, true),
  ('37000000-0000-0000-0000-0000000000a1', '37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000004', false, false),
  ('37000000-0000-0000-0000-0000000000a1', '37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000005', false, false),
  ('37000000-0000-0000-0000-0000000000a2', '37000000-0000-0000-0000-0000000000e1', '37000000-0000-0000-0000-000000000006', false, true);

-- What the steps hand on to each other, readable by every role
create table pg_temp.zz (k text primary key, v text);
grant all on pg_temp.zz to authenticated;

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

set local role authenticated;

-- ---------- 1. Manual mode (the event's default) ----------
do $$
declare
  v_id uuid;
begin
  -- 1a. A member cannot open one; another group's IC cannot either
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000004');
  if pg_temp.zz_refused($q$select public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'X', 10)$q$) = '' then
    raise exception 'FAIL 1a: a member opened a roll call';
  end if;
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000006');
  if pg_temp.zz_refused($q$select public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'X', 10)$q$) = '' then
    raise exception 'FAIL 1a: another group''s IC opened a roll call';
  end if;

  -- 1b. The IC opens one: manual, and they are present
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000003');
  if pg_temp.zz_refused($q$select public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'X', 2)$q$) = '' then
    raise exception 'FAIL 1b: a 2-minute roll call was opened';
  end if;
  v_id := public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'Morning muster', 10);
  if (select mode from public.attendance_rollcalls where id = v_id) <> 'manual'
     or not exists (select 1 from public.attendance_checkins where rollcall_id = v_id and user_id = '37000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL 1b: not manual, or the IC is not present';
  end if;

  -- 1c. The IC marks people; someone of another group is refused
  perform public.mark_attendance(v_id, '37000000-0000-0000-0000-000000000004', 'present');
  perform public.mark_attendance(v_id, '37000000-0000-0000-0000-000000000005', 'excused');
  if (select count(*) from public.attendance_checkins where rollcall_id = v_id) <> 3 then
    raise exception 'FAIL 1c: the IC could not mark people';
  end if;
  if pg_temp.zz_refused(format('select public.mark_attendance(%L, %L, %L)', v_id, '37000000-0000-0000-0000-000000000006', 'present')) = '' then
    raise exception 'FAIL 1c: someone from another group was marked';
  end if;
  -- 1d. A manual roll call has no QR, and cannot be scanned
  if pg_temp.zz_refused(format('select public.rollcall_qr(%L)', v_id)) not like '%by hand%' then
    raise exception 'FAIL 1d: a manual roll call has a QR';
  end if;

  -- 1e. A member sees only their own check-in; another group does not see the roll call
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000004');
  if (select count(*) from public.attendance_checkins where rollcall_id = v_id) <> 1 then
    raise exception 'FAIL 1e: a member sees other people''s check-ins';
  end if;
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000006');
  if exists (select 1 from public.attendance_rollcalls where id = v_id) then
    raise exception 'FAIL 1e: a member of H sees G''s roll call';
  end if;

  -- 1f. Closing it
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000003');
  perform public.close_rollcall(v_id);
  if (select closed_at from public.attendance_rollcalls where id = v_id) is null then
    raise exception 'FAIL 1f: not closed';
  end if;
end $$;

-- ---------- 2. QR mode ----------
do $$
declare
  v_id uuid;
  j jsonb;
begin
  -- 2a. Only the root or a planner chooses the mode
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000003');
  if pg_temp.zz_refused($q$select public.set_attendance_mode('37000000-0000-0000-0000-0000000000e1', 'manual')$q$) = '' then
    raise exception 'FAIL 2a: an IC chose the mode';
  end if;
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000002');
  if pg_temp.zz_refused($q$select public.set_attendance_mode('37000000-0000-0000-0000-0000000000e1', 'honour')$q$) = '' then
    raise exception 'FAIL 2a: an unknown mode was saved';
  end if;
  perform public.set_attendance_mode('37000000-0000-0000-0000-0000000000e1', 'qr');

  -- 2b. The IC opens one: QR, and shows a QR of 16 characters that changes within 5 s
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000003');
  v_id := public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'Muster', 10);
  insert into pg_temp.zz values ('rc', v_id::text);
  j := public.rollcall_qr(v_id);
  if (select mode from public.attendance_rollcalls where id = v_id) <> 'qr'
     or j ->> 'token' !~ '^[0-9a-f]{16}$' or (j ->> 'seconds_left')::int not between 1 and 5 then
    raise exception 'FAIL 2b: % %', (select mode from public.attendance_rollcalls where id = v_id), j;
  end if;
  insert into pg_temp.zz values ('token', j ->> 'token');

  -- 2c. ...but cannot mark anyone by hand, or undo a mark
  if pg_temp.zz_refused(format('select public.mark_attendance(%L, %L, %L)', v_id, '37000000-0000-0000-0000-000000000004', 'present')) not like '%only a planner or the root%' then
    raise exception 'FAIL 2c: the IC marked someone by hand in QR mode';
  end if;
  if pg_temp.zz_refused(format('select public.mark_attendance(%L, %L, null)', v_id, '37000000-0000-0000-0000-000000000003')) = '' then
    raise exception 'FAIL 2c: the IC cleared a mark in QR mode';
  end if;

  -- 2d. A member cannot see the QR, or read the secret
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000004');
  if pg_temp.zz_refused(format('select public.rollcall_qr(%L)', v_id)) = '' then
    raise exception 'FAIL 2d: a member saw the QR';
  end if;
  if pg_temp.zz_refused($q$select secret from public.attendance_secrets$q$) = '' then
    raise exception 'FAIL 2d: the secret could be read';
  end if;
end $$;

-- The QR of the step before and two steps before (as the database owner: the secret is hidden from everyone else)
reset role;
insert into pg_temp.zz
select 'prev', public.att_token(s.secret, public.att_step(clock_timestamp()) - 1) from public.attendance_secrets s
where s.rollcall_id = (select v::uuid from pg_temp.zz where k = 'rc');
insert into pg_temp.zz
select 'old', public.att_token(s.secret, public.att_step(clock_timestamp()) - 2) from public.attendance_secrets s
where s.rollcall_id = (select v::uuid from pg_temp.zz where k = 'rc');
set local role authenticated;

do $$
declare
  v_id uuid := (select v::uuid from pg_temp.zz where k = 'rc');
  v_token text := (select v from pg_temp.zz where k = 'token');
  j jsonb;
begin
  -- 3a. Scanning a made-up QR: not in
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000004');
  j := public.scan_rollcall(v_id, '0123456789abcdef');
  if (j ->> 'ok')::boolean or j ->> 'message' not like '%has changed%' then
    raise exception 'FAIL 3a: a made-up QR gave %', j;
  end if;
  -- 3b. The QR on screen: in, by scan
  j := public.scan_rollcall(v_id, v_token);
  if not (j ->> 'ok')::boolean or j ->> 'title' <> 'Muster'
     or not exists (select 1 from public.attendance_checkins where rollcall_id = v_id and user_id = '37000000-0000-0000-0000-000000000004' and method = 'scan') then
    raise exception 'FAIL 3b: the QR on screen gave %', j;
  end if;
  -- 3c. Scanning again is fine
  if not (public.scan_rollcall(v_id, v_token) ->> 'ok')::boolean then
    raise exception 'FAIL 3c: scanning twice failed';
  end if;

  -- 3d. The QR of the step before still works (up to 10 s); two steps before does not
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000005');
  if (public.scan_rollcall(v_id, (select v from pg_temp.zz where k = 'old')) ->> 'ok')::boolean then
    raise exception 'FAIL 3d: a QR two steps old was accepted';
  end if;
  if not (public.scan_rollcall(v_id, (select v from pg_temp.zz where k = 'prev')) ->> 'ok')::boolean then
    raise exception 'FAIL 3d: the QR just before was refused';
  end if;

  -- 3e. Someone of another group scanning G's QR: not in
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000006');
  j := public.scan_rollcall(v_id, v_token);
  if (j ->> 'ok')::boolean or j ->> 'message' not like '%another group%' then
    raise exception 'FAIL 3e: a member of H scanned in to G: %', j;
  end if;

  -- 3f. A planner may still mark by hand in QR mode (someone without a phone)
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000002');
  perform public.mark_attendance(v_id, '37000000-0000-0000-0000-000000000005', 'excused');
  if not exists (select 1 from public.attendance_checkins where rollcall_id = v_id and user_id = '37000000-0000-0000-0000-000000000005' and status = 'excused') then
    raise exception 'FAIL 3f: a planner could not mark someone in QR mode';
  end if;

  -- 3g. Closed: no QR, no scanning
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000003');
  perform public.close_rollcall(v_id);
  if pg_temp.zz_refused(format('select public.rollcall_qr(%L)', v_id)) not like '%closed%' then
    raise exception 'FAIL 3g: a closed roll call still has a QR';
  end if;
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000004');
  if (public.scan_rollcall(v_id, v_token) ->> 'message') not like '%closed%' then
    raise exception 'FAIL 3g: scanned in to a closed roll call';
  end if;

  -- 3h. Opening a new one closes the one still open; one with no name is given one
  perform pg_temp.zz_as('37000000-0000-0000-0000-000000000002');
  perform public.open_rollcall('37000000-0000-0000-0000-0000000000a1', '', 5);
  perform public.open_rollcall('37000000-0000-0000-0000-0000000000a1', 'Second', 5);
  if (select count(*) from public.attendance_rollcalls where group_id = '37000000-0000-0000-0000-0000000000a1' and closed_at is null) <> 1 then
    raise exception 'FAIL 3h: two roll calls open at once';
  end if;
  if not exists (select 1 from public.attendance_rollcalls where title like 'Roll call %') then
    raise exception 'FAIL 3h: a roll call with no name was not given one';
  end if;

  raise notice 'attendance_test: all checks passed';
end $$;

rollback;
