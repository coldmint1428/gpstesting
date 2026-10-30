-- Step 19, checked at the database: the plan row is the channel, and every write that changes a plan touches it.
--
--     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
--     node tools/sql.mjs --file dev/checks/step19-realtime.sql
--
-- What has to be true, and why each one is here:
--
--   1. THE CHANNEL EXISTS, AND IT IS THE PLAN ROW. `plans` is in supabase_realtime with its three operations, and its
--      replica identity is full -- a DELETE event with the default identity carries the primary key and nothing else,
--      so the client's event filter could never match a plan somebody deleted. `plan_frames` and `plan_positions` are
--      deliberately NOT in the publication: the design is one signal on the plan row (055), and if a future step adds
--      them the reason it did not need to is written down in the migration.
--   2. EVERY WRITE TOUCHES THE PLAN ROW. A subscription can only be the change log if it really is one, so this is
--      proved behaviourally: move the plan's `updated_at` back to a sentinel, run one write as a planner, and assert
--      the row came back touched -- for a create, a note, a move, a shift, a hold, a fill, a verify patch, a rename
--      and a frame delete. A write that changed nothing (the same verify flag again) must NOT touch the row: a signal
--      for every keystroke would be a screen that reloads for every keystroke.
--
-- The check builds a scratch plan inside one transaction, runs every write through the real functions as the
-- planner, and rolls the whole thing back, so the bench is left exactly as the fixture wrote it.

begin;

-- ---------- a scratch plan on the bench, and a way to see the plan row being written ----------
update public.event_sessions
   set ended_at = coalesce(ended_at, now()), end_reason = coalesce(end_reason, 'ended')
 where event_id = '0b000000-0000-4000-8000-000000000e01' and ended_at is null;

delete from public.plan_progress where event_id = '0b000000-0000-4000-8000-000000000e01'
  and plan_id = '0b000000-0000-4000-8000-000000000b91';
delete from public.plan_positions where plan_id = '0b000000-0000-4000-8000-000000000b91';
delete from public.plan_frames    where plan_id = '0b000000-0000-4000-8000-000000000b91';
delete from public.plans          where id       = '0b000000-0000-4000-8000-000000000b91';

do $$
begin
  if not exists (select 1 from public.events where id = '0b000000-0000-4000-8000-000000000e01') then
    raise exception 'The bench is not there: run supabase/fixtures/plan_bench.sql first';
  end if;
end $$;

-- Two moments 300 s apart, Gate Crew 24 m north a frame (so the 25 m rule is happy while the reads below are not
-- about geometry). The sentinel is what every "the plan row moved" assertion measures against: the functions set
-- updated_at = now(), and now() is always years after 2001 -- including inside this one transaction, which is why the
-- check can run every write under a single rollback.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
values ('0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01', 'Realtime scratch',
        current_date, '18:00', 'draft', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00'
 where id = '0b000000-0000-4000-8000-000000000b91';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f9101', '0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01',   0, 'call', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f9102', '0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01', 300, 'walk', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng) values
  ('0b000000-0000-4000-8000-0000000f9101', '0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3300000, 103.77400),
  ('0b000000-0000-4000-8000-0000000f9102', '0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01', '0b000000-0000-4000-8000-00000000a001', 1.3302171, 103.77400);

-- ---------- 1. the channel is the plan row, and it is configured to be readable for a DELETE ----------
do $$
declare
  v_repl text;
begin
  reset role;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'plans'
  ) then
    raise exception 'FAIL 1a: plans is not in the supabase_realtime publication';
  end if;

  select c.relreplident::text into v_repl from pg_class c where c.oid = 'public.plans'::regclass;
  if v_repl <> 'f' then
    raise exception 'FAIL 1b: plans replica identity is %, not full -- a deleted plan would say no event id', v_repl;
  end if;

  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename in ('plan_frames', 'plan_positions')
  ) then
    raise exception 'FAIL 1c: a plan content table is in the publication; 055''s design is one signal on plans';
  end if;

  if not exists (
    select 1 from pg_publication
     where pubname = 'supabase_realtime' and pubinsert and pubupdate and pubdelete and not puballtables
  ) then
    raise exception 'FAIL 1d: supabase_realtime is not a row-level publication with insert/update/delete on';
  end if;
end $$;

-- ---------- 2. every write to a plan touches the plan row ----------
-- Each write is run as the planner (the real caller), between a sentinel and the assertion. `reset role` first: the
-- sentinel and the read are the owner's, and 054's version of this lesson was a record that had lost its fields.

-- 2a. frame_save, creating a moment
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.frame_save('0b000000-0000-4000-8000-000000000b91', '{"t_s": 600, "note": "last"}'::jsonb);
  reset role;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2a: frame_save creating a frame did not touch the plan row';
  end if;
end $$;

