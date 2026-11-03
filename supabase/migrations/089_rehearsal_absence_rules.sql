-- 089: three rules for rehearsal absences, and the end of the "take the board" calls.
--   1. A request is answered before its rehearsal starts, not after: afterwards it is a record.
--   2. Moving a rehearsal puts every answered request on it back to waiting, so the root or a planner decides again for
--      the new time (an approval for the old time does not carry over).
--   3. handover_take and handover_log_list had no caller left once "Take board" left the Live page. The log table stays,
--      as the record of who held the board.

create or replace function public.rehearsal_absence_decide(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event uuid;
  v_starts timestamptz;
begin
  select a.event_id, r.starts_at into v_event, v_starts
    from public.rehearsal_absences a join public.event_rehearsals r on r.id = a.rehearsal_id
   where a.id = p_id;
  if not found or not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can decide this.' using errcode = '42501';
  end if;
  if v_starts <= now() then
    raise exception 'That rehearsal has already started.';
  end if;
  update public.rehearsal_absences
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(),
         decided_at = now()
   where id = p_id;
end
$$;

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
  if p_starts_at <> v_old then
    update public.rehearsal_absences
       set status = 'pending', decided_by = null, decided_at = null
     where rehearsal_id = p_id and status <> 'pending';
  end if;
end;
$$;

drop function if exists public.handover_take(uuid, text);
drop function if exists public.handover_log_list(uuid);

notify pgrst, 'reload schema';
