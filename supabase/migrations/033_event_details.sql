-- 033_event_details.sql -- the root edits the event's details after it is made: name, description, venue, start
-- and end (the wizard's step 1, 030). Run AFTER 032_people_search_by_name.sql (Supabase -> SQL Editor). Can be re-run.
--
-- The same rules as the wizard: name 1-80 characters, description up to 1000, venue up to 120, the end after the
-- start. Start and end go together: both, or (for events made before 030) neither.

create or replace function public.update_event_details(
  p_event_id uuid,
  p_name text,
  p_description text,
  p_venue text,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_description text := nullif(trim(coalesce(p_description, '')), '');
  v_venue text := nullif(trim(coalesce(p_venue, '')), '');
begin
  if not public.has_event_role(p_event_id, array['root']) then
    raise exception 'Only the root can change the event''s details';
  end if;
  if char_length(v_name) not between 1 and 80 then
    raise exception 'The event name must be 1-80 characters';
  end if;
  if char_length(coalesce(v_description, '')) > 1000 then
    raise exception 'The description can be at most 1000 characters';
  end if;
  if char_length(coalesce(v_venue, '')) > 120 then
    raise exception 'The venue can be at most 120 characters';
  end if;
  if (p_starts_at is null) <> (p_ends_at is null) then
    raise exception 'Pick both a start and an end time';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'The end time must be after the start time';
  end if;

  update public.events
  set name = v_name, description = v_description, venue = v_venue, starts_at = p_starts_at, ends_at = p_ends_at
  where id = p_event_id;
end;
$$;

revoke execute on function public.update_event_details(uuid, text, text, text, timestamptz, timestamptz) from public, anon;
grant execute on function public.update_event_details(uuid, text, text, text, timestamptz, timestamptz) to authenticated;

-- Tell the API (PostgREST) to pick up the new functions now, not after its next restart
notify pgrst, 'reload schema';
