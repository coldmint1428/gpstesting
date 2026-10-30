-- Step 22, checked at the database: the plan's own log, one tap to ack it, and the push that goes only to the groups
-- whose walk changed.
--
--     node tools/sql.mjs --file dev/checks/step22-log-targeting.sql
--
-- (No fixture first: this check builds its own event, four groups, a plan and a session inside its transaction and
-- rolls the lot back. The bench event has three people who may be in a group and this needs five.)
--
-- What the step asks for, and what is proved here:
--
--   1. A BROADCAST WRITES ONE ROW TO THE NEW LOG AND NOTHING TO THE OLD ONE. The plan has its own log (058): who sent
--      it, to which audience, one recipient row per person, one push each. Nothing went to 031's run-sheet log -- and
--      since step 25 deleted that table, the shortcut is not merely unused but impossible; the check asserts its
--      absence after every message in this file.
--   2. ONE TAP ACKS IT. plan_log_ack writes the wall-clock instant once; a second press returns the first instant and
--      moves nothing; a person the message was not sent to is refused; a member's read carries their own instant and
--      the sender's read carries the tally and who is still to ack.
--   3. THE AUDIENCE IS THE PLAN'S GROUPS. `all` reaches the members of the groups the plan places (a group with no part
--      in the plan is not told, a group with no members contributes nobody), `group` reaches one of them, `ops` reaches
--      the root/planners/marshals; the sender is never a recipient; a marshal may send, a member may not.
--   4. THE TIMELINE PUSH IS TARGETED. Publishing compares the walk it announces with the walk it replaces, group by
--      group, and writes one `timeline` row whose recipients are the members of the affected groups only. A republish
--      that changes nothing writes nothing and queues nothing; a first publish tells nobody; moving one group's point
--      tells that group; moving a frame's time tells the groups the move carries as well as the one that states it; a
--      copy's first publish compares against the plan it was cut from, from the cut onward, so editing one group's
--      moment on the copy tells that group and not the others.
--   5. NOTHING ELSE MOVED. The two new push kinds are additive (the thirteen from 057, `sos` included, are still
--      there), the internal walk helper is not executable by a signed-in caller, both new tables are readable through
--      RLS and not writable, and a plan that has been deleted answers no rows rather than an error.
--
-- The clock: the plan's printed T+0 is 90 seconds ago, so the session's clock is T+1:30. Distances are ~24 m per frame
-- step, under the 25 m budget, so every publish below passes plan_check; the two point moves are sideways by 5 m so a
-- single step stays under it.
--
-- Everything runs in one transaction and is rolled back.

begin;

-- ---------- 1. the event, its groups, its people, its plan ----------
insert into public.events (id, name, created_by, description, venue, starts_at, ends_at)
values ('0b000000-0000-4000-8000-000000000e22', 'Log bench',
        'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7',
        'Fixture for step 22 (plan log, single ack, targeted timeline push). Built and rolled back by dev/checks/step22-log-targeting.sql.',
        'Bukit Timah', now() - interval '5 minutes', now() + interval '2 hours');

insert into public.groups (id, event_id, name, code, colour) values
  ('0b000000-0000-4000-8000-00000000a221', '0b000000-0000-4000-8000-000000000e22', 'Gate Crew', 'GATE',  '#244f3f'),
  ('0b000000-0000-4000-8000-00000000a222', '0b000000-0000-4000-8000-000000000e22', 'Sound',     'SOUND', '#8a5a2b'),
  ('0b000000-0000-4000-8000-00000000a223', '0b000000-0000-4000-8000-000000000e22', 'Backstage', 'BACK',  '#3b5a8a'),
  -- In the event, in no frame of the plan: `all` must not reach it, and a message addressed to it is refused.
  ('0b000000-0000-4000-8000-00000000a224', '0b000000-0000-4000-8000-000000000e22', 'Scaffold',  'SCAF',  '#7a3742');

