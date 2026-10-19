-- 032: Message everyone (broadcast).
--
-- Until now a planner could only message ONE group at a time, and only a group already in "Needs attention" during a
-- live show (message_group, 027/028). Weather, a medical stop or an evacuation needs every group told at once: "Lightning:
-- take shelter now", "Hold in place", "Evacuate to DISPERSAL". The NDP scenario tests (lightning hold, evacuation) found
-- this gap on 19 Oct 2026.
--
-- A broadcast goes to an audience worked out when it is sent:
--   everyone   every person in the event (all roles)
--   groups     every member of every group
--   ics        every group's ICs and group admins
--   staff      root, planners and marshals
--   sector     the members of the groups in one sector, plus the marshals of that sector
--   category   the members of the groups in one category (e.g. every "Contingent")
-- Each recipient gets a push (not in simulation events, as for group messages) and a banner on the event page that stays
-- until they press "Got it" or a planner clears it. The planner sees how many have seen it and pressed Got it, and who
-- has not, so the radio is used only for those. Root and planners send; the sender is not a recipient.
--
-- Pushes reuse the queue (028) as kind 'message' with their own tag, so the Edge Function and the phone app's
-- notification code need no change. The show log gets a 'broadcast' line when a show is running.

create table if not exists public.broadcasts (
  id bigserial primary key,
  event_id uuid not null references public.events (id) on delete cascade,
  session_id uuid references public.event_sessions (id) on delete set null, -- the live session when it was sent, if any
  audience text not null check (audience in ('everyone', 'groups', 'ics', 'staff', 'sector', 'category')),
  audience_value text check (audience_value is null or char_length(audience_value) between 1 and 50),
  body text not null check (char_length(body) between 1 and 300),
  urgent boolean not null default false,
  from_user uuid references auth.users (id) on delete set null,
  from_name text,
  at timestamptz not null default now(),
  cleared_at timestamptz,
  cleared_by uuid references auth.users (id) on delete set null,
  check ((audience in ('sector', 'category')) = (audience_value is not null))
);
create index if not exists broadcasts_event on public.broadcasts (event_id, at desc);

create table if not exists public.broadcast_recipients (
  broadcast_id bigint not null references public.broadcasts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  seen_at timestamptz,  -- the banner was on their screen
  acked_at timestamptz, -- they pressed Got it
  primary key (broadcast_id, user_id)
);
create index if not exists broadcast_recipients_user on public.broadcast_recipients (user_id, broadcast_id);

alter table public.broadcasts enable row level security;
alter table public.broadcast_recipients enable row level security;

-- The two read rules ask about each other's table; asking through these (security definer) helpers keeps Postgres from
-- going round in circles ("infinite recursion detected in policy").
create or replace function public.broadcast_is_recipient(p_id bigint)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.broadcast_recipients r where r.broadcast_id = p_id and r.user_id = auth.uid());
$$;
create or replace function public.broadcast_planner_of(p_id bigint)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.broadcasts b
    where b.id = p_id and public.has_event_role(b.event_id, array['root', 'planner'])
  );
$$;

-- Staff of the event see every broadcast; anyone else only the ones sent to them.
drop policy if exists "broadcasts: staff and recipients read" on public.broadcasts;
create policy "broadcasts: staff and recipients read" on public.broadcasts
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']) or public.broadcast_is_recipient(id));

-- Your own receipt; root and planners see everyone's (for "seen by 80 of 120").
drop policy if exists "broadcast recipients: own and planners read" on public.broadcast_recipients;
create policy "broadcast recipients: own and planners read" on public.broadcast_recipients
  for select to authenticated
  using (user_id = (select auth.uid()) or public.broadcast_planner_of(broadcast_id));

-- (Supabase grants signed-in users every right on a new table by default: take them all back, then allow reading)
revoke all on table public.broadcasts, public.broadcast_recipients from anon, authenticated, public;
grant select on table public.broadcasts, public.broadcast_recipients to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.broadcasts;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.broadcast_recipients;
exception when duplicate_object then null;
end $$;

