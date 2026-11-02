-- 073_members_see_own_group.sql -- ICs and members see only themselves and their own group.
-- Run AFTER 072_sos.sql (Supabase -> SQL Editor). Can be re-run.
--
-- Until now anyone in an event could read everyone in it, and every group. Now:
--   Root, planners, marshals, group admins : everyone in the event, every group (as before)
--   ICs and members                        : themselves, the people in their own group, and their own group
-- Someone without a group sees only themselves. The database functions (security definer) are not limited by this.
--
-- An SOS goes to everyone in the event, so it now keeps the sender's name and group name: people outside the sender's
-- group cannot look them up.

-- ============================================================
-- 1. Helpers
-- ============================================================
-- May I see everyone in this event?
create or replace function public.sees_all_people(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.has_event_role(p_event, array['root', 'planner', 'marshal'])
      or exists (select 1 from public.group_members where event_id = p_event and user_id = auth.uid() and is_admin);
$$;

-- Is this person in my group in this event?
create or replace function public.in_my_group(p_event uuid, p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.group_members
    where event_id = p_event and user_id = p_user and group_id = public.my_group_id(p_event)
  );
$$;

-- May I see this person's name? (The profiles policy from 002 asks this.) Myself is checked by the policy.
create or replace function public.shares_event_with(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.event_roles mine
    join public.event_roles theirs on theirs.event_id = mine.event_id
    where mine.user_id = auth.uid()
      and theirs.user_id = p_user_id
      and (public.sees_all_people(mine.event_id) or public.in_my_group(mine.event_id, p_user_id))
  );
$$;

revoke execute on function public.sees_all_people(uuid) from public, anon;
revoke execute on function public.in_my_group(uuid, uuid) from public, anon;
revoke execute on function public.shares_event_with(uuid) from public, anon;
grant execute on function public.sees_all_people(uuid) to authenticated;
grant execute on function public.in_my_group(uuid, uuid) to authenticated;
grant execute on function public.shares_event_with(uuid) to authenticated;

-- ============================================================
-- 2. Who may read what
-- ============================================================
drop policy if exists "members see event roles" on public.event_roles;
drop policy if exists "see own role, own group, or everyone as staff" on public.event_roles;
create policy "see own role, own group, or everyone as staff" on public.event_roles
  for select to authenticated
  using (user_id = (select auth.uid()) or public.sees_all_people(event_id) or public.in_my_group(event_id, user_id));

drop policy if exists "members see group members" on public.group_members;
drop policy if exists "see own group, or everyone as staff" on public.group_members;
create policy "see own group, or everyone as staff" on public.group_members
  for select to authenticated
  using (user_id = (select auth.uid()) or public.sees_all_people(event_id) or group_id = public.my_group_id(event_id));

drop policy if exists "members see groups" on public.groups;
drop policy if exists "see own group, or every group as staff" on public.groups;
create policy "see own group, or every group as staff" on public.groups
  for select to authenticated
  using (public.sees_all_people(event_id) or id = public.my_group_id(event_id));

-- ============================================================
-- 3. An SOS keeps who sent it
-- ============================================================
alter table public.sos_alerts add column if not exists sender_name text;
alter table public.sos_alerts add column if not exists group_name text;

create or replace function public.sos_alerts_names()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.sender_name := public.sos_name(new.user_id);
  new.group_name := (select name from public.groups where id = new.group_id);
  return new;
end;
$$;
revoke execute on function public.sos_alerts_names() from public, anon, authenticated;

drop trigger if exists sos_alerts_names on public.sos_alerts;
create trigger sos_alerts_names
  before insert on public.sos_alerts
  for each row execute function public.sos_alerts_names();

-- SOSs already sent
update public.sos_alerts a
set sender_name = public.sos_name(a.user_id),
    group_name = (select g.name from public.groups g where g.id = a.group_id)
where a.sender_name is null;

notify pgrst, 'reload schema';
