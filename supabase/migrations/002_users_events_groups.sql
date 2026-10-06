-- Step 2: real users, events, groups and role-based access.
-- Run AFTER 001_locations.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- Roles (all scoped to ONE event; a person can hold several):
--   event_roles.role : 'root' (creator, one per event) | 'planner' | 'marshal' | 'participant' (= "User" in the spec)
--   group_members    : is_admin (group admin) | is_ic (the device that shares GPS for the group)
--
-- Who can do what is enforced HERE (Row Level Security + functions), not only in the Vue pages.

-- ============================================================
-- 1. Tables
-- ============================================================

-- One profile per login account (created automatically by the trigger below)
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 50),
  created_at timestamptz not null default now()
);

-- Random 6-character join code without look-alike characters (no 0/O, 1/I/L)
create function public.generate_join_code()
returns text
language plpgsql
set search_path = ''
as $$
declare
  chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text := '';
begin
  for i in 1..6 loop
    code := code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
  end loop;
  return code;
end;
$$;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  join_code text not null unique default public.generate_join_code(),
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now()
);

create table public.event_roles (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null check (role in ('root', 'planner', 'marshal', 'participant')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id, role)
);
-- Exactly one root per event
create unique index event_roles_one_root on public.event_roles (event_id) where role = 'root';
create index event_roles_user_idx on public.event_roles (user_id);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 50),
  colour text not null default '#0d6efd' check (colour ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now(),
  unique (event_id, name),
  unique (id, event_id) -- lets group_members check the group belongs to the same event
);

create table public.group_members (
  group_id uuid not null,
  event_id uuid not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  is_admin boolean not null default false,
  is_ic boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id),
  unique (event_id, user_id), -- at most one group per person per event
  foreign key (group_id, event_id) references public.groups (id, event_id) on delete cascade
);

-- Link existing locations to real events/groups.
-- NOT VALID = old sandbox rows (fake test ids) are kept; every NEW row is checked.
alter table public.locations
  add constraint locations_event_fk foreign key (event_id) references public.events (id) on delete cascade not valid,
  add constraint locations_group_fk foreign key (group_id) references public.groups (id) on delete cascade not valid;
create index locations_event_user_time_idx on public.locations (event_id, user_id, recorded_at desc);

-- ============================================================
-- 2. New sign-ups get a profile (username + display name come from the sign-up form)
-- ============================================================
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Old anonymous test accounts have no username: skip them
  if new.raw_user_meta_data ->> 'username' is null then
    return new;
  end if;

  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    lower(new.raw_user_meta_data ->> 'username'),
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), new.raw_user_meta_data ->> 'username')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- 3. Helper functions used by the RLS policies.
-- SECURITY DEFINER lets them read the membership tables without triggering
-- those tables' own policies again (which would cause "infinite recursion").
-- ============================================================
create function public.has_event_role(p_event_id uuid, p_roles text[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.event_roles
    where event_id = p_event_id and user_id = auth.uid() and role = any (p_roles)
  );
$$;

create function public.is_event_member(p_event_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.event_roles where event_id = p_event_id and user_id = auth.uid()
  );
$$;

-- The group I am in for this event (null if none)
create function public.my_group_id(p_event_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select group_id from public.group_members where event_id = p_event_id and user_id = auth.uid();
$$;

create function public.is_group_admin(p_group_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.group_members where group_id = p_group_id and user_id = auth.uid() and is_admin
  );
$$;

create function public.is_ic_of(p_event_id uuid, p_group_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.group_members
    where event_id = p_event_id and group_id = p_group_id and user_id = auth.uid() and is_ic
  );
$$;

-- Do I share at least one event with this person? (to see their name)
create function public.shares_event_with(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.event_roles mine
    join public.event_roles theirs on theirs.event_id = mine.event_id
    where mine.user_id = auth.uid() and theirs.user_id = p_user_id
  );
$$;

-- ============================================================
-- 4. Row Level Security. Writes to events/roles/groups go through the
--    functions in section 5 (no insert/update/delete policies = blocked).
-- ============================================================
alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.event_roles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;

create policy "see own profile and people in my events" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.shares_event_with(id));

create policy "edit own display name" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy "members see their events" on public.events
  for select to authenticated using (public.is_event_member(id));

create policy "members see event roles" on public.event_roles
  for select to authenticated using (public.is_event_member(event_id));

create policy "members see groups" on public.groups
  for select to authenticated using (public.is_event_member(event_id));

create policy "members see group members" on public.group_members
  for select to authenticated using (public.is_event_member(event_id));

-- Locations: replace the sandbox policies with role-based ones
drop policy if exists "insert own locations" on public.locations;
drop policy if exists "read locations (sandbox)" on public.locations;

-- Only the group's IC may share, only as themselves, only for their own group
create policy "ICs insert own group locations" on public.locations
  for insert to authenticated
  with check (user_id = (select auth.uid()) and public.is_ic_of(event_id, group_id));

-- Root/planners/marshals see everyone in the event; others see only their own group
create policy "see locations by role" on public.locations
  for select to authenticated
  using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal'])
    or group_id = public.my_group_id(event_id)
  );

