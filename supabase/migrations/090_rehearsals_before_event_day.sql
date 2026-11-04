-- ============================================================
-- 090: a rehearsal is before the event. One may not start or end on the event's day or any day after it (days in
--   Singapore time, the time the app shows). An event with no start date has no such limit. Checked on every insert
--   and on every change of time (update_rehearsal in 089 writes through the same table), so neither the app nor a
--   direct write can put one there. Rehearsals already saved on or after the day are left as they are.
-- ============================================================

create or replace function public.rehearsal_before_event_day()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_day date;
begin
  if tg_op = 'UPDATE' and new.starts_at is not distinct from old.starts_at and new.ends_at is not distinct from old.ends_at then
    return new;
  end if;
  select (e.starts_at at time zone 'Asia/Singapore')::date into v_day from public.events e where e.id = new.event_id;
  if v_day is null then
    return new;
  end if;
  if (new.starts_at at time zone 'Asia/Singapore')::date >= v_day
     or (new.ends_at is not null and (new.ends_at at time zone 'Asia/Singapore')::date >= v_day) then
    raise exception 'A rehearsal must be before the event day' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists rehearsal_before_event_day on public.event_rehearsals;
create trigger rehearsal_before_event_day
  before insert or update of starts_at, ends_at on public.event_rehearsals
  for each row execute function public.rehearsal_before_event_day();

notify pgrst, 'reload schema';