insert into public.event_roles (event_id, user_id, role) values
  ('0b000000-0000-4000-8000-000000000e22', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'root'),
  ('0b000000-0000-4000-8000-000000000e22', 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'),
  ('0b000000-0000-4000-8000-000000000e22', 'c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5', 'planner'),
  ('0b000000-0000-4000-8000-000000000e22', '2906655b-33ad-4e9d-a608-f083e43e22d4', 'participant'),
  ('0b000000-0000-4000-8000-000000000e22', 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'participant'),
  ('0b000000-0000-4000-8000-000000000e22', '00cd023b-0e26-4574-a635-760e782c8029', 'participant');

-- Gate Crew has TWO people (so "1 of 2" and "waiting on Gate Crew" mean something), Sound has one, Backstage has none.
insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values
  ('0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', 'ba04a00c-518f-4252-91d5-1081cecec1d2', true, false),
  ('0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', '00cd023b-0e26-4574-a635-760e782c8029', true, false),
  ('0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a222', '2906655b-33ad-4e9d-a608-f083e43e22d4', true, true);

insert into public.plans (id, event_id, name, for_date, t0_time, status, rev, created_by)
select '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', 'Log walk',
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::date,
       (now() at time zone 'Asia/Singapore' - interval '90 seconds')::time,
       'draft', 1, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';

insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
select f.id, '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', f.t_s, f.note,
       'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7'
  from (values
    ('0b000000-0000-4000-8000-0000000f2211'::uuid,    0, 'call'),
    ('0b000000-0000-4000-8000-0000000f2212'::uuid,   60, 'stage'),
    ('0b000000-0000-4000-8000-0000000f2213'::uuid,  120, 'out'),
    ('0b000000-0000-4000-8000-0000000f2214'::uuid,  180, 'end')
  ) f(id, t_s, note);

insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state) values
  -- Gate Crew: a statement at every frame, 24 m north each step.
  ('0b000000-0000-4000-8000-0000000f2211', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', 1.3300000, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2212', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', 1.3302171, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2213', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', 1.3304342, 103.77400, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2214', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a221', 1.3306513, 103.77400, 'on_site'),
  -- Sound: two statements, then carried to the end -- which is what section 7 uses.
  ('0b000000-0000-4000-8000-0000000f2211', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a222', 1.3340000, 103.77300, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2212', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a222', 1.3342171, 103.77300, 'on_site'),
  -- Backstage: a group the plan places, with nobody in it.
  ('0b000000-0000-4000-8000-0000000f2211', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a223', 1.3350000, 103.77500, 'on_site'),
  ('0b000000-0000-4000-8000-0000000f2212', '0b000000-0000-4000-8000-000000000b22', '0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-00000000a223', 1.3352171, 103.77500, 'on_site');

-- The first publish: as the root, at the revision the row holds (1). It tells nobody -- there is nothing to compare it
-- with, and nobody was following this plan yet.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b22', 1);
  v_s := public.start_event('0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-000000000b22');
  perform set_config('check.session', v_s::text, true);
end $$;

reset role;

-- ---------- 0. the first publish, and the clock it started ----------
do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_n integer;
  v_plan uuid;
begin
  select plan_id into v_plan from public.event_sessions where id = v_s;
  if v_plan is distinct from '0b000000-0000-4000-8000-000000000b22' then
    raise exception 'FAIL 0a: the session is on %, expected plan b22', v_plan;
  end if;

  -- The plan's printed T+0 is 90 s ago and the session takes the plan's clock (039), so the fixture's arithmetic holds.
  select count(*) into v_n from public.event_sessions s
   where s.id = v_s and abs(extract(epoch from (s.t0_at - (now() - interval '90 seconds')))) < 5;
  if v_n is distinct from 1 then
    raise exception 'FAIL 0b: the session''s T+0 is not the plan''s printed zero';
  end if;

  -- A first publish writes a version and tells nobody.
  select count(*) into v_n from public.plan_versions
   where plan_id = '0b000000-0000-4000-8000-000000000b22';
  if v_n is distinct from 1 then
    raise exception 'FAIL 0c: % versions after the first publish, expected 1', v_n;
  end if;
  select count(*) into v_n from public.plan_log where event_id = '0b000000-0000-4000-8000-000000000e22';
  if v_n is distinct from 0 then
    raise exception 'FAIL 0d: the first publish wrote % plan_log rows, expected none', v_n;
  end if;
  select count(*) into v_n from public.push_queue
   where kind = 'plan_changed' and event_id = '0b000000-0000-4000-8000-000000000e22';
  if v_n is distinct from 0 then
    raise exception 'FAIL 0e: the first publish queued % plan_changed pushes, expected none', v_n;
  end if;
end $$;

-- ============================================================
-- 1. a message to one group
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_s uuid := current_setting('check.session')::uuid;
  v_ans jsonb;
  v_id bigint;
  v_n integer;
  v_r record;
  v_refused boolean;
begin
  v_ans := public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', '  Gate: hold at the gate  ',
                                'group', '0b000000-0000-4000-8000-00000000a221', false);
  if (v_ans ->> 'recipients')::integer is distinct from 2 or (v_ans ->> 'groups')::integer is distinct from 1 then
    raise exception 'FAIL 1a: the send answered %, expected 2 recipients in 1 group', v_ans;
  end if;
  v_id := (v_ans ->> 'id')::bigint;
  perform set_config('check.log1', v_id::text, true);

  select * into v_r from public.plan_log where id = v_id;
  if v_r.kind is distinct from 'message' or v_r.audience is distinct from 'group'
     or v_r.audience_group is distinct from '0b000000-0000-4000-8000-00000000a221' then
    raise exception 'FAIL 1b: the row is kind % audience % group %, expected message/group/Gate Crew',
      v_r.kind, v_r.audience, v_r.audience_group;
  end if;
  if v_r.body is distinct from 'Gate: hold at the gate' then
    raise exception 'FAIL 1c: the body is "%", expected it trimmed', v_r.body;
  end if;
  if v_r.session_id is distinct from v_s then
    raise exception 'FAIL 1d: the row names session %, expected the live one %', v_r.session_id, v_s;
  end if;
  if v_r.from_name is distinct from (select coalesce(display_name, 'someone') from public.profiles
                                      where id = 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7') then
    raise exception 'FAIL 1e: the sender is named %', v_r.from_name;
  end if;

  -- One recipient row per person, addressed as their group, and nobody else -- in particular not the group with no
  -- members and not the group with no part in the plan.
  select count(*) into v_n from public.plan_log_recipients where log_id = v_id;
  if v_n is distinct from 2 then
    raise exception 'FAIL 1f: % recipient rows, expected 2', v_n;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and group_id = '0b000000-0000-4000-8000-00000000a221';
  if v_n is distinct from 2 then
    raise exception 'FAIL 1g: % recipients addressed as Gate Crew, expected 2', v_n;
  end if;

  -- The done-when: nothing in the run-sheet log. Since step 25 deleted `show_log` the shortcut is not merely unused,
  -- it is unreachable: the table is not in the catalogue any more. (Asserted once here, and re-asserted by name at the
  -- end of the run so a later file cannot quietly reintroduce it.)
  if to_regclass('public.show_log') is not null then
    raise exception 'FAIL 1j: show_log exists again';
  end if;
end $$;

-- The pushes are the owner's table (authenticated may not read push_queue), so they are asserted from here.
reset role;

do $$
declare
  v_id bigint := current_setting('check.log1')::bigint;
  v_n integer;
begin
  select count(*) into v_n from public.push_queue
   where kind = 'plan_message' and dedup like 'plan_message:' || v_id || ':%';
  if v_n is distinct from 2 then
    raise exception 'FAIL 1h: % plan_message pushes, expected 2', v_n;
  end if;
  select count(*) into v_n from public.push_queue
   where kind = 'plan_message' and dedup like 'plan_message:' || v_id || ':%'
     and title = 'Message from ' || (select coalesce(display_name, 'someone') from public.profiles
                                      where id = 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7') || ' to Gate Crew';
  if v_n is distinct from 2 then
    raise exception 'FAIL 1i: the push titles are not "Message from <sender> to Gate Crew"';
  end if;
end $$;

-- The recipient's half: their own row, their own instant, and nothing of the tally.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ba04a00c-518f-4252-91d5-1081cecec1d2","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log1')::bigint;
  v_r record;
  v_n integer;
  v_at1 timestamptz;
  v_at2 timestamptz;
begin
  select * into v_r from public.plan_log_list('0b000000-0000-4000-8000-000000000b22')
   where id = v_id;
  if not found then
    raise exception 'FAIL 1k: Gate Crew''s IC cannot see the message sent to their group';
  end if;
  if not v_r.i_recipient then
    raise exception 'FAIL 1l: the row does not say it was addressed to them';
  end if;
  if v_r.recipients is not null or v_r.acked is not null or v_r.waiting is not null then
    raise exception 'FAIL 1m: a member''s read carries the tally (recipients %, acked %, waiting %)',
      v_r.recipients, v_r.acked, v_r.waiting;
  end if;
  if v_r.i_acked is not null then
    raise exception 'FAIL 1n: the message is already acked';
  end if;

  -- One tap, one instant; a second tap returns the first and moves nothing.
  v_at1 := public.plan_log_ack(v_id);
  if v_at1 is null then
    raise exception 'FAIL 1o: the ack wrote no instant';
  end if;
  v_at2 := public.plan_log_ack(v_id);
  if v_at2 is distinct from v_at1 then
    raise exception 'FAIL 1p: a second ack moved the record (% -> %)', v_at1, v_at2;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = 'ba04a00c-518f-4252-91d5-1081cecec1d2' and acked_at = v_at1;
  if v_n is distinct from 1 then
    raise exception 'FAIL 1q: the acked instant is not the one the function returned';
  end if;
end $$;

-- Somebody the message was not sent to: no rows, and no ack.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log1')::bigint;
  v_n integer;
begin
  select count(*) into v_n from public.plan_log_list('0b000000-0000-4000-8000-000000000b22');
  if v_n is distinct from 0 then
    raise exception 'FAIL 1r: Sound''s admin reads % rows, expected none', v_n;
  end if;
  begin
    perform public.plan_log_ack(v_id);
    raise exception 'FAIL 1s: a message was acked by somebody it was not sent to';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The sender's half: the tally, and who is still to ack.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log1')::bigint;
  v_r record;
  v_refused boolean;
begin
  select * into v_r from public.plan_log_list('0b000000-0000-4000-8000-000000000b22') where id = v_id;
  if v_r.recipients is distinct from 2 or v_r.acked is distinct from 1 then
    raise exception 'FAIL 1t: the tally reads % of %, expected 1 of 2', v_r.acked, v_r.recipients;
  end if;
  if v_r.waiting is distinct from array['Gate Crew'] then
    raise exception 'FAIL 1u: waiting is %, expected the one group with somebody left', v_r.waiting;
  end if;
  if v_r.i_recipient then
    raise exception 'FAIL 1v: the sender reads themselves as a recipient';
  end if;

  -- The sender may not ack a message they were not sent.
  begin
    perform public.plan_log_ack(v_id);
    raise exception 'FAIL 1w: the sender acked their own message';
  exception when insufficient_privilege then null;
  end;

  -- An audience outside the plan's groups is refused, and so is an empty body.
  begin
    perform public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', 'x', 'group',
                                  '0b000000-0000-4000-8000-00000000a224');
    raise exception 'FAIL 1x: a message to a group with no part in the plan was accepted';
  exception when invalid_parameter_value then null;
  end;

  -- The empty body is refused with the sentence about length; the check distinguishes it from its own FAIL.
  v_refused := false;
  begin
    perform public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', '   ');
  exception when others then
    if sqlerrm like '%Write a message of 1 to 300 characters%' then
      v_refused := true;
    else
      raise;
    end if;
  end;
  if not v_refused then
    raise exception 'FAIL 1y: an empty message was accepted';
  end if;
end $$;

-- A member of the groups, no role in the event beyond participant: not a sender.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
begin
  begin
    perform public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', 'hello');
    raise exception 'FAIL 1z: a group admin sent a plan message';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ============================================================
-- 2. a message to every group the plan places
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_ans jsonb;
  v_id bigint;
  v_n integer;
  v_r record;
begin
  v_ans := public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', 'Weather: towers at 7.');
  v_id := (v_ans ->> 'id')::bigint;
  perform set_config('check.log2', v_id::text, true);

  -- Gate Crew's two, Sound's one. Not Backstage (nobody in it), not Scaffold (not in the plan), not the sender, and
  -- not the ops team (a planner is an ops role, not a group).
  if (v_ans ->> 'recipients')::integer is distinct from 3 or (v_ans ->> 'groups')::integer is distinct from 2 then
    raise exception 'FAIL 2a: "every group" answered %, expected 3 people in 2 groups', v_ans;
  end if;
  select count(*) into v_n from public.plan_log_recipients where log_id = v_id;
  if v_n is distinct from 3 then
    raise exception 'FAIL 2b: % recipient rows, expected 3', v_n;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and group_id = '0b000000-0000-4000-8000-00000000a224';
  if v_n is distinct from 0 then
    raise exception 'FAIL 2c: the group with no part in the plan was told';
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';
  if v_n is distinct from 0 then
    raise exception 'FAIL 2d: the sender is a recipient of their own message';
  end if;

  select * into v_r from public.plan_log where id = v_id;
  if v_r.audience is distinct from 'all' or v_r.audience_group is not null then
    raise exception 'FAIL 2e: the row is audience % group %, expected all/null', v_r.audience, v_r.audience_group;
  end if;
end $$;

reset role;

do $$
declare
  v_id bigint := current_setting('check.log2')::bigint;
  v_n integer;
begin
  select count(*) into v_n from public.push_queue where kind = 'plan_message' and dedup like 'plan_message:' || v_id || ':%';
  if v_n is distinct from 3 then
    raise exception 'FAIL 2f: % pushes for a message to 3 people, expected 3', v_n;
  end if;
end $$;

-- ============================================================
-- 3. a message to the ops team, from a planner who is not the sender
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"c6bba1d6-9ef3-41f7-b504-9a9b4b7de8e5","role":"authenticated"}';

