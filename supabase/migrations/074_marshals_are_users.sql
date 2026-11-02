-- 074_marshals_are_users.sql -- a marshal sees what any other user sees: themselves and their own group.
-- Run AFTER 073_members_see_own_group.sql (Supabase -> SQL Editor). Can be re-run.
--
-- Being a marshal used to open every group: the people, the map, roll calls, the plan and the ops board. Now the only
-- people who see the whole event are the root and planners; group admins keep the list of people and groups (073).
--
-- Dozens of rules across the migrations list 'marshal' when they call has_event_role. They all pass through that one
-- function, so it now ignores 'marshal': the rule is changed once, here, and none can be missed.
--
-- One thing stays: a marshal can still end an SOS (everyone in the event sees an SOS, so it opens nothing new).
-- Who is a marshal is still stored, and shown as a badge.

-- ============================================================
-- 1. 'marshal' no longer gives any access
-- ============================================================
create or replace function public.has_event_role(p_event_id uuid, p_roles text[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.event_roles
    where event_id = p_event_id and user_id = auth.uid() and role = any (array_remove(p_roles, 'marshal'))
  );
$$;

-- ============================================================
-- 2. Who may see everyone (073 listed marshals)
-- ============================================================
create or replace function public.sees_all_people(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.has_event_role(p_event, array['root', 'planner'])
      or exists (select 1 from public.group_members where event_id = p_event and user_id = auth.uid() and is_admin);
$$;

-- ============================================================
-- 3. A marshal can still end an SOS (072, with the marshal looked up directly)
-- ============================================================
create or replace function public.resolve_sos(p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sos_alerts;
  v_me uuid := auth.uid();
begin
  select * into s from public.sos_alerts where id = p_id;
  if s.id is null or not public.is_event_member(s.event_id) then
    raise exception 'This SOS no longer exists';
  end if;
  if s.resolved_at is not null then
    return; -- someone else ended it first
  end if;
  if s.user_id <> v_me
     and not public.has_event_role(s.event_id, array['root', 'planner'])
     and not exists (select 1 from public.event_roles where event_id = s.event_id and user_id = v_me and role = 'marshal')
     and not (s.group_id is not null and exists (
       select 1 from public.group_members
       where group_id = s.group_id and user_id = v_me and (is_ic or is_admin)
     )) then
    raise exception 'Only the person who sent it, a planner, a marshal, or their group''s IC or admin can end an SOS'
      using errcode = '42501';
  end if;
  update public.sos_alerts
  set resolved_at = now(), resolved_by = v_me, resolution = case when s.user_id = v_me then 'safe' else 'handled' end
  where id = p_id;
end;
$$;

notify pgrst, 'reload schema';
