-- 041_frame_id.sql
--
-- frame_save honours a client-supplied id when it creates a frame.
--
-- WHY. Undo (step 13) has to bring a deleted frame back with the id it had. Rows elsewhere point at that id --
-- plan_progress (step 14, on delete cascade) and the origin_frame_id links a fork writes (step 17) -- so a
-- delete-then-undo that let Postgres mint a fresh id would leave them pointing at a frame nobody can see, or
-- silently detach the progress that was restored with it. The same id is what makes a retried paste idempotent.
--
-- THE RULE. An id is honoured only when it is free:
--   * id already in this plan  -> the ordinary update path (stale rev still raises PT409);
--   * id in another plan       -> refused, never moved or duplicated across plans;
--   * id nowhere               -> insert with that id (a restore, or a create that names its own id);
--   * no id at all             -> insert and let the default mint one, exactly as before.
-- Callers that send no id see no change, which is why the client can adopt this without a flag: paste today
-- sends no id, and the undo stack will.
--
-- The return type and the ACL are unchanged, so this is a replace, not a drop-and-recreate (R2). The grant is
-- repeated anyway so the file stands on its own (R4).

create or replace function public.frame_save(p_plan uuid, p_frame jsonb)
returns public.plan_frames
language plpgsql
security definer
set search_path = public
as $body$
declare
  v_event uuid;
  v_id uuid := nullif(p_frame ->> 'id', '')::uuid;
  v_row public.plan_frames;
  v_t integer := (p_frame ->> 't_s')::int;
  v_rev integer := nullif(p_frame ->> 'rev', '')::int;
  v_group_text text;
  v_point jsonb;
begin
  select event_id into v_event from public.plans where id = p_plan;
  if not found then
    raise exception 'That plan does not exist.' using errcode = '42501';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root user or a planner can change a plan.' using errcode = '42501';
  end if;
  if v_t is null or v_t < 0 then
    raise exception 'A frame cannot sit before T+0.' using errcode = '22023';
  end if;

  if v_id is null then
    if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t) then
      raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
        using errcode = '22023';
    end if;
    insert into public.plan_frames (plan_id, event_id, t_s, note, created_by)
    values (p_plan, v_event, v_t, nullif(p_frame ->> 'note', ''), auth.uid())
    returning * into v_row;
  else
    select * into v_row from public.plan_frames where id = v_id and plan_id = p_plan for update;
    if found then
      if v_rev is not null and v_rev <> v_row.rev then
        raise exception 'Someone else changed this frame first. Reload the plan.' using errcode = 'PT409';
      end if;
      if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t and f.id <> v_id) then
        raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
          using errcode = '22023';
      end if;
      update public.plan_frames
         set t_s = v_t,
             note = case when p_frame ? 'note' then nullif(p_frame ->> 'note', '') else note end,
             rev = rev + 1,
             updated_by = auth.uid(),
             updated_at = now()
       where id = v_id
      returning * into v_row;
    else
      -- The id is not in this plan: either a restore, or a create that names its own id. It must not be
      -- pulled out of another plan -- that would move a frame between plans under a caller who only meant
      -- to write one, and leave the other plan's frames and progress pointing at nothing.
      if exists (select 1 from public.plan_frames f where f.id = v_id) then
        raise exception 'That frame id belongs to another plan.' using errcode = '42501';
      end if;
      if exists (select 1 from public.plan_frames f where f.plan_id = p_plan and f.t_s = v_t) then
        raise exception 'There is already a frame at %. Move one of them first.', public.plan_clock(v_t)
          using errcode = '22023';
      end if;
      insert into public.plan_frames (id, plan_id, event_id, t_s, note, created_by)
      values (v_id, p_plan, v_event, v_t, nullif(p_frame ->> 'note', ''), auth.uid())
      returning * into v_row;
    end if;
  end if;

  if p_frame ? 'positions' then
    -- Drop the groups this frame no longer mentions ...
    delete from public.plan_positions pp
     where pp.frame_id = v_row.id
       and not (coalesce(p_frame -> 'positions', '{}'::jsonb) ? pp.group_id::text);

    -- ... then write the ones it does.
    for v_group_text, v_point in
      select key, value from jsonb_each(coalesce(p_frame -> 'positions', '{}'::jsonb))
    loop
      if not exists (select 1 from public.groups g where g.id = v_group_text::uuid and g.event_id = v_event) then
        raise exception 'That group belongs to another event.' using errcode = '42501';
      end if;
      insert into public.plan_positions (frame_id, plan_id, event_id, group_id, lat, lng)
      values (v_row.id, p_plan, v_event, v_group_text::uuid,
              (v_point ->> 'lat')::float8, (v_point ->> 'lng')::float8)
      on conflict (frame_id, group_id) do update
        set lat = excluded.lat, lng = excluded.lng;
    end loop;
  end if;

  update public.plans set updated_at = now() where id = p_plan;
  return v_row;
end;
$body$;

grant execute on function public.frame_save(uuid, jsonb) to authenticated;