do $$
declare
  v_ans jsonb;
  v_id bigint;
  v_n integer;
  v_r record;
begin
  v_ans := public.plan_broadcast('0b000000-0000-4000-8000-000000000b22', 'Root: stage door is open.', 'ops', null, true);
  v_id := (v_ans ->> 'id')::bigint;
  perform set_config('check.log3', v_id::text, true);

  -- One recipient: the root. The sender is a planner and is excluded; nobody else has an ops role.
  if (v_ans ->> 'recipients')::integer is distinct from 1 then
    raise exception 'FAIL 3a: the ops message answered %, expected 1 recipient', v_ans;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7' and group_id is null;
  if v_n is distinct from 1 then
    raise exception 'FAIL 3b: the root is not a recipient of the ops message';
  end if;
  select count(*) into v_n from public.plan_log_recipients where log_id = v_id and group_id is not null;
  if v_n is distinct from 0 then
    raise exception 'FAIL 3c: an ops message named a group';
  end if;

  select * into v_r from public.plan_log where id = v_id;
  if v_r.audience is distinct from 'ops' or not v_r.urgent then
    raise exception 'FAIL 3d: the row is audience % urgent %, expected ops/true', v_r.audience, v_r.urgent;
  end if;
end $$;

reset role;

do $$
declare
  v_id bigint := current_setting('check.log3')::bigint;
  v_n integer;
