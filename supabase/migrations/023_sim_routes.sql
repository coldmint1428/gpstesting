-- 023_sim_routes.sql -- merger Stage 3 fix after the first live simulator run (16 Oct 2026).
--
-- sim_setup() picked each group's start at a random bearing and distance from its target, with no regard
-- for No-Go zones: a group could start inside the stage, and straight walks between zones on either side
-- of it crossed it. Both set off No-Go alerts for groups that were meant to be on time. Now a start must
-- be 25 m clear of every No-Go zone and, unless the group is "wrong zone", its straight walk 20 m clear.
-- Same signature, so the grants from 022 still apply. Only new groups are affected.

create or replace function public.sim_setup(p_event uuid, p_groups int, p_ics_min int default 2, p_ics_max int default 3, p_mix jsonb default '{"on_time":80,"late_2min":10,"stops_halfway":0,"loses_signal":5,"wrong_zone":5}')
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_short text := left(replace(p_event::text, '-', ''), 6);
  v_scripts text[] := '{}';
  v_key text;
  v_total numeric := 0;
  v_count int;
  v_i int;
  v_n int;
  v_group uuid;
  v_zone record;
  v_start extensions.geography;
  v_end extensions.geography;
  v_path double precision;
  v_pace double precision;
  v_script text;
  v_ics int;
  v_user uuid;
  v_next int;
  v_try int;
  v_colours text[] := array['#0d6efd', '#d63384', '#198754', '#fd7e14', '#6f42c1', '#0dcaf0', '#b02a37', '#20c997', '#6610f2', '#ffc107'];
begin
  perform public.sim_check(p_event);
  if exists (select 1 from public.sim_runs r where r.event_id = p_event and r.status = 'running') then
    raise exception 'Pause the simulation before adding groups';
  end if;
  if p_groups is null or p_groups < 1 or p_groups > 150 then
    raise exception 'Between 1 and 150 groups at a time';
  end if;
  p_ics_min := greatest(1, least(coalesce(p_ics_min, 2), 3));
  p_ics_max := greatest(p_ics_min, least(coalesce(p_ics_max, 3), 3));
  if not exists (select 1 from public.zones z where z.event_id = p_event and z.kind <> 'no_go') then
    raise exception 'Draw at least one zone (not No-Go) in the Zones tab first: the virtual groups walk to the zones';
  end if;

  -- The behaviours, spread by the percentages (largest remainders last so the counts add up to N).
  for v_key in select key from public.sim_scripts order by sort loop
    v_total := v_total + greatest(coalesce((p_mix ->> v_key)::numeric, 0), 0);
  end loop;
  if v_total <= 0 then v_total := 1; p_mix := '{"on_time":1}'; end if;
  for v_key in select key from public.sim_scripts order by sort loop
    v_count := round(p_groups * greatest(coalesce((p_mix ->> v_key)::numeric, 0), 0) / v_total);
    for v_i in 1 .. v_count loop v_scripts := v_scripts || v_key; end loop;
  end loop;
  while coalesce(array_length(v_scripts, 1), 0) < p_groups loop v_scripts := v_scripts || 'on_time'::text; end loop;
  v_scripts := v_scripts[1:p_groups];

  select coalesce(max(substring(g.name from 'SIM-(\d+)')::int), 0) into v_next
  from public.groups g where g.event_id = p_event and g.name ~ '^SIM-\d+$';
  select count(*) into v_n from public.sim_ics s where s.event_id = p_event;

  for v_i in 1 .. p_groups loop
    v_script := v_scripts[v_i];

    -- Where it walks: a No-Go zone for "wrong zone" (if the event has one), otherwise any other zone.
    select z.id, extensions.st_centroid(z.shape::extensions.geometry)::extensions.geography as c into v_zone
    from public.zones z
    where z.event_id = p_event
      and (case when v_script = 'wrong_zone' and exists (select 1 from public.zones x where x.event_id = p_event and x.kind = 'no_go')
                then z.kind = 'no_go' else z.kind <> 'no_go' end)
    order by random() limit 1;

    v_end := v_zone.c;
    -- A start 200-600 m away that does not stand in a No-Go zone, and (for everybody but "wrong zone")
    -- whose straight walk does not cut through one either -- otherwise on-time groups set off No-Go alerts
    -- by spawning inside the stage or walking across it (first live run, 16 Oct: 10 of 28 alerts were
    -- that). Up to 25 tries; if nothing fits (zones packed tight) the last try is used.
    for v_try in 1 .. 25 loop
      v_start := extensions.st_project(v_end, 200 + random() * 400, random() * 2 * pi());
      exit when not exists (
        select 1 from public.zones x
        where x.event_id = p_event and x.kind = 'no_go'
          and (extensions.st_dwithin(x.shape, v_start, 25)
               or (v_script <> 'wrong_zone' and extensions.st_dwithin(
                     x.shape,
                     extensions.st_makeline(v_start::extensions.geometry, v_end::extensions.geometry)::extensions.geography,
                     20)))
      );
    end loop;
    v_path := extensions.st_distance(v_start, v_end);
    v_pace := 1.0 + random() * 0.5;

    insert into public.groups (event_id, name, colour, category)
    values (p_event, 'SIM-' || lpad((v_next + v_i)::text, 3, '0'), v_colours[1 + ((v_next + v_i) % 10)], 'Simulated')
    returning id into v_group;

    insert into public.sim_groups (event_id, group_id, script, target_zone_id, start_lat, start_lng, end_lat, end_lng,
                                   path_m, pace_mps, depart_after_s, stop_at_m, silent_from_s, silent_to_s)
    values (p_event, v_group, v_script, v_zone.id,
            extensions.st_y(v_start::extensions.geometry), extensions.st_x(v_start::extensions.geometry),
            extensions.st_y(v_end::extensions.geometry), extensions.st_x(v_end::extensions.geometry),
            v_path, v_pace,
            case when v_script = 'late_2min' then 120 else 0 end,
            case when v_script = 'stops_halfway' then v_path * 0.5 end,
            case when v_script = 'loses_signal' then (v_path * 0.4) / v_pace end,
            case when v_script = 'loses_signal' then (v_path * 0.4) / v_pace + 150 end);

    v_ics := p_ics_min + floor(random() * (p_ics_max - p_ics_min + 1))::int;
    for v_count in 1 .. v_ics loop
      v_n := v_n + 1;
      v_user := gen_random_uuid();
      -- A fake Auth account: no password and no identity, so it can never sign in. handle_new_user makes
      -- its profile from the metadata.
      insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'sim-' || v_short || '-' || lpad(v_n::text, 4, '0') || '@simulation.invalid', '', now(),
              '{"provider":"simulation","providers":[]}'::jsonb,
              jsonb_build_object('username', 'sim_' || v_short || '_' || lpad(v_n::text, 4, '0'),
                                 'display_name', 'Sim IC ' || lpad(v_n::text, 4, '0')),
              now(), now());
      update public.profiles set is_simulated = true where id = v_user;
      insert into public.sim_ics (user_id, event_id, group_id) values (v_user, p_event, v_group);
      insert into public.event_roles (event_id, user_id, role) values (p_event, v_user, 'participant') on conflict do nothing;
      insert into public.group_members (event_id, group_id, user_id, is_ic, is_admin) values (p_event, v_group, v_user, true, false);
    end loop;
  end loop;

  insert into public.sim_runs (event_id, status) values (p_event, 'ready')
  on conflict (event_id) do nothing;
  return p_groups;
end;
$$;
