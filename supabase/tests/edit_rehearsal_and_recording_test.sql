-- ============================================================
-- Tests for 085_edit_rehearsal.sql and 086_recording_names.sql.
--
-- Run in the Supabase SQL Editor AFTER 085 and 086, or locally with `node tools/pgtest.mjs`.
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

-- R root, P planner, B plain member
insert into auth.users (id, email, raw_user_meta_data) values
  ('86000000-0000-0000-0000-000000000001', 'er-r@example.test', '{"username":"er_r","display_name":"Er Root"}'),
  ('86000000-0000-0000-0000-000000000002', 'er-p@example.test', '{"username":"er_p","display_name":"Er Planner"}'),
  ('86000000-0000-0000-0000-000000000003', 'er-b@example.test', '{"username":"er_b","display_name":"Er Bee"}');
insert into public.events (id, name, created_by) values ('86000000-0000-0000-0000-0000000000e1', 'Edit rehearsal test', '86000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('86000000-0000-0000-0000-0000000000e1', '86000000-0000-0000-0000-000000000001', 'root'),
  ('86000000-0000-0000-0000-0000000000e1', '86000000-0000-0000-0000-000000000002', 'participant'),
  ('86000000-0000-0000-0000-0000000000e1', '86000000-0000-0000-0000-000000000002', 'planner'),
  ('86000000-0000-0000-0000-0000000000e1', '86000000-0000-0000-0000-000000000003', 'participant')
  on conflict do nothing;
insert into public.event_rehearsals (id, event_id, starts_at, created_by) values
  ('86000000-0000-0000-0000-0000000000c1', '86000000-0000-0000-0000-0000000000e1', now() + interval '3 days', '86000000-0000-0000-0000-000000000001'),
  ('86000000-0000-0000-0000-0000000000c2', '86000000-0000-0000-0000-0000000000e1', now() + interval '5 days', '86000000-0000-0000-0000-000000000001');
-- one that has already started (inserted as the table owner, past the policy)
insert into public.event_rehearsals (id, event_id, starts_at, created_by) values
  ('86000000-0000-0000-0000-0000000000c3', '86000000-0000-0000-0000-0000000000e1', now() - interval '2 days', '86000000-0000-0000-0000-000000000001');

set local role authenticated;

-- As a plain member: nothing may change
select set_config('request.jwt.claims', '{"sub":"86000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
do $$
begin
  if pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', now() + interval '4 days', null, 'x')$q$) = ''
     or pg_temp.zz_refused($q$select public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'day-2026-11-03', 'x')$q$) = '' then
    raise exception 'FAIL 1: a member changed a rehearsal or a recording name';
  end if;
end $$;

-- As a planner
select set_config('request.jwt.claims', '{"sub":"86000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
do $$
begin
  -- 2. Moving a rehearsal, with an end and a note
  perform public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', now() + interval '4 days', now() + interval '4 days 2 hours', '  Main gate  ');
  if not exists (select 1 from public.event_rehearsals where id = '86000000-0000-0000-0000-0000000000c1' and note = 'Main gate' and ends_at is not null) then
    raise exception 'FAIL 2: the rehearsal was not changed (or the note was not trimmed)';
  end if;
  -- an empty note clears it
  perform public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', now() + interval '4 days', null, '   ');
  if exists (select 1 from public.event_rehearsals where id = '86000000-0000-0000-0000-0000000000c1' and (note is not null or ends_at is not null)) then
    raise exception 'FAIL 2: an empty note / end was not cleared';
  end if;

  -- 3. A start in the past, an end before the start, a clash, a missing rehearsal
  if pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', now() - interval '1 hour', null, null)$q$) = ''
     or pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', now() + interval '4 days', now() + interval '3 days', null)$q$) = ''
     or pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000c1', (select starts_at from public.event_rehearsals where id = '86000000-0000-0000-0000-0000000000c2'), null, null)$q$) = ''
     or pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000ff', now() + interval '4 days', null, null)$q$) = '' then
    raise exception 'FAIL 3: a bad change was accepted';
  end if;

  -- 4. One that has started is a record
  if pg_temp.zz_refused($q$select public.update_rehearsal('86000000-0000-0000-0000-0000000000c3', now() + interval '6 days', null, null)$q$) = '' then
    raise exception 'FAIL 4: a rehearsal that had started was changed';
  end if;

  -- 5. Naming a recording, renaming it, clearing it
  perform public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'day-2026-11-03', '  Dress run  ');
  if not exists (select 1 from public.recording_names where event_id = '86000000-0000-0000-0000-0000000000e1' and key = 'day-2026-11-03' and name = 'Dress run') then
    raise exception 'FAIL 5: the recording was not named';
  end if;
  perform public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'day-2026-11-03', 'Final run');
  if (select count(*) from public.recording_names where event_id = '86000000-0000-0000-0000-0000000000e1') <> 1
     or not exists (select 1 from public.recording_names where name = 'Final run') then
    raise exception 'FAIL 5: renaming made a second row or did not change the name';
  end if;
  if pg_temp.zz_refused($q$select public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'day-2026-11-03', repeat('x', 81))$q$) = '' then
    raise exception 'FAIL 5: a name over 80 characters was accepted';
  end if;
  perform public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'day-2026-11-03', '  ');
  if exists (select 1 from public.recording_names where event_id = '86000000-0000-0000-0000-0000000000e1') then
    raise exception 'FAIL 5: an empty name did not put the times back';
  end if;
end $$;

-- 6. A member cannot read names (only the root and planners see the Playback page)
select set_config('request.jwt.claims', '{"sub":"86000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.rename_recording('86000000-0000-0000-0000-0000000000e1', 'k1', 'Name');
select set_config('request.jwt.claims', '{"sub":"86000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
do $$
begin
  if exists (select 1 from public.recording_names) then
    raise exception 'FAIL 6: a member can read recording names';
  end if;
end $$;

rollback;
select 'edit_rehearsal_and_recording_test: all checks passed' as result;
