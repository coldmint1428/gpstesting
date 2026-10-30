-- Step 23, checked at the database: a sheet replaces every moment of a plan in one transaction, and refuses the plan
-- it must not overwrite.
--
--     node tools/sql.mjs --file dev/checks/step23-import.sql
--
-- (No fixture first: this builds its own event, two groups, a plan and a session inside its transaction and rolls the
-- lot back. The browser check has a bench of its own -- step23-sheet-prep.sql -- because it needs a file on disk and
-- a board to read it.)
--
-- The step's done-when has two halves. The client half ("a sheet with one 100 m step is refused with the same message
-- the board shows") is dev/checks/step23-csv.mjs, because the sentence is the board's and the refusal happens before
-- any call. What is proved HERE is the other half and the machinery under both:
--
--   1. A SHEET IS THE WHOLE PLAN. One call replaces the frames, their notes and every position -- including the two
--      flags, a position off site confirmed by hand, an omitted flag taking its default, and a moment nobody stands
--      at. The plan's revision does not move (content never does; a publish is the only announcement), its updated_at
--      does (the other tabs hear about it through 055's channel), and every old frame id is gone while every new one
--      is a frame of this plan.
--   2. AND IT IS ONE TRANSACTION. Seven refusals -- two frames at one time, a time that is not one, positions that are
--      not a map, a group from another event, a state word that is not a state, a sheet that is not a list, a plan that
--      is not there -- each leave the plan exactly as it was. Two of them fail *after* the delete has run, so the
--      rollback is the thing being proved, not just the order of the checks.
--   3. THE ROLE RULE IS THE PLAN'S RULE. A planner may import (not only the root); a participant and a stranger are
--      refused in frame_save's own sentence; anon has no execute grant at all.
--   4. WHAT HAPPENED IS NOT A SHEET'S TO ERASE. Once a session on the plan has recorded one arrival, an import is
--      refused before anything is deleted, the frames stay, and the mark survives. This is the refusal a planner can
--      only see after the confirmation (the client cannot read progress), which is why it is a sentence and not a 500.
--   5. THE 25 m RULE IS NOT THIS FUNCTION'S. A sheet with a 100 m step imports, and plan_check then reports exactly
--      one break: the client refuses that sheet in front of the file, the database's gate is still the publish, and
--      the function does not quietly grow a third copy of the rule.
--
-- Everything runs in one transaction and is rolled back.

begin;

-- ---------- the event, its groups, its people, its plan ----------
insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e33', 'Import bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 23 (plan_import). Built and rolled back by dev/checks/step23-import.sql.',
        'Bukit Timah', now() - interval '2 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a331', '0b000000-0000-4000-8000-000000000e33', 'Gate Crew', 'GATE',  '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a332', '0b000000-0000-4000-8000-000000000e33', 'Sound',     'SOUND', '#8a5a2b');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e33', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e33', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e33', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  ('0b000000-0000-4000-8000-000000000e33', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant');
-- testuser4 is in the bench's own event and not in this one: the stranger.

