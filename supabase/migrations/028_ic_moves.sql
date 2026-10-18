-- 028_ic_moves.sql -- merger Stage 8: the IC's next move on the phone, and pushes that tell the group when to go.
-- Applied on the project as 028 + 028b (move_step, section 8) + 028c (late push grace); this file holds the final state.
--
-- 1. The group's own view: my_moves(session) gives a group's members (any member: the IC walks, the admin may
--    hold the phone) their movements of the live show: where, by when (as projected), leave by, ETA, status, the
--    zone's shape and the route for a mini map. Members could already read their rows of movement_status (027);
--    this adds the zone, the cue and the route, which members cannot read themselves.
-- 2. Pushes, through push_queue and the Edge Function send-reminders (which already sends with Firebase):
--      * "Get ready"            60 s before the leave-by time   (if the group has not left yet)
--      * "Leave now"            at the leave-by time            (if not left yet; up to 5 min after it)
--      * "You are running late" when the movement turns late (once moving, or a minute after the leave-by)
--      * a planner's message    to the group's admins and ICs   (027's "Message group admin")
--      * "You are in a No-Go area" to the IC who walked in      (Stage 2's alert, now also when the app is closed)
--    Each is sent once per movement (or per message / per No-Go entry) and person: push_queue.dedup is unique.
--    Movement pushes go to the group's ICs and admins. The movements engine queues them every 5 s (move_tick) and
--    sends at once; a 5 s pg_cron job (gps-push-send) also queues No-Go pushes and sends anything left, so a push
--    leaves the server within about 5 s of its time. Leave-by moves with the show's delay, so +30 s on the show
--    moves "Leave now" too. Simulation events are left out (their virtual ICs have no phones).
-- 3. "Tell planner: delayed": report_delay(...) by a member of the group marks the movement (delay_note, delay_at),
--    puts it back in the planners' Needs attention list and logs it (a toast for every ops screen).

-- ============================================================
-- 1. Tables and columns
-- ============================================================
create table public.push_queue (
  id bigserial primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid references public.event_sessions (id) on delete cascade,
  kind text not null check (kind in ('get_ready', 'leave_now', 'late', 'message', 'nogo')),
  dedup text not null unique,          -- one push per movement / message / No-Go entry and person
  title text not null,
  body text not null,
  data jsonb not null default '{}',    -- what a tap opens (kind, eventId, ...) and the notification tag
  created_at timestamptz not null default now(),
  sent_at timestamptz                  -- handed to the Edge Function
);
create index push_queue_unsent on public.push_queue (id) where sent_at is null;
create index push_queue_created on public.push_queue (created_at);
alter table public.push_queue enable row level security; -- no policies: only through functions
revoke all on table public.push_queue from anon, authenticated, public;

create index if not exists zone_alerts_at on public.zone_alerts (at);

alter table public.movement_status
  add column if not exists delay_note text check (delay_note is null or char_length(delay_note) <= 200),
  add column if not exists delay_at timestamptz,
  add column if not exists delay_by uuid references auth.users (id) on delete set null;

alter table public.show_log drop constraint if exists show_log_kind_check;
alter table public.show_log add constraint show_log_kind_check
  check (kind in ('go', 'hold', 'resume', 'add_time', 'skip', 'end_now', 'auto_start', 'auto_end', 'anchor_start', 'anchor_cut',
                  'waiting_go', 'waiting_groups', 'anchor_risk', 'finished', 'switch', 'keep_holding', 'message', 'delay_report'));

-- ============================================================
-- 2. Queueing pushes
-- ============================================================
-- "18:04:27" in Singapore time
create or replace function public.sg_hms(p timestamptz)
returns text
language sql immutable set search_path = ''
as $$ select to_char(p at time zone 'Asia/Singapore', 'HH24:MI:SS'); $$;

-- "1:05" from seconds
create or replace function public.push_mmss(p integer)
returns text
language sql immutable set search_path = ''
as $$ select (abs(p) / 60) || ':' || lpad((abs(p) % 60)::text, 2, '0'); $$;

-- Movement pushes that are due in one show now (called by move_tick after each move_step). Returns how many were queued.
create or replace function public.push_collect_moves(p_session uuid, p_now timestamptz)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select gm.user_id, ms.event_id, ms.session_id, k.kind,
         k.kind || ':' || ms.session_id || ':' || ms.movement_id || ':' || ms.group_id || ':' || gm.user_id,
         case k.kind
           when 'get_ready' then 'Get ready: leave at ' || public.sg_hms(ms.leave_by)
           when 'leave_now' then 'Leave now for ' || z.name
           else 'Running late for ' || z.name end,
         case k.kind
           when 'get_ready' then 'Head to ' || z.name || ' (' || z.code || '). Be inside by ' || public.sg_hms(ms.deadline) || '.'
           when 'leave_now' then 'Be inside ' || z.code || ' by ' || public.sg_hms(ms.deadline) ||
                                 coalesce(' · ' || round(ms.remaining_m) || ' m to go', '') || '.'
           else 'At your pace you arrive ' || public.push_mmss(coalesce(ms.late_s, 0)) || ' late (be inside ' || z.code || ' by ' ||
                public.sg_hms(ms.deadline) || '). Tell your planner if you are held up.' end,
         jsonb_build_object('kind', 'move', 'eventId', ms.event_id, 'movementId', ms.movement_id, 'groupId', ms.group_id,
                            'tag', 'move-' || ms.movement_id || '-' || ms.group_id)
  from public.movement_status ms
  join public.movements mv on mv.id = ms.movement_id
  join public.zones z on z.id = mv.zone_id
  join public.group_members gm on gm.group_id = ms.group_id and (gm.is_ic or gm.is_admin)
  cross join lateral (
    values
      ('get_ready', ms.leave_by is not null and ms.moving_since is null and ms.ics_inside < ms.ics_required
                    and p_now >= ms.leave_by - interval '60 seconds' and p_now < ms.leave_by),
      ('leave_now', ms.leave_by is not null and ms.moving_since is null and ms.ics_inside < ms.ics_required
                    and p_now >= ms.leave_by and p_now < ms.leave_by + interval '5 minutes'),
      -- late: on the way and still late, or a minute after the leave-by without moving (the engine needs about a minute of
      -- readings to see a group has set off: without this, a group leaving on the dot was told it was late 10 s later)
      ('late', ms.status = 'late' and (ms.moving_since is not null or ms.leave_by is null
                                       or p_now >= ms.leave_by + interval '60 seconds'))
  ) as k(kind, due)
  where ms.session_id = p_session and ms.state = 'active' and k.due
  on conflict (dedup) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- No-Go entries of the last 2 minutes (real events): a push to the IC who walked in. Also tidies the queue.
create or replace function public.push_collect_nogo()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select a.user_id, a.event_id, a.session_id, 'nogo', 'nogo:' || a.id,
         'You are in a No-Go area', 'Please leave ' || z.name || ' (' || z.code || ') now.',
         jsonb_build_object('kind', 'nogo', 'eventId', a.event_id, 'tag', 'nogo-' || a.zone_id)
  from public.zone_alerts a
  join public.zones z on z.id = a.zone_id
  join public.events e on e.id = a.event_id and not e.is_simulation
  where a.at > now() - interval '2 minutes'
  on conflict (dedup) do nothing;
  get diagnostics n = row_count;
  delete from public.push_queue where created_at < now() - interval '2 days';
  return n;
end;
$$;

-- Anything to send? (pushes not sent within 10 minutes are dropped: too late to help)
create or replace function public.push_due()
returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.push_queue where sent_at is null and created_at > now() - interval '10 minutes'); $$;

-- Ask the Edge Function to send what is queued (pg_net: the call goes out after this transaction commits)
create or replace function public.push_kick()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.push_due() or not exists (select 1 from vault.decrypted_secrets where name = 'project_url') then
    return;
  end if;
  perform net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
    body := '{"queue": true}'::jsonb,
    timeout_milliseconds := 15000
  );