-- The show log may say "broadcast"
alter table public.show_log drop constraint if exists show_log_kind_check;
alter table public.show_log add constraint show_log_kind_check check (kind in (
  'go', 'hold', 'resume', 'add_time', 'skip', 'end_now', 'auto_start', 'auto_end', 'anchor_start', 'anchor_cut',
  'waiting_go', 'waiting_groups', 'anchor_risk', 'finished', 'switch', 'keep_holding', 'message', 'delay_report',
  'radio', 'broadcast'
));

-- ============================================================
-- Who an audience is (everyone except the sender)
-- ============================================================
create or replace function public.broadcast_audience(p_event uuid, p_audience text, p_value text, p_sender uuid)
returns table (user_id uuid)
language sql stable security definer set search_path = ''
as $$
  select distinct x.user_id from (
    select er.user_id from public.event_roles er
    where er.event_id = p_event and p_audience = 'everyone'
    union all
    select gm.user_id from public.group_members gm
    where gm.event_id = p_event and p_audience = 'groups'
    union all
    select gm.user_id from public.group_members gm
    where gm.event_id = p_event and p_audience = 'ics' and (gm.is_ic or gm.is_admin)
    union all
    select er.user_id from public.event_roles er
    where er.event_id = p_event and p_audience = 'staff' and er.role in ('root', 'planner', 'marshal')
    union all
    select gm.user_id from public.group_members gm join public.groups g on g.id = gm.group_id
    where gm.event_id = p_event and p_audience = 'sector' and lower(g.sector) = lower(p_value)
    union all
    select er.user_id from public.event_roles er
    where er.event_id = p_event and p_audience = 'sector' and er.role = 'marshal' and lower(er.sector) = lower(p_value)
    union all
    select gm.user_id from public.group_members gm join public.groups g on g.id = gm.group_id
    where gm.event_id = p_event and p_audience = 'category' and lower(g.category) = lower(p_value)
  ) x
  where x.user_id is distinct from p_sender;
$$;