begin
  select count(*) into v_n from public.push_queue
   where kind = 'plan_message' and dedup like 'plan_message:' || v_id || ':%' and title like 'URGENT · %';
  if v_n is distinct from 1 then
    raise exception 'FAIL 3e: % urgent pushes, expected 1 with the URGENT prefix', v_n;
  end if;
end $$;

-- The root, receiving it, acks it like any other.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log3')::bigint;
  v_at timestamptz;
begin
  v_at := public.plan_log_ack(v_id);
  if v_at is null then
    raise exception 'FAIL 3f: the root could not ack the ops message';
  end if;
end $$;

-- ============================================================
-- 4. a republish that changes nothing tells nobody
-- ============================================================
reset role;

do $$
declare
  v_logs integer;
  v_pushes integer;
begin
  select count(*) into v_logs from public.plan_log where event_id = '0b000000-0000-4000-8000-000000000e22';
  select count(*) into v_pushes from public.push_queue
   where kind = 'plan_changed' and event_id = '0b000000-0000-4000-8000-000000000e22';
  perform set_config('check.logs4', v_logs::text, true);
  perform set_config('check.pushes4', v_pushes::text, true);
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b22', 2);
end $$;

reset role;

do $$
declare
  v_logs integer := current_setting('check.logs4')::integer;
  v_pushes integer := current_setting('check.pushes4')::integer;
  v_n integer;
