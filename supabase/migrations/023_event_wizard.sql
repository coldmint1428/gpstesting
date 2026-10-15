-- Step 23: the 4-step "Create an event" wizard (/events/new).
-- Run AFTER 022_simulator.sql.
--
-- The wizard keeps everything in the browser until Confirm, then saves it with ONE call:
-- create_event_with_setup(). It runs in a single transaction, so a broken rule saves nothing
-- (no half-made events). It uses the roles 002 already has:
--   event_roles.role : 'root' (the creator) | 'planner' | 'marshal' | 'participant'
--   group_members    : is_admin | is_ic   (at most one group per person per event)
--
-- Also adds search_people() so step 2 can find accounts the creator doesn't share an event with yet
-- (the profiles RLS from 002 hides those, on purpose).

-- ============================================================
-- 1. Event details from step 1 (optional for events made before this)
-- ============================================================
alter table public.events add column if not exists description text
  check (description is null or char_length(description) <= 1000);
alter table public.events add column if not exists venue text
  check (venue is null or char_length(venue) <= 120);
alter table public.events add column if not exists starts_at timestamptz;
alter table public.events add column if not exists ends_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'events_ends_after_starts') then
    alter table public.events add constraint events_ends_after_starts
      check (starts_at is null or ends_at is null or ends_at > starts_at);
  end if;
end $$;