-- A plan at revision 7 whose updated_at is an hour old, so "the import touched it" is a fact and not a guess. Two
-- moments, so the first import really does have something to replace.
insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by, updated_at) values
  ('0b000000-0000-4000-8000-000000000b33', '0b000000-0000-4000-8000-000000000e33', 'Import walk',
   current_date, '18:00', 'draft', 7, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', now() - interval '1 hour');

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by) values
  ('0b000000-0000-4000-8000-0000000f3301', '0b000000-0000-4000-8000-000000000b33', '0b000000-0000-4000-8000-000000000e33',
   0, 'old start', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'),
  ('0b000000-0000-4000-8000-0000000f3302', '0b000000-0000-4000-8000-000000000b33', '0b000000-0000-4000-8000-000000000e33',
   30, 'old middle', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7');

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify) values
  ('0b000000-0000-4000-8000-0000000f3301', '0b000000-0000-4000-8000-000000000b33', '0b000000-0000-4000-8000-000000000e33',
   '0b000000-0000-4000-8000-00000000a331', 1.2966000, 103.773100, 'on_site', 'auto'),
  ('0b000000-0000-4000-8000-0000000f3302', '0b000000-0000-4000-8000-000000000b33', '0b000000-0000-4000-8000-000000000e33',
   '0b000000-0000-4000-8000-00000000a331', 1.2967000, 103.773100, 'on_site', 'auto');

-- ============================================================
-- 1. a sheet is the whole plan
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_sum jsonb;
  v_n integer;
  v_ids uuid[];
  v_old uuid[] := array['0b000000-0000-4000-8000-0000000f3301', '0b000000-0000-4000-8000-0000000f3302'];
  v_times integer[];
  v_rev integer;
  v_touch timestamptz;
  v_lat double precision;
  v_lng double precision;
  v_state text;
  v_verify text;
  v_note text;
begin
  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b33';

  v_sum := public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
    jsonb_build_object(
      't_s', 0,
      'note', 'Call, "gate"',
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a331',
          jsonb_build_object('lat', 1.2966, 'lng', 103.7731, 'state', 'on_site', 'verify', 'auto'),
        '0b000000-0000-4000-8000-00000000a332',
          jsonb_build_object('lat', 1.29662, 'lng', 103.7732, 'state', 'off_site', 'verify', 'manual')
      )
    ),
    -- No flags on this one: the default is part of the contract (on site, trusted).
    jsonb_build_object('t_s', 90, 'note', '',
      'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a331', jsonb_build_object('lat', 1.2967, 'lng', 103.7731)
      )),
    -- A moment nobody stands at: it is a row of the sheet and a frame of the plan.
    jsonb_build_object('t_s', 180, 'note', 'End', 'positions', '{}'::jsonb)
  ));

  if (v_sum ->> 'frames')::int is distinct from 3 then
    raise exception 'FAIL 1a: the import answered % frames, expected 3 (%)', v_sum ->> 'frames', v_sum;
  end if;
  if (v_sum ->> 'positions')::int is distinct from 3 then
    raise exception 'FAIL 1b: the import answered % positions, expected 3', v_sum ->> 'positions';
  end if;

  select array_agg(f.id order by f.t_s), array_agg(f.t_s order by f.t_s) into v_ids, v_times
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_times is distinct from array[0, 90, 180] then
    raise exception 'FAIL 1c: the moments are %, expected 0/90/180', v_times;
  end if;
  if exists (select 1 from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33' and f.id = any (v_old)) then
    raise exception 'FAIL 1d: an old frame survived the replace';
  end if;
  if array_length(v_ids, 1) is distinct from 3 then
    raise exception 'FAIL 1e: % new frames, expected 3', array_length(v_ids, 1);
  end if;

  -- The notes, exactly: the comma and the quotation marks are the client's quoting problem, and here they are just text.
  select f.note into v_note from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33' and f.t_s = 0;
  if v_note is distinct from 'Call, "gate"' then
    raise exception 'FAIL 1f: the first note is %', v_note;
  end if;
  select f.note into v_note from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33' and f.t_s = 90;
  if v_note is not null then
    raise exception 'FAIL 1g: an empty note came back as %', v_note;
  end if;

  -- The two flags, on the group that carried them.
  select p.lat, p.lng, p.state, p.verify into v_lat, v_lng, v_state, v_verify
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33' and f.t_s = 0
     and p.group_id = '0b000000-0000-4000-8000-00000000a332';
  if v_lat is distinct from 1.29662 or v_lng is distinct from 103.7732 then
    raise exception 'FAIL 1h: Sound is at %, %', v_lat, v_lng;
  end if;
  if v_state is distinct from 'off_site' or v_verify is distinct from 'manual' then
    raise exception 'FAIL 1i: Sound came back % / %, expected off_site / manual', v_state, v_verify;
  end if;

  -- The omitted flags took their defaults.
  select p.state, p.verify into v_state, v_verify
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33' and f.t_s = 90;
  if v_state is distinct from 'on_site' or v_verify is distinct from 'auto' then
    raise exception 'FAIL 1j: an omitted flag wrote % / %, expected the defaults', v_state, v_verify;
  end if;

  -- Positions: two at the call, one at the move, none at the end.
  select count(*) into v_n from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from 3 then
    raise exception 'FAIL 1k: % positions after the import, expected 3', v_n;
  end if;

  -- Content does not move the revision; the plan row is touched so the other tabs read it again (055).
  select rev, updated_at into v_rev, v_touch from public.plans where id = '0b000000-0000-4000-8000-000000000b33';
  if v_rev is distinct from 7 then
    raise exception 'FAIL 1l: the plan''s revision is %, expected it to stay 7', v_rev;
  end if;
  if v_touch < now() - interval '5 minutes' then
    raise exception 'FAIL 1m: the plan''s updated_at is still %, so no tab would hear about the import', v_touch;
  end if;
end $$;

reset role;

-- ============================================================
-- 2. what the plan reads back is what the sheet said
-- ============================================================
do $$
declare
  v_n integer;
  v_times integer[];
  v_lat double precision;
  v_state text;
begin
  select array_agg(t_s order by t_s) into v_times from public.plan_frames_list('0b000000-0000-4000-8000-000000000b33');
  if v_times is distinct from array[0, 90, 180] then
    raise exception 'FAIL 2a: plan_frames_list answers %, expected 0/90/180', v_times;
  end if;

  select count(*) into v_n
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b33') l,
         lateral jsonb_object_keys(l.positions) k;
  if v_n is distinct from 3 then
    raise exception 'FAIL 2b: the read answers % positions, expected 3', v_n;
  end if;

  select (l.positions -> '0b000000-0000-4000-8000-00000000a331' ->> 'lat')::double precision,
         l.positions -> '0b000000-0000-4000-8000-00000000a331' ->> 'state'
    into v_lat, v_state
    from public.plan_frames_list('0b000000-0000-4000-8000-000000000b33') l where l.t_s = 90;
  if v_lat is distinct from 1.2967 or v_state is distinct from 'on_site' then
    raise exception 'FAIL 2c: the move reads back %, %', v_lat, v_state;
  end if;
end $$;

-- ============================================================
-- 3. a sheet with nothing in it empties a plan (the client refuses this; the function can do it)
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_sum jsonb;
  v_n integer;
begin
  v_sum := public.plan_import('0b000000-0000-4000-8000-000000000b33', '[]'::jsonb);
  if (v_sum ->> 'frames')::int is distinct from 0 or (v_sum ->> 'positions')::int is distinct from 0 then
    raise exception 'FAIL 3a: an empty sheet answered %', v_sum;
  end if;
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from 0 then
    raise exception 'FAIL 3b: % frames left after an empty sheet, expected none', v_n;
  end if;

  -- Put something back for the refusals below: two moments, legal, so nothing else in this file trips over them.
  perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
    jsonb_build_object('t_s', 0, 'note', 'call',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.7731))),
    jsonb_build_object('t_s', 60, 'note', '',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2967, 'lng', 103.7731)))
  ));
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from 2 then
    raise exception 'FAIL 3c: the restore left % frames, expected 2', v_n;
  end if;