begin
  select count(*) into v_n from public.plan_log where event_id = '0b000000-0000-4000-8000-000000000e22';
  if v_n is distinct from v_logs then
    raise exception 'FAIL 4a: a publish that changed nothing wrote % plan_log rows', v_n - v_logs;
  end if;
  select count(*) into v_n from public.push_queue
   where kind = 'plan_changed' and event_id = '0b000000-0000-4000-8000-000000000e22';
  if v_n is distinct from v_pushes then
    raise exception 'FAIL 4b: a publish that changed nothing queued % plan_changed pushes', v_n - v_pushes;
  end if;
  -- The version is still written: every publish is a version, whether or not anyone is told. (Two publishes so far, so
  -- two versions -- the draft revision 1 was never announced and has none.)
  select count(*) into v_n from public.plan_versions where plan_id = '0b000000-0000-4000-8000-000000000b22';
  if v_n is distinct from 2 then
    raise exception 'FAIL 4c: % versions, expected 2 (one per publish)', v_n;
  end if;
end $$;

-- ============================================================
-- 5. one group's point moves: that group is told, and only that group
-- ============================================================
reset role;

-- Sound's +1:00 point moves 5 m east (sideways, so the 25 m step still holds).
update public.plan_positions set lng = 103.773045
 where group_id = '0b000000-0000-4000-8000-00000000a222'
   and frame_id = '0b000000-0000-4000-8000-0000000f2212';

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_id bigint;
  v_n integer;
  v_r record;
  v_pushes integer;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b22', 3);

  select * into v_r from public.plan_log where kind = 'timeline' order by id desc limit 1;
  if not found then
    raise exception 'FAIL 5a: moving one group''s point wrote no timeline row';
  end if;
  v_id := v_r.id;
  perform set_config('check.log4', v_id::text, true);
  if v_r.rev is distinct from 4 then
    raise exception 'FAIL 5b: the timeline row names version %, expected 4', v_r.rev;
  end if;
  if v_r.audience is distinct from 'groups' or v_r.audience_group is not null then
    raise exception 'FAIL 5c: the row is audience % group %, expected groups/null', v_r.audience, v_r.audience_group;
  end if;
  if v_r.body not like '%Sound%' or v_r.body like '%Gate Crew%' then
    raise exception 'FAIL 5d: the body is "%", expected it to name Sound only', v_r.body;
  end if;

  -- Only Sound's people. Gate Crew walked exactly as it did.
  select count(*) into v_n from public.plan_log_recipients where log_id = v_id;
  if v_n is distinct from 1 then
    raise exception 'FAIL 5e: % recipients, expected 1 (Sound''s admin)', v_n;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4'
     and group_id = '0b000000-0000-4000-8000-00000000a222';
  if v_n is distinct from 1 then
    raise exception 'FAIL 5f: the recipient is not Sound''s admin addressed as Sound';
  end if;

  -- The group that did not move is not told, and the run-sheet log is still untouched.
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and group_id = '0b000000-0000-4000-8000-00000000a221';
  if v_n is distinct from 0 then
    raise exception 'FAIL 5i: Gate Crew was told about a change to Sound''s walk';
  end if;
  -- The run-sheet log is gone entirely since step 25, so "publishing wrote nothing to it" is proved by its absence.
  if to_regclass('public.show_log') is not null then
    raise exception 'FAIL 5j: show_log exists again';
  end if;
