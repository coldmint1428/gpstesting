-- 036_planners_not_in_groups.sql -- planners run the whole event, so they are never in a group.
-- Run AFTER 035_event_details.sql (Supabase -> SQL Editor). Can be re-run.
--
--  1. Two triggers guard every way in (assign_group, add_member_by_username, add_event_member, the wizard's
--     create_event_with_setup): a planner cannot be put in a group, and someone in a group cannot get a planner row.
--  2. set_member_role: making someone a planner takes them out of their group first (refused if they are the
--     group's only IC and others are in it, as removing them is in 033).
--
-- Planners who are ALREADY in a group are left as they are. To list them:
--   select gm.event_id, gm.user_id from public.group_members gm
--   join public.event_roles er on er.event_id = gm.event_id and er.user_id = gm.user_id and er.role = 'planner';

-- ---------- 1. The guards ----------
create or replace function public.group_members_no_planners()
returns trigger
language plpgsql
security definer -- sees every role row, whatever the caller may read
set search_path = ''
as $$
begin
  if exists (select 1 from public.event_roles
             where event_id = new.event_id and user_id = new.user_id and role = 'planner') then
    raise exception 'Planners cannot be in a group';
  end if;
  return new;
end;
$$;

drop trigger if exists group_members_no_planners on public.group_members;
create trigger group_members_no_planners
  before insert or update of user_id, event_id on public.group_members
  for each row execute function public.group_members_no_planners();

create or replace function public.event_roles_planner_not_in_group()
returns trigger
language plpgsql
security definer -- sees every role row, whatever the caller may read
set search_path = ''
as $$
begin
  if new.role = 'planner'
     and exists (select 1 from public.group_members where event_id = new.event_id and user_id = new.user_id) then
    raise exception 'Planners cannot be in a group: take them out of their group first';
  end if;
  return new;
end;
$$;

drop trigger if exists event_roles_planner_not_in_group on public.event_roles;
create trigger event_roles_planner_not_in_group
  before insert or update of role on public.event_roles
  for each row execute function public.event_roles_planner_not_in_group();

-- ---------- 2. set_member_role (033), now leaving the group on the way to planner ----------
create or replace function public.set_member_role(p_event_id uuid, p_user_id uuid, p_new_role text)
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
    -- planners are not in a group: leave it first (a group with an IC keeps one)
    select group_id, is_ic into v_gm from public.group_members where event_id = p_event_id and user_id = p_user_id;
    if v_gm.is_ic
       and not exists (select 1 from public.group_members
                       where group_id = v_gm.group_id and user_id <> p_user_id and is_ic)
       and exists (select 1 from public.group_members where group_id = v_gm.group_id and user_id <> p_user_id) then
      raise exception 'That person is the group''s only IC. Make someone else IC first.';
    end if;
    delete from public.group_members where event_id = p_event_id and user_id = p_user_id;
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

-- Tell the API (PostgREST) to pick up the changes now, not after its next restart
notify pgrst, 'reload schema';
