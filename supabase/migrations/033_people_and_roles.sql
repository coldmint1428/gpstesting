-- 033_people_and_roles.sql -- accounts, profiles and the role hierarchy (promote / demote / IC / remove).
-- Run AFTER 030_event_wizard.sql (Supabase -> SQL Editor). Only needs the tables of 002, and can be re-run.
--
-- Roles stay where 002 put them: event_roles (root / planner / marshal / participant) and the group flags
-- group_members.is_admin / is_ic. For managing people each person has ONE "top role", highest first:
--
--   root (4)  >  planner (3)  >  group admin (2)  >  member (1)
--
-- Marshal and IC are duties ON TOP of that (a marshal row in event_roles, the is_ic flag), not ranks: a marshal
-- still sees every group, the run sheet and the ops view, but ranks as what they otherwise are (member or admin).
--
--   root     : makes anyone a planner, group admin or member; marshal on / off; IC in any group; removes anyone
--   planner  : the same for people below planner (never another planner or the root)
--   group admin : sets IC and removes members of THEIR OWN group only
--   member (marshal or not) : cannot change anyone
--
-- Nobody changes their own role or removes themselves here (leaving is remove_member on yourself). The root
-- is never changed or removed. A group that has an IC keeps at least one: the last IC cannot be unset or removed.
-- IC is still allowed for any role (planners share GPS while testing), unlike the original brief.
--
--  1. profiles.first_name / last_name (display_name follows them); the sign-up trigger reads them; users may
--     only edit username and names (column grants); login_email() for signing in with a username.
--  2. member_top_role(), role_rank(), my_event_membership() (one round trip for the event page's guard).
--  3. set_member_role, set_marshal, set_group_ic, remove_event_member; remove_member and set_group_flags follow the
--     same rules; rename_event and delete_event (root).

-- ---------- 1. Profiles ----------
alter table public.profiles
  add column if not exists first_name text check (first_name is null or char_length(first_name) between 1 and 50),
  add column if not exists last_name text check (last_name is null or char_length(last_name) between 1 and 50);

-- The name everyone sees (map, toasts, lists) is "First Last" once the names are set
create or replace function public.profiles_sync_display_name()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  full_name text := left(trim(concat_ws(' ', nullif(trim(new.first_name), ''), nullif(trim(new.last_name), ''))), 50);
begin
  new.first_name := nullif(trim(new.first_name), '');
  new.last_name := nullif(trim(new.last_name), '');
  if full_name <> '' then
    new.display_name := full_name;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_sync_display_name on public.profiles;
create trigger profiles_sync_display_name
  before insert or update of first_name, last_name on public.profiles
  for each row execute function public.profiles_sync_display_name();

-- Sign-up form sends username, first_name, last_name (older clients: display_name)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  meta jsonb := new.raw_user_meta_data;
begin
  -- Old anonymous test accounts have no username: skip them
  if meta ->> 'username' is null then
    return new;
  end if;

  insert into public.profiles (id, username, display_name, first_name, last_name)
  values (
    new.id,
    lower(trim(meta ->> 'username')),
    left(coalesce(
      nullif(trim(meta ->> 'display_name'), ''),
      nullif(trim(concat_ws(' ', nullif(trim(meta ->> 'first_name'), ''), nullif(trim(meta ->> 'last_name'), ''))), ''),
      meta ->> 'username'
    ), 50),
    left(nullif(trim(meta ->> 'first_name'), ''), 50),
    left(nullif(trim(meta ->> 'last_name'), ''), 50)
  );
  return new;
end;
$$;

-- Users edit their own row (policy from 002) but only these columns: not id, is_simulated or created_at.
-- (The email lives in Supabase Auth, not here, and changes there.)
revoke update on public.profiles from anon, authenticated;
grant update (username, display_name, first_name, last_name) on public.profiles to authenticated;

-- Sign in with a username: the login form asks for the account's email first. Anyone can call it, so it
-- reveals the email of a username someone already knows (simulated accounts are left out).
create or replace function public.login_email(p_username text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.email
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.username = lower(trim(p_username)) and not coalesce((to_jsonb(p) ->> 'is_simulated')::boolean, false);
$$;

-- ---------- 2. The hierarchy ----------
create or replace function public.role_rank(p_role text)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'root' then 4
    when 'planner' then 3
    when 'admin' then 2
    when 'member' then 1
    else 0
  end;
$$;

-- A person's top role in an event: root | planner | admin | member, or null if not in it (marshal is a duty, not a rank)
create or replace function public.member_top_role(p_event_id uuid, p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from public.event_roles where event_id = p_event_id and user_id = p_user_id) then null
    when exists (select 1 from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'root') then 'root'
    when exists (select 1 from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'planner') then 'planner'
    when exists (select 1 from public.group_members where event_id = p_event_id and user_id = p_user_id and is_admin) then 'admin'
    else 'member'
  end;
$$;

-- Everything the event page needs to decide what I see, in one call (null if I am not in the event).
-- plpgsql so it can name event_sessions (007) without this file depending on it.
create or replace function public.my_event_membership(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text := public.member_top_role(p_event_id, auth.uid());
  v_gm record;
  v_live boolean;
begin
  if auth.uid() is null or v_role is null then
    return null;
  end if;
  select group_id, is_admin, is_ic into v_gm
  from public.group_members where event_id = p_event_id and user_id = auth.uid();
  select exists (
    select 1 from public.event_sessions where event_id = p_event_id and starts_at <= now() and ended_at is null
  ) into v_live;
  return jsonb_build_object(
    'role', v_role,
    'group_id', v_gm.group_id,
    'is_admin', coalesce(v_gm.is_admin, false),
    'is_ic', coalesce(v_gm.is_ic, false),
    'is_marshal', exists (select 1 from public.event_roles where event_id = p_event_id and user_id = auth.uid() and role = 'marshal'),
    'is_simulation', (select coalesce((to_jsonb(e) ->> 'is_simulation')::boolean, false) from public.events e where e.id = p_event_id),
    'live', v_live
  );
end;
$$;

-- ---------- 3. Actions the app calls ----------

-- Give someone a top role: 'planner' | 'admin' (of the group they are in) | 'member'.
-- Becoming a planner ends the marshal duty (a planner sees everything anyway); otherwise marshal and IC stay.
create or replace function public.set_member_role(p_event_id uuid, p_user_id uuid, p_new_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public.member_top_role(p_event_id, auth.uid());
  v_target text := public.member_top_role(p_event_id, p_user_id);
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You cannot change your own role';
  end if;
  if p_new_role is null or p_new_role not in ('planner', 'admin', 'member') then
    raise exception 'Role must be planner, admin or member';
  end if;
  if v_actor is null then
    raise exception 'You are not part of this event';
  end if;
  if v_actor not in ('root', 'planner') then
    raise exception 'Only the root and planners can change roles';
  end if;
  if v_target is null then
    raise exception 'That person is not part of this event';
  end if;
  -- only people strictly below you, and only roles strictly below your own
  if public.role_rank(v_target) >= public.role_rank(v_actor) then
    raise exception 'You can only change the role of people below you';
  end if;
  if public.role_rank(p_new_role) >= public.role_rank(v_actor) then
    raise exception 'You can only give roles below your own';
  end if;
  if p_new_role = 'admin'
     and not exists (select 1 from public.group_members where event_id = p_event_id and user_id = p_user_id) then
    raise exception 'Put them in a group first: a group admin manages their own group';
  end if;

  -- the participant row keeps them in the event when their planner row goes
  insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, 'participant')
  on conflict do nothing;
  if p_new_role = 'planner' then
    delete from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'marshal';
    insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, 'planner')
    on conflict do nothing;
  else
    delete from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'planner';
  end if;
  update public.group_members set is_admin = (p_new_role = 'admin')
  where event_id = p_event_id and user_id = p_user_id;
end;
$$;

-- The marshal duty on / off (root / planners, for people below them). Off also clears their sector.
create or replace function public.set_marshal(p_event_id uuid, p_user_id uuid, p_is_marshal boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public.member_top_role(p_event_id, auth.uid());
  v_target text := public.member_top_role(p_event_id, p_user_id);
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if v_actor is null or v_actor not in ('root', 'planner') then
    raise exception 'Only the root and planners can make marshals';
  end if;
  if v_target is null then
    raise exception 'That person is not part of this event';
  end if;
  if p_user_id = auth.uid() or public.role_rank(v_target) >= public.role_rank(v_actor) then
    raise exception 'You can only change people below you';
  end if;
  if coalesce(p_is_marshal, false) then
    insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, 'marshal')
    on conflict do nothing;
  else
    -- the participant row keeps them in the event
    insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, 'participant')
    on conflict do nothing;
    delete from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'marshal';
  end if;
end;
$$;

-- Make someone IC of their group, or not. Root / planners: anyone in any group (themselves too).
-- A group admin: themselves and members of their own group.
create or replace function public.set_group_ic(p_group_id uuid, p_user_id uuid, p_is_ic boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event uuid;
  v_was_ic boolean;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  select event_id into v_event from public.groups where id = p_group_id;
  if v_event is null then
    raise exception 'Group not found';
  end if;

  if not public.has_event_role(v_event, array['root', 'planner']) then
    if not public.is_group_admin(p_group_id) then
      if exists (select 1 from public.group_members where event_id = v_event and user_id = auth.uid() and is_admin) then
        raise exception 'Admins can only manage their own group';
      end if;
      raise exception 'Only the root, planners and group admins can set IC';
    end if;
    if p_user_id <> auth.uid() and public.member_top_role(v_event, p_user_id) <> 'member' then
      raise exception 'You can only change people below you';
    end if;
  end if;

  select is_ic into v_was_ic from public.group_members where group_id = p_group_id and user_id = p_user_id;
  if v_was_ic is null then
    raise exception 'That person is not in this group';
  end if;

  update public.group_members set is_ic = coalesce(p_is_ic, false)
  where group_id = p_group_id and user_id = p_user_id;

  -- a group with an IC keeps at least one
  if v_was_ic and not exists (select 1 from public.group_members where group_id = p_group_id and is_ic) then
    raise exception 'Each group needs at least one IC. Make someone else IC first.';
  end if;
end;
$$;

-- Remove someone else from the event (and their group). Root / planners: people below them.
-- A group admin: members of their own group.
create or replace function public.remove_event_member(p_event_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public.member_top_role(p_event_id, auth.uid());
  v_target text := public.member_top_role(p_event_id, p_user_id);
  v_gm record;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You cannot remove yourself here';
  end if;
  if v_actor is null or v_target is null then
    raise exception 'Both people must be part of this event';
  end if;

  select group_id, is_ic into v_gm from public.group_members where event_id = p_event_id and user_id = p_user_id;

  if v_actor in ('root', 'planner') then
    if public.role_rank(v_target) >= public.role_rank(v_actor) then
      raise exception 'You can only remove people below you';
    end if;
  elsif exists (select 1 from public.group_members where event_id = p_event_id and user_id = auth.uid() and is_admin) then
    if v_gm.group_id is null or not public.is_group_admin(v_gm.group_id) then
      raise exception 'Admins can only manage their own group';
    end if;
    if v_target <> 'member' then
      raise exception 'You can only remove people below you';
    end if;
  else
    raise exception 'You can only remove people below you';
  end if;

  if v_gm.is_ic
     and not exists (select 1 from public.group_members
                     where group_id = v_gm.group_id and user_id <> p_user_id and is_ic)
     and exists (select 1 from public.group_members where group_id = v_gm.group_id and user_id <> p_user_id) then
    raise exception 'That person is the group''s only IC. Make someone else IC first.';
  end if;

  delete from public.group_members where event_id = p_event_id and user_id = p_user_id;
  delete from public.event_roles where event_id = p_event_id and user_id = p_user_id;
end;
$$;

-- 002's remove_member: leaving the event yourself stays here; removing someone else follows the rules above
-- (before, a planner could remove another planner).
create or replace function public.remove_member(p_event_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if p_user_id <> auth.uid() then
    perform public.remove_event_member(p_event_id, p_user_id);
    return;
  end if;
  if public.has_event_role(p_event_id, array['root']) then
    raise exception 'The root cannot leave their own event';
  end if;
  delete from public.group_members where event_id = p_event_id and user_id = p_user_id;
  delete from public.event_roles where event_id = p_event_id and user_id = p_user_id;
end;
$$;

-- 002's set_group_flags (no longer used by the app): the same rules as set_member_role / set_group_ic
create or replace function public.set_group_flags(p_group_id uuid, p_user_id uuid, p_is_admin boolean, p_is_ic boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gm record;
begin
  select event_id, is_admin, is_ic into v_gm from public.group_members where group_id = p_group_id and user_id = p_user_id;
  if v_gm.event_id is null then
    raise exception 'That person is not in this group';
  end if;
  if p_is_admin is distinct from v_gm.is_admin then
    perform public.set_member_role(v_gm.event_id, p_user_id, case when p_is_admin then 'admin' else 'member' end);
  end if;
  if p_is_ic is distinct from v_gm.is_ic then
    perform public.set_group_ic(p_group_id, p_user_id, p_is_ic);
  end if;
end;
$$;

-- Event details (root): the name
create or replace function public.rename_event(p_event_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root']) then
    raise exception 'Only the root can change the event''s details';
  end if;
  update public.events set name = trim(p_name) where id = p_event_id;
end;
$$;

-- Delete the whole event (root): everything in it goes with it (on delete cascade)
create or replace function public.delete_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root']) then
    raise exception 'Only the root can delete the event';
  end if;
  delete from public.events where id = p_event_id;
end;
$$;

-- ---------- Permissions (explicit per function) ----------
revoke execute on function public.profiles_sync_display_name() from public, anon, authenticated;
revoke execute on function public.login_email(text) from public;
revoke execute on function public.role_rank(text) from public, anon;
revoke execute on function public.member_top_role(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.my_event_membership(uuid) from public, anon;
revoke execute on function public.set_member_role(uuid, uuid, text) from public, anon;
revoke execute on function public.set_marshal(uuid, uuid, boolean) from public, anon;
revoke execute on function public.set_group_ic(uuid, uuid, boolean) from public, anon;
revoke execute on function public.remove_event_member(uuid, uuid) from public, anon;
revoke execute on function public.remove_member(uuid, uuid) from public, anon;
revoke execute on function public.set_group_flags(uuid, uuid, boolean, boolean) from public, anon;
revoke execute on function public.rename_event(uuid, text) from public, anon;
revoke execute on function public.delete_event(uuid) from public, anon;

-- the login form runs before login
grant execute on function public.login_email(text) to anon, authenticated;
grant execute on function public.role_rank(text) to authenticated;
grant execute on function public.my_event_membership(uuid) to authenticated;
grant execute on function public.set_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.set_marshal(uuid, uuid, boolean) to authenticated;
grant execute on function public.set_group_ic(uuid, uuid, boolean) to authenticated;
grant execute on function public.remove_event_member(uuid, uuid) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;
grant execute on function public.set_group_flags(uuid, uuid, boolean, boolean) to authenticated;
grant execute on function public.rename_event(uuid, text) to authenticated;
grant execute on function public.delete_event(uuid) to authenticated;