end $$;

reset role;

do $$
declare
  v_id bigint := current_setting('check.log4')::bigint;
  v_n integer;
begin
  select count(*) into v_n from public.push_queue where kind = 'plan_changed' and dedup like 'plan_changed:' || v_id || ':%';
  if v_n is distinct from 1 then
    raise exception 'FAIL 5g: % plan_changed pushes, expected 1', v_n;
  end if;
  select count(*) into v_n from public.push_queue
   where kind = 'plan_changed' and dedup like 'plan_changed:' || v_id || ':%'
     and title = 'Your timetable changed' and data ->> 'rev' = '4' and data ->> 'logId' = v_id::text;
  if v_n is distinct from 1 then
    raise exception 'FAIL 5h: the plan_changed push is not titled and tagged as the change';
  end if;
end $$;

-- Sound's admin has it, and one tap closes the tally.
set local role authenticated;
set local request.jwt.claims = '{"sub":"2906655b-33ad-4e9d-a608-f083e43e22d4","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log4')::bigint;
begin
  perform public.plan_log_ack(v_id);
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_id bigint := current_setting('check.log4')::bigint;
  v_r record;
begin
  select * into v_r from public.plan_log_list('0b000000-0000-4000-8000-000000000b22') where id = v_id;
  if v_r.recipients is distinct from 1 or v_r.acked is distinct from 1 then
    raise exception 'FAIL 5k: the timeline tally reads % of %, expected 1 of 1', v_r.acked, v_r.recipients;
  end if;
  if v_r.waiting is not null then
    raise exception 'FAIL 5l: waiting is %, expected nobody left', v_r.waiting;
  end if;
end $$;

-- ============================================================
-- 6. a frame's time moves: the groups it carries are told as well
-- ============================================================
reset role;

-- The +2:00 frame moves to +2:30. Gate Crew is the only group with a position at it; Sound and Backstage carry into it,
-- so their walk changes too -- and a comparison that only looked at stated positions would miss them.
update public.plan_frames set t_s = 150
 where id = '0b000000-0000-4000-8000-0000000f2213';

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_id bigint;
  v_n integer;
  v_groups uuid[];
  v_body text;
begin
  perform public.plan_publish('0b000000-0000-4000-8000-000000000b22', 4);

  select id into v_id from public.plan_log where kind = 'timeline' order by id desc limit 1;
  perform set_config('check.log5', v_id::text, true);

  -- The premise: no position of Sound's at that frame.
  select count(*) into v_n from public.plan_positions
   where frame_id = '0b000000-0000-4000-8000-0000000f2213';
  if v_n is distinct from 1 then
    raise exception 'FAIL 6a: the moved frame has % positions, expected 1 (Gate Crew only)', v_n;
  end if;

  -- The row's sentence names all three walks, including Backstage's -- the group with nobody in it is still a walk the
  -- move changed, and the record says so even though there is no inbox to put it in.
  select body into v_body from public.plan_log where id = v_id;
  if v_body not like '%Backstage%' or v_body not like '%Gate Crew%' or v_body not like '%Sound%' then
    raise exception 'FAIL 6b: the timeline sentence is "%", expected it to name all three walks', v_body;
  end if;

  -- The inboxes are the groups with people: Gate Crew's two and Sound's one.
  select array_agg(distinct group_id order by group_id) into v_groups
    from public.plan_log_recipients where log_id = v_id;
  if v_groups is distinct from array['0b000000-0000-4000-8000-00000000a221'::uuid,
                                    '0b000000-0000-4000-8000-00000000a222'::uuid] then
    raise exception 'FAIL 6e: the recipients'' groups are %, expected Gate Crew and Sound', v_groups;
  end if;

  -- Sound's admin is told even though Sound states nothing at the moved frame: the move carried them.
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4';
  if v_n is distinct from 1 then
    raise exception 'FAIL 6c: Sound''s admin was not told about a frame move that changed their walk';
  end if;

  -- Backstage has nobody in it, so it is in the row's groups and in nobody's inbox.
  select count(*) into v_n from public.plan_log_recipients where log_id = v_id;
  if v_n is distinct from 3 then
    raise exception 'FAIL 6d: % recipients, expected 3 (two in Gate Crew, one in Sound)', v_n;
  end if;
