-- 029_field_hardening.sql -- after the NDP scenario tests (supabase/tests/ndp_scenarios_test.sql): field hardening
-- and radio features. Applied on the project as 029 + 029b ("Show resumed" wording) + 029c (undo corrects a "Next" push); this file holds all three.
--
--  1. A phone with a fast clock: uploads dated in the future are stored as now (report_location; the website's own
--     inserts through a trigger). Before, one reading 10 min "ahead" made every true reading after it look late.
--  2. Rough fixes (accuracy over 100 m: indoors, under a stand, network location) neither open nor close a zone stay,
--     and are not used as a position by the movements engine.
--  3. +30 s / -30 s: someone else changing the same cue's time within 5 s is refused (two stage managers answering
--     the same radio call made it +60 s). The same person pressing twice still adds twice.
--  4. Radio: groups.radio (channel / call sign; set_group_radio), mark_in_position (ops "heard on the radio" or the
--     group's IC / admin: the arrival counts at once, undo within 5 min; "Auto when ready" counts it), report_delay
--     open to ops (a delay heard on the radio). ops_board and my_moves return the radio; my_moves also can_report,
--     is_ic and held_since.
--  5. A zone the live show still needs cannot be deleted.
--  6. A version switch keeps the planners' answers (handled by, acknowledged, snoozed) and a reported delay, and
--     pushes "Change of plan" to groups whose current move was cancelled or now goes elsewhere.
--  7. Pushes follow the show: nothing while it is held (leave-by times slide), "Show on hold" after 20 s, "Show
--     resumed" with the next step, "Next: <zone>" for back-to-back moves; Get ready / Leave now are keyed by
--     movement code and told again only when the leave-by moves 2 min or more or the zone changes.
-- Long functions are changed by replacing an exact piece of their text (the helper refuses if the piece is not there
-- exactly once), so nothing else in them changes.
create or replace function pg_temp.zz_patch(p_fn regprocedure, p_old text, p_new text)
returns void language plpgsql as $$
declare
  d text := pg_get_functiondef(p_fn);
  n integer := (length(d) - length(replace(d, p_old, ''))) / greatest(length(p_old), 1);
begin
  if n <> 1 then
    raise exception 'patch of %: the text to replace is there % times: %', p_fn, n, left(p_old, 80);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ---------- 1. A phone whose clock is fast: its readings must not be dated in the future ----------
-- (a reading 10 min "ahead" made every true reading after it look late, so the IC's zone stays froze)
create or replace function public.locations_clamp_time()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- the website's own inserts (signed in); the phone's uploads go through report_location
  if current_user = 'authenticated' and new.recorded_at > now() + interval '30 seconds' then
    new.recorded_at := now();
  end if;
  return new;
end $$;
drop trigger if exists locations_clamp_time on public.locations;
create trigger locations_clamp_time before insert on public.locations
  for each row execute function public.locations_clamp_time();
revoke execute on function public.locations_clamp_time() from public, anon, authenticated;

select pg_temp.zz_patch('public.report_location(uuid,double precision,double precision,real,timestamp with time zone)',
  $o$'gps', coalesce(p_recorded_at, now()));$o$,
  $n$'gps',
          -- a phone clock that is fast: now (a time in the future would freeze the IC's zone presence)
          case when p_recorded_at is null or p_recorded_at > now() + interval '30 seconds' then now() else p_recorded_at end);$n$);

-- ---------- 2. Rough fixes (over 100 m: indoors, under a stand, network location) do not decide zones ----------
select pg_temp.zz_patch('public.locations_zone_update()',
  $o$    v_point := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;$o$,
  $n$    -- A fix this rough says nothing about a zone's edge: it neither opens nor closes a stay
    if coalesce(new.accuracy, 0) > 100 then
      perform public.refresh_group_position(v_session, new.event_id, new.group_id, new.recorded_at);
      return null;
    end if;
    v_point := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;$n$);

select pg_temp.zz_patch('public.move_step(uuid,timestamp with time zone)',
  $o$        where x.event_id = s.event_id and x.user_id = gm.user_id and x.recorded_at >= s.starts_at and x.recorded_at <= p_now
        order by x.recorded_at desc limit 1$o$,
  $n$        where x.event_id = s.event_id and x.user_id = gm.user_id and x.recorded_at >= s.starts_at and x.recorded_at <= p_now
          and (x.source = 'stop' or coalesce(x.accuracy, 0) <= 100)   -- a rough fix (100 m+) is not a position
        order by x.recorded_at desc limit 1$n$);
select pg_temp.zz_patch('public.move_step(uuid,timestamp with time zone)',
  $o$      where x.event_id = s.event_id and x.user_id = ic.user_id and x.source <> 'stop'
$o$,
  $n$      where x.event_id = s.event_id and x.user_id = ic.user_id and x.source <> 'stop' and coalesce(x.accuracy, 0) <= 100
$n$);

-- ---------- 3. Two stage managers answer the same radio call: one +30 s, not two ----------
select pg_temp.zz_patch('public.show_add_time(uuid,integer)',
  $o$  v_now timestamptz;
$o$,
  $n$  v_now timestamptz;
  v_last record;
$n$);
select pg_temp.zz_patch('public.show_add_time(uuid,integer)',
  $o$  if run.added_s + p_seconds > 3600$o$,
  $n$  -- someone else changed this cue's time in the last 5 s: most likely the same call on the radio
  select l.by_user, l.at, l.message into v_last from public.show_log l
  where l.session_id = p_session and l.cue_id = run.cue_id and l.kind = 'add_time'
    and l.by_user is distinct from auth.uid() and l.at > v_now - interval '5 seconds' and l.at <= v_now
  order by l.at desc limit 1;
  if found then
    raise exception '% (% s ago). Check the clock: press again only if you want more.',
      rtrim(v_last.message, '.'), greatest(0, round(extract(epoch from v_now - v_last.at))::int) using errcode = 'PT409';
  end if;
  if run.added_s + p_seconds > 3600$n$);

-- ---------- 4. Radio: a group's channel / call sign, "in position" by radio or by the IC ----------
alter table public.groups add column if not exists radio text check (radio is null or char_length(radio) between 1 and 40);
alter table public.movement_status drop constraint if exists movement_status_basis_check;
alter table public.movement_status add constraint movement_status_basis_check
  check (basis in ('route', 'straight', 'inside', 'reported'));
alter table public.show_log drop constraint if exists show_log_kind_check;
alter table public.show_log add constraint show_log_kind_check
  check (kind in ('go', 'hold', 'resume', 'add_time', 'skip', 'end_now', 'auto_start', 'auto_end', 'anchor_start', 'anchor_cut',
                  'waiting_go', 'waiting_groups', 'anchor_risk', 'finished', 'switch', 'keep_holding', 'message', 'delay_report',
                  'radio'));
alter table public.push_queue drop constraint if exists push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check
  check (kind in ('get_ready', 'leave_now', 'late', 'message', 'nogo', 'next', 'hold', 'resume', 'change'));

create or replace function public.set_group_radio(p_group uuid, p_radio text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.groups where id = p_group;
  if v_event is null then
    raise exception 'That group no longer exists';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change group details' using errcode = '42501';
  end if;
  p_radio := nullif(regexp_replace(btrim(coalesce(p_radio, '')), '\s+', ' ', 'g'), '');
  if char_length(p_radio) > 40 then
    raise exception 'Keep the radio channel / call sign under 40 characters';
  end if;
  update public.groups set radio = p_radio where id = p_group;
end;
$$;

-- "In position": a marshal or planner heard it on the radio, or the group's IC / admin says so. Faster than GPS (which
-- needs the IC inside for the stay time); the arrival counts at once. Undo within 5 minutes (a wrong call).
create or replace function public.mark_in_position(p_session uuid, p_movement uuid, p_group uuid, p_undo boolean default false)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_sessions;
  ms public.movement_status;
  v_ops boolean;
  v_now timestamptz := public.show_now();
  v_zone text;
  v_name text;
  v_how text;
begin
  select * into s from public.event_sessions where id = p_session;
  if not found or s.ended_at is not null then
    raise exception 'The show is not live';
  end if;
  v_ops := public.has_event_role(s.event_id, array['root', 'planner', 'marshal']);
  if not v_ops and not exists (select 1 from public.group_members gm where gm.group_id = p_group and gm.user_id = auth.uid()
                                and (gm.is_ic or gm.is_admin)) then
    raise exception 'Only the group''s IC or admin, or the root, planners and marshals can say a group is in position'
      using errcode = '42501';
  end if;
  select * into ms from public.movement_status
  where session_id = p_session and movement_id = p_movement and group_id = p_group for update;
  if not found then
    raise exception 'That movement is not in the live show';
  end if;
  select z.code into v_zone from public.movements mv join public.zones z on z.id = mv.zone_id where mv.id = p_movement;
  select g.name into v_name from public.groups g where g.id = p_group;
  v_how := case when v_ops then 'radio, ' else 'IC, ' end || public.show_who(auth.uid());

  if p_undo then
    if ms.basis is distinct from 'reported' or ms.state <> 'done' or ms.arrived_at < v_now - interval '5 minutes' then
      raise exception 'Only a reported arrival of the last 5 minutes can be undone';
    end if;
    update public.movement_status
    set state = 'active', status = 'pending', cand_status = null, arrived_at = null, late_s = null, spare_s = null,
        basis = null, status_since = v_now, updated_at = now()
    where session_id = p_session and movement_id = p_movement and group_id = p_group;
    -- the group's next movement goes back to waiting
    update public.movement_status
    set state = 'waiting', status = 'pending', cand_status = null, updated_at = now()
    where session_id = p_session and group_id = p_group and state = 'active' and movement_id <> p_movement;
    perform public.show_log_add(p_session, null, 'radio',
      v_name || ' not in position at ' || coalesce(v_zone, 'its zone') || ' after all (' || v_how || ').', auth.uid(), v_now);
    return 'undone';
  end if;

  if ms.state = 'done' then
    raise exception '% is already % (since %).', v_name,
      case ms.status when 'arrived' then 'in position' when 'arrived_late' then 'in position' else replace(ms.status, '_', ' ') end,
      coalesce(public.sg_hms(ms.arrived_at), '-') using errcode = 'PT409';
  end if;
  if ms.state <> 'active' then
    raise exception 'That is not the group''s current movement';
  end if;
  update public.movement_status
  set state = 'done', status = case when ms.deadline is null or v_now <= ms.deadline then 'arrived' else 'arrived_late' end,
      cand_status = null, status_since = v_now, arrived_at = v_now, basis = 'reported', remaining_m = 0,
      late_s = case when ms.deadline is not null and v_now > ms.deadline then public.show_secs(v_now - ms.deadline) end,
      spare_s = case when ms.deadline is not null and v_now <= ms.deadline then public.show_secs(ms.deadline - v_now) end,
      updated_at = now()
  where session_id = p_session and movement_id = p_movement and group_id = p_group;
  perform public.show_log_add(p_session, null, 'radio',
    v_name || ' in position at ' || coalesce(v_zone, 'its zone') || ' (' || v_how || ')' ||
    case when ms.deadline is not null and v_now > ms.deadline then ', ' || public.push_mmss(public.show_secs(v_now - ms.deadline)) || ' late'
         else '' end || '.', auth.uid(), v_now);
  return 'in_position';
end;
$$;

-- "Auto when ready": a group reported in position (or arrived by GPS) is there
select pg_temp.zz_patch('public.show_missing_groups(uuid,uuid,uuid,timestamp with time zone)',
  $o$    and not (
      e.zone_id is not null$o$,
  $n$    and not exists (select 1 from public.movement_status ms
                    where ms.session_id = p_session and ms.movement_id = e.movement_id and ms.group_id = e.group_id
                      and ms.status in ('arrived', 'arrived_late'))
    and not (
      e.zone_id is not null$n$);

-- A delay heard on the radio: a marshal or planner can pass it on too
select pg_temp.zz_patch('public.report_delay(uuid,uuid,uuid,text)',
  $o$  if v_event is null or public.my_group_id(v_event) is distinct from p_group then
    raise exception 'Only a member of this group can report its delay' using errcode = '42501';$o$,
  $n$  if v_event is null or (public.my_group_id(v_event) is distinct from p_group
                         and not public.has_event_role(v_event, array['root', 'planner', 'marshal'])) then
    raise exception 'Only a member of this group (or the root, planners and marshals) can report its delay' using errcode = '42501';$n$);
select pg_temp.zz_patch('public.report_delay(uuid,uuid,uuid,text)',
  $o$      v_name || ' reports a delay (' || public.show_who(auth.uid()) || ')'$o$,
  $n$      v_name || ' reports a delay (' || case when public.my_group_id(v_event) is distinct from p_group then 'radio, ' else '' end ||
      public.show_who(auth.uid()) || ')'$n$);

-- The group's radio on the ops board and on the group's own card; the card also knows the show is held and who may
-- say "in position"
select pg_temp.zz_patch('public.ops_board(uuid,timestamp with time zone)',
  $o$'movement_id', ms.movement_id, 'group_id', ms.group_id, 'code', ms.code,$o$,
  $n$'movement_id', ms.movement_id, 'group_id', ms.group_id, 'code', ms.code,
        'radio', (select g.radio from public.groups g where g.id = ms.group_id),$n$);
select pg_temp.zz_patch('public.my_moves(uuid)',
  $o$    'group_id', v_group,$o$,
  $n$    'group_id', v_group,
    'radio', (select g.radio from public.groups g where g.id = v_group),
    'can_report', exists (select 1 from public.group_members gm where gm.group_id = v_group and gm.user_id = auth.uid()
                          and (gm.is_ic or gm.is_admin)),
    'is_ic', exists (select 1 from public.group_members gm where gm.group_id = v_group and gm.user_id = auth.uid() and gm.is_ic),
    'held_since', (select st.held_since from public.show_state st where st.session_id = p_session),$n$);

-- ---------- 5. A zone the live show still needs cannot be deleted ----------
create or replace function public.zones_guard_live()
returns trigger language plpgsql set search_path = '' as $$
declare
  r record;
begin
  select ms.code, g.name into r
  from public.movement_status ms
  join public.movements m on m.id = ms.movement_id
  join public.groups g on g.id = ms.group_id
  join public.event_sessions s on s.id = ms.session_id and s.ended_at is null
  where m.zone_id = old.id and ms.state <> 'done'
  limit 1;
  if found then
    raise exception '% is used by the live show (movement % of %): end the show or switch to a version without it first.',
      coalesce(old.code, old.name), r.code, r.name using errcode = 'PT409';
  end if;
  return old;
end $$;
drop trigger if exists zones_guard_live on public.zones;
create trigger zones_guard_live before delete on public.zones for each row execute function public.zones_guard_live();
revoke execute on function public.zones_guard_live() from public, anon, authenticated;

-- ---------- 6. A version switch keeps the planners' answers, and tells groups whose move changed ----------
select pg_temp.zz_patch('public.move_step(uuid,timestamp with time zone)',
  $o$    delete from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id;$o$,
  $n$    -- the planners' answers and a reported delay stay with the group's movement (same code)
    update public.movement_status n
    set handled_by = o.handled_by, acked_status = o.acked_status, snoozed_until = o.snoozed_until,
        delay_note = o.delay_note, delay_at = o.delay_at, delay_by = o.delay_by, updated_at = now()
    from public.movement_status o
    where n.session_id = p_session and n.run_sheet_id = st.run_sheet_id and n.state <> 'done'
      and o.session_id = p_session and o.run_sheet_id <> st.run_sheet_id and o.code = n.code and o.group_id = n.group_id
      and o.state <> 'done';
    -- a group on its way (or about to go) whose movement is gone or goes elsewhere now: "Change of plan"
    if not v_sim then
      insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
      select gm.user_id, o.event_id, p_session, 'change',
             'change:' || p_session || ':' || o.code || ':' || o.group_id || ':' || gm.user_id || ':' || st.run_sheet_id,
             'Change of plan',
             case when n.movement_id is null
                  then 'Your move to ' || coalesce(oz.name || ' (' || oz.code || ')', 'its zone') || ' is cancelled. Wait for instructions.'
                  else 'Go to ' || nz.name || ' (' || nz.code || ') instead' || coalesce(' of ' || oz.code, '') || '.' end,
             jsonb_build_object('kind', 'move', 'eventId', o.event_id, 'groupId', o.group_id, 'code', o.code,
                                'zoneId', nm.zone_id, 'at', p_now, 'tag', 'move-' || o.code || '-' || o.group_id)
      from public.movement_status o
      join public.movements om on om.id = o.movement_id
      left join public.zones oz on oz.id = om.zone_id
      left join public.movement_status n on n.session_id = p_session and n.run_sheet_id = st.run_sheet_id
                                         and n.code = o.code and n.group_id = o.group_id
      left join public.movements nm on nm.id = n.movement_id
      left join public.zones nz on nz.id = nm.zone_id
      join public.group_members gm on gm.group_id = o.group_id and (gm.is_ic or gm.is_admin)
      where o.session_id = p_session and o.run_sheet_id <> st.run_sheet_id and o.state = 'active'
        and (n.movement_id is null or nm.zone_id is distinct from om.zone_id)
      on conflict (dedup) do nothing;
    end if;
    delete from public.movement_status where session_id = p_session and run_sheet_id <> st.run_sheet_id;$n$);

-- ---------- 7. Pushes that follow the show: held, resumed, next move, moved times ----------
create or replace function public.push_collect_moves(p_session uuid, p_now timestamptz)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  st public.show_state;
  v_res record;
  v_prev_res timestamptz;
  n integer := 0;
  k integer;
begin
  select * into st from public.show_state where session_id = p_session;

  -- Held (rain, lightning, an incident): leave-by times slide with the hold, so no Get ready / Leave now / late. After
  -- 20 s, one "Show on hold" to the ICs and admins of groups that are about to move or on their way (the radio's
  -- "all stations hold").
  if st.held_since is not null then
    if p_now >= st.held_since + interval '20 seconds' then
      insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
      select distinct on (gm.user_id) gm.user_id, ms.event_id, ms.session_id, 'hold',
             'hold:' || ms.session_id || ':' || extract(epoch from st.held_since)::bigint || ':' || gm.user_id,
             'Show on hold', 'Stay where you are and wait: you will be told when the show goes on.',
             jsonb_build_object('kind', 'show', 'eventId', ms.event_id, 'heldAt', st.held_since, 'tag', 'show-' || ms.session_id)
      from public.movement_status ms
      join public.group_members gm on gm.group_id = ms.group_id and (gm.is_ic or gm.is_admin)
      where ms.session_id = p_session and ms.state = 'active'
        and (ms.moving_since is not null or ms.leave_by is null or ms.leave_by <= p_now + interval '15 minutes')
      order by gm.user_id
      on conflict (dedup) do nothing;
      get diagnostics n = row_count;
    end if;
    return n;
  end if;

  -- Resumed in the last 2 minutes: everyone told "on hold" hears it goes on, with their next step
  select l.id, l.at into v_res from public.show_log l
  where l.session_id = p_session and l.kind = 'resume' and l.at <= p_now and l.at > p_now - interval '2 minutes'
  order by l.at desc limit 1;
  if found then
    select max(l.at) into v_prev_res from public.show_log l where l.session_id = p_session and l.kind = 'resume' and l.at < v_res.at;
    insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
    select distinct on (h.user_id) h.user_id, h.event_id, p_session, 'resume',
           'resume:' || p_session || ':' || v_res.id || ':' || h.user_id,
           'Show resumed',
           case when ms.movement_id is null then 'The show goes on.'
                when ms.leave_by is not null and ms.leave_by <= p_now and ms.ics_inside < ms.ics_required
                  then 'Leave now for ' || z.name || ': be inside ' || z.code || ' by ' || public.sg_hms(ms.deadline) || '.'
                when ms.leave_by is not null
                  then 'Leave at ' || public.sg_hms(ms.leave_by) || ' for ' || z.name || ' (be inside by ' || public.sg_hms(ms.deadline) || ').'
                else 'Be inside ' || z.code || ' by ' || public.sg_hms(ms.deadline) || '.' end,
           jsonb_build_object('kind', 'show', 'eventId', h.event_id, 'groupId', ms.group_id, 'code', ms.code, 'zoneId', mv.zone_id,
                              'leaveBy', ms.leave_by, 'at', p_now,
                              'leaveNow', coalesce(ms.leave_by <= p_now and ms.ics_inside < ms.ics_required, false),
                              'tag', 'show-' || p_session)
    from public.push_queue h
    join public.group_members gm on gm.user_id = h.user_id and gm.event_id = h.event_id and (gm.is_ic or gm.is_admin)
    left join public.movement_status ms on ms.session_id = p_session and ms.group_id = gm.group_id and ms.state = 'active'
    left join public.movements mv on mv.id = ms.movement_id
    left join public.zones z on z.id = mv.zone_id
    where h.session_id = p_session and h.kind = 'hold'
      and (h.data ->> 'heldAt')::timestamptz <= v_res.at
      and (v_prev_res is null or (h.data ->> 'heldAt')::timestamptz > v_prev_res)
    order by h.user_id
    on conflict (dedup) do nothing;
    get diagnostics k = row_count;
    n := n + k;
  end if;

  -- Next move: the group just got to its last zone and has another to go to straight away
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select gm.user_id, ms.event_id, ms.session_id, 'next',
         'next:' || ms.session_id || ':' || ms.code || ':' || ms.group_id || ':' || gm.user_id,
         'Next: ' || z.name,
         'Be inside ' || z.code || ' by ' || public.sg_hms(ms.deadline) || coalesce(' · ' || round(ms.remaining_m) || ' m to go', '') ||
         case when ms.leave_by is null then '.' when ms.leave_by <= p_now then '. Leave now.'
              else '. Leave at ' || public.sg_hms(ms.leave_by) || '.' end,
         jsonb_build_object('kind', 'move', 'eventId', ms.event_id, 'movementId', ms.movement_id, 'groupId', ms.group_id,
                            'code', ms.code, 'zoneId', mv.zone_id, 'leaveBy', ms.leave_by, 'at', p_now,
                            'leaveNow', coalesce(ms.leave_by <= p_now, false), 'tag', 'move-' || ms.code || '-' || ms.group_id)
  from public.movement_status ms
  join public.movements mv on mv.id = ms.movement_id
  join public.zones z on z.id = mv.zone_id
  join public.group_members gm on gm.group_id = ms.group_id and (gm.is_ic or gm.is_admin)
  where ms.session_id = p_session and ms.state = 'active' and ms.ics_inside < ms.ics_required and ms.deadline is not null
    and exists (select 1 from public.movement_status p
                where p.session_id = ms.session_id and p.group_id = ms.group_id and p.state = 'done'
                  and p.status in ('arrived', 'arrived_late') and p.arrived_at <= p_now and p.arrived_at > p_now - interval '2 minutes')
  on conflict (dedup) do nothing;
  get diagnostics k = row_count;
  n := n + k;

  -- Get ready (-60 s) / Leave now (at the leave-by) / Running late. Get ready and Leave now are told again when the
  -- leave-by moves by 2 minutes or more (after a hold, a switch) or the zone changes; not when "Next", "Show
  -- resumed" or "Change of plan" already said it.
  insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
  select gm.user_id, ms.event_id, ms.session_id, k.kind,
         k.kind || ':' || ms.session_id || ':' || ms.code || ':' || ms.group_id || ':' || gm.user_id ||
           case when k.kind = 'late' then '' else ':' || extract(epoch from ms.leave_by)::bigint || ':' || mv.zone_id end,
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
                            'code', ms.code, 'zoneId', mv.zone_id, 'leaveBy', ms.leave_by, 'at', p_now,
                            'tag', 'move-' || ms.code || '-' || ms.group_id)
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
      -- readings to see a group has set off)
      ('late', ms.status = 'late' and (ms.moving_since is not null or ms.leave_by is null
                                       or p_now >= ms.leave_by + interval '60 seconds'))
  ) as k(kind, due)
  where ms.session_id = p_session and ms.state = 'active' and k.due
    and not exists (
      select 1 from public.push_queue q
      where q.session_id = ms.session_id and q.user_id = gm.user_id and q.data ->> 'code' = ms.code
        and q.data ->> 'groupId' = ms.group_id::text
        and case k.kind
              -- told this already, for (nearly) the same time and the same zone
              when 'get_ready' then q.kind in ('get_ready', 'leave_now', 'next', 'resume', 'change')
                                    and q.data ->> 'zoneId' = mv.zone_id::text and q.data ? 'leaveBy'
                                    and abs(extract(epoch from (q.data ->> 'leaveBy')::timestamptz - ms.leave_by)) < 120
              when 'leave_now' then ((q.kind = 'leave_now') or (q.kind in ('next', 'resume') and (q.data ->> 'leaveNow')::boolean))
                                    and q.data ->> 'zoneId' = mv.zone_id::text and q.data ? 'leaveBy'
                                    and abs(extract(epoch from (q.data ->> 'leaveBy')::timestamptz - ms.leave_by)) < 120
              -- a minute's grace after "Next" / "Show resumed" / "Change of plan"
              else q.kind in ('next', 'resume', 'change') and (q.data ->> 'at')::timestamptz > p_now - interval '60 seconds'
            end)
  on conflict (dedup) do nothing;
  get diagnostics k = row_count;
  return n + k;
