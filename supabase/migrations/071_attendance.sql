-- Numbering (1 Nov): written by Ern on the event_creation_ern branch as 037, and applied to the live project
-- directly on 28 Oct. Renumbered 071 when merged into komin-merge, whose own 035-038 are different migrations.
-- Every function and trigger here was checked live before the merge; this file is the record, not a pending change.

-- 037_attendance.sql -- attendance (roll calls), in one of two modes the organisers choose for the event.
-- Run AFTER 036_auto_headcount.sql (Supabase -> SQL Editor). Can be re-run, also over the first version of this file
-- (the 6-digit spoken code), which it replaces.
--
--   manual  the group's IC (or admin) ticks people present or excused by hand. For ICs the organisers trust.
--   qr      the IC's screen shows a QR code that changes every 5 seconds, and each person scans it with the
--           app. A photo of it sent to someone who is not there is out of date before they can use it (the QR on
--           screen and the one before it are accepted: at most 10 seconds). ICs and admins cannot mark anyone by
--           hand in this mode, only the root and planners can.
--
-- The root or a planner sets the event's mode; each roll call keeps the mode it was opened in.
-- The QR is made here from a secret no one can read, so a phone cannot make the next one.
-- A roll call closes by itself after its time (5-60 minutes), or when it is closed by hand.

-- ============================================================
-- 1. Tables
-- ============================================================
alter table public.events add column if not exists attendance_mode text not null default 'manual'
  check (attendance_mode in ('manual', 'qr'));

create table if not exists public.attendance_rollcalls (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  opened_by uuid references public.profiles (id) on delete set null,
  opened_at timestamptz not null default now(),
  closes_at timestamptz not null,
  closed_at timestamptz -- closed early by hand (null: open until closes_at)
);
alter table public.attendance_rollcalls add column if not exists mode text not null default 'manual'
  check (mode in ('manual', 'qr'));
create index if not exists attendance_rollcalls_event on public.attendance_rollcalls (event_id, opened_at desc);

-- The secret each QR is made from. No one may read it: only the functions below.
create table if not exists public.attendance_secrets (
  rollcall_id uuid primary key references public.attendance_rollcalls (id) on delete cascade,
  secret text not null
);