end $$;

-- ============================================================
-- 7. a copy: the first publish compares against the plan it was cut from
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_copy public.plans;
  v_n integer;
begin
  v_copy := public.plan_fork('0b000000-0000-4000-8000-000000000b22');
  perform set_config('check.copy', v_copy.id::text, true);

  -- The clock is 90 s in (to the second the plan was printed), so the copy keeps the moments after it and starts with
  -- an anchor there.
  if v_copy.fork_cut_s is null or v_copy.fork_cut_s not between 89 and 92 then
    raise exception 'FAIL 7a: the copy was cut at %, expected about 90', v_copy.fork_cut_s;
  end if;
  select count(*) into v_n from public.plan_frames
   where plan_id = v_copy.id and t_s > v_copy.fork_cut_s;
  if v_n is distinct from 2 then
    raise exception 'FAIL 7b: the copy has % frames after the cut, expected 2', v_n;
  end if;

  -- Publishing it untouched changes nobody's future: the anchor is where everyone already stood, and the two moments
  -- ahead were copied. A comparison that included the anchor would tell every group on the plan.
  perform public.plan_publish(v_copy.id, v_copy.rev);
  select count(*) into v_n from public.plan_log where plan_id = v_copy.id;
  if v_n is distinct from 0 then
    raise exception 'FAIL 7c: the copy''s first publish wrote % plan_log rows, expected none', v_n;
  end if;

  -- The running session was carried onto it (053/054): these are the people whose timetable the copy is now.
  select count(*) into v_n from public.event_sessions
   where id = current_setting('check.session')::uuid and plan_id = v_copy.id;
  if v_n is distinct from 1 then
    raise exception 'FAIL 7d: the session was not carried onto the copy';
  end if;
end $$;

reset role;

-- One group's moment on the copy changes: Sound gets a point of its own at the +2:30 moment, 10 m east of where the
-- anchor carried it.
insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state)
select f.id, f.plan_id, f.event_id, '0b000000-0000-4000-8000-00000000a222', 1.3342171, 103.773090, 'on_site'
  from public.plan_frames f
 where f.plan_id = current_setting('check.copy')::uuid and f.t_s = 150;

do $$
declare
  v_n integer;
begin
  select count(*) into v_n
    from public.plan_positions p
    join public.plan_frames f on f.id = p.frame_id
   where f.plan_id = current_setting('check.copy')::uuid and f.t_s = 150
     and p.group_id = '0b000000-0000-4000-8000-00000000a222';
  if v_n is distinct from 1 then
    raise exception 'FAIL 7x: the edit wrote % positions on the copy''s +2:30 moment, expected 1', v_n;
  end if;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_copy uuid := current_setting('check.copy')::uuid;
  v_rev integer;
  v_id bigint;
  v_n integer;
begin
  select rev into v_rev from public.plans where id = v_copy;
  perform public.plan_publish(v_copy, v_rev);

  select id into v_id from public.plan_log where plan_id = v_copy and kind = 'timeline' order by id desc limit 1;
  if v_id is null then
    raise exception 'FAIL 7e: editing one group on the copy wrote no timeline row';
  end if;

  select count(*) into v_n from public.plan_log_recipients where log_id = v_id;
  if v_n is distinct from 1 then
    raise exception 'FAIL 7f: % recipients on the copy''s change, expected 1 (Sound only)', v_n;
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and user_id = '2906655b-33ad-4e9d-a608-f083e43e22d4';
  if v_n is distinct from 1 then
    raise exception 'FAIL 7g: the copy''s change did not reach Sound''s admin';
  end if;
  select count(*) into v_n from public.plan_log_recipients
   where log_id = v_id and group_id = '0b000000-0000-4000-8000-00000000a221';
  if v_n is distinct from 0 then
    raise exception 'FAIL 7h: Gate Crew was told about a change that did not touch their walk';
  end if;
end $$;

reset role;

do $$
declare
  v_copy uuid := current_setting('check.copy')::uuid;
  v_id bigint;
  v_n integer;
begin
  select id into v_id from public.plan_log where plan_id = v_copy and kind = 'timeline' order by id desc limit 1;
  select count(*) into v_n from public.push_queue where kind = 'plan_changed' and dedup like 'plan_changed:' || v_id || ':%';
  if v_n is distinct from 1 then
    raise exception 'FAIL 7i: % plan_changed pushes on the copy''s change, expected 1', v_n;
  end if;
end $$;

-- ============================================================
-- 8. the invariants: grants, RLS, and a deleted plan
-- ============================================================
reset role;

