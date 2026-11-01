-- ============================================================
-- Tests for 038_sos.sql: anyone in an event can call for help.
--
-- Run in the Supabase SQL Editor AFTER 038, or locally with `node tools/pgtest.mjs`.
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

-- R root, M marshal; group G: A (IC), B, C; group H: D; O is in another event
insert into auth.users (id, email, raw_user_meta_data) values
  ('38000000-0000-0000-0000-000000000001', 'so-r@example.test', '{"username":"so_r","display_name":"So Root"}'),
  ('38000000-0000-0000-0000-000000000002', 'so-m@example.test', '{"username":"so_m","display_name":"So Marshal"}'),
  ('38000000-0000-0000-0000-000000000003', 'so-a@example.test', '{"username":"so_a","display_name":"So Ic"}'),
  ('38000000-0000-0000-0000-000000000004', 'so-b@example.test', '{"username":"so_b","display_name":"So Bee"}'),
  ('38000000-0000-0000-0000-000000000005', 'so-c@example.test', '{"username":"so_c","display_name":"So Cee"}'),
  ('38000000-0000-0000-0000-000000000006', 'so-d@example.test', '{"username":"so_d","display_name":"So Dee"}'),
  ('38000000-0000-0000-0000-000000000007', 'so-o@example.test', '{"username":"so_o","display_name":"So Other"}');
insert into public.events (id, name, created_by) values
  ('38000000-0000-0000-0000-0000000000e1', 'SOS test', '38000000-0000-0000-0000-000000000001'),
  ('38000000-0000-0000-0000-0000000000e2', 'Other event', '38000000-0000-0000-0000-000000000007');
insert into public.event_roles (event_id, user_id, role) values
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000001', 'root'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000002', 'participant'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000002', 'marshal'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000003', 'participant'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000004', 'participant'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000005', 'participant'),
  ('38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000006', 'participant'),
  ('38000000-0000-0000-0000-0000000000e2', '38000000-0000-0000-0000-000000000007', 'root')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('38000000-0000-0000-0000-0000000000a1', '38000000-0000-0000-0000-0000000000e1', 'G'),
  ('38000000-0000-0000-0000-0000000000a2', '38000000-0000-0000-0000-0000000000e1', 'H');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('38000000-0000-0000-0000-0000000000a1', '38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000003', false, true),
  ('38000000-0000-0000-0000-0000000000a1', '38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000004', false, false),
  ('38000000-0000-0000-0000-0000000000a1', '38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000005', false, false),
  ('38000000-0000-0000-0000-0000000000a2', '38000000-0000-0000-0000-0000000000e1', '38000000-0000-0000-0000-000000000006', false, false);

create table pg_temp.zz (k text primary key, v text);
grant all on pg_temp.zz to authenticated;

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

set local role authenticated;

do $$
declare
  v_id bigint;
  v_again bigint;
  n integer;