end;
$$;

-- The Edge Function takes up to p_limit queued pushes (marked sent), one row per phone of each person
create or replace function public.claim_push_queue(p_limit integer default 200)
returns table (id bigint, token text, kind text, title text, body text, data jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
  with picked as (
    select q.id from public.push_queue q
    where q.sent_at is null and q.created_at > now() - interval '10 minutes'
    order by q.id
    limit greatest(1, least(coalesce(p_limit, 200), 500))
    for update skip locked
  ),
  upd as (
    update public.push_queue q set sent_at = now() from picked where q.id = picked.id
    returning q.id, q.user_id, q.kind, q.title, q.body, q.data
  )
  select upd.id, t.token, upd.kind, upd.title, upd.body, upd.data
  from upd join public.push_tokens t on t.user_id = upd.user_id;
end;
$$;

-- ============================================================
-- 3. The movements tick now also queues and sends the pushes (027's move_tick)
-- ============================================================
create or replace function public.move_tick()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  n integer := 0;
  queued integer := 0;
begin
  for s in
    select es.id, e.is_simulation from public.event_sessions es
    join public.show_state st on st.session_id = es.id
    join public.events e on e.id = es.event_id
    where es.ended_at is null and es.starts_at <= now() and es.run_sheet_id is not null
      and (es.scheduled_end is null or es.scheduled_end > now())
  loop
    begin
      perform public.move_step(s.id, public.show_now());
      if not s.is_simulation then
        queued := queued + public.push_collect_moves(s.id, public.show_now());
      end if;
      n := n + 1;
    exception when others then
      raise warning 'move_tick %: %', s.id, sqlerrm;
    end;
  end loop;
  if queued > 0 then
    perform public.push_kick();
  end if;
  return n;
end;
$$;

-- Every 5 s: No-Go pushes, then send whatever is queued (a message, or anything a tick could not send)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gps-push-send';
    perform cron.schedule('gps-push-send', '5 seconds', 'select public.push_collect_nogo(); select public.push_kick();');
  end if;
end $$;

-- ============================================================
-- 4. A planner's message to a group: also a push to its admins and ICs (027's message_group)
-- ============================================================
create or replace function public.message_group(p_session uuid, p_group uuid, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid := public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  v_name text;
  v_id bigint;
  v_from text := public.show_who(auth.uid());
begin
  select g.name into v_name from public.groups g where g.id = p_group and g.event_id = v_event;
  if v_name is null then
    raise exception 'That group is not in this event';
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 300 then
    raise exception 'Write a message of 1 to 300 characters';
  end if;
  insert into public.group_messages (event_id, session_id, group_id, from_user, from_name, body)
  values (v_event, p_session, p_group, auth.uid(), v_from, p_body)
  returning id into v_id;
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select gm.user_id, v_event, p_session, 'message', 'message:' || v_id || ':' || gm.user_id,
         'Message from ' || v_from, p_body,
         jsonb_build_object('kind', 'message', 'eventId', v_event, 'groupId', p_group, 'tag', 'message-' || p_group)
  from public.group_members gm
  join public.events e on e.id = v_event and not e.is_simulation
  where gm.group_id = p_group and (gm.is_ic or gm.is_admin)
  on conflict (dedup) do nothing;
  if exists (select 1 from public.show_state where session_id = p_session) then
    perform public.show_log_add(p_session, null, 'message', v_from || ' messaged ' || v_name || ': "' || p_body || '"',
      auth.uid(), public.show_now());
  end if;
  perform public.push_kick();
end;
$$;

-- ============================================================
-- 5. The group's own view of its movements
-- ============================================================
create or replace function public.my_moves(p_session uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_group uuid;
begin
  select event_id into v_event from public.event_sessions where id = p_session;
  v_group := case when v_event is null then null else public.my_group_id(v_event) end;
  if v_group is null then
    raise exception 'You are not in a group of this event' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'server_now', public.show_now(),
    'group_id', v_group,
    'rows', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'movement_id', ms.movement_id, 'code', ms.code, 'state', ms.state, 'status', ms.status,
        'zone_code', z.code, 'zone_name', z.name, 'zone_kind', z.kind,
        'zone', case when ms.state <> 'done' then extensions.st_asgeojson(z.shape, 6)::jsonb end,
        'cue_code', c.code, 'cue_title', c.title, 'deadline_kind', mv.deadline_kind,
        'planned_deadline', ms.planned_deadline, 'deadline', ms.deadline, 'eta', ms.eta, 'spare_s', ms.spare_s,
        'late_s', ms.late_s, 'leave_by', ms.leave_by, 'remaining_m', ms.remaining_m, 'basis', ms.basis,
        'speed_mps', ms.speed_mps, 'pace_mps', mv.pace_mps, 'moving', case when ms.moving_since is not null then true end,
        'inside', ms.ics_inside, 'required', ms.ics_required, 'sharing', ms.ics_sharing, 'no_signal', nullif(ms.ics_no_signal, 0),
        'dwell_s', mv.dwell_s, 'arrived_at', ms.arrived_at, 'delay_at', ms.delay_at, 'delay_note', ms.delay_note,
        'route', case when ms.state = 'active' then
                   (select extensions.st_asgeojson(mr.path, 5)::jsonb from public.movement_routes mr
                    where mr.session_id = ms.session_id and mr.movement_id = ms.movement_id and mr.group_id = ms.group_id) end
      )) order by ms.planned_deadline nulls last, ms.code), '[]'::jsonb)
      from public.movement_status ms
      join public.movements mv on mv.id = ms.movement_id
      left join public.zones z on z.id = mv.zone_id
      left join public.cues c on c.id = mv.cue_id
      where ms.session_id = p_session and ms.group_id = v_group
    )
  );