do $$
declare
  v_n integer;
begin
  -- Both new kinds are additive: the thirteen 057 restated (sos included) are still legal.
  select count(*) into v_n
    from pg_constraint c
   where c.conrelid = 'public.push_queue'::regclass and c.conname = 'push_queue_kind_check'
     and pg_get_constraintdef(c.oid) like '%''plan_message''%'
     and pg_get_constraintdef(c.oid) like '%''plan_changed''%'
     and pg_get_constraintdef(c.oid) like '%''sos''%';
  if v_n is distinct from 1 then
    raise exception 'FAIL 8a: the push kind constraint does not carry the new kinds and the old ones';
  end if;

  -- The walk helper is internal.
  if has_function_privilege('authenticated', 'public.plan_version_walk(jsonb)', 'execute') then
    raise exception 'FAIL 8b: authenticated can execute plan_version_walk';
  end if;
  if not has_function_privilege('authenticated', 'public.plan_broadcast(uuid, text, text, uuid, boolean)', 'execute') then
    raise exception 'FAIL 8c: authenticated cannot send a plan message';
  end if;
  if has_function_privilege('anon', 'public.plan_log_list(uuid, integer)', 'execute') then
    raise exception 'FAIL 8d: anon can read a plan log';
  end if;

  -- RLS is on, and a signed-in caller has no write privilege on either table.
  if not (select relrowsecurity from pg_class where oid = 'public.plan_log'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.plan_log_recipients'::regclass) then
    raise exception 'FAIL 8e: a plan log table has RLS off';
  end if;
  if has_table_privilege('authenticated', 'public.plan_log', 'insert')
     or has_table_privilege('authenticated', 'public.plan_log_recipients', 'insert') then
    raise exception 'FAIL 8f: authenticated can insert into the plan log';
  end if;
end $$;

-- A direct write is refused at the door, and a stranger is refused the read.
set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
begin
  begin
    insert into public.plan_log (event_id, plan_id, kind, audience, body)
    values ('0b000000-0000-4000-8000-000000000e22', '0b000000-0000-4000-8000-000000000b22', 'message', 'all', 'x');
    raise exception 'FAIL 8g: authenticated inserted a plan_log row directly';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.plan_log;
    raise exception 'FAIL 8h: authenticated deleted plan_log rows';
  exception when insufficient_privilege then null;
  end;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  begin
    perform public.plan_log_list('0b000000-0000-4000-8000-000000000b22');
    raise exception 'FAIL 8i: somebody outside the event read the plan log';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Deleting a plan takes its log and answers no rows rather than an error (finding 79's rule).
reset role;

do $$
declare
  v_copy uuid := current_setting('check.copy')::uuid;
  v_n integer;
begin
  delete from public.plans where id = v_copy;
  select count(*) into v_n from public.plan_log where plan_id = v_copy;
  if v_n is distinct from 0 then
    raise exception 'FAIL 8j: deleting the plan left % log rows', v_n;
  end if;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7","role":"authenticated"}';

do $$
declare
  v_copy uuid := current_setting('check.copy')::uuid;
  v_n integer;
begin
  select count(*) into v_n from public.plan_log_list(v_copy);
  if v_n is distinct from 0 then
    raise exception 'FAIL 8k: listing a deleted plan answered % rows, expected none', v_n;
  end if;
end $$;

-- ============================================================
-- 9. and the run-sheet log is still not there at all
-- ============================================================
reset role;

do $$
declare
  v_n integer;
  v_logs integer;
  v_ats integer;
begin
  -- Step 22's done-when was "one row to the new log, zero to show_log". Step 25 deleted show_log with the run sheet
  -- engine, so the zero is now structural: the table does not exist for any code -- old, new or future -- to write to.
  if to_regclass('public.show_log') is not null then
    raise exception 'FAIL 9a: show_log exists again; the plan log must not become the run-sheet log''s neighbour';
  end if;

  -- Every message and every timeline row was written in this one transaction; wall-clock instants still tell them apart
  -- (finding 74's lesson, applied to the new table). Scoped to this check's own event: the browser bench's rows are
  -- somebody else's and must not decide what this file proves.
  select count(*), count(distinct at) into v_logs, v_ats
    from public.plan_log where event_id = '0b000000-0000-4000-8000-000000000e22';
  if v_logs < 5 then
    raise exception 'FAIL 9b: % log rows, expected the messages and the timeline rows', v_logs;
  end if;
  if v_ats is distinct from v_logs then
    raise exception 'FAIL 9c: % rows share % instants; identical timestamps hide one under the other', v_logs, v_ats;
  end if;
end $$;

-- The last result set the tool prints.
select 'step 22: plan log, single ack and targeted timeline push' as check, 'PASS' as result;

rollback;