begin
  -- 1a. Someone in another event cannot send an SOS here
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000007');
  if pg_temp.zz_refused($q$select public.raise_sos('38000000-0000-0000-0000-0000000000e1', 1.29, 103.85, 10, null)$q$) = '' then
    raise exception 'FAIL 1a: an outsider sent an SOS';
  end if;

  -- 1b. A member sends one with a location and a message: it records their group
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000004');
  v_id := public.raise_sos('38000000-0000-0000-0000-0000000000e1', 1.2903, 103.8519, 12, '  Twisted ankle  ');
  insert into pg_temp.zz values ('id', v_id::text);
  if not exists (select 1 from public.sos_alerts where id = v_id and group_id = '38000000-0000-0000-0000-0000000000a1'
                 and note = 'Twisted ankle' and lat = 1.2903 and located_at is not null and resolved_at is null) then
    raise exception 'FAIL 1b: the SOS was not saved as sent';
  end if;

  -- 1c. Pressing SOS again updates the same one (no second alert)
  v_again := public.raise_sos('38000000-0000-0000-0000-0000000000e1', 1.2910, 103.8520, 8, null);
  if v_again <> v_id or (select lat from public.sos_alerts where id = v_id) <> 1.2910
     or (select note from public.sos_alerts where id = v_id) <> 'Twisted ankle' then
    raise exception 'FAIL 1c: a second press made a new SOS or lost the message';
  end if;

  -- 1d. The location updates while it is active
  perform public.update_sos_location(v_id, 1.2920, 103.8530, 5);
  if (select lat from public.sos_alerts where id = v_id) <> 1.2920 then
    raise exception 'FAIL 1d: the location did not update';
  end if;

  -- 1e. Everyone in the event sees it; the outsider does not
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000006');
  if not exists (select 1 from public.sos_alerts where id = v_id) then
    raise exception 'FAIL 1e: someone in another group cannot see the SOS';
  end if;
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000007');
  if exists (select 1 from public.sos_alerts where id = v_id) then
    raise exception 'FAIL 1e: an outsider sees the SOS';
  end if;

  -- 1f. Someone else cannot move my SOS
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000006');
  perform public.update_sos_location(v_id, 0, 0, 5);
  if (select lat from public.sos_alerts where id = v_id) = 0 then
    raise exception 'FAIL 1f: someone else changed the location';
  end if;

  -- 2a. Anyone in the event can say they are on their way, once
  perform public.help_sos(v_id);
  perform public.help_sos(v_id);
  select jsonb_array_length(helpers) into n from public.sos_alerts where id = v_id;
  if n <> 1 or (select helpers -> 0 ->> 'name' from public.sos_alerts where id = v_id) <> 'So Dee' then
    raise exception 'FAIL 2a: helpers are %', (select helpers from public.sos_alerts where id = v_id);
  end if;
  -- 2b. Not for your own SOS
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000004');
  if pg_temp.zz_refused(format('select public.help_sos(%s)', v_id)) not like '%your own%' then
    raise exception 'FAIL 2b: helped with their own SOS';
  end if;

  -- 3a. Someone in another group, or a plain member of the same group, cannot end it
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000006');
  if pg_temp.zz_refused(format('select public.resolve_sos(%s)', v_id)) = '' then
    raise exception 'FAIL 3a: someone in another group ended the SOS';
  end if;
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000005');
  if pg_temp.zz_refused(format('select public.resolve_sos(%s)', v_id)) = '' then
    raise exception 'FAIL 3a: a member of the same group ended the SOS';
  end if;
  -- 3b. Their group's IC can: handled
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000003');
  perform public.resolve_sos(v_id);
  if (select resolution from public.sos_alerts where id = v_id) is distinct from 'handled' then
    raise exception 'FAIL 3b: the IC could not end it';
  end if;
  -- 3c. Ended: no more helpers, no location changes
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000006');
  if pg_temp.zz_refused(format('select public.help_sos(%s)', v_id)) not like '%already ended%' then
    raise exception 'FAIL 3c: helped with an ended SOS';
  end if;

  -- 4. After it ends a new SOS can be sent; the sender ends it themselves: safe. A marshal can end anyone's.
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000004');
  v_again := public.raise_sos('38000000-0000-0000-0000-0000000000e1', null, null, null, null);
  if v_again = v_id or (select lat from public.sos_alerts where id = v_again) is not null then
    raise exception 'FAIL 4a: no new SOS after the first ended, or a location appeared from nowhere';
  end if;
  perform public.resolve_sos(v_again);
  if (select resolution from public.sos_alerts where id = v_again) is distinct from 'safe' then
    raise exception 'FAIL 4b: the sender could not say they are safe';
  end if;
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000006');
  v_again := public.raise_sos('38000000-0000-0000-0000-0000000000e1', 1.3, 103.8, 20, null);
  perform pg_temp.zz_as('38000000-0000-0000-0000-000000000002');
  perform public.resolve_sos(v_again);
  if (select resolution from public.sos_alerts where id = v_again) is distinct from 'handled' then
    raise exception 'FAIL 4c: a marshal could not end an SOS';
  end if;
end $$;

-- 5. Notifications went to everyone in the event but the sender, and "Help is coming" to the sender
reset role;
do $$
declare
  v_id bigint := (select v::bigint from pg_temp.zz where k = 'id');
begin
  if (select count(*) from public.push_queue where dedup like 'sos:' || v_id || ':%') <> 5 then
    raise exception 'FAIL 5a: % SOS notifications, not 5', (select count(*) from public.push_queue where dedup like 'sos:' || v_id || ':%');
  end if;
  if exists (select 1 from public.push_queue where dedup like 'sos:' || v_id || ':%' and user_id = '38000000-0000-0000-0000-000000000004') then
    raise exception 'FAIL 5a: the sender was notified of their own SOS';
  end if;
  if not exists (select 1 from public.push_queue where dedup like 'sos-help:' || v_id || ':%'
                 and user_id = '38000000-0000-0000-0000-000000000004' and title = 'Help is coming') then
    raise exception 'FAIL 5b: the sender was not told help is coming';
  end if;
  raise notice 'sos_test: all checks passed';
end $$;

rollback;
