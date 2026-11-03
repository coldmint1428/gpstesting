-- ============================================================
-- 085: edit a rehearsal (079 said "remove it and add another"; that also threw away its absence requests).
--   Root / planners only. A rehearsal that has started is a record and stays as it was. The new start must be in the
--   future, the end after the start, the note 1-500 characters (empty = none), and two rehearsals of one event may not
--   start at the same time. Absence requests stay attached to it.
-- ============================================================

create or replace function public.update_rehearsal(p_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_old timestamptz;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select event_id, starts_at into v_event, v_old from public.event_rehearsals where id = p_id;
  if v_event is null then
    raise exception 'That rehearsal no longer exists';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change a rehearsal' using errcode = '42501';
  end if;
  if v_old <= now() then
    raise exception 'A rehearsal that has started cannot be changed';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Choose a time in the future';
  end if;
  if p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'Choose an end time after the start';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'A note can be at most 500 characters';
  end if;
  if exists (select 1 from public.event_rehearsals r where r.event_id = v_event and r.starts_at = p_starts_at and r.id <> p_id) then
    raise exception 'There is already a rehearsal at that time';
  end if;
  update public.event_rehearsals set starts_at = p_starts_at, ends_at = p_ends_at, note = v_note where id = p_id;
end;
$$;

revoke execute on function public.update_rehearsal(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.update_rehearsal(uuid, timestamptz, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';
