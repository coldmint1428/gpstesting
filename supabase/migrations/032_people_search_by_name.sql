-- 032_people_search_by_name.sql -- find people by name only, and show their email to tell apart two people
-- with the same name. Run AFTER 031_people_and_roles.sql (Supabase -> SQL Editor). Can be re-run.
--
--  1. search_people(term): matches the display name only (not the username or an email any more) and returns
--     { id, display_name, email }. NOTE: any signed-in user who types a name now sees that person's email.
--  2. add_event_member(event, user, group): add an existing account by id (the People page picks from the
--     search results). Same rules as add_member_by_username (002), which stays for older clients.

-- ---------- 1. Search by name ----------
drop function if exists public.search_people(text); -- the returned columns change
create function public.search_people(p_term text)
returns table (id uuid, display_name text, email text)
language sql stable security definer set search_path = ''
as $$
  with t as (
    select lower(trim(coalesce(p_term, ''))) as term,
           -- the term as a LIKE pattern: its own % _ \ are plain characters
           '%' || replace(replace(replace(lower(trim(coalesce(p_term, ''))), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
  )
  select p.id, p.display_name, u.email::text
  from public.profiles p
  join auth.users u on u.id = p.id
  cross join t
  where auth.uid() is not null
    and char_length(t.term) >= 2
    and p.id <> auth.uid()
    and not p.is_simulated
    and lower(p.display_name) like t.pattern
  order by (lower(p.display_name) = t.term) desc, p.display_name, u.email
  limit 10;
$$;

revoke execute on function public.search_people(text) from public, anon;
grant execute on function public.search_people(text) to authenticated;

-- ---------- 2. Add a person by id ----------
create or replace function public.add_event_member(p_event_id uuid, p_user_id uuid, p_group_id uuid default null)
returns void
language plpgsql security definer set search_path = ''
as $$
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
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'No such account';
  end if;

  insert into public.event_roles (event_id, user_id, role)
  values (p_event_id, p_user_id, 'participant')
  on conflict do nothing;

  if p_group_id is not null then
    perform public.assign_group(p_event_id, p_user_id, p_group_id);
  end if;
end;
$$;

revoke execute on function public.add_event_member(uuid, uuid, uuid) from public, anon;
grant execute on function public.add_event_member(uuid, uuid, uuid) to authenticated;

-- Tell the API (PostgREST) to pick up the new functions now, not after its next restart
notify pgrst, 'reload schema';
