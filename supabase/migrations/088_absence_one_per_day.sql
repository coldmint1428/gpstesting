-- One "not available" request per member per rehearsal day. A member who asks again for another rehearsal on the same
-- day (Singapore time) replaces their earlier request that was not approved, instead of leaving an old row the planner
-- has to find and answer; if one that day is already approved, the new one is refused. For the same rehearsal the
-- (rehearsal_id, user_id) key already gave one row, which is reset to waiting.
create or replace function public.rehearsal_absence_request(p_rehearsal uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rehearsal public.event_rehearsals;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_day date;
begin
  select * into v_rehearsal from public.event_rehearsals where id = p_rehearsal;
  if not found or not public.is_event_member(v_rehearsal.event_id) then
    raise exception 'That rehearsal is not in one of your events.' using errcode = '42501';
  end if;
  if v_rehearsal.starts_at <= now() then
    raise exception 'That rehearsal has already started.';
  end if;
  if char_length(v_reason) not between 1 and 300 then
    raise exception 'Give a reason of up to 300 characters.';
  end if;

  v_day := (v_rehearsal.starts_at at time zone 'Asia/Singapore')::date;
  if exists (
    select 1
      from public.rehearsal_absences a
      join public.event_rehearsals r on r.id = a.rehearsal_id
     where a.user_id = auth.uid()
       and a.event_id = v_rehearsal.event_id
       and a.rehearsal_id <> p_rehearsal
       and a.status = 'approved'
       and (r.starts_at at time zone 'Asia/Singapore')::date = v_day
  ) then
    raise exception 'You already have an approved request for another rehearsal that day.';
  end if;
  delete from public.rehearsal_absences a
   using public.event_rehearsals r
   where r.id = a.rehearsal_id
     and a.user_id = auth.uid()
     and a.event_id = v_rehearsal.event_id
     and a.rehearsal_id <> p_rehearsal
     and a.status <> 'approved'
     and (r.starts_at at time zone 'Asia/Singapore')::date = v_day;

  insert into public.rehearsal_absences (rehearsal_id, event_id, user_id, reason)
  values (p_rehearsal, v_rehearsal.event_id, auth.uid(), v_reason)
  on conflict (rehearsal_id, user_id) do update
    set reason = excluded.reason, status = 'pending', decided_by = null, decided_at = null, created_at = now()
    where public.rehearsal_absences.status <> 'approved';
  if not found then
    raise exception 'Your request for this rehearsal is already approved.';
  end if;
end
$$;
