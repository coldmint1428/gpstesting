-- Numbering (1 Nov): written by Ern on the event_creation_ern branch as 036, and applied to the live project
-- directly on 28 Oct. Renumbered 070 when merged into komin-merge, whose own 035-038 are different migrations.
-- Every function and trigger here was checked live before the merge; this file is the record, not a pending change.

-- 036_auto_headcount.sql -- a group's headcount is the number of people in it, kept up to date by the database.
-- Run AFTER 035_edit_group.sql (Supabase -> SQL Editor). Can be re-run.
--
-- It used to be typed in (Groups page, update_group_details 024) or read from a run sheet file (025). Now:
--   * any write to groups.headcount (those two calls included) is replaced by the real count, so they need no change;
--   * someone joining, moving or leaving a group (group_members) recounts the groups involved.

create or replace function public.groups_headcount_is_count()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.headcount := (select count(*) from public.group_members m where m.group_id = new.id);
  return new;
end;
$$;

drop trigger if exists groups_headcount_is_count on public.groups;
create trigger groups_headcount_is_count
  before insert or update on public.groups
  for each row execute function public.groups_headcount_is_count();

-- Touching the row is enough: the trigger above recounts it
create or replace function public.group_members_recount()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.groups set headcount = null where id = old.group_id;
  end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.group_id is distinct from old.group_id) then
    update public.groups set headcount = null where id = new.group_id;
  end if;
  return null;
end;
$$;

drop trigger if exists group_members_recount on public.group_members;
create trigger group_members_recount
  after insert or update of group_id or delete on public.group_members
  for each row execute function public.group_members_recount();

revoke execute on function public.groups_headcount_is_count() from public, anon, authenticated;
revoke execute on function public.group_members_recount() from public, anon, authenticated;

-- Every group as it is now
update public.groups set headcount = null;

notify pgrst, 'reload schema';