end;
$$;

-- ============================================================
-- 6. "Tell planner: delayed" (a member of the group, on its active movement)
-- ============================================================
create or replace function public.report_delay(p_session uuid, p_movement uuid, p_group uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  ms public.movement_status;
  v_zone text;
  v_name text;
begin
  select event_id into v_event from public.event_sessions where id = p_session;
  if v_event is null or public.my_group_id(v_event) is distinct from p_group then
    raise exception 'Only a member of this group can report its delay' using errcode = '42501';
  end if;
  select * into ms from public.movement_status
  where session_id = p_session and movement_id = p_movement and group_id = p_group for update;
  if not found or ms.state <> 'active' then
    raise exception 'That movement is not the group''s current one';
  end if;
  if ms.delay_at > now() - interval '1 minute' then
    raise exception 'Already told at % by %.', public.sg_hms(ms.delay_at), public.show_who(ms.delay_by) using errcode = 'PT409';
  end if;
  p_note := nullif(btrim(coalesce(p_note, '')), '');
  if char_length(p_note) > 200 then
    raise exception 'Keep it under 200 characters';
  end if;
  update public.movement_status
  set delay_note = p_note, delay_at = now(), delay_by = auth.uid(), acked_status = null, snoozed_until = null, updated_at = now()
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
  select z.code into v_zone from public.movements mv join public.zones z on z.id = mv.zone_id where mv.id = p_movement;
  select g.name into v_name from public.groups g where g.id = p_group;
  if exists (select 1 from public.show_state where session_id = p_session) then
    perform public.show_log_add(p_session, null, 'delay_report',
      v_name || ' reports a delay (' || public.show_who(auth.uid()) || ')' || coalesce(': "' || p_note || '"', '') ||
      ' · due in ' || coalesce(v_zone, 'its zone') || ' by ' || public.sg_hms(ms.deadline) || '.', auth.uid(), public.show_now());
  end if;
end;
$$;

-- ============================================================
-- 7. The ops board shows a reported delay (027's ops_board)
-- ============================================================
create or replace function public.ops_board(p_session uuid, p_since timestamptz default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_event uuid := public.ops_session_role(p_session, array['root', 'planner', 'marshal']);
  v_since timestamptz := p_since - interval '10 seconds';
begin
  return jsonb_build_object(
    'server_now', public.show_now(),
    'as_of', now(),
    'full', p_since is null,
    'run_sheet_id', (select st.run_sheet_id from public.show_state st where st.session_id = p_session),
    'my_sector', (select er.sector from public.event_roles er where er.event_id = v_event and er.user_id = auth.uid() and er.role = 'marshal'),
    'rows', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'movement_id', ms.movement_id, 'group_id', ms.group_id, 'code', ms.code, 'zone_id', mv.zone_id, 'cue_id', mv.cue_id,
        'category', coalesce(mv.category, (select p.category from public.movements p where p.id = mv.parent_id)),
        'state', ms.state, 'status', ms.status, 'planned_deadline', ms.planned_deadline, 'deadline', ms.deadline,
        'spare_s', ms.spare_s, 'late_s', ms.late_s, 'leave_by', ms.leave_by, 'remaining_m', ms.remaining_m,
        'speed_mps', ms.speed_mps, 'basis', ms.basis, 'moving', case when ms.moving_since is not null then true end,
        'inside', nullif(ms.ics_inside, 0), 'required', ms.ics_required, 'sharing', ms.ics_sharing,
        'no_signal', nullif(ms.ics_no_signal, 0), 'arrived_at', ms.arrived_at,
        'handled_by', case when ms.handled_by is null then null else public.show_who(ms.handled_by) end,
        'handled_mine', case when ms.handled_by = auth.uid() then true end,
        'acked_status', ms.acked_status, 'snoozed_until', ms.snoozed_until,
        'delay_at', ms.delay_at, 'delay_note', ms.delay_note,
        'delay_by', case when ms.delay_by is null then null else public.show_who(ms.delay_by) end,
        'route_at', case when w.problem then mr.fetched_at end,
        'route', case when w.problem and mr.path is not null and (p_since is null or mr.fetched_at > v_since)
                      then extensions.st_asgeojson(mr.path, 5)::jsonb end
      ))), '[]'::jsonb)
      from public.movement_status ms
      join public.movements mv on mv.id = ms.movement_id
      left join public.movement_routes mr on mr.session_id = ms.session_id and mr.movement_id = ms.movement_id and mr.group_id = ms.group_id
      cross join lateral (select ms.state = 'active' and (ms.status in ('at_risk', 'late', 'no_signal') or ms.delay_at is not null) as problem) w
      where ms.session_id = p_session and (p_since is null or ms.updated_at > v_since)
    )
  );