-- ============================================================
-- 2. Find people to add (step 2)
--    Matches username or display name (part of it), or a whole email address.
--    Emails are never returned, and a partial email matches nothing, so this can't be used
--    to list other people's addresses.
-- ============================================================
create or replace function public.search_people(p_term text)
returns table (id uuid, username text, display_name text)
language sql stable security definer set search_path = ''
as $$
  with t as (
    select lower(trim(coalesce(p_term, ''))) as term,
           -- the term as a LIKE pattern: its own % _ \ are plain characters
           '%' || replace(replace(replace(lower(trim(coalesce(p_term, ''))), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
  )
  select p.id, p.username, p.display_name
  from public.profiles p, t
  where auth.uid() is not null
    and char_length(t.term) >= 2
    and p.id <> auth.uid()
    and not p.is_simulated
    and (
      p.username like t.pattern
      or lower(p.display_name) like t.pattern
      or exists (select 1 from auth.users u where u.id = p.id and lower(u.email) = t.term)
    )
  order by (p.username = t.term) desc, p.username
  limit 10;
$$;

-- ============================================================
-- 3. Save the whole wizard (step 4 Confirm)
--
-- p_event   : { "name", "description", "venue", "starts_at", "ends_at" }   (ISO times)
-- p_members : [ { "user_id", "role" } ]                  role: participant | planner | marshal
-- p_groups  : [ { "name", "colour",
--                 "members": [ { "user_id", "is_admin", "is_ic" } ] } ]
--
-- Everyone in p_members is a participant (that row makes them a member, as join_event does);
-- planner / marshal is added on top. The creator is root and may also be put in a group.
-- ============================================================
create or replace function public.create_event_with_setup(
  p_event jsonb,
  p_members jsonb default '[]'::jsonb,
  p_groups jsonb default '[]'::jsonb
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_event_id uuid;
  v_group_id uuid;
  v_user_id uuid;
  v_role text;
  v_name text;
  v_colour text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_seen uuid[] := '{}';
  v_ics int;
  g jsonb;
  m jsonb;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Your account has no profile. Please sign up again.';
  end if;
  if jsonb_typeof(coalesce(p_members, '[]')) <> 'array' or jsonb_typeof(coalesce(p_groups, '[]')) <> 'array' then
    raise exception 'Members and groups must be lists';
  end if;

  -- ---- Step 1: event details ----
  v_name := trim(coalesce(p_event ->> 'name', ''));
  if char_length(v_name) not between 1 and 80 then
    raise exception 'The event name must be 1-80 characters';
  end if;
  begin
    v_starts := (p_event ->> 'starts_at')::timestamptz;
    v_ends := (p_event ->> 'ends_at')::timestamptz;
  exception when others then
    raise exception 'The start or end time is not a valid date';
  end;
  if v_starts is null or v_ends is null then raise exception 'Pick a start and an end time'; end if;
  if v_ends <= v_starts then raise exception 'The end time must be after the start time'; end if;

  -- Retry if the random join code is already taken (very rare), like create_event()
  loop
    begin
      insert into public.events (name, description, venue, starts_at, ends_at, created_by)
      values (
        v_name,
        nullif(trim(p_event ->> 'description'), ''),
        nullif(trim(p_event ->> 'venue'), ''),
        v_starts,
        v_ends,
        v_uid
      )
      returning id into v_event_id;
      exit;
    exception when unique_violation then
      -- try again with a new code
    end;
  end loop;

  insert into public.event_roles (event_id, user_id, role) values (v_event_id, v_uid, 'root');

  -- ---- Step 2: people and their roles ----
  for m in select * from jsonb_array_elements(coalesce(p_members, '[]')) loop
    v_user_id := (m ->> 'user_id')::uuid;
    v_role := coalesce(m ->> 'role', 'participant');

    if v_user_id is null then raise exception 'A person has no id'; end if;
    if v_user_id = v_uid then continue; end if; -- the creator is already root
    if v_role = 'root' then raise exception 'Only the event creator can be root'; end if;
    if v_role not in ('participant', 'planner', 'marshal') then
      raise exception 'Unknown role: %', v_role;
    end if;
    if v_user_id = any (v_seen) then raise exception 'A person was added twice'; end if;
    if not exists (select 1 from public.profiles where id = v_user_id) then
      raise exception 'A person you added no longer has an account';
    end if;
    v_seen := v_seen || v_user_id;

    insert into public.event_roles (event_id, user_id, role) values (v_event_id, v_user_id, 'participant');
    if v_role <> 'participant' then
      insert into public.event_roles (event_id, user_id, role) values (v_event_id, v_user_id, v_role);
    end if;
  end loop;

  -- ---- Step 3: groups and who is in them ----
  for g in select * from jsonb_array_elements(coalesce(p_groups, '[]')) loop
    v_name := trim(coalesce(g ->> 'name', ''));
    v_colour := coalesce(nullif(g ->> 'colour', ''), '#0d6efd');
    if char_length(v_name) not between 1 and 50 then
      raise exception 'Group names must be 1-50 characters';
    end if;
    if v_colour !~ '^#[0-9a-fA-F]{6}$' then
      raise exception 'Group "%" has an invalid colour', v_name;
    end if;
    if exists (select 1 from public.groups where event_id = v_event_id and name = v_name) then
      raise exception 'Two groups are called "%"', v_name;
    end if;

    insert into public.groups (event_id, name, colour) values (v_event_id, v_name, v_colour)
    returning id into v_group_id;

    v_ics := 0;
    for m in select * from jsonb_array_elements(coalesce(g -> 'members', '[]')) loop
      v_user_id := (m ->> 'user_id')::uuid;

      if not exists (select 1 from public.event_roles where event_id = v_event_id and user_id = v_user_id) then
        raise exception 'Someone in group "%" was not added to the event in step 2', v_name;
      end if;
      if exists (select 1 from public.group_members where event_id = v_event_id and user_id = v_user_id) then
        raise exception 'A person can only be in one group per event';
      end if;

      insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic)
      values (
        v_group_id,
        v_event_id,
        v_user_id,
        coalesce((m ->> 'is_admin')::boolean, false),
        coalesce((m ->> 'is_ic')::boolean, false)
      );
      if coalesce((m ->> 'is_ic')::boolean, false) then v_ics := v_ics + 1; end if;
    end loop;

    if jsonb_array_length(coalesce(g -> 'members', '[]')) > 0 and v_ics = 0 then
      raise exception 'Group "%" needs at least one IC', v_name;
    end if;
  end loop;

  return v_event_id;
end;
$$;

-- Only signed-in users may call these
revoke execute on function public.search_people(text) from public, anon;
revoke execute on function public.create_event_with_setup(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.search_people(text) to authenticated;
grant execute on function public.create_event_with_setup(jsonb, jsonb, jsonb) to authenticated;