end $$;

-- ============================================================
-- 4. every refusal leaves the plan exactly as it was
-- ============================================================
-- The helper shape, repeated per case so each failure names itself: capture the frames, run the import in a
-- subtransaction, keep the state a refusal raised with, then compare the frames and the message.

-- 4a. two frames at one time.
do $$
declare
  v_state text;
  v_msg text;
  v_before text;
  v_after text;
begin
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
      jsonb_build_object('t_s', 30, 'note', 'one'),
      jsonb_build_object('t_s', 30, 'note', 'two')
    ));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_state is distinct from '22023' then
    raise exception 'FAIL 4a: state %, expected 22023 (% — a sheet with two frames at one time was accepted)', v_state, v_msg;
  end if;
  if v_msg not like '%two frames at +0:30%' then
    raise exception 'FAIL 4a: said %, expected it to name +0:30', v_msg;
  end if;
  if v_before is distinct from v_after then
    raise exception 'FAIL 4a: the refused sheet changed the plan (% -> %)', v_before, v_after;
  end if;
end $$;

-- 4b. a time that is not a time.
do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', '[{"t_s":"ninety"}]'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '22023' or v_msg not like '%whole seconds from T+0%' then
    raise exception 'FAIL 4b: said % (%)', v_msg, v_state;
  end if;