-- ============================================================
-- Send (or, with p_dry, only count who would get it)
-- ============================================================
create or replace function public.broadcast_send(
  p_event uuid, p_audience text, p_value text, p_body text, p_urgent boolean default false, p_dry boolean default false
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_from text := public.show_who(auth.uid());
  v_session uuid;
  v_id bigint;
  v_count integer;
  v_sim boolean;
  v_label text;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root and planners can message everyone' using errcode = '42501';
  end if;
  if p_audience not in ('everyone', 'groups', 'ics', 'staff', 'sector', 'category') then
    raise exception 'Pick who gets the message';
  end if;
  p_value := nullif(btrim(coalesce(p_value, '')), '');
  if p_audience in ('sector', 'category') and p_value is null then
    raise exception 'Pick the %', p_audience;
  end if;
  if p_audience not in ('sector', 'category') then
    p_value := null;
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 300 then
    raise exception 'Write a message of 1 to 300 characters';
  end if;

  select count(*) into v_count from public.broadcast_audience(p_event, p_audience, p_value, v_me);
  if p_dry then
    return jsonb_build_object('recipients', v_count);
  end if;
  if v_count = 0 then
    raise exception 'Nobody would get this message: no one in the event matches "%"', coalesce(p_value, p_audience);
  end if;

  select s.id into v_session from public.event_sessions s
  where s.event_id = p_event and s.ended_at is null and s.starts_at <= now()
  order by s.starts_at desc limit 1;

  insert into public.broadcasts (event_id, session_id, audience, audience_value, body, urgent, from_user, from_name)
  values (p_event, v_session, p_audience, p_value, p_body, coalesce(p_urgent, false), v_me, v_from)
  returning id into v_id;

  insert into public.broadcast_recipients (broadcast_id, user_id)
  select v_id, a.user_id from public.broadcast_audience(p_event, p_audience, p_value, v_me) a;

  v_label := case p_audience
    when 'everyone' then 'everyone'
    when 'groups' then 'every group'
    when 'ics' then 'all ICs and group admins'
    when 'staff' then 'the planners and marshals'
    when 'sector' then 'sector ' || p_value
    else 'every ' || p_value || ' group' end;
  select e.is_simulation into v_sim from public.events e where e.id = p_event;
  if not coalesce(v_sim, false) then
    insert into public.push_queue (user_id, event_id, session_id, kind, dedup, title, body, data)
    select r.user_id, p_event, v_session, 'message', 'broadcast:' || v_id || ':' || r.user_id,
           case when p_urgent then 'URGENT · ' else '' end || 'Message from ' || v_from || ' to ' || v_label, p_body,
           jsonb_build_object('kind', 'message', 'eventId', p_event, 'broadcastId', v_id, 'tag', 'broadcast-' || v_id)
    from public.broadcast_recipients r
    where r.broadcast_id = v_id
    on conflict (dedup) do nothing;
  end if;

  if v_session is not null and exists (select 1 from public.show_state where session_id = v_session) then
    perform public.show_log_add(v_session, null, 'broadcast',
      v_from || ' messaged ' || v_label || ' (' || v_count || ' people)' || case when p_urgent then ', urgent' else '' end ||
      ': "' || p_body || '"', v_me, public.show_now());
  end if;
  perform public.push_kick();
  return jsonb_build_object('id', v_id, 'recipients', v_count);
end;
$$;

-- ============================================================
-- A recipient: seen (on screen) / Got it
-- ============================================================
create or replace function public.broadcast_mark(p_id bigint, p_ack boolean default false)
returns void
language sql security definer set search_path = ''
as $$
  update public.broadcast_recipients
  set seen_at = coalesce(seen_at, now()),
      acked_at = case when p_ack then coalesce(acked_at, now()) else acked_at end
  where broadcast_id = p_id and user_id = auth.uid();
$$;

-- ============================================================
-- A planner: take it off everyone's screen
-- ============================================================
create or replace function public.broadcast_clear(p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.broadcasts where id = p_id;
  if v_event is null or not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root and planners can clear a message' using errcode = '42501';
  end if;
  update public.broadcasts set cleared_at = coalesce(cleared_at, now()), cleared_by = coalesce(cleared_by, auth.uid())
  where id = p_id;
end;
$$;

-- ============================================================
-- A planner: who has seen it, who has not (with their group, to radio them)
-- ============================================================
create or replace function public.broadcast_status(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.broadcasts where id = p_id;
  if v_event is null or not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root and planners can see who has read a message' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'total', count(*),
      'seen', count(*) filter (where r.seen_at is not null),
      'acked', count(*) filter (where r.acked_at is not null),
      'waiting', coalesce(jsonb_agg(jsonb_build_object(
          'name', coalesce(nullif(p.display_name, ''), p.username),
          'group', g.name,
          'radio', g.radio,
          'ic', coalesce(gm.is_ic, false),
          'seen', r.seen_at is not null
        ) order by g.name nulls last, coalesce(nullif(p.display_name, ''), p.username)) filter (where r.acked_at is null), '[]'::jsonb)
    )
    from public.broadcast_recipients r
    join public.profiles p on p.id = r.user_id
    left join public.group_members gm on gm.user_id = r.user_id and gm.event_id = v_event
    left join public.groups g on g.id = gm.group_id
    where r.broadcast_id = p_id
  );
end;
$$;

revoke execute on function public.broadcast_audience(uuid, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.broadcast_is_recipient(bigint) from public, anon;
revoke execute on function public.broadcast_planner_of(bigint) from public, anon;
grant execute on function public.broadcast_is_recipient(bigint) to authenticated;
grant execute on function public.broadcast_planner_of(bigint) to authenticated;
revoke execute on function public.broadcast_send(uuid, text, text, text, boolean, boolean) from public, anon;
revoke execute on function public.broadcast_mark(bigint, boolean) from public, anon;
revoke execute on function public.broadcast_clear(bigint) from public, anon;
revoke execute on function public.broadcast_status(bigint) from public, anon;
grant execute on function public.broadcast_send(uuid, text, text, text, boolean, boolean) to authenticated;
grant execute on function public.broadcast_mark(bigint, boolean) to authenticated;
grant execute on function public.broadcast_clear(bigint) to authenticated;
grant execute on function public.broadcast_status(bigint) to authenticated;