end;
$$;

-- ============================================================
-- 8. The movements engine keeps the planners' answer to a reported delay (027's move_step; only the two
--    "acknowledged / snoozed" lines near the end changed: they are no longer cleared while delay_at is set)
-- ============================================================
create or replace function public.move_step(p_session uuid, p_now timestamptz)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  s public.event_sessions;
  v_sim boolean;
  r record;
  ic record;
  d record;
  d_old record;
  v_group uuid;
  v_active_found boolean := false;
  v_factor double precision;
  v_route extensions.geography;
  v_arr timestamptz[];          -- inside ICs: when they have stayed long enough
  v_eta timestamptz[];          -- every IC that counts for the ETA
  v_rem double precision[];     -- its distance still to go
  v_out_rem double precision[]; -- ICs on their way: distance still to go
  v_out_prog double precision[];-- ... how fast they get closer (null: no earlier reading yet)
  v_out_bas text[];             -- ... how the distance was measured
  v_spd double precision[];     -- every IC: speed used
  v_mov boolean[];              -- every IC: moving
  v_bas text[];                 -- every IC: basis
  v_mov_k boolean;
  v_sig integer;
  v_nosig integer;
  v_inside integer;
  v_k integer;
  v_moving boolean;
  v_moving_since timestamptz;
  v_speed double precision;
  v_w double precision;
  v_arrived timestamptz;
  v_eta_k timestamptz;
  v_rem_k double precision;
  v_basis text;
  v_raw text;
  v_status text;
  v_cand text;
  v_since timestamptz;
  v_spare integer;
  v_late integer;
  v_leave timestamptz;
  v_planned_leave timestamptz;
  v_state text;
  n integer := 0;
  i integer;