end $$;

-- 4c. positions that are not a map: refused by the shape check, before anything is deleted (4d and 4e are the two that
-- fail after the delete, and 4d is the one with a first frame already written).
do $$
declare
  v_state text;
  v_msg text;
  v_before text;
  v_after text;
begin
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33',
      '[{"t_s":10,"note":"new","positions":[{"lat":1.2}]}]'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_state is distinct from '22023' or v_msg not like '%map from group to place%' then
    raise exception 'FAIL 4c: said % (%)', v_msg, v_state;
  end if;
  if v_before is distinct from v_after then
    raise exception 'FAIL 4c: the sheet with an array of positions changed the plan';
  end if;
end $$;

-- 4d. a group from another event, on the SECOND frame: the first frame has already been written when frame_save
-- refuses, so only the transaction can put the plan back.
do $$
declare
  v_state text;
  v_msg text;
  v_before text;
  v_after text;
  v_n integer;
begin
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
      jsonb_build_object('t_s', 10, 'note', 'fine',
        'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
          jsonb_build_object('lat', 1.2966, 'lng', 103.7731))),
      jsonb_build_object('t_s', 20, 'note', 'not fine',
        'positions', jsonb_build_object(
          -- The bench event's Gate Crew: a real group, in the wrong event.
          '0b000000-0000-4000-8000-00000000a001', jsonb_build_object('lat', 1.2966, 'lng', 103.7731)))
    ));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_state is distinct from '42501' or v_msg not like '%belongs to another event%' then
    raise exception 'FAIL 4d: said % (%)', v_msg, v_state;
  end if;
  if v_before is distinct from v_after then
    raise exception 'FAIL 4d: the half-written sheet stayed (% -> %)', v_before, v_after;
  end if;
  select count(*) into v_n from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from 2 then
    raise exception 'FAIL 4d: % positions after the rollback, expected the 2 it had', v_n;
  end if;
end $$;

-- 4e. a state word that is not one of the two.
do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
      jsonb_build_object('t_s', 10, 'positions', jsonb_build_object(
        '0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.7731, 'state', 'onsite')))
    ));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '22023' or v_msg not like '%on site or off site, not onsite%' then
    raise exception 'FAIL 4e: said % (%)', v_msg, v_state;
  end if;
end $$;

-- 4f. a sheet that is not a list.
do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', '{"t_s":0}'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '22023' or v_msg not like '%list of frames%' then
    raise exception 'FAIL 4f: said % (%)', v_msg, v_state;
  end if;
end $$;

-- 4g. a plan that is not there.
do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-0000000000ff', '[]'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '42501' or v_msg not like '%plan does not exist%' then
    raise exception 'FAIL 4g: said % (%)', v_msg, v_state;
  end if;
end $$;

reset role;

-- ============================================================
-- 5. who may import: a planner, not a participant, not a stranger, not anon
-- ============================================================
-- 5a. a planner who is not the root.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

do $$
declare
  v_sum jsonb;
  v_n integer;
begin
  v_sum := public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
    jsonb_build_object('t_s', 0, 'note', 'by the second planner',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a332',
        jsonb_build_object('lat', 1.2966, 'lng', 103.7731)))
  ));
  if (v_sum ->> 'frames')::int is distinct from 1 then
    raise exception 'FAIL 5a: a planner imported % frames, expected 1', v_sum;
  end if;
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from 1 then
    raise exception 'FAIL 5a: the planner''s import left % frames, expected 1', v_n;
  end if;
  perform set_config('check.frames', v_n::text, true);
