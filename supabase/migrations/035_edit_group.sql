-- 035_edit_group.sql -- the root or a planner renames a group and changes its colour after it is made (the Groups
-- page). Run AFTER 034_planners_not_in_groups.sql (Supabase -> SQL Editor). Can be re-run.
--
-- The same rules as create_group (002): a name of 1-50 characters, unique in the event, and a #rrggbb colour.
-- Its details (category, code, sector, headcount, radio) keep their own calls (024, 029).

create or replace function public.update_group(p_group uuid, p_name text, p_colour text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_name text := btrim(coalesce(p_name, ''));
  v_colour text := lower(btrim(coalesce(p_colour, '')));
begin
  select event_id into v_event from public.groups where id = p_group;
  if v_event is null then
    raise exception 'That group no longer exists';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can rename a group or change its colour' using errcode = '42501';
  end if;
  if char_length(v_name) not between 1 and 50 then
    raise exception 'A group name must be 1-50 characters';
  end if;
  if v_colour !~ '^#[0-9a-f]{6}$' then
    raise exception 'Choose a colour for the group';
  end if;
  if exists (select 1 from public.groups g where g.event_id = v_event and lower(g.name) = lower(v_name) and g.id <> p_group) then
    raise exception 'Another group is already called %', v_name;
  end if;
  update public.groups set name = v_name, colour = v_colour where id = p_group;
end;
$$;

revoke execute on function public.update_group(uuid, text, text) from public, anon;
grant execute on function public.update_group(uuid, text, text) to authenticated;

-- Tell the API (PostgREST) to pick up the new function now, not after its next restart
notify pgrst, 'reload schema';