begin
  select * into st from public.show_state where session_id = p_session;
  if not found or st.run_sheet_id is null then
    return 0;
  end if;
  select * into s from public.event_sessions where id = p_session;
  select e.is_simulation into v_sim from public.events e where e.id = s.event_id;

  -- 1. One row per movement and group of the version running (new groups of a category join in). After a switch to
  --    another version, arrivals carry over by movement code and group, like the cues.
  insert into public.movement_status (session_id, movement_id, group_id, event_id, run_sheet_id, code)
  select p_session, m.movement_id, m.group_id, s.event_id, st.run_sheet_id, m.code
  from public.rs_moves(st.run_sheet_id) m
  on conflict do nothing;
  if exists (select 1 from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id) then
    update public.movement_status n
    set status = o.status, state = 'done', status_since = o.status_since, arrived_at = o.arrived_at, late_s = o.late_s,
        spare_s = o.spare_s, deadline = o.deadline, planned_deadline = o.planned_deadline, updated_at = now()
    from public.movement_status o
    where n.session_id = p_session and n.run_sheet_id = st.run_sheet_id and n.status = 'pending'
      and o.session_id = p_session and o.run_sheet_id <> st.run_sheet_id and o.code = n.code and o.group_id = n.group_id
      and o.status in ('arrived', 'arrived_late');
    delete from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id;
  end if;

  -- 2. Every row, by group and planned deadline: finished ones stay; a group's first unfinished one is active.
  for r in
    -- when each cue was due: its plan, or when the cue before it ended (a cue held for GO or for its groups does not
    -- give the groups more time; a cue started early by GO does take time away)
    with c as (
      select x.*, greatest(x.planned_start, st.opened_at,
                           max(coalesce(x.ended_at, x.projected_end)) over (order by x.pos rows between unbounded preceding and 1 preceding)) as due_calc
      from public.show_rows(p_session, p_now) x
    )
    select ms.*, mv.zone_id, mv.deadline_kind, mv.cue_id, mv.early_s, mv.min_ics, mv.dwell_s, mv.amber_s, mv.travel_mode,
           mv.pace_mps::double precision as pace, mv.leave_by as planned_leave_text, z.shape as zone_shape,
           c.status as cue_status,
           case mv.deadline_kind
             when 'fixed' then public.show_at(st.show_date, mv.fixed_day_offset, mv.fixed_time)
             when 'cue_start' then c.planned_start
             else c.planned_end end - make_interval(secs => mv.early_s) as p_deadline,
           case mv.deadline_kind
             when 'fixed' then public.show_at(st.show_date, mv.fixed_day_offset, mv.fixed_time)
             when 'cue_start' then case when c.type = 'anchor' then coalesce(c.started_at, c.due_at)
                                        when c.status in ('running', 'done') then least(c.started_at, c.due_calc)
                                        else c.due_at end
             else case when c.status = 'done' then c.ended_at else c.projected_end end end - make_interval(secs => mv.early_s) as x_deadline
    from public.movement_status ms
    join public.movements mv on mv.id = ms.movement_id
    left join public.zones z on z.id = mv.zone_id
    left join c on c.cue_id = mv.cue_id
    where ms.session_id = p_session
    order by ms.group_id, p_deadline nulls last, ms.code
  loop
    if v_group is distinct from r.group_id then
      v_group := r.group_id;
      v_active_found := false;
    end if;
    if r.status in ('arrived', 'arrived_late', 'missed', 'skipped') then
      continue;
    end if;

    -- A skipped cue skips its movements; a movement without a cue or zone (deleted since) cannot be followed
    if (r.deadline_kind <> 'fixed' and (r.cue_status is null or r.cue_status = 'skipped')) or r.zone_shape is null then
      update public.movement_status
      set status = 'skipped', state = 'done', status_since = p_now, cand_status = null, eta = null, spare_s = null, late_s = null,
          deadline = r.x_deadline, planned_deadline = r.p_deadline, updated_at = now()
      where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
      n := n + 1;
      continue;
    end if;

    if v_active_found then
      -- waits for the group's earlier movement: keep its deadline current, nothing else
      if (r.state, r.status, r.deadline, r.planned_deadline) is distinct from ('waiting', 'pending', r.x_deadline, r.p_deadline) then
        update public.movement_status
        set state = 'waiting', status = 'pending', cand_status = null, deadline = r.x_deadline, planned_deadline = r.p_deadline,
            eta = null, spare_s = null, late_s = null, leave_by = null, moving_since = null, updated_at = now()
        where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
        n := n + 1;
      end if;
      continue;
    end if;
    v_active_found := true;

    -- ---------- The group's active movement ----------
    v_factor := case when v_sim then 1.0 when r.travel_mode = 'vehicle' then 1.4 else 1.3 end;
    v_route := (select mr.path from public.movement_routes mr
                where mr.session_id = p_session and mr.movement_id = r.movement_id and mr.group_id = r.group_id);
    v_arr := '{}'; v_out_rem := '{}'; v_out_prog := '{}'; v_out_bas := '{}';
    v_sig := 0; v_nosig := 0; v_inside := 0;

    for ic in
      select gm.user_id, l.lat, l.lng, l.recorded_at, l.source,
             (select min(zp.entered_at) from public.zone_presence zp
              where zp.session_id = p_session and zp.user_id = gm.user_id and zp.zone_id = r.zone_id and zp.exited_at is null
                and zp.entered_at <= p_now) as inside_since
      from public.group_members gm
      left join lateral (
        select x.lat, x.lng, x.recorded_at, x.source from public.locations x
        where x.event_id = s.event_id and x.user_id = gm.user_id and x.recorded_at >= s.starts_at and x.recorded_at <= p_now
        order by x.recorded_at desc limit 1
      ) l on true
      where gm.group_id = r.group_id and gm.is_ic
    loop
      if ic.inside_since is not null then
        v_inside := v_inside + 1;
        v_arr := v_arr || (ic.inside_since + make_interval(secs => r.dwell_s));
      end if;
      if ic.recorded_at is null then
        continue;                                  -- has not shared in this session
      end if;
      if ic.source = 'stop' or ic.recorded_at <= p_now - interval '2 minutes' then
        v_nosig := v_nosig + 1;
        continue;
      end if;
      v_sig := v_sig + 1;
      if ic.inside_since is not null then
        continue;                                  -- counted in v_arr
      end if;
      d := public.move_dist(r.zone_shape, v_route, ic.lat, ic.lng, v_factor);
      v_out_rem := v_out_rem || d.remaining_m;
      v_out_bas := v_out_bas || d.basis;
      -- progress towards the zone: the same distance from this IC's earliest reading 50-90 s before
      select x.lat, x.lng, x.recorded_at into d_old from public.locations x
      where x.event_id = s.event_id and x.user_id = ic.user_id and x.source <> 'stop'
        and x.recorded_at between ic.recorded_at - interval '90 seconds' and ic.recorded_at - interval '50 seconds'
      order by x.recorded_at limit 1;
      v_out_prog := v_out_prog || case when found then
        ((public.move_dist(r.zone_shape, v_route, d_old.lat, d_old.lng, v_factor)).remaining_m - d.remaining_m)
          / greatest(extract(epoch from ic.recorded_at - d_old.recorded_at), 1) end;
    end loop;

    -- the group moves once one of its ICs does (0.5 m/s closer or more)
    v_moving := exists (select 1 from unnest(v_out_prog) p where p >= 0.5);
    v_moving_since := case when v_moving then coalesce(r.moving_since, p_now) end;
    v_w := case when v_moving then extract(epoch from p_now - v_moving_since) else 0 end;
    v_w := v_w / (v_w + 30);

    -- ETAs: inside ICs when they have stayed long enough; the others by distance / their speed (the planned pace until
    -- they move, then blended towards their real progress)
    v_eta := v_arr;
    v_rem := array_fill(0::double precision, array[cardinality(v_arr)]);
    v_spd := array_fill(null::double precision, array[cardinality(v_arr)]);
    v_mov := array_fill(false, array[cardinality(v_arr)]);
    v_bas := array_fill('inside'::text, array[cardinality(v_arr)]);
    for i in 1 .. coalesce(cardinality(v_out_rem), 0) loop
      v_speed := case when v_out_prog[i] >= 0.5 then (1 - v_w) * r.pace + v_w * v_out_prog[i] else r.pace end;
      v_eta := v_eta || (p_now + make_interval(secs => v_out_rem[i] / v_speed + r.dwell_s));
      v_rem := v_rem || v_out_rem[i];
      v_spd := v_spd || v_speed;
      v_mov := v_mov || coalesce(v_out_prog[i] >= 0.5, false);
      v_bas := v_bas || v_out_bas[i];
    end loop;

    v_k := greatest(1, coalesce(r.min_ics, v_sig));
    v_arrived := (select a from unnest(v_arr) a order by a offset v_k - 1 limit 1);
    if v_arrived > p_now then
      v_arrived := null;                           -- inside, still staying long enough
    end if;
    -- the group's ETA is the k-th IC's (the one the group waits for)
    v_eta_k := null; v_rem_k := null; v_speed := null; v_mov_k := false; v_basis := null;
    select e, rm, sp, mv, bs into v_eta_k, v_rem_k, v_speed, v_mov_k, v_basis
    from unnest(v_eta, v_rem, v_spd, v_mov, v_bas) as t(e, rm, sp, mv, bs) order by e offset v_k - 1 limit 1;
    if v_eta_k is not null then
      v_eta_k := to_timestamp(ceil(extract(epoch from v_eta_k) / 5) * 5);   -- rounded up to 5 s
    end if;

    v_spare := null; v_late := null;
    if v_arrived is not null then
      v_raw := case when v_arrived <= r.x_deadline then 'arrived' else 'arrived_late' end;
      v_spare := public.show_secs(r.x_deadline - v_arrived);
      v_late := case when v_raw = 'arrived_late' then -v_spare end;
    elsif (r.deadline_kind = 'cue_start' and r.cue_status = 'done') or p_now > r.x_deadline + interval '10 minutes' then
      v_raw := 'missed';
      v_late := public.show_secs(p_now - r.x_deadline);
    elsif v_eta_k is null then
      v_raw := 'no_signal';
      v_late := case when p_now > r.x_deadline then public.show_secs(p_now - r.x_deadline) end;
    else
      v_spare := public.show_secs(r.x_deadline - v_eta_k);
      v_raw := case when v_spare >= r.amber_s then 'on_track' when v_spare >= 0 then 'at_risk' else 'late' end;
      v_late := case when v_spare < 0 then -v_spare end;
    end if;

    -- two evaluations in a row must agree (arriving and missing are facts: at once; the first evaluation too)
    v_status := r.status; v_cand := null; v_since := r.status_since;
    if v_raw in ('arrived', 'arrived_late', 'missed') or r.status = 'pending' then
      v_status := v_raw;
    elsif v_raw <> r.status then
      if r.cand_status = v_raw then v_status := v_raw; else v_cand := v_raw; end if;
    end if;
    if v_status is distinct from r.status then
      v_since := p_now;
    end if;
    v_state := case when v_status in ('arrived', 'arrived_late', 'missed') then 'done' else 'active' end;

    -- leave by: worked out while the IC the group waits for has not left, kept once it moves
    if v_state = 'done' or v_inside >= v_k then
      v_leave := r.leave_by;
    elsif v_rem_k is not null and (not v_mov_k or r.leave_by is null) then
      v_leave := r.x_deadline - make_interval(secs => r.dwell_s + v_rem_k / r.pace);
      v_leave := to_timestamp(floor(extract(epoch from v_leave) / 5) * 5);
      v_planned_leave := public.move_planned_leave(r.planned_leave_text, p_session, st.show_date, p_now);
      if v_planned_leave < v_leave then
        v_leave := v_planned_leave;
      end if;
    else
      v_leave := coalesce(r.leave_by, public.move_planned_leave(r.planned_leave_text, p_session, st.show_date, p_now));
    end if;

    if (r.state, r.status, r.status_since, r.cand_status, r.deadline, r.planned_deadline, r.eta, r.spare_s, r.late_s, r.leave_by,
        r.remaining_m, r.speed_mps, r.basis, r.moving_since, r.ics_inside, r.ics_required, r.ics_sharing, r.ics_no_signal, r.arrived_at)
       is distinct from
       (v_state, v_status, v_since, v_cand, r.x_deadline, r.p_deadline,
        case when v_state = 'done' and v_status = 'missed' then null else v_eta_k end, v_spare, v_late, v_leave,
        round(v_rem_k)::real, round(coalesce(v_speed, r.pace)::numeric, 2)::real, v_basis, v_moving_since, v_inside, v_k, v_sig, v_nosig,
        case when v_status in ('arrived', 'arrived_late') then v_arrived end) then
      update public.movement_status
      set state = v_state, status = v_status, status_since = v_since, cand_status = v_cand, deadline = r.x_deadline,
          planned_deadline = r.p_deadline, eta = case when v_state = 'done' and v_status = 'missed' then null else v_eta_k end,
          spare_s = v_spare, late_s = v_late, leave_by = v_leave, remaining_m = round(v_rem_k)::real,
          speed_mps = round(coalesce(v_speed, r.pace)::numeric, 2)::real, basis = v_basis, moving_since = v_moving_since, ics_inside = v_inside,
          ics_required = v_k, ics_sharing = v_sig, ics_no_signal = v_nosig,
          arrived_at = case when v_status in ('arrived', 'arrived_late') then v_arrived end,
          -- a problem that is over needs no acknowledging or snoozing any more (unless the group reported a delay:
          -- the planners' answer to that stands)
          acked_status = case when v_status in ('on_track', 'arrived') and r.delay_at is null then null else acked_status end,
          snoozed_until = case when v_status in ('on_track', 'arrived') and r.delay_at is null then null else snoozed_until end,
          updated_at = now()
      where session_id = p_session and movement_id = r.movement_id and group_id = r.group_id;
      n := n + 1;
    end if;
  end loop;

  if v_sim then
    perform public.sim_follow_plan(p_session, p_now);
  end if;
  return n;
end;
$$;


-- ============================================================
-- 9. Permissions
-- ============================================================
revoke execute on function public.sg_hms(timestamptz) from public, anon, authenticated;
revoke execute on function public.push_mmss(integer) from public, anon, authenticated;
revoke execute on function public.push_collect_moves(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.push_collect_nogo() from public, anon, authenticated;
revoke execute on function public.push_due() from public, anon, authenticated;
revoke execute on function public.push_kick() from public, anon, authenticated;
revoke execute on function public.claim_push_queue(integer) from public, anon, authenticated;
revoke execute on function public.move_tick() from public, anon, authenticated;
grant execute on function public.claim_push_queue(integer) to service_role;

revoke execute on function public.my_moves(uuid) from public, anon;
revoke execute on function public.report_delay(uuid, uuid, uuid, text) from public, anon;
revoke execute on function public.message_group(uuid, uuid, text) from public, anon;
revoke execute on function public.ops_board(uuid, timestamptz) from public, anon;
grant execute on function public.my_moves(uuid) to authenticated;
grant execute on function public.report_delay(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.message_group(uuid, uuid, text) to authenticated;
grant execute on function public.ops_board(uuid, timestamptz) to authenticated;