end $$;

reset role;

-- 5b. a participant. THE COUNT OF WHAT SURVIVED IS TAKEN AS THE OWNER: a participant's read of plan_frames is scoped
-- to their own group (040), and this one is in no group here, so their own count would answer 0 whether or not the
-- plan was emptied -- an assertion that cannot fail. The refusal is theirs; the proof that nothing changed is not.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', '[]'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '42501' or v_msg not like '%Only the root user or a planner can change a plan%' then
    raise exception 'FAIL 5b: a participant said % (%)', v_msg, v_state;
  end if;
end $$;

reset role;

do $$
declare
  v_n integer;
begin
  select count(*) into v_n from public.plan_frames where plan_id = '0b000000-0000-4000-8000-000000000b33';
  if v_n is distinct from current_setting('check.frames')::int then
    raise exception 'FAIL 5b: the participant''s refusal changed the plan (% frames, was %)', v_n, current_setting('check.frames');
  end if;
end $$;

reset role;

-- 5c. a stranger: signed in, in the app, in no role of this event.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_state text;
  v_msg text;
begin
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', '[]'::jsonb);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state is distinct from '42501' or v_msg not like '%Only the root user or a planner%' then
    raise exception 'FAIL 5c: a stranger said % (%)', v_msg, v_state;
  end if;
end $$;

reset role;

-- 5d. anon cannot call it at all: the grant is for authenticated, and nothing else.
do $$
begin
  if has_function_privilege('anon', 'public.plan_import(uuid, jsonb)', 'execute') then
    raise exception 'FAIL 5d: anon may execute plan_import';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_import(uuid, jsonb)', 'execute') then
    raise exception 'FAIL 5e: authenticated may not execute plan_import';
  end if;
end $$;

-- ============================================================
-- 6. the 25 m rule is not this function's: it imports, and plan_check reports it
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_sum jsonb;
  v_n integer;
begin
  v_sum := public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
    jsonb_build_object('t_s', 0, 'note', 'gate',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.7731))),
    jsonb_build_object('t_s', 60, 'note', 'a hundred metres on',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.774)))
  ));
  if (v_sum ->> 'frames')::int is distinct from 2 then
    raise exception 'FAIL 6a: the 100 m sheet imported % frames, expected 2', v_sum;
  end if;

  -- The database's gate still sees it, and says one walk is too long: the client refuses this sheet in front of the
  -- file, so a planner never gets here -- but a caller that bypasses the client would, and the plan would be red.
  select count(*) into v_n from public.plan_check('0b000000-0000-4000-8000-000000000b33');
  if v_n is distinct from 1 then
    raise exception 'FAIL 6b: plan_check reports % breaks for the 100 m sheet, expected 1', v_n;
  end if;
end $$;

-- ============================================================
-- 7. what happened is not a sheet's to erase
-- ============================================================
-- Publish the plan (its walk is the 100 m one, so make it legal first: two 30 m steps over three frames), start a
-- session on it, and record one arrival. Then the import must be refused before anything is deleted.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_rev integer;
  v_session uuid;
begin
  perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
    jsonb_build_object('t_s', 0, 'note', 'call',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.7731))),
    jsonb_build_object('t_s', 60, 'note', '',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.77332))),
    jsonb_build_object('t_s', 120, 'note', 'end',
      'positions', jsonb_build_object('0b000000-0000-4000-8000-00000000a331',
        jsonb_build_object('lat', 1.2966, 'lng', 103.77354)))
  ));

  select rev into v_rev from public.plans where id = '0b000000-0000-4000-8000-000000000b33';
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b33', v_rev);
  v_session := public.start_event('0b000000-0000-4000-8000-000000000e33', '0b000000-0000-4000-8000-000000000b33');
  perform set_config('check.session', v_session::text, true);
end $$;

reset role;

