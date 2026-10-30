-- 066_plan_t0_singapore_date.sql
--
-- QA 31 Oct: a plan's T+0 fell on the wrong day for eight hours of every day.
--
-- plan_t0 read a plan with no for_date as "today at t0_time" and took today from current_date, which is the
-- database's date, in UTC. Between midnight and 08:00 in Singapore the UTC date is still yesterday, so an event started
-- at 01:04 got a T+0 of 18:00 the evening before and every group showed "7 h late" from its first moment. The day is
-- now Singapore's, the same zone the time is read in.
--
-- And a scheduled start took its day from when the schedule was SAVED, not from when the event starts: scheduling
-- tonight for tomorrow's doors put T+0 tonight, a day early. schedule_event_start now anchors a plan with no for_date
-- on the scheduled start's own Singapore date. A plan with a for_date keeps it in both places.

create or replace function public.plan_t0(p_plan uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $function$
  select ((coalesce(p.for_date, (now() at time zone 'Asia/Singapore')::date)::timestamp + p.t0_time) at time zone 'Asia/Singapore')
  from public.plans p
  where p.id = p_plan;
$function$;

create or replace function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz, p_plan uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  open_session public.event_sessions;
  new_id uuid;
  v_t0 timestamptz;
  v_rev integer;
  v_plan public.plans;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can schedule the event' using errcode = '42501';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Pick a start time in the future';
  end if;
  if p_starts_at > now() + interval '1 year' then
    raise exception 'Pick a start time within the next year';
  end if;
  v_t0 := public.session_engine(p_event_id, p_plan);
  select * into v_plan from public.plans where id = p_plan;
  v_rev := v_plan.rev;
  -- A plan with no date runs on the day it starts, not on the day somebody scheduled it
  if p_plan is not null and v_plan.for_date is null then
    v_t0 := (((p_starts_at at time zone 'Asia/Singapore')::date)::timestamp + v_plan.t0_time) at time zone 'Asia/Singapore';
  end if;

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions
       set starts_at = p_starts_at, started_by = auth.uid(), plan_id = p_plan, t0_at = v_t0,
           plan_rev = coalesce(v_rev, 0),
           scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
     where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, plan_id, t0_at, plan_rev)
  values (p_event_id, p_starts_at, auth.uid(), p_plan, v_t0, coalesce(v_rev, 0))
  returning id into new_id;
  return new_id;
end;
$function$;