create table if not exists public.attendance_checkins (
  rollcall_id uuid not null references public.attendance_rollcalls (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null check (status in ('present', 'excused')),
  method text not null, -- 'scan' (scanned the QR) or 'manual' (marked by hand)
  marked_by uuid references public.profiles (id) on delete set null,
  at timestamptz not null default now(),
  primary key (rollcall_id, user_id)
);
create index if not exists attendance_checkins_event on public.attendance_checkins (event_id);
-- (the first version had 'code' for the spoken code)
alter table public.attendance_checkins drop constraint if exists attendance_checkins_method_check;
update public.attendance_checkins set method = 'scan' where method = 'code';
alter table public.attendance_checkins add constraint attendance_checkins_method_check check (method in ('scan', 'manual'));

-- The first version's spoken code: gone
drop function if exists public.check_in(uuid, text);
drop function if exists public.rollcall_code(uuid);
drop function if exists public.att_code(text, bigint);
drop function if exists public.att_step(timestamptz);
drop table if exists public.attendance_tries;

-- ============================================================
-- 2. Who may read what
-- ============================================================
alter table public.attendance_rollcalls enable row level security;
alter table public.attendance_secrets enable row level security;
alter table public.attendance_checkins enable row level security;

-- May I run this group's roll calls? The root, planners, and the group's ICs and admins.
create or replace function public.att_can_run(p_event uuid, p_group uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.has_event_role(p_event, array['root', 'planner'])
      or exists (
        select 1 from public.group_members
        where event_id = p_event and group_id = p_group and user_id = auth.uid() and (is_ic or is_admin)
      );
$$;

-- Roll calls: staff (root, planners, marshals) see every group's; anyone else only their own group's
drop policy if exists "attendance rollcalls: staff and the group read" on public.attendance_rollcalls;
create policy "attendance rollcalls: staff and the group read" on public.attendance_rollcalls
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']) or group_id = public.my_group_id(event_id));

-- Check-ins: your own; staff every one; a group's ICs and admins their group's
drop policy if exists "attendance checkins: own, staff and the group's ICs read" on public.attendance_checkins;
create policy "attendance checkins: own, staff and the group's ICs read" on public.attendance_checkins
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or public.has_event_role(event_id, array['root', 'planner', 'marshal'])
    or public.att_can_run(event_id, group_id)
  );

-- (Supabase grants signed-in users every right on a new table by default: take them all back, then allow reading)
revoke all on table public.attendance_rollcalls, public.attendance_secrets, public.attendance_checkins
  from anon, authenticated, public;
grant select on table public.attendance_rollcalls, public.attendance_checkins to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.attendance_rollcalls;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.attendance_checkins;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- 3. The QR
-- ============================================================
-- The QR's text for one 5 s step: 16 hex characters of the md5 of the secret and the step (seconds since 1970 / 5)
create or replace function public.att_token(p_secret text, p_step bigint)
returns text
language sql immutable set search_path = ''
as $$
  select substr(md5(p_secret || ':' || p_step), 1, 16);
$$;

create or replace function public.att_step(p_at timestamptz)
returns bigint
language sql immutable set search_path = ''
as $$
  select floor(extract(epoch from p_at) / 5)::bigint;
$$;

-- ============================================================
-- 4. The mode (root / planners)
-- ============================================================
create or replace function public.set_attendance_mode(p_event uuid, p_mode text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the attendance mode' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('manual', 'qr') then
    raise exception 'Choose by hand (manual) or QR code (qr)';
  end if;
  update public.events set attendance_mode = p_mode where id = p_event;
end;
$$;

-- ============================================================
-- 5. Running a roll call (root, planners, the group's ICs and admins)
-- ============================================================
-- Open one for a group, in the event's mode (a roll call still open for it is closed first).
-- Whoever opens it, if in the group, is present.
create or replace function public.open_rollcall(p_group uuid, p_title text, p_minutes integer)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_mode text;
  v_title text := btrim(coalesce(p_title, ''));
  v_id uuid;
begin
  select g.event_id, e.attendance_mode into v_event, v_mode
  from public.groups g join public.events e on e.id = g.event_id
  where g.id = p_group;
  if v_event is null then
    raise exception 'That group no longer exists';
  end if;
  if not public.att_can_run(v_event, p_group) then
    raise exception 'Only the group''s IC or admin, a planner or the root can take attendance' using errcode = '42501';
  end if;
  if v_title = '' then
    v_title := 'Roll call ' || to_char(now() at time zone 'Asia/Singapore', 'HH24:MI');
  end if;
  if char_length(v_title) > 60 then
    raise exception 'A roll call''s name is up to 60 characters';
  end if;
  if p_minutes is null or p_minutes not between 5 and 60 then
    raise exception 'A roll call stays open for 5 to 60 minutes';
  end if;

  update public.attendance_rollcalls set closed_at = now()
  where group_id = p_group and closed_at is null and closes_at > now();

  insert into public.attendance_rollcalls (event_id, group_id, title, mode, opened_by, closes_at)
  values (v_event, p_group, v_title, v_mode, auth.uid(), now() + make_interval(mins => p_minutes))
  returning id into v_id;
  insert into public.attendance_secrets (rollcall_id, secret) values (v_id, md5(random()::text || clock_timestamp()::text || v_id::text));

  if exists (select 1 from public.group_members where group_id = p_group and user_id = auth.uid()) then
    insert into public.attendance_checkins (rollcall_id, event_id, group_id, user_id, status, method, marked_by)
    values (v_id, v_event, p_group, auth.uid(), 'present', 'manual', auth.uid());
  end if;
  return v_id;
end;
$$;

-- The QR to show now (QR mode): { token, seconds_left } (seconds_left: until it changes)
create or replace function public.rollcall_qr(p_rollcall uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r public.attendance_rollcalls;
  v_secret text;
  v_now timestamptz := clock_timestamp();
begin
  select * into r from public.attendance_rollcalls where id = p_rollcall;
  if r.id is null then
    raise exception 'That roll call no longer exists';
  end if;
  if not public.att_can_run(r.event_id, r.group_id) then
    raise exception 'Only the group''s IC or admin, a planner or the root can show the QR code' using errcode = '42501';
  end if;
  if r.mode <> 'qr' then
    raise exception 'This roll call is taken by hand, so it has no QR code';
  end if;
  if not (r.closed_at is null and r.closes_at > v_now) then
    raise exception 'This roll call is closed';
  end if;
  select secret into v_secret from public.attendance_secrets where rollcall_id = p_rollcall;
  return jsonb_build_object(
    'token', public.att_token(v_secret, public.att_step(v_now)),
    'seconds_left', 5 - floor(extract(epoch from v_now))::bigint % 5
  );
end;
$$;

-- Mark someone of the group present or excused by hand, or clear their mark (p_status null).
-- By hand: the group's ICs and admins in a manual roll call; in a QR one only the root and planners.
create or replace function public.mark_attendance(p_rollcall uuid, p_user uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.attendance_rollcalls;
begin
  select * into r from public.attendance_rollcalls where id = p_rollcall;
  if r.id is null then
    raise exception 'That roll call no longer exists';
  end if;
  if r.mode = 'qr' and not public.has_event_role(r.event_id, array['root', 'planner']) then
    raise exception 'In a QR roll call only a planner or the root can mark people by hand' using errcode = '42501';
  end if;
  if not public.att_can_run(r.event_id, r.group_id) then
    raise exception 'Only the group''s IC or admin, a planner or the root can mark attendance' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('present', 'excused') then
    raise exception 'Mark someone present or excused';
  end if;
  if p_status is null then
    delete from public.attendance_checkins where rollcall_id = p_rollcall and user_id = p_user;
    return;
  end if;
  if not exists (select 1 from public.group_members where group_id = r.group_id and user_id = p_user) then
    raise exception 'That person is not in this group';
  end if;
  insert into public.attendance_checkins (rollcall_id, event_id, group_id, user_id, status, method, marked_by)
  values (p_rollcall, r.event_id, r.group_id, p_user, p_status, 'manual', auth.uid())
  on conflict (rollcall_id, user_id) do update set status = excluded.status, method = 'manual', marked_by = excluded.marked_by, at = now();
end;
$$;

create or replace function public.close_rollcall(p_rollcall uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.attendance_rollcalls;
begin
  select * into r from public.attendance_rollcalls where id = p_rollcall;
  if r.id is null then
    raise exception 'That roll call no longer exists';
  end if;
  if not public.att_can_run(r.event_id, r.group_id) then
    raise exception 'Only the group''s IC or admin, a planner or the root can close a roll call' using errcode = '42501';
  end if;
  update public.attendance_rollcalls set closed_at = now() where id = p_rollcall and closed_at is null and closes_at > now();
end;
$$;

-- ============================================================
-- 6. Scanning the QR (anyone in the group)
-- ============================================================
-- Returns { ok: true, title } when I am in, or { ok: false, message } (an old QR, someone else's group, closed...).
create or replace function public.scan_rollcall(p_rollcall uuid, p_token text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r public.attendance_rollcalls;
  v_secret text;
  v_now timestamptz := clock_timestamp();
  v_step bigint := public.att_step(clock_timestamp());
  v_token text := lower(btrim(coalesce(p_token, '')));
begin
  select * into r from public.attendance_rollcalls where id = p_rollcall;
  if r.id is null or r.mode <> 'qr' then
    return jsonb_build_object('ok', false, 'message', 'This is not an attendance QR code.');
  end if;
  if not exists (select 1 from public.group_members where group_id = r.group_id and user_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'message', 'This QR code is for another group. Scan your own IC''s code.');
  end if;
  if not (r.closed_at is null and r.closes_at > v_now) then
    return jsonb_build_object('ok', false, 'message', 'This roll call is closed. Ask your IC.');
  end if;
  if exists (select 1 from public.attendance_checkins where rollcall_id = r.id and user_id = auth.uid() and status = 'present') then
    return jsonb_build_object('ok', true, 'title', r.title); -- already in: nothing to do
  end if;

  select secret into v_secret from public.attendance_secrets where rollcall_id = r.id;
  if v_token not in (public.att_token(v_secret, v_step), public.att_token(v_secret, v_step - 1)) then
    return jsonb_build_object('ok', false, 'message', 'This QR code has changed. Scan the code on your IC''s screen again.');
  end if;

  insert into public.attendance_checkins (rollcall_id, event_id, group_id, user_id, status, method, marked_by)
  values (r.id, r.event_id, r.group_id, auth.uid(), 'present', 'scan', auth.uid())
  on conflict (rollcall_id, user_id) do update set status = 'present', method = 'scan', marked_by = excluded.marked_by, at = now();
  return jsonb_build_object('ok', true, 'title', r.title);
end;
$$;

-- ============================================================
-- 7. Permissions
-- ============================================================
revoke execute on function public.att_token(text, bigint) from public, anon, authenticated;
revoke execute on function public.att_step(timestamptz) from public, anon, authenticated;
revoke execute on function public.att_can_run(uuid, uuid) from public, anon;
revoke execute on function public.set_attendance_mode(uuid, text) from public, anon;
revoke execute on function public.open_rollcall(uuid, text, integer) from public, anon;
revoke execute on function public.rollcall_qr(uuid) from public, anon;
revoke execute on function public.mark_attendance(uuid, uuid, text) from public, anon;
revoke execute on function public.close_rollcall(uuid) from public, anon;
revoke execute on function public.scan_rollcall(uuid, text) from public, anon;

grant execute on function public.att_can_run(uuid, uuid) to authenticated;
grant execute on function public.set_attendance_mode(uuid, text) to authenticated;
grant execute on function public.open_rollcall(uuid, text, integer) to authenticated;
grant execute on function public.rollcall_qr(uuid) to authenticated;
grant execute on function public.mark_attendance(uuid, uuid, text) to authenticated;
grant execute on function public.close_rollcall(uuid) to authenticated;
grant execute on function public.scan_rollcall(uuid, text) to authenticated;

notify pgrst, 'reload schema';