do $$
declare
  v_session uuid := current_setting('check.session')::uuid;
  v_frame uuid;
begin
  select f.id into v_frame from public.plan_frames f
   where f.plan_id = '0b000000-0000-4000-8000-000000000b33' order by f.t_s limit 1;
  perform set_config('check.frame', v_frame::text, true);
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_session uuid := current_setting('check.session')::uuid;
  v_frame uuid := current_setting('check.frame')::uuid;
begin
  perform public.progress_mark(v_session, v_frame, '0b000000-0000-4000-8000-00000000a331', 'arrived');
end $$;

-- 7a. the import is refused, and says what to do instead.
do $$
declare
  v_state text;
  v_msg text;
  v_before text;
  v_after text;
  v_n integer;
begin
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_before
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';
  begin
    perform public.plan_import('0b000000-0000-4000-8000-000000000b33', jsonb_build_array(
      jsonb_build_object('t_s', 0, 'note', 'a new plan', 'positions', '{}'::jsonb)
    ));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  select string_agg(f.id::text || '@' || f.t_s, ',' order by f.t_s) into v_after
    from public.plan_frames f where f.plan_id = '0b000000-0000-4000-8000-000000000b33';

  if v_state is distinct from '22023' then
    raise exception 'FAIL 7a: state %, expected 22023 (% — a sheet was imported over recorded actuals)', v_state, v_msg;
  end if;
  if v_msg not like '%already has what actually happened at 1 moment%' then
    raise exception 'FAIL 7b: said %, expected it to count the moment', v_msg;
  end if;
  if v_msg not like '%Copy the plan and import into the copy%' then
    raise exception 'FAIL 7c: said %, expected it to say what to do instead', v_msg;
  end if;
  if v_before is distinct from v_after then
    raise exception 'FAIL 7d: the refused import changed the moments (% -> %)', v_before, v_after;
  end if;

  select count(*) into v_n from public.plan_progress where session_id = current_setting('check.session')::uuid;
  if v_n is distinct from 1 then
    raise exception 'FAIL 7e: % marks survived, expected the one that was there', v_n;
  end if;
end $$;

reset role;

-- 7f. the plan is still the live one, still tracked by its session -- nothing about the refusal moved it.
do $$
declare
  v_status text;
  v_plan uuid;
begin
  select status into v_status from public.plans where id = '0b000000-0000-4000-8000-000000000b33';
  if v_status is distinct from 'live' then
    raise exception 'FAIL 7f: the plan is %, expected live', v_status;
  end if;
  select plan_id into v_plan from public.event_sessions where id = current_setting('check.session')::uuid;
  if v_plan is distinct from '0b000000-0000-4000-8000-000000000b33' then
    raise exception 'FAIL 7g: the session moved to %', v_plan;
  end if;
end $$;

-- ============================================================
-- 8. the function is where it says it is
-- ============================================================
do $$
declare
  v_definer boolean;
  v_config text[];
  v_grantees integer[];
begin
  select p.prosecdef, p.proconfig, array(select a.grantee from aclexplode(p.proacl) a)
    into v_definer, v_config, v_grantees
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'plan_import';

  if v_definer is not true then
    raise exception 'FAIL 8a: plan_import is not security definer';
  end if;
  if v_config is null or not (v_config::text like '%search_path=public%') then
    raise exception 'FAIL 8b: plan_import does not pin its search_path (%)', v_config;
  end if;
  -- R4: PUBLIC is grantee 0. It must not be there, and authenticated must be.
  if 0 = any (v_grantees) then
    raise exception 'FAIL 8c: plan_import is executable by PUBLIC';
  end if;
  if not exists (select 1 from pg_roles r where r.rolname = 'authenticated'
                  and has_function_privilege('authenticated', 'public.plan_import(uuid, jsonb)', 'execute')) then
    raise exception 'FAIL 8d: authenticated may not execute plan_import';
  end if;
end $$;

select 'PASS step 23 — the sheet replaces a plan in one transaction, and refuses what it must not overwrite' as verdict;