-- ============================================================
-- 5. Actions (called from Vue with supabase.rpc). Each one checks the caller's role.
-- ============================================================

-- For the sign-up form: is this username free?
create function public.username_available(p_username text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select not exists (select 1 from public.profiles where username = lower(p_username));
$$;

-- Create an event; the creator becomes root
create function public.create_event(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- Retry if the random join code is already taken (very rare)
  loop
    begin
      insert into public.events (name, created_by) values (trim(p_name), auth.uid()) returning id into new_id;
      exit;
    exception when unique_violation then
      -- try again with a new code
    end;
  end loop;

  insert into public.event_roles (event_id, user_id, role) values (new_id, auth.uid(), 'root');
  return new_id;
end;
$$;

-- Join an event with its code (from the home page, QR code or shared link)
create function public.join_event(p_code text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  found_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select id into found_id from public.events where join_code = upper(trim(p_code));
  if found_id is null then raise exception 'No event with that code'; end if;

  insert into public.event_roles (event_id, user_id, role)
  values (found_id, auth.uid(), 'participant')
  on conflict do nothing;
  return found_id;
end;
$$;

-- Create a group (root / planner)
create function public.create_group(p_event_id uuid, p_name text, p_colour text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can create groups';
  end if;
  insert into public.groups (event_id, name, colour) values (p_event_id, trim(p_name), coalesce(p_colour, '#0d6efd'))
  returning id into new_id;
  return new_id;
end;
$$;

-- Put a person into a group, move them, or remove them from groups (p_group_id = null).
-- Root/planner: any group. Group admin: only into/out of their own group.
create function public.assign_group(p_event_id uuid, p_user_id uuid, p_group_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  current_group uuid;
  is_manager boolean := public.has_event_role(p_event_id, array['root', 'planner']);
begin
  select group_id into current_group from public.group_members
  where event_id = p_event_id and user_id = p_user_id;

  if not is_manager then
    -- Group admins may add someone without a group to their group, or remove someone from it
    if not (
      (p_group_id is not null and current_group is null and public.is_group_admin(p_group_id))
      or (p_group_id is null and current_group is not null and public.is_group_admin(current_group))
    ) then
      raise exception 'Not allowed to change this person''s group';
    end if;
  end if;

  if not exists (select 1 from public.event_roles where event_id = p_event_id and user_id = p_user_id) then
    raise exception 'That person is not in this event';
  end if;

  delete from public.group_members where event_id = p_event_id and user_id = p_user_id;
  if p_group_id is not null then
    -- New group = start as a normal member (not admin, not IC)
    insert into public.group_members (group_id, event_id, user_id) values (p_group_id, p_event_id, p_user_id);
  end if;
end;
$$;

-- Add an existing account to the event by username (optionally straight into a group)
create function public.add_member_by_username(p_event_id uuid, p_username text, p_group_id uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target uuid;
begin
  if not (
    public.has_event_role(p_event_id, array['root', 'planner'])
    or (p_group_id is not null and public.is_group_admin(p_group_id))
  ) then
    raise exception 'Only the root, a planner or that group''s admin can add people';
  end if;
  if p_group_id is not null
     and not exists (select 1 from public.groups where id = p_group_id and event_id = p_event_id) then
    raise exception 'That group is not in this event';
  end if;

  select id into target from public.profiles where username = lower(trim(p_username));
  if target is null then raise exception 'No account with that username'; end if;

  insert into public.event_roles (event_id, user_id, role)
  values (p_event_id, target, 'participant')
  on conflict do nothing;

  if p_group_id is not null then
    perform public.assign_group(p_event_id, target, p_group_id);
  end if;
  return target;
end;
$$;

-- Make someone group admin and/or IC.
-- Root/planner can set both; a group admin can only promote/demote ICs (spec).
create function public.set_group_flags(p_group_id uuid, p_user_id uuid, p_is_admin boolean, p_is_ic boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  ev uuid;
  old_admin boolean;
begin
  select event_id, is_admin into ev, old_admin from public.group_members
  where group_id = p_group_id and user_id = p_user_id;
  if ev is null then raise exception 'That person is not in this group'; end if;

  if public.has_event_role(ev, array['root', 'planner']) then
    update public.group_members set is_admin = p_is_admin, is_ic = p_is_ic
    where group_id = p_group_id and user_id = p_user_id;
  elsif public.is_group_admin(p_group_id) then
    if p_is_admin is distinct from old_admin then
      raise exception 'Only the root or a planner can change group admins';
    end if;
    update public.group_members set is_ic = p_is_ic
    where group_id = p_group_id and user_id = p_user_id;
  else
    raise exception 'Not allowed';
  end if;
end;
$$;

-- Give or take away an event-level role (planner / marshal). Root only.
create function public.set_event_role(p_event_id uuid, p_user_id uuid, p_role text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root']) then
    raise exception 'Only the root can change planners and marshals';
  end if;
  if p_role not in ('planner', 'marshal') then
    raise exception 'Role must be planner or marshal';
  end if;

  if p_enabled then
    insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, p_role)
    on conflict do nothing;
  else
    delete from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = p_role;
  end if;
end;
$$;

-- Remove someone from the event (root / planner), or leave it yourself. The root cannot be removed.
create function public.remove_member(p_event_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (p_user_id = auth.uid() or public.has_event_role(p_event_id, array['root', 'planner'])) then
    raise exception 'Not allowed';
  end if;
  if exists (select 1 from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'root') then
    raise exception 'The root cannot be removed';
  end if;

  delete from public.group_members where event_id = p_event_id and user_id = p_user_id;
  delete from public.event_roles where event_id = p_event_id and user_id = p_user_id;
end;
$$;

-- Latest position of each person I am allowed to see (RLS on locations decides who).
-- SECURITY INVOKER (the default) so the caller's own policies apply.
create function public.latest_locations(p_event_id uuid)
returns table (
  user_id uuid,
  group_id uuid,
  lat double precision,
  lng double precision,
  accuracy real,
  recorded_at timestamptz
)
language sql stable set search_path = ''
as $$
  select distinct on (l.user_id) l.user_id, l.group_id, l.lat, l.lng, l.accuracy, l.recorded_at
  from public.locations l
  where l.event_id = p_event_id
  order by l.user_id, l.recorded_at desc;
$$;

-- ============================================================
-- 6. Permissions: only signed-in users may call the functions
--    (username_available is also needed on the sign-up page, before login).
-- ============================================================
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.username_available(text) to anon;
-- Internal only: the trigger function and code generator are never called from the app
revoke execute on function public.handle_new_user() from authenticated;
revoke execute on function public.generate_join_code() from authenticated;

-- Live updates for the members page (who joined, group changes)
alter publication supabase_realtime add table public.group_members, public.event_roles;