-- 2b. frame_save, labelling an existing one
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.frame_save('0b000000-0000-4000-8000-000000000b91',
                            '{"id": "0b000000-0000-4000-8000-0000000f9102", "t_s": 300, "note": "walk on"}'::jsonb);
  reset role;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2b: frame_save labelling a frame did not touch the plan row';
  end if;
  if (select note from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f9102') <> 'walk on' then
    raise exception 'FAIL 2b: the note was not written';
  end if;
end $$;

-- 2c. frame_move, dragging a moment along the bar
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.frame_move('0b000000-0000-4000-8000-0000000f9102', 360, null);
  reset role;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2c: frame_move did not touch the plan row';
  end if;
end $$;

-- 2d. frame_shift, pushing the whole strip
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
declare v_moved integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  v_moved := public.frame_shift('0b000000-0000-4000-8000-000000000b91', 0, 60, null);
  reset role;
  if v_moved <> 3 then
    raise exception 'FAIL 2d: frame_shift moved % frames, expected 3', v_moved;
  end if;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2d: frame_shift did not touch the plan row';
  end if;
end $$;

-- 2e. frame_hold, keeping one group where it stands
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
declare v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select count(*) into v_rows
    from public.frame_hold('0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-0000000f9101', 120,
                           array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
  reset role;
  if v_rows = 0 then
    raise exception 'FAIL 2e: frame_hold wrote nothing';
  end if;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2e: frame_hold did not touch the plan row';
  end if;
end $$;

-- 2f. frames_fill, spacing an impossible stretch out
-- The far moment gains a position 111 m north by hand -- a planner's edit, not a function's -- so the pair between
-- the last two moments is a real gap for frames_fill to split. The writes it makes go through frame_save, which is
-- the point: it still has to touch the row.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
select f.id, '0b000000-0000-4000-8000-000000000b91', '0b000000-0000-4000-8000-000000000e01',
       '0b000000-0000-4000-8000-00000000a001', 1.3310000, 103.77400
  from public.plan_frames f
 where f.plan_id = '0b000000-0000-4000-8000-000000000b91' and f.t_s = 660
on conflict (frame_id, group_id) do update set lat = excluded.lat;
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
declare v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select count(*) into v_rows
    from public.frames_fill('0b000000-0000-4000-8000-000000000b91',
                            '0b000000-0000-4000-8000-0000000f9102',
                            (select id from public.plan_frames
                              where plan_id = '0b000000-0000-4000-8000-000000000b91' and t_s = 660),
                            array['0b000000-0000-4000-8000-00000000a001']::uuid[]);
  reset role;
  if v_rows = 0 then
    raise exception 'FAIL 2f: frames_fill generated nothing for a 87 m gap';
  end if;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2f: frames_fill did not touch the plan row';
  end if;
end $$;

-- 2g. frame_set_verify, confirming positions
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
declare v_set integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select positions_set into v_set
    from public.frame_set_verify('0b000000-0000-4000-8000-000000000b91',
                                 array['0b000000-0000-4000-8000-0000000f9101']::uuid[],
                                 array['0b000000-0000-4000-8000-00000000a001']::uuid[], 'manual');
  reset role;
  if v_set <> 1 then
    raise exception 'FAIL 2g: frame_set_verify set % positions, expected 1', v_set;
  end if;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2g: frame_set_verify did not touch the plan row';
  end if;
end $$;

-- 2h. the same verify flag again writes nothing, so it must not touch the row: no reload for a no-op
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
declare v_set integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  select positions_set into v_set
    from public.frame_set_verify('0b000000-0000-4000-8000-000000000b91',
                                 array['0b000000-0000-4000-8000-0000000f9101']::uuid[],
                                 array['0b000000-0000-4000-8000-00000000a001']::uuid[], 'manual');
  reset role;
  if v_set <> 0 then
    raise exception 'FAIL 2h: the same flag was written twice (% positions)', v_set;
  end if;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <> timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2h: a write that changed nothing still touched the plan row';
  end if;
end $$;

-- 2i. plan_save, renaming
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.plan_save('0b000000-0000-4000-8000-000000000e01',
                            '{"id": "0b000000-0000-4000-8000-000000000b91", "name": "Realtime scratch renamed"}'::jsonb);
  reset role;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2i: plan_save did not touch the plan row';
  end if;
end $$;

-- 2j. frame_delete, taking a moment away
update public.plans set updated_at = timestamptz '2001-01-01 00:00:00+00' where id = '0b000000-0000-4000-8000-000000000b91';
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}', true);
  perform public.frame_delete('0b000000-0000-4000-8000-0000000f9102', null);
  reset role;
  if (select updated_at from public.plans where id = '0b000000-0000-4000-8000-000000000b91') <= timestamptz '2001-01-01 00:00:00+00' then
    raise exception 'FAIL 2j: frame_delete did not touch the plan row';
  end if;
  if exists (select 1 from public.plan_frames where id = '0b000000-0000-4000-8000-0000000f9102') then
    raise exception 'FAIL 2j: the frame was not deleted';
  end if;
end $$;

rollback;

select 'step 19: the plan row is the realtime channel -- plans is published with its event id and full replica identity, every frame, position, rename and delete write touches it, and a write that changes nothing does not' as result;
