-- 025_run_sheet_import.sql -- merger Stage 5: Excel import / export of run sheets.
--
-- The page reads and writes the workbook (template = docs/templates/run-sheet-template.xlsx, built by the same
-- code that exports). The database gets:
--   1. three planned-only movement fields from the template (Must leave by, Arrival point, Route), so a file
--      that is exported and imported again comes back the same (used from Stages 7 and 9);
--   2. save_movement / create_run_sheet (copy) know them;
--   3. import_run_sheet: a whole workbook as a new Draft version, all or nothing.

-- ============================================================
-- 1. Planned-only movement fields
-- ============================================================
alter table public.movements
  add column if not exists leave_by text
    check (leave_by is null or leave_by ~ '^([A-Z0-9_-]{1,20} (START|END)|([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9])$'),
  add column if not exists arrival_point text check (arrival_point is null or arrival_point ~ '^[A-Z0-9_]{1,40}$'),
  add column if not exists route text check (route is null or char_length(route) between 1 and 60);

-- ============================================================
-- 2. Saving and copying keep them
-- ============================================================
create or replace function public.save_movement(p_sheet uuid, p_move jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_sheet public.run_sheets;
  v_id uuid := nullif(p_move ->> 'id', '')::uuid;
  v_old public.movements;
  v_parent public.movements;
  v_parent_id uuid := nullif(p_move ->> 'parent_id', '')::uuid;
  v_group uuid := nullif(p_move ->> 'group_id', '')::uuid;
  v_category text := nullif(btrim(coalesce(p_move ->> 'category', '')), '');
  v_skip boolean := coalesce((p_move ->> 'skip')::boolean, false);
  v_zone uuid := nullif(p_move ->> 'zone_id', '')::uuid;
  v_kind text := coalesce(nullif(p_move ->> 'deadline_kind', ''), 'cue_start');
  v_cue uuid := nullif(p_move ->> 'cue_id', '')::uuid;
  v_fixed time := public.rs_time(p_move ->> 'fixed_time', 'Fixed time');
  v_fixed_day integer := public.rs_int(p_move, 'fixed_day_offset', 0, 0, 1, 'Next day');
  v_early integer := public.rs_int(p_move, 'early_s', 0, 0, 7200, 'Arrive early by (seconds)');
  v_min integer := public.rs_int(p_move, 'min_ics', null, 1, 50, 'At least how many ICs');
  v_dwell integer := public.rs_int(p_move, 'dwell_s', 20, 0, 600, 'Inside for (seconds)');
  v_amber integer := public.rs_int(p_move, 'amber_s', 30, 0, 3600, 'Amber when spare under (seconds)');
  v_mode text := coalesce(nullif(p_move ->> 'travel_mode', ''), 'on_foot');
  v_pace numeric;
  v_code text := public.rs_code(p_move ->> 'code');
  v_zone_kind text;
  v_leave text := nullif(upper(btrim(coalesce(p_move ->> 'leave_by', ''))), '');
  v_arrival text := nullif(upper(btrim(coalesce(p_move ->> 'arrival_point', ''))), '');
  v_route text := nullif(btrim(coalesce(p_move ->> 'route', '')), '');
begin
  v_sheet := public.rs_edit(p_sheet);

  begin
    v_pace := coalesce(nullif(btrim(coalesce(p_move ->> 'pace_mps', '')), '')::numeric, 1.2);
  exception when others then
    raise exception 'Pace must be a number of metres per second, like 1.2';
  end;
  if v_pace <= 0 or v_pace > 60 then
    raise exception 'Pace must be more than 0 and at most 60 m/s';
  end if;
  if v_kind not in ('cue_start', 'cue_end', 'fixed') then
    raise exception 'Unknown deadline "%"', v_kind;
  end if;
  if v_mode not in ('on_foot', 'vehicle', 'fixed_route') then
    raise exception 'Unknown travel mode "%"', v_mode;
  end if;
  -- Planned only for now (Stages 7 and 9): must have left by, door they enter by, fixed route name
  if v_leave is not null and v_leave !~ '^([A-Z0-9_-]{1,20} (START|END)|([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9])$' then
    raise exception 'Must leave by is a cue and start or end (C034 end) or a time like 18:20:00';
  end if;
  if v_arrival is not null and v_arrival !~ '^[A-Z0-9_]{1,40}$' then
    raise exception 'Arrival point is a zone code, like D4';
  end if;
  if v_route is not null and char_length(v_route) > 60 then
    raise exception 'A route name is up to 60 characters';
  end if;

  -- WHO
  if v_parent_id is not null then
    select * into v_parent from public.movements where id = v_parent_id and run_sheet_id = p_sheet;
    if not found or v_parent.category is null then
      raise exception 'An exception belongs to a movement for a category';
    end if;
    if v_group is null or not exists (select 1 from public.groups g where g.id = v_group and g.event_id = v_sheet.event_id
                                      and lower(g.category) = lower(v_parent.category)) then
      raise exception 'Pick a group of the category "%"', v_parent.category;
    end if;
    v_category := null;
  else
    v_skip := false;
    if num_nonnulls(v_group, v_category) <> 1 then
      raise exception 'Pick who moves: one group, or a category';
    end if;
    if v_group is not null and not exists (select 1 from public.groups g where g.id = v_group and g.event_id = v_sheet.event_id) then
      raise exception 'That group is not in this event';
    end if;
    if v_category is not null and char_length(v_category) > 50 then
      raise exception 'A category is up to 50 characters';
    end if;
  end if;

  -- WHERE (a draft may leave it empty; the check flags it). Never into a No-Go zone.
  if v_zone is not null then
    select z.kind into v_zone_kind from public.zones z where z.id = v_zone and z.event_id = v_sheet.event_id;
    if v_zone_kind is null then
      raise exception 'That zone is not in this event';
    end if;
    if v_zone_kind = 'no_go' then
      raise exception 'A movement cannot go to a No-Go zone';
    end if;
  end if;

  -- BY WHEN
  if v_cue is not null and not exists (select 1 from public.cues c where c.id = v_cue and c.run_sheet_id = p_sheet) then
    raise exception 'That cue is not in this version';
  end if;
  if v_kind = 'fixed' then
    v_cue := null;
  else
    v_fixed := null;
    v_fixed_day := 0;
  end if;

  if v_id is not null then
    select * into v_old from public.movements where id = v_id and run_sheet_id = p_sheet for update;
    if not found then
      raise exception 'That movement was deleted by someone else. Reload the page.';
    end if;
    if (p_move ->> 'rev') is not null and (p_move ->> 'rev')::integer <> v_old.rev then
      raise exception 'Someone else changed this movement a moment ago. Your screen has been updated: check it and save again.'
        using errcode = 'PT409'; -- HTTP 409. Not 40001: PostgREST retries that code forever
    end if;
    if v_old.parent_id is distinct from v_parent_id then
      raise exception 'A movement cannot be turned into an exception (or back). Delete it and add it again.';
    end if;
    v_code := coalesce(v_code, v_old.code);
    if v_parent_id is null and exists (select 1 from public.movements where run_sheet_id = p_sheet and parent_id is null
                                        and code = v_code and id <> v_id) then
      raise exception 'Another movement already has the code %', v_code;
    end if;
    update public.movements
    set code = v_code, group_id = v_group, category = v_category, skip = v_skip, zone_id = v_zone, deadline_kind = v_kind,
        cue_id = v_cue, fixed_time = v_fixed, fixed_day_offset = v_fixed_day, early_s = v_early, min_ics = v_min,
        dwell_s = v_dwell, amber_s = v_amber, travel_mode = v_mode, pace_mps = v_pace,
        notes = nullif(btrim(coalesce(p_move ->> 'notes', '')), ''),
        -- not sent (an older page) = keep
        leave_by = case when p_move ? 'leave_by' then v_leave else leave_by end,
        arrival_point = case when p_move ? 'arrival_point' then v_arrival else arrival_point end,
        route = case when p_move ? 'route' then v_route else route end,
        rev = rev + 1, updated_at = now()
    where id = v_id;
    return v_id;
  end if;

  if v_parent_id is not null then
    v_code := v_parent.code; -- an exception shares its movement's code
    if exists (select 1 from public.movements where parent_id = v_parent_id and group_id = v_group) then
      raise exception 'That group already has an exception for this movement';
    end if;
  elsif v_code is null then
    v_code := public.rs_next_code(p_sheet, 'M');
  elsif exists (select 1 from public.movements where run_sheet_id = p_sheet and parent_id is null and code = v_code) then
    raise exception 'Another movement already has the code %', v_code;
  end if;
  if (select count(*) from public.movements where run_sheet_id = p_sheet) >= 2000 then
    raise exception 'A run sheet can have at most 2000 movements';
  end if;
  insert into public.movements (run_sheet_id, code, group_id, category, parent_id, skip, zone_id, deadline_kind, cue_id,
                                fixed_time, fixed_day_offset, early_s, min_ics, dwell_s, amber_s, travel_mode, pace_mps, notes,
                                leave_by, arrival_point, route)
  values (p_sheet, v_code, v_group, v_category, v_parent_id, v_skip, v_zone, v_kind, v_cue, v_fixed, v_fixed_day, v_early,
          v_min, v_dwell, v_amber, v_mode, v_pace, nullif(btrim(coalesce(p_move ->> 'notes', '')), ''),
          v_leave, v_arrival, v_route)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.create_run_sheet(p_event uuid, p_name text, p_for_date date default null, p_copy_from uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
  v_cue record;
  v_move record;
  v_new uuid;
  v_cues jsonb := '{}';
  v_moves jsonb := '{}';
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can create a run sheet' using errcode = '42501';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 60 then
    raise exception 'Give the version a name (up to 60 characters), for example "Rehearsal 2"';
  end if;
  if exists (select 1 from public.run_sheets r where r.event_id = p_event and lower(r.name) = lower(v_name)) then
    raise exception 'There is already a version called "%". Pick another name.', v_name;
  end if;
  if p_copy_from is not null and not exists (select 1 from public.run_sheets r where r.id = p_copy_from and r.event_id = p_event) then
    raise exception 'The version to copy is not in this event';
  end if;

  insert into public.run_sheets (event_id, name, for_date, created_by, updated_by)
  values (p_event, v_name, p_for_date, auth.uid(), auth.uid())
  returning id into v_id;

  if p_copy_from is not null then
    for v_cue in select * from public.cues where run_sheet_id = p_copy_from order by position loop
      insert into public.cues (run_sheet_id, position, code, section, title, start_time, day_offset, length_s, type,
                               can_shorten_s, start_mode, area, department, notes)
      values (v_id, v_cue.position, v_cue.code, v_cue.section, v_cue.title, v_cue.start_time, v_cue.day_offset,
              v_cue.length_s, v_cue.type, v_cue.can_shorten_s, v_cue.start_mode, v_cue.area, v_cue.department, v_cue.notes)
      returning id into v_new;
      v_cues := v_cues || jsonb_build_object(v_cue.id::text, v_new);
    end loop;
    -- Movements first, then their exceptions (which point at a movement of the new version)
    for v_move in select * from public.movements where run_sheet_id = p_copy_from order by (parent_id is not null), code loop
      insert into public.movements (run_sheet_id, code, group_id, category, parent_id, skip, zone_id, deadline_kind, cue_id,
                                    fixed_time, fixed_day_offset, early_s, min_ics, dwell_s, amber_s, travel_mode, pace_mps, notes,
                                    leave_by, arrival_point, route)
      values (v_id, v_move.code, v_move.group_id, v_move.category,
              case when v_move.parent_id is null then null else (v_moves ->> v_move.parent_id::text)::uuid end,
              v_move.skip, v_move.zone_id, v_move.deadline_kind,
              case when v_move.cue_id is null then null else (v_cues ->> v_move.cue_id::text)::uuid end,
              v_move.fixed_time, v_move.fixed_day_offset, v_move.early_s, v_move.min_ics, v_move.dwell_s, v_move.amber_s,
              v_move.travel_mode, v_move.pace_mps, v_move.notes, v_move.leave_by, v_move.arrival_point, v_move.route)
      returning id into v_new;
      v_moves := v_moves || jsonb_build_object(v_move.id::text, v_new);
    end loop;
  end if;
  return v_id;
end;
$$;

-- During import_run_sheet (one transaction) saving a cue or movement does not touch the version row each
-- time; everything else is checked as usual. The setting lives only for that transaction.
create or replace function public.rs_edit(p_sheet uuid)
returns public.run_sheets
language plpgsql security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  v_used timestamptz;
  -- coalesce: outside an import the setting does not exist, and NULL here would skip the update below
  v_importing boolean := coalesce(current_setting('rs.importing', true), '') = p_sheet::text;
begin
  if v_importing then
    select * into v from public.run_sheets where id = p_sheet;
  else
    select * into v from public.run_sheets where id = p_sheet for update;
  end if;
  if not found then
    raise exception 'That run sheet version no longer exists. Reload the page.';
  end if;
  if not public.has_event_role(v.event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can edit the run sheet' using errcode = '42501';
  end if;
  v_used := public.run_sheet_used_on(p_sheet);
  if v_used is not null then
    raise exception '"%" already ran on %. Duplicate it to make changes.', v.name, public.rs_day(v_used);
  end if;
  if not v_importing then
    update public.run_sheets set status = 'draft', rev = rev + 1, updated_at = now(), updated_by = auth.uid()
    where id = p_sheet;
  end if;
  return v;
end;
$$;

-- ============================================================
-- 3. Import a whole workbook as a new Draft version, all or nothing
-- ============================================================
-- The page reads the Excel file, checks every row and shows a preview; only a clean preview is sent here.
-- This function checks everything again (through save_cue / save_movement / update_group_details, the same
-- rules as typing it in) and either stores ALL of it or NOTHING: any error rolls back the version, the groups
-- and the zones it made, and names the tab and row ("Movements row 12: ...").
--
-- p_data (codes, never ids - the server finds the rows itself):
--   { name, for_date,
--     groups:    [{ row, code, name, category, sector, headcount, colour }]
--     zones:     [{ row, code, name, kind, source: 'circle'|'polygon', lat, lng, radius_m, capacity }]
--     cues:      [{ row, code, section, title, start_time, day_offset, length_s, type, can_shorten_s, start_mode,
--                   area, department, notes }]
--     movements: [{ row, code, group_code | category, parent_code (an exception of that category movement),
--                   skip, zone_code, deadline_kind, cue_code, fixed_time, fixed_day_offset, early_s, min_ics,
--                   dwell_s, amber_s, travel_mode, pace_mps, leave_by, arrival_point, route, notes }] }
-- Groups: matched by code, else by name; a new one is created. Blank details keep what the group has.
-- Zones: matched by code (capacity updated); a missing Circle zone is drawn on the event's bench as a
--   32-point area (so it shows and can be edited in the Zones tab); a missing Polygon zone is left out
--   (its movements get no zone, which the check flags).
create or replace function public.rs_circle_points(p_lat double precision, p_lng double precision, p_radius_m double precision)
returns jsonb
language sql immutable set search_path = ''
as $$
  select jsonb_agg(jsonb_build_array(
           round((p_lat + p_radius_m / 111320.0 * cos(2 * pi() * i / 32))::numeric, 7),
           round((p_lng + p_radius_m / (111320.0 * cos(radians(p_lat))) * sin(2 * pi() * i / 32))::numeric, 7))
         order by i)
  from generate_series(0, 31) as i;
$$;

create or replace function public.import_run_sheet(p_event uuid, p_data jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_sheet uuid;
  v_id uuid;
  v_group public.groups;
  v_code text;
  v_name text;
  v_layout uuid;
  v_rev bigint;
  v_object text;
  v_area jsonb;
  v_problem text;
  v_kind text;
  v_lat double precision;
  v_lng double precision;
  v_radius double precision;
  v_cues jsonb := '{}';
  v_moves jsonb := '{}';
  v_move jsonb;
  n_groups_new integer := 0;
  n_groups_upd integer := 0;
  n_zones_new integer := 0;
  n_cues integer := 0;
  n_moves integer := 0;
  n_exc integer := 0;
  v_where text;
  v_seen jsonb := '{}';
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can import a run sheet' using errcode = '42501';
  end if;
  if jsonb_array_length(coalesce(p_data -> 'cues', '[]')) > 500 then
    raise exception 'A run sheet can have at most 500 cues';
  end if;
  if jsonb_array_length(coalesce(p_data -> 'movements', '[]')) > 2000 then
    raise exception 'A run sheet can have at most 2000 movements';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    raise exception 'That is not a run sheet file';
  end if;
  if jsonb_array_length(coalesce(p_data -> 'cues', '[]')) = 0 then
    raise exception 'The Cues tab has no cues';
  end if;

  -- ---------- Groups ----------
  for r in select * from jsonb_array_elements(coalesce(p_data -> 'groups', '[]')) loop
    v_where := 'Groups row ' || coalesce(r ->> 'row', '?');
    v_code := upper(btrim(coalesce(r ->> 'code', '')));
    v_name := btrim(coalesce(r ->> 'name', ''));
    if v_code !~ '^[A-Z0-9_]{1,40}$' then
      raise exception 'a group code is 1 to 40 capital letters, digits or _ (for example BAND_1)';
    end if;
    if v_seen ? ('G' || v_code) then
      raise exception 'the Group code % is used twice', v_code;
    end if;
    v_seen := v_seen || jsonb_build_object('G' || v_code, true);
    select * into v_group from public.groups g where g.event_id = p_event and g.code = v_code;
    if not found and v_name <> '' then
      select * into v_group from public.groups g where g.event_id = p_event and lower(g.name) = lower(v_name);
    end if;
    if v_group.id is null then
      if char_length(v_name) not between 1 and 50 then
        raise exception 'give the group a name (up to 50 characters)';
      end if;
      insert into public.groups (event_id, name, colour)
      values (p_event, v_name, case when (r ->> 'colour') ~ '^#[0-9a-fA-F]{6}$' then r ->> 'colour' else '#0d6efd' end)
      returning * into v_group;
      n_groups_new := n_groups_new + 1;
    else
      if (r ->> 'colour') ~ '^#[0-9a-fA-F]{6}$' and lower(r ->> 'colour') <> lower(v_group.colour) then
        update public.groups set colour = r ->> 'colour' where id = v_group.id;
      end if;
      n_groups_upd := n_groups_upd + 1;
    end if;
    -- blank = keep what the group has
    perform public.update_group_details(
      v_group.id, v_code,
      coalesce(nullif(btrim(coalesce(r ->> 'category', '')), ''), v_group.category),
      coalesce(nullif(btrim(coalesce(r ->> 'sector', '')), ''), v_group.sector),
      coalesce(public.rs_int(r, 'headcount', null, 0, 100000, 'Headcount'), v_group.headcount));
    v_group := null;
  end loop;

  -- ---------- Zones ----------
  for r in select * from jsonb_array_elements(coalesce(p_data -> 'zones', '[]')) loop
    v_where := 'Zones row ' || coalesce(r ->> 'row', '?');
    v_code := upper(btrim(coalesce(r ->> 'code', '')));
    if v_code !~ '^[A-Z0-9_]{1,40}$' then
      raise exception 'a zone code is 1 to 40 capital letters, digits or _ (for example FORMATION_1)';
    end if;
    if v_seen ? ('Z' || v_code) then
      raise exception 'the Zone code % is used twice', v_code;
    end if;
    v_seen := v_seen || jsonb_build_object('Z' || v_code, true);
    select z.id into v_id from public.zones z where z.event_id = p_event and z.code = v_code;
    if v_id is not null then
      if (r ->> 'capacity') is not null then
        update public.zones set capacity = public.rs_int(r, 'capacity', null, 0, 1000000, 'Capacity') where id = v_id;
      end if;
    elsif r ->> 'source' = 'circle' then
      v_kind := r ->> 'kind';
      v_lat := (r ->> 'lat')::double precision;
      v_lng := (r ->> 'lng')::double precision;
      v_radius := (r ->> 'radius_m')::double precision;
      if v_radius is null or v_radius < 15 or v_radius > 5000 then
        raise exception 'a circle radius is 15 to 5000 m';
      end if;
      insert into public.layouts (created_by, event_id, name) values (auth.uid(), p_event, 'Zones') on conflict do nothing;
      select l.id into v_layout from public.layouts l where l.event_id = p_event;
      v_object := gen_random_uuid()::text;
      v_area := jsonb_build_object('id', v_object, 'name', btrim(coalesce(r ->> 'name', '')), 'kind', v_kind,
                                   'code', v_code, 'points', public.rs_circle_points(v_lat, v_lng, v_radius));
      v_problem := public.shape_problem('area', v_area);
      if v_problem is not null then
        raise exception '%', v_problem;
      end if;
      update public.layouts set rev = rev + 1, updated_at = now() where id = v_layout returning rev into v_rev;
      insert into public.layout_objects (layout_id, object_id, kind, data, rev, updated_at, updated_by)
      values (v_layout, v_object, 'area', v_area, v_rev, now(), auth.uid());
      update public.zones
      set is_circle = true, radius_m = v_radius, capacity = public.rs_int(r, 'capacity', null, 0, 1000000, 'Capacity')
      where source_area_id = v_object;
      n_zones_new := n_zones_new + 1;
    end if;
    v_id := null;
  end loop;

  -- ---------- The version and its cues ----------
  v_where := 'Event tab';
  v_sheet := public.create_run_sheet(p_event, p_data ->> 'name', nullif(p_data ->> 'for_date', '')::date);
  -- Saving each cue and movement normally also turns the version back into a Draft and counts its revision:
  -- 2,000 updates of one row in one transaction made a big import too slow (10 s; requests stop at 8 s).
  -- The new version is a Draft already, so rs_edit skips that while this import runs (it still checks the
  -- role and that the version has not run).
  perform set_config('rs.importing', v_sheet::text, true);

  for r in select * from jsonb_array_elements(p_data -> 'cues') loop
    v_where := 'Cues row ' || coalesce(r ->> 'row', '?');
    v_code := public.rs_code(r ->> 'code');
    if v_code is null then
      raise exception 'give the cue an ID (for example C034)';
    end if;
    if v_cues ? v_code then
      raise exception 'the Cue ID % is used twice', v_code;
    end if;
    v_id := public.save_cue(v_sheet, (r - 'row' - 'id' - 'rev' - 'after_position') || jsonb_build_object('code', v_code));
    v_cues := v_cues || jsonb_build_object(v_code, v_id);
    n_cues := n_cues + 1;
  end loop;

  -- ---------- Movements, then the exceptions to category movements ----------
  for r in
    select e from jsonb_array_elements(coalesce(p_data -> 'movements', '[]')) as e
    order by (nullif(e ->> 'parent_code', '') is not null)
  loop
    v_where := 'Movements row ' || coalesce(r ->> 'row', '?');
    v_move := r - 'row' - 'id' - 'rev' - 'group_code' - 'zone_code' - 'cue_code' - 'parent_code';
    -- who
    if nullif(btrim(coalesce(r ->> 'group_code', '')), '') is not null then
      select g.id into v_id from public.groups g where g.event_id = p_event and g.code = upper(btrim(r ->> 'group_code'));
      if v_id is null then
        raise exception 'no group has the code %', upper(btrim(r ->> 'group_code'));
      end if;
      v_move := v_move || jsonb_build_object('group_id', v_id);
    end if;
    -- where (a zone that does not exist yet is left empty: the check asks for it)
    if nullif(btrim(coalesce(r ->> 'zone_code', '')), '') is not null then
      select z.id into v_id from public.zones z where z.event_id = p_event and z.code = upper(btrim(r ->> 'zone_code'));
      v_move := v_move || jsonb_build_object('zone_id', v_id);
    end if;
    -- by when
    if nullif(btrim(coalesce(r ->> 'cue_code', '')), '') is not null then
      if not v_cues ? upper(btrim(r ->> 'cue_code')) then
        raise exception 'no cue has the ID %', upper(btrim(r ->> 'cue_code'));
      end if;
      v_move := v_move || jsonb_build_object('cue_id', v_cues ->> upper(btrim(r ->> 'cue_code')));
    end if;
    if nullif(r ->> 'parent_code', '') is not null then
      if not v_moves ? upper(r ->> 'parent_code') then
        raise exception 'it changes movement %, which is not a movement for a category', upper(r ->> 'parent_code');
      end if;
      v_move := (v_move - 'code' - 'category') || jsonb_build_object('parent_id', v_moves ->> upper(r ->> 'parent_code'));
      perform public.save_movement(v_sheet, v_move);
      n_exc := n_exc + 1;
    else
      v_code := public.rs_code(r ->> 'code');
      if v_code is null then
        raise exception 'give the movement an ID (for example M012)';
      end if;
      if v_moves ? v_code then
        raise exception 'the Move ID % is used twice', v_code;
      end if;
      v_id := public.save_movement(v_sheet, v_move || jsonb_build_object('code', v_code));
      v_moves := v_moves || jsonb_build_object(v_code, v_id);
      n_moves := n_moves + 1;
    end if;
    v_id := null;
  end loop;

  perform set_config('rs.importing', '', true);
  return jsonb_build_object('sheet_id', v_sheet, 'cues', n_cues, 'movements', n_moves, 'exceptions', n_exc,
                            'groups_created', n_groups_new, 'groups_updated', n_groups_upd, 'zones_created', n_zones_new);
exception when others then
  -- One handler for the whole import: name the tab and row it was on (no sub-transaction per row)
  if v_where is null then
    raise;
  end if;
  raise exception '%: %', v_where, sqlerrm;
end;
$$;

-- ============================================================
-- 4. Permissions
-- ============================================================
revoke execute on function public.rs_circle_points(double precision, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.import_run_sheet(uuid, jsonb) from public, anon;
grant execute on function public.import_run_sheet(uuid, jsonb) to authenticated;