end;
$$;

-- ---------- Permissions ----------
revoke execute on function public.set_group_radio(uuid, text) from public, anon;
revoke execute on function public.mark_in_position(uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.set_group_radio(uuid, text) to authenticated;
grant execute on function public.mark_in_position(uuid, uuid, uuid, boolean) to authenticated;

-- ---------- 029b: "Show resumed" to a group already on its way says keep going, not leave now ----------
select pg_temp.zz_patch('public.push_collect_moves(uuid,timestamp with time zone)',
  $o$           case when ms.movement_id is null then 'The show goes on.'
                when ms.leave_by is not null$o$,
  $n$           case when ms.movement_id is null then 'The show goes on.'
                when ms.moving_since is not null
                  then 'Keep going to ' || z.name || ': be inside ' || z.code || ' by ' || public.sg_hms(ms.deadline) || '.'
                when ms.leave_by is not null$n$);
select pg_temp.zz_patch('public.push_collect_moves(uuid,timestamp with time zone)',
  $o$                              'leaveNow', coalesce(ms.leave_by <= p_now and ms.ics_inside < ms.ics_required, false),$o$,
  $n$                              'leaveNow', coalesce(ms.leave_by <= p_now and ms.ics_inside < ms.ics_required
                                                   and ms.moving_since is null, false),$n$);

-- ---------- 029c: undoing a reported arrival corrects a "Next: ..." the group was already sent ----------
select pg_temp.zz_patch('public.mark_in_position(uuid,uuid,uuid,boolean)',
  $o$    perform public.show_log_add(p_session, null, 'radio',
      v_name || ' not in position at ' || coalesce(v_zone, 'its zone') || ' after all (' || v_how || ').', auth.uid(), v_now);$o$,
  $n$    perform public.show_log_add(p_session, null, 'radio',
      v_name || ' not in position at ' || coalesce(v_zone, 'its zone') || ' after all (' || v_how || ').', auth.uid(), v_now);
    -- the group may already have been told "Next: ..." (a real event): correct it
    if not exists (select 1 from public.events e where e.id = s.event_id and e.is_simulation) then
      insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
      select distinct gm.user_id, s.event_id, p_session, 'change',
             'change:undo:' || p_session || ':' || ms.code || ':' || p_group || ':' || gm.user_id || ':' || extract(epoch from v_now)::bigint,
             'Correction: not in position yet',
             'Keep heading to ' || coalesce(v_zone, 'your zone') || ': be inside by ' || public.sg_hms(ms.deadline) || '.',
             jsonb_build_object('kind', 'move', 'eventId', s.event_id, 'groupId', p_group, 'code', ms.code, 'at', v_now,
                                'tag', 'move-' || ms.code || '-' || p_group)
      from public.group_members gm
      join public.push_queue q on q.session_id = p_session and q.user_id = gm.user_id and q.kind = 'next'
                               and q.data ->> 'groupId' = p_group::text and (q.data ->> 'at')::timestamptz >= ms.arrived_at
      where gm.group_id = p_group and (gm.is_ic or gm.is_admin)
      on conflict (dedup) do nothing;
    end if;$n$);
