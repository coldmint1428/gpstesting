-- 078: a duplicated plan is named "<name> (Copied)" instead of "<name> (edited)".
-- Run AFTER 077_no_marshals.sql (Supabase -> SQL Editor). Can be re-run.
--
-- WHY. The board's button is now "Duplicate plan" (QA 2 Nov), and "(edited)" read as if the original had been
-- changed. plan_fork is 053's body unchanged apart from that one word. Plans already made keep their names.

create or replace function public.plan_fork(p_plan uuid)
returns public.plans
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_src public.plans;
  v_row public.plans;
  v_name text;
  v_cut integer;
  v_anchor uuid;
  v_group uuid;
  v_point record;
begin
  select * into v_src from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_src.event_id, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can copy a plan.' using errcode = '42501';
  end if;

  -- ---------- where the running clock has got to ----------
  -- Only a session that has actually started has a past to protect, and only past T+0: a copy taken at the zero point
  -- still has its whole walk ahead of it, so it is an ordinary deep copy.
  select greatest(0, least(86400 * 3, floor(extract(epoch from now() - s.t0_at))::int))
    into v_cut
    from public.event_sessions s
   where s.event_id = v_src.event_id
     and s.plan_id = p_plan
     and s.ended_at is null
     and s.starts_at <= now()
     and s.t0_at is not null
   order by s.starts_at desc
   limit 1;
  if not found or v_cut <= 0 then
    v_cut := null;
  end if;

  v_name := left(v_src.name || ' (Copied)', 80);

  insert into public.plans (event_id, name, for_date, t0_time, status, fork_of, forked_at, created_by)
  values (v_src.event_id, v_name, v_src.for_date, v_src.t0_time, 'draft', v_src.id, now(), auth.uid())
  returning * into v_row;

  -- ---------- the future, copied ----------
  with copied as (
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    select v_row.id, f.event_id, f.t_s, f.note, auth.uid()
    from public.plan_frames f
    where f.plan_id = p_plan
      and (v_cut is null or f.t_s > v_cut)
    returning id, t_s
  )
  insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
  select c.id, v_row.id, v_row.event_id, p.group_id, p.lat, p.lng, p.state, p.verify
  from copied c
  join public.plan_frames f_old on f_old.plan_id = p_plan and f_old.t_s = c.t_s
  join public.plan_positions p on p.frame_id = f_old.id;

  -- ---------- finding 8: the origin links, in a second pass ----------
  -- The INSERT above cannot name the frame it copied, because the new ids did not exist while it ran. Time is unique
  -- in a plan, so the two plans can be paired by it. The anchor is not a copy of anything and keeps a null origin.
  update public.plan_frames nf
     set origin_frame_id = src.id
    from public.plan_frames src
   where nf.plan_id = v_row.id
     and nf.origin_frame_id is null
     and (v_cut is null or nf.t_s > v_cut)
     and src.plan_id = p_plan
     and src.t_s = nf.t_s;

  -- ---------- the anchor: everyone where the walk already had them ----------
  if v_cut is not null then
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    values (v_row.id, v_row.event_id, v_cut, null, auth.uid())
    returning id into v_anchor;

    for v_group in
      select distinct pp.group_id
        from public.plan_positions pp
        join public.plan_frames pf on pf.id = pp.frame_id
       where pf.plan_id = p_plan
         and pf.t_s <= v_cut
       order by pp.group_id
    loop
      select * into v_point from public.plan_position_at(p_plan, v_group, v_cut);
      if found then
        insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng, state, verify)
        values (v_anchor, v_row.id, v_row.event_id, v_group,
                v_point.lat, v_point.lng, v_point.state, v_point.verify);
      end if;
    end loop;

    -- The cut goes on last. Everything above is the copy; from here the triggers freeze what it starts from.
    update public.plans set fork_cut_s = v_cut where id = v_row.id returning * into v_row;
  end if;

  return v_row;
end;
$body$;

revoke execute on function public.plan_fork(uuid) from public, anon;
grant execute on function public.plan_fork(uuid) to authenticated;
