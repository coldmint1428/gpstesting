-- 024_run_sheets.sql -- merger Stage 4: run sheet builder (manual entry).
--
-- A run sheet VERSION ("Rehearsal 2", optionally for a date) holds the show's cues and the movements groups
-- must make. Status in plain words: draft (being edited) / ready (passed the check, can run). "Used" is not
-- stored: a version is used once a session that started has run with it, and is then locked (duplicate it to
-- change it). Cue times are TIME OF DAY (+1 day after midnight), applied to whichever session runs the
-- version, so one version can run on any date. Start event / Schedule pick the version
-- (event_sessions.run_sheet_id).
--
-- Root and planners edit, marshals read. Nothing writes these tables directly: every change goes through a
-- function below, which checks the role, the lock (used) and the values, and turns a Ready version back
-- into a Draft. Nothing here RUNS the show yet (Stage 6).

-- ============================================================
-- 1. Tables
-- ============================================================
create table public.run_sheets (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  for_date date,
  status text not null default 'draft' check (status in ('draft', 'ready')),
  rev integer not null default 1,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now()
);
create unique index run_sheets_event_name on public.run_sheets (event_id, lower(name));

create table public.cues (
  id uuid primary key default gen_random_uuid(),
  run_sheet_id uuid not null references public.run_sheets (id) on delete cascade,
  position integer not null,
  code text not null check (code ~ '^[A-Z0-9_-]{1,20}$'),
  section text check (section is null or char_length(section) between 1 and 60),
  title text not null check (char_length(title) between 1 and 120),
  start_time time not null,
  day_offset integer not null default 0 check (day_offset between 0 and 1),
  length_s integer not null default 0 check (length_s between 0 and 86400),
  type text not null default 'normal' check (type in ('normal', 'flexible', 'anchor')),
  can_shorten_s integer not null default 0 check (can_shorten_s >= 0),
  start_mode text not null default 'auto' check (start_mode in ('auto', 'auto_ready', 'manual')),
  area text check (area is null or char_length(area) <= 60),
  department text check (department is null or char_length(department) <= 60),
  notes text check (notes is null or char_length(notes) <= 500),
  rev integer not null default 1,
  updated_at timestamptz not null default now(),
  check (type <> 'anchor' or start_mode = 'auto'),
  check (type = 'flexible' or can_shorten_s = 0),
  check (can_shorten_s <= length_s)
);
create unique index cues_sheet_code on public.cues (run_sheet_id, code);
create index cues_sheet_position on public.cues (run_sheet_id, position);

create table public.movements (
  id uuid primary key default gen_random_uuid(),
  run_sheet_id uuid not null references public.run_sheets (id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9_-]{1,20}$'),
  -- WHO: one group, or every group of a category. An exception (parent_id) is one group of its parent's
  -- category, either skipped or with its own values.
  group_id uuid references public.groups (id) on delete cascade,
  category text check (category is null or char_length(category) between 1 and 50),
  parent_id uuid references public.movements (id) on delete cascade,
  skip boolean not null default false,
  -- WHERE and BY WHEN
  zone_id uuid references public.zones (id) on delete set null,
  deadline_kind text not null default 'cue_start' check (deadline_kind in ('cue_start', 'cue_end', 'fixed')),
  cue_id uuid references public.cues (id) on delete set null,
  fixed_time time,
  fixed_day_offset integer not null default 0 check (fixed_day_offset between 0 and 1),
  early_s integer not null default 0 check (early_s between 0 and 7200),
  -- ARRIVED: min_ics ICs (null = all that are sharing) inside for dwell_s seconds; amber below amber_s spare
  min_ics integer check (min_ics is null or min_ics between 1 and 50),
  dwell_s integer not null default 20 check (dwell_s between 0 and 600),
  amber_s integer not null default 30 check (amber_s between 0 and 3600),
  -- HOW (vehicle and fixed route are stored, used from Stages 7 and 9)
  travel_mode text not null default 'on_foot' check (travel_mode in ('on_foot', 'vehicle', 'fixed_route')),
  pace_mps numeric(5, 2) not null default 1.2 check (pace_mps > 0 and pace_mps <= 60),
  notes text check (notes is null or char_length(notes) <= 500),
  rev integer not null default 1,
  updated_at timestamptz not null default now(),
  check (
    (parent_id is null and num_nonnulls(group_id, category) = 1 and not skip)
    or (parent_id is not null and group_id is not null and category is null)
  )
);
create unique index movements_sheet_code on public.movements (run_sheet_id, code) where parent_id is null;
create unique index movements_exception on public.movements (parent_id, group_id) where parent_id is not null;
create index movements_sheet on public.movements (run_sheet_id);

alter table public.event_sessions add column if not exists run_sheet_id uuid references public.run_sheets (id) on delete set null;

-- Realtime: other planners' edits reload the open sheet. FULL so a delete still carries the sheet id the
-- page filters on.
alter table public.run_sheets replica identity full;
alter table public.cues replica identity full;
alter table public.movements replica identity full;
alter publication supabase_realtime add table public.run_sheets, public.cues, public.movements;

-- ============================================================
-- 2. Reading: root, planners and marshals of the event
-- ============================================================
alter table public.run_sheets enable row level security;
alter table public.cues enable row level security;
alter table public.movements enable row level security;

create policy "run sheets: root, planners, marshals read" on public.run_sheets
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner', 'marshal']));
create policy "cues: root, planners, marshals read" on public.cues
  for select to authenticated
  using (exists (select 1 from public.run_sheets s where s.id = run_sheet_id
                 and public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])));
create policy "movements: root, planners, marshals read" on public.movements
  for select to authenticated
  using (exists (select 1 from public.run_sheets s where s.id = run_sheet_id
                 and public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])));

-- ============================================================
-- 3. Helpers
-- ============================================================
-- When a version was first run (a session that has started with it), or null.
create or replace function public.run_sheet_used_on(p_sheet uuid)
returns timestamptz
language sql stable security definer set search_path = ''
as $$
  select min(s.starts_at) from public.event_sessions s where s.run_sheet_id = p_sheet and s.starts_at <= now();
$$;

-- "Sat 19 Jul" in Singapore time, for messages.
create or replace function public.rs_day(p_at timestamptz)
returns text
language sql stable set search_path = ''
as $$ select to_char(p_at at time zone 'Asia/Singapore', 'Dy FMDD Mon') $$;

-- Seconds from the show day's midnight -> "00:05:00 (next day)", for messages.
create or replace function public.rs_clock(p_s integer)
returns text
language sql immutable set search_path = ''
as $$
  select to_char(make_interval(secs => p_s % 86400), 'HH24:MI:SS')
         || case when p_s >= 86400 then ' (next day)' else '' end;
$$;

-- Take a version for an edit: it exists, the caller may edit it, it has not run. Locks the row (two planners'
-- edits to one version are applied one after the other) and turns a Ready version back into a Draft.
create or replace function public.rs_edit(p_sheet uuid)
returns public.run_sheets
language plpgsql security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  v_used timestamptz;
begin
  select * into v from public.run_sheets where id = p_sheet for update;
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
  update public.run_sheets set status = 'draft', rev = rev + 1, updated_at = now(), updated_by = auth.uid()
  where id = p_sheet;
  return v;
end;
$$;

-- "12:34:56" -> time, with a clear message instead of a cast error.
create or replace function public.rs_time(p_text text, p_what text)
returns time
language plpgsql immutable set search_path = ''
as $$
begin
  if p_text is null or btrim(p_text) = '' then
    return null;
  end if;
  if btrim(p_text) !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
    raise exception '% must be a time like 18:04:30', p_what;
  end if;
  return btrim(p_text)::time;
end;
$$;

-- A whole number from a JSON field, within limits, with a clear message.
create or replace function public.rs_int(p_json jsonb, p_key text, p_default integer, p_min integer, p_max integer, p_what text)
returns integer
language plpgsql immutable set search_path = ''
as $$
declare
  v_text text := p_json ->> p_key;
  v integer;
begin
  if v_text is null or btrim(v_text) = '' then
    return p_default;
  end if;
  if btrim(v_text) !~ '^-?[0-9]{1,9}$' then
    raise exception '% must be a whole number', p_what;
  end if;
  v := btrim(v_text)::integer;
  if v < p_min or v > p_max then
    raise exception '% must be between % and %', p_what, p_min, p_max;
  end if;
  return v;
end;
$$;

-- Next free code like C07 / M03 in a version.
create or replace function public.rs_next_code(p_sheet uuid, p_prefix text)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  n integer;
  v_code text;
begin
  if p_prefix = 'C' then
    select count(*) + 1 into n from public.cues where run_sheet_id = p_sheet;
  else
    select count(*) + 1 into n from public.movements where run_sheet_id = p_sheet and parent_id is null;
  end if;
  loop
    -- C01..C99, then C100: lpad(n, 2) would cut 100 to "10" (taken), looping forever
    v_code := p_prefix || lpad(n::text, greatest(2, length(n::text)), '0');
    exit when not exists (
      select 1 from public.cues where p_prefix = 'C' and run_sheet_id = p_sheet and code = v_code
      union all
      select 1 from public.movements where p_prefix = 'M' and run_sheet_id = p_sheet and parent_id is null and code = v_code
    );
    n := n + 1;
  end loop;
  return v_code;
end;
$$;

-- A code the planner typed: capitals, digits, _ and -.
create or replace function public.rs_code(p_text text)
returns text
language plpgsql immutable set search_path = ''
as $$
declare
  v text := upper(btrim(coalesce(p_text, '')));
begin
  if v = '' then
    return null;
  end if;
  v := regexp_replace(v, '\s+', '_', 'g');
  if v !~ '^[A-Z0-9_-]{1,20}$' then
    raise exception 'A code is 1 to 20 letters, digits, _ or - (for example C07)';
  end if;
  return v;
end;
$$;

-- ============================================================
-- 4. Versions
-- ============================================================
-- Every version of an event, newest date first, with its status in plain words.
create or replace function public.run_sheet_list(p_event uuid)
returns table (id uuid, name text, for_date date, status text, used_on timestamptz, scheduled_at timestamptz,
               live boolean, cue_count integer, movement_count integer, rev integer, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event, array['root', 'planner', 'marshal']) then
    raise exception 'Only the root, planners and marshals can see the run sheet' using errcode = '42501';
  end if;
  return query
    select r.id, r.name, r.for_date,
           case when public.run_sheet_used_on(r.id) is not null then 'used' else r.status end,
           public.run_sheet_used_on(r.id),
           (select min(s.starts_at) from public.event_sessions s
            where s.run_sheet_id = r.id and s.ended_at is null and s.starts_at > now()),
           exists (select 1 from public.event_sessions s
                   where s.run_sheet_id = r.id and s.ended_at is null and s.starts_at <= now()),
           (select count(*)::int from public.cues c where c.run_sheet_id = r.id),
           (select count(*)::int from public.movements m where m.run_sheet_id = r.id and m.parent_id is null),
           r.rev, r.updated_at
    from public.run_sheets r
    where r.event_id = p_event
    order by r.for_date desc nulls last, r.created_at desc;
end;
$$;

-- A new version: blank, or a copy of another version of the same event (its cues, movements and exceptions).
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
                                    fixed_time, fixed_day_offset, early_s, min_ics, dwell_s, amber_s, travel_mode, pace_mps, notes)
      values (v_id, v_move.code, v_move.group_id, v_move.category,
              case when v_move.parent_id is null then null else (v_moves ->> v_move.parent_id::text)::uuid end,
              v_move.skip, v_move.zone_id, v_move.deadline_kind,
              case when v_move.cue_id is null then null else (v_cues ->> v_move.cue_id::text)::uuid end,
              v_move.fixed_time, v_move.fixed_day_offset, v_move.early_s, v_move.min_ics, v_move.dwell_s, v_move.amber_s,
              v_move.travel_mode, v_move.pace_mps, v_move.notes)
      returning id into v_new;
      v_moves := v_moves || jsonb_build_object(v_move.id::text, v_new);
    end loop;
  end if;
  return v_id;
end;
$$;

-- Rename or re-date a version. Allowed for a used version too: it changes the label, not what ran.
create or replace function public.update_run_sheet(p_sheet uuid, p_name text, p_for_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  v_name text := btrim(coalesce(p_name, ''));
begin
  select * into v from public.run_sheets where id = p_sheet for update;
  if not found then
    raise exception 'That run sheet version no longer exists. Reload the page.';
  end if;
  if not public.has_event_role(v.event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can rename a version' using errcode = '42501';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 60 then
    raise exception 'Give the version a name (up to 60 characters)';
  end if;
  if exists (select 1 from public.run_sheets r where r.event_id = v.event_id and r.id <> p_sheet and lower(r.name) = lower(v_name)) then
    raise exception 'There is already a version called "%". Pick another name.', v_name;
  end if;
  update public.run_sheets set name = v_name, for_date = p_for_date, rev = rev + 1, updated_at = now(), updated_by = auth.uid()
  where id = p_sheet;
end;
$$;

-- Delete a version that has never run and is not picked for a scheduled start.
create or replace function public.delete_run_sheet(p_sheet uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  v_used timestamptz;
begin
  select * into v from public.run_sheets where id = p_sheet for update;
  if not found then
    return;
  end if;
  if not public.has_event_role(v.event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can delete a version' using errcode = '42501';
  end if;
  v_used := public.run_sheet_used_on(p_sheet);
  if v_used is not null then
    raise exception '"%" ran on % and is kept as a record. It cannot be deleted.', v.name, public.rs_day(v_used);
  end if;
  if exists (select 1 from public.event_sessions s where s.run_sheet_id = p_sheet and s.ended_at is null) then
    raise exception '"%" is picked for the scheduled start. Change the schedule first.', v.name;
  end if;
  delete from public.run_sheets where id = p_sheet;
end;
$$;

-- ============================================================
-- 5. Cues
-- ============================================================
-- Add (no "id") or change (with "id" and the "rev" the page last saw) one cue. A new cue goes after
-- "after_position" (or at the end). Returns the cue id.
create or replace function public.save_cue(p_sheet uuid, p_cue jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_sheet public.run_sheets;
  v_id uuid := nullif(p_cue ->> 'id', '')::uuid;
  v_old public.cues;
  v_title text := btrim(coalesce(p_cue ->> 'title', ''));
  v_section text := nullif(btrim(coalesce(p_cue ->> 'section', '')), '');
  v_code text := public.rs_code(p_cue ->> 'code');
  v_start time := public.rs_time(p_cue ->> 'start_time', 'Start');
  v_day integer := public.rs_int(p_cue, 'day_offset', 0, 0, 1, 'Next day');
  v_length integer := public.rs_int(p_cue, 'length_s', 0, 0, 86400, 'Length (seconds)');
  v_type text := coalesce(nullif(p_cue ->> 'type', ''), 'normal');
  v_shorten integer := public.rs_int(p_cue, 'can_shorten_s', 0, 0, 86400, 'Can shorten by (seconds)');
  v_mode text := coalesce(nullif(p_cue ->> 'start_mode', ''), 'auto');
  v_after integer := public.rs_int(p_cue, 'after_position', null, 0, 100000, 'Position');
  v_pos integer;
begin
  v_sheet := public.rs_edit(p_sheet);
  if char_length(v_title) < 1 or char_length(v_title) > 120 then
    raise exception 'Give the cue a name (up to 120 characters)';
  end if;
  if v_start is null then
    raise exception 'Give the cue a start time, like 18:04:30';
  end if;
  if v_type not in ('normal', 'flexible', 'anchor') then
    raise exception 'Unknown cue type "%"', v_type;
  end if;
  if v_mode not in ('auto', 'auto_ready', 'manual') then
    raise exception 'Unknown start mode "%"', v_mode;
  end if;
  if v_type = 'anchor' then
    v_mode := 'auto'; -- an anchor always starts on its time
  end if;
  if v_type <> 'flexible' then
    v_shorten := 0;
  elsif v_shorten > v_length then
    raise exception 'A cue cannot shorten by more than its length';
  end if;
  if v_section is not null and char_length(v_section) > 60 then
    raise exception 'A section name is up to 60 characters';
  end if;

  if v_id is not null then
    select * into v_old from public.cues where id = v_id and run_sheet_id = p_sheet for update;
    if not found then
      raise exception 'That cue was deleted by someone else. Reload the page.';
    end if;
    if (p_cue ->> 'rev') is not null and (p_cue ->> 'rev')::integer <> v_old.rev then
      raise exception 'Someone else changed this cue a moment ago. Your screen has been updated: check it and save again.'
        using errcode = 'PT409'; -- HTTP 409. Not 40001: PostgREST retries that code forever
    end if;
    v_code := coalesce(v_code, v_old.code);
    if exists (select 1 from public.cues where run_sheet_id = p_sheet and code = v_code and id <> v_id) then
      raise exception 'Another cue already has the code %', v_code;
    end if;
    update public.cues
    set code = v_code, section = v_section, title = v_title, start_time = v_start, day_offset = v_day, length_s = v_length,
        type = v_type, can_shorten_s = v_shorten, start_mode = v_mode,
        area = nullif(btrim(coalesce(p_cue ->> 'area', '')), ''),
        department = nullif(btrim(coalesce(p_cue ->> 'department', '')), ''),
        notes = nullif(btrim(coalesce(p_cue ->> 'notes', '')), ''),
        rev = rev + 1, updated_at = now()
    where id = v_id;
    return v_id;
  end if;

  if v_code is null then
    v_code := public.rs_next_code(p_sheet, 'C');
  elsif exists (select 1 from public.cues where run_sheet_id = p_sheet and code = v_code) then
    raise exception 'Another cue already has the code %', v_code;
  end if;
  if (select count(*) from public.cues where run_sheet_id = p_sheet) >= 500 then
    raise exception 'A run sheet can have at most 500 cues';
  end if;
  select coalesce(max(position), 0) + 1 into v_pos from public.cues where run_sheet_id = p_sheet;
  if v_after is not null and v_after < v_pos - 1 then
    v_pos := v_after + 1;
    update public.cues set position = position + 1 where run_sheet_id = p_sheet and position >= v_pos;
  end if;
  insert into public.cues (run_sheet_id, position, code, section, title, start_time, day_offset, length_s, type,
                           can_shorten_s, start_mode, area, department, notes)
  values (p_sheet, v_pos, v_code, v_section, v_title, v_start, v_day, v_length, v_type, v_shorten, v_mode,
          nullif(btrim(coalesce(p_cue ->> 'area', '')), ''), nullif(btrim(coalesce(p_cue ->> 'department', '')), ''),
          nullif(btrim(coalesce(p_cue ->> 'notes', '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_cue(p_cue uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_sheet uuid;
begin
  select run_sheet_id into v_sheet from public.cues where id = p_cue;
  if v_sheet is null then
    return; -- already gone
  end if;
  perform public.rs_edit(v_sheet);
  delete from public.cues where id = p_cue;
  -- Close the gap so positions stay 1..n
  update public.cues c set position = n.rn
  from (select id, row_number() over (order by position) rn from public.cues where run_sheet_id = v_sheet) n
  where c.id = n.id and c.position <> n.rn;
end;
$$;

-- Move a cue one row up (-1) or down (+1).
create or replace function public.move_cue(p_cue uuid, p_direction integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.cues;
  v_other public.cues;
begin
  select * into v from public.cues where id = p_cue;
  if not found then
    raise exception 'That cue was deleted by someone else. Reload the page.';
  end if;
  perform public.rs_edit(v.run_sheet_id);
  select * into v_other from public.cues
  where run_sheet_id = v.run_sheet_id
    and (case when p_direction < 0 then position < v.position else position > v.position end)
  order by case when p_direction < 0 then -position else position end
  limit 1;
  if not found then
    return; -- already first / last
  end if;
  update public.cues set position = v_other.position, rev = rev + 1, updated_at = now() where id = v.id;
  update public.cues set position = v.position, rev = rev + 1, updated_at = now() where id = v_other.id;
end;
$$;

-- ============================================================
-- 6. Movements
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
        notes = nullif(btrim(coalesce(p_move ->> 'notes', '')), ''), rev = rev + 1, updated_at = now()
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
                                fixed_time, fixed_day_offset, early_s, min_ics, dwell_s, amber_s, travel_mode, pace_mps, notes)
  values (p_sheet, v_code, v_group, v_category, v_parent_id, v_skip, v_zone, v_kind, v_cue, v_fixed, v_fixed_day, v_early,
          v_min, v_dwell, v_amber, v_mode, v_pace, nullif(btrim(coalesce(p_move ->> 'notes', '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_movement(p_move uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_sheet uuid;
begin
  select run_sheet_id into v_sheet from public.movements where id = p_move;
  if v_sheet is null then
    return;
  end if;
  perform public.rs_edit(v_sheet);
  delete from public.movements where id = p_move; -- its exceptions go with it
end;
$$;

-- Every group's movement once a category movement is expanded: one row per (movement, group), with the
-- group's exception applied (skipped groups left out). The engine (Stage 7) and the check read this.
create or replace function public.run_sheet_moves(p_sheet uuid)
returns table (movement_id uuid, code text, group_id uuid, via_category text, is_exception boolean, zone_id uuid,
               deadline_kind text, cue_id uuid, fixed_time time, fixed_day_offset integer, early_s integer,
               min_ics integer, dwell_s integer, amber_s integer, travel_mode text, pace_mps numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.run_sheets r where r.id = p_sheet
                 and public.has_event_role(r.event_id, array['root', 'planner', 'marshal'])) then
    raise exception 'Only the root, planners and marshals can see the run sheet' using errcode = '42501';
  end if;
  return query
  -- one group
  select m.id, m.code, m.group_id, null::text, false, m.zone_id, m.deadline_kind, m.cue_id, m.fixed_time, m.fixed_day_offset,
         m.early_s, m.min_ics, m.dwell_s, m.amber_s, m.travel_mode, m.pace_mps
  from public.movements m
  where m.run_sheet_id = p_sheet and m.parent_id is null and m.group_id is not null
  union all
  -- every group of a category, unless it has an exception
  select m.id, m.code, g.id, m.category, false, m.zone_id, m.deadline_kind, m.cue_id, m.fixed_time, m.fixed_day_offset,
         m.early_s, m.min_ics, m.dwell_s, m.amber_s, m.travel_mode, m.pace_mps
  from public.movements m
  join public.run_sheets r on r.id = m.run_sheet_id
  join public.groups g on g.event_id = r.event_id and lower(g.category) = lower(m.category)
  where m.run_sheet_id = p_sheet and m.parent_id is null and m.category is not null
    and not exists (select 1 from public.movements x where x.parent_id = m.id and x.group_id = g.id)
  union all
  -- the exceptions that are not "skip"
  select x.id, x.code, x.group_id, p.category, true, x.zone_id, x.deadline_kind, x.cue_id, x.fixed_time, x.fixed_day_offset,
         x.early_s, x.min_ics, x.dwell_s, x.amber_s, x.travel_mode, x.pace_mps
  from public.movements x
  join public.movements p on p.id = x.parent_id
  where x.run_sheet_id = p_sheet and x.parent_id is not null and not x.skip;
end;
$$;

-- ============================================================
-- 7. Check, ready, live
-- ============================================================
-- Everything wrong with a version: errors block "Ready", warnings do not.
create or replace function public.check_run_sheet(p_sheet uuid)
returns table (severity text, item_type text, item_id uuid, message text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  c record;
  prev record;
  v_first boolean := true;
  m record;
  v_count integer;
  v_ics integer;
begin
  select * into v from public.run_sheets where id = p_sheet;
  if not found then
    raise exception 'That run sheet version no longer exists. Reload the page.';
  end if;
  if not public.has_event_role(v.event_id, array['root', 'planner', 'marshal']) then
    raise exception 'Only the root, planners and marshals can see the run sheet' using errcode = '42501';
  end if;

  if not exists (select 1 from public.cues where run_sheet_id = p_sheet) then
    return query select 'error', 'sheet', p_sheet, 'Add at least one cue.';
  end if;

  -- Cues, in running order
  for c in
    select x.*, x.day_offset * 86400 + extract(epoch from x.start_time)::int as start_s,
           x.day_offset * 86400 + extract(epoch from x.start_time)::int + x.length_s as end_s
    from public.cues x where x.run_sheet_id = p_sheet order by x.position
  loop
    if not v_first then
      if c.start_s < prev.start_s then
        return query select 'warning', 'cue', c.id,
          format('Starts at %s, before "%s" above it (%s). Check the order.', public.rs_clock(c.start_s), prev.title, public.rs_clock(prev.start_s))
          || case when c.day_offset = 0 and c.start_time < '06:00' and prev.start_time >= '12:00'
                  then ' If it is after midnight, tick "+1 day".' else '' end;
      elsif c.start_s < prev.end_s then
        if c.type = 'anchor' then
          return query select 'error', 'cue', c.id,
            format('This anchor starts at %s but "%s" only ends at %s. Shorten or move "%s".', public.rs_clock(c.start_s),
                   prev.title, public.rs_clock(prev.end_s), prev.title);
        else
          return query select 'warning', 'cue', c.id,
            format('Starts at %s, before "%s" ends (%s).', public.rs_clock(c.start_s), prev.title, public.rs_clock(prev.end_s));
        end if;
      end if;
    end if;
    if c.length_s = 0 and c.type <> 'anchor' then
      return query select 'warning', 'cue', c.id, 'Has no length (0:00).';
    end if;
    prev := c;
    v_first := false;
  end loop;

  -- Movements (before expansion: what the planner typed)
  for m in select * from public.movements where run_sheet_id = p_sheet order by (parent_id is not null), code loop
    if m.parent_id is null and m.category is not null then
      select count(*) into v_count from public.groups g where g.event_id = v.event_id and lower(g.category) = lower(m.category);
      if v_count = 0 then
        return query select 'error', 'movement', m.id, format('%s: no group has the category "%s".', m.code, m.category);
      end if;
    end if;
    if m.skip then
      continue;
    end if;
    if m.zone_id is null then
      return query select 'error', 'movement', m.id, format('%s: pick the zone they must reach.', m.code);
    elsif exists (select 1 from public.zones z where z.id = m.zone_id and z.kind = 'no_go') then
      return query select 'error', 'movement', m.id, format('%s: its zone has become a No-Go zone.', m.code);
    end if;
    if m.deadline_kind in ('cue_start', 'cue_end') and m.cue_id is null then
      return query select 'error', 'movement', m.id, format('%s: pick the cue it is timed to (the cue may have been deleted).', m.code);
    end if;
    if m.deadline_kind = 'fixed' and m.fixed_time is null then
      return query select 'error', 'movement', m.id, format('%s: give the fixed time.', m.code);
    end if;
    if m.travel_mode = 'on_foot' and (m.pace_mps < 0.3 or m.pace_mps > 3) then
      return query select 'error', 'movement', m.id, format('%s: a walking pace of %s m/s is not realistic (0.3 to 3).', m.code, m.pace_mps);
    elsif m.travel_mode = 'vehicle' and m.pace_mps > 40 then
      return query select 'error', 'movement', m.id, format('%s: %s m/s is too fast for a vehicle (at most 40).', m.code, m.pace_mps);
    end if;
  end loop;

  -- Per group, after expansion: can its arrival be tracked at all?
  for m in select e.*, g.name as group_name from public.run_sheet_moves(p_sheet) e join public.groups g on g.id = e.group_id loop
    select count(*) into v_ics from public.group_members gm where gm.group_id = m.group_id and gm.is_ic;
    if v_ics = 0 then
      return query select 'warning', 'movement', m.movement_id, format('%s: %s has no IC, so its arrival cannot be tracked.', m.code, m.group_name);
    elsif m.min_ics is not null and m.min_ics > v_ics then
      return query select 'warning', 'movement', m.movement_id,
        format('%s: needs %s ICs inside but %s has only %s.', m.code, m.min_ics, m.group_name, v_ics);
    end if;
  end loop;

  -- One group sent to two different zones by the same deadline
  for m in
    select a.group_id, g.name as group_name, a.code as a_code, b.code as b_code, a.movement_id
    from public.run_sheet_moves(p_sheet) a
    join public.run_sheet_moves(p_sheet) b
      on a.group_id = b.group_id and a.movement_id < b.movement_id and a.deadline_kind = b.deadline_kind
     and a.cue_id is not distinct from b.cue_id and a.fixed_time is not distinct from b.fixed_time
     and a.zone_id is distinct from b.zone_id
    join public.groups g on g.id = a.group_id
  loop
    return query select 'warning', 'movement', m.movement_id,
      format('%s and %s send %s to two different zones by the same time.', m.a_code, m.b_code, m.group_name);
  end loop;
end;
$$;

-- Check, and mark Ready when there are no errors.
create or replace function public.mark_run_sheet_ready(p_sheet uuid)
returns integer -- number of warnings
language plpgsql security definer set search_path = ''
as $$
declare
  v public.run_sheets;
  v_errors integer;
  v_warnings integer;
  v_used timestamptz;
begin
  select * into v from public.run_sheets where id = p_sheet for update;
  if not found then
    raise exception 'That run sheet version no longer exists. Reload the page.';
  end if;
  if not public.has_event_role(v.event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can mark a version ready' using errcode = '42501';
  end if;
  v_used := public.run_sheet_used_on(p_sheet);
  if v_used is not null then
    raise exception '"%" already ran on %. It stays as it was.', v.name, public.rs_day(v_used);
  end if;
  select count(*) filter (where severity = 'error'), count(*) filter (where severity = 'warning')
  into v_errors, v_warnings from public.check_run_sheet(p_sheet);
  if v_errors > 0 then
    raise exception 'Fix % problem% first (shown in red).', v_errors, case when v_errors = 1 then '' else 's' end;
  end if;
  update public.run_sheets set status = 'ready', rev = rev + 1, updated_at = now(), updated_by = auth.uid() where id = p_sheet;
  return v_warnings;
end;
$$;

-- The version a session may run: in this event and Ready or Used.
create or replace function public.rs_runnable(p_event uuid, p_sheet uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
declare
  v public.run_sheets;
begin
  if p_sheet is null then
    return;
  end if;
  select * into v from public.run_sheets where id = p_sheet;
  if not found or v.event_id <> p_event then
    raise exception 'That run sheet version is not in this event';
  end if;
  if v.status <> 'ready' and public.run_sheet_used_on(p_sheet) is null then
    raise exception '"%" is still a draft. Check it and mark it ready first.', v.name;
  end if;
end;
$$;

-- During a live show: run the rest of it with another version (the page asks first).
create or replace function public.switch_live_run_sheet(p_event uuid, p_sheet uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the live run sheet' using errcode = '42501';
  end if;
  perform public.rs_runnable(p_event, p_sheet);
  select id into v_session from public.event_sessions
  where event_id = p_event and ended_at is null and starts_at <= now() for update;
  if v_session is null then
    raise exception 'The event is not live';
  end if;
  update public.event_sessions set run_sheet_id = p_sheet where id = v_session;
end;
$$;

-- ============================================================
-- 8. Start / schedule pick the version (null = no run sheet, tracking only)
-- ============================================================
drop function public.start_event(uuid);
create function public.start_event(p_event_id uuid, p_run_sheet uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  open_session public.event_sessions;
  new_id uuid;
begin
  perform public.end_scheduled_sessions(); -- close events whose end time has passed
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can start the event' using errcode = '42501';
  end if;
  perform public.rs_runnable(p_event_id, p_run_sheet);

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live';
    end if;
    update public.event_sessions set starts_at = now(), started_by = auth.uid(), run_sheet_id = p_run_sheet
    where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, run_sheet_id)
  values (p_event_id, now(), auth.uid(), p_run_sheet)
  returning id into new_id;
  return new_id;
end;
$$;

drop function public.schedule_event_start(uuid, timestamptz);
create function public.schedule_event_start(p_event_id uuid, p_starts_at timestamptz, p_run_sheet uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  open_session public.event_sessions;
  new_id uuid;
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
  perform public.rs_runnable(p_event_id, p_run_sheet);

  select * into open_session from public.event_sessions
  where event_id = p_event_id and ended_at is null for update;

  if found then
    if open_session.starts_at <= now() then
      raise exception 'The event is already live. End it first.';
    end if;
    update public.event_sessions
    set starts_at = p_starts_at, started_by = auth.uid(), run_sheet_id = p_run_sheet,
        scheduled_end = case when scheduled_end > p_starts_at then scheduled_end end
    where id = open_session.id;
    return open_session.id;
  end if;

  insert into public.event_sessions (event_id, starts_at, started_by, run_sheet_id)
  values (p_event_id, p_starts_at, auth.uid(), p_run_sheet)
  returning id into new_id;
  return new_id;
end;
$$;

-- ============================================================
-- 9. Groups: code, category, sector, headcount (Members tab)
-- ============================================================
create or replace function public.update_group_details(p_group uuid, p_code text, p_category text, p_sector text, p_headcount integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_category text := nullif(btrim(coalesce(p_category, '')), '');
  v_sector text := nullif(btrim(coalesce(p_sector, '')), '');
begin
  select event_id into v_event from public.groups where id = p_group;
  if v_event is null then
    raise exception 'That group no longer exists';
  end if;
  if not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change group details' using errcode = '42501';
  end if;
  v_code := nullif(regexp_replace(v_code, '\s+', '_', 'g'), '');
  if v_code is not null and v_code !~ '^[A-Z0-9_]{1,40}$' then
    raise exception 'A group code is 1 to 40 capital letters, digits or _ (for example BAND_1)';
  end if;
  if v_code is not null and exists (select 1 from public.groups g where g.event_id = v_event and g.code = v_code and g.id <> p_group) then
    raise exception 'Another group already has the code %', v_code;
  end if;
  if v_category is not null and char_length(v_category) > 50 then
    raise exception 'A category is up to 50 characters';
  end if;
  if v_sector is not null and char_length(v_sector) > 50 then
    raise exception 'A sector is up to 50 characters';
  end if;
  if p_headcount is not null and (p_headcount < 0 or p_headcount > 100000) then
    raise exception 'Headcount must be between 0 and 100000';
  end if;
  update public.groups set code = v_code, category = v_category, sector = v_sector, headcount = p_headcount where id = p_group;
end;
$$;

-- ============================================================
-- 10. Permissions: internal by default, the page's doors opened one by one
-- ============================================================
revoke execute on function public.run_sheet_used_on(uuid) from public, anon, authenticated;
revoke execute on function public.rs_day(timestamptz) from public, anon, authenticated;
revoke execute on function public.rs_clock(integer) from public, anon, authenticated;
revoke execute on function public.rs_edit(uuid) from public, anon, authenticated;
revoke execute on function public.rs_time(text, text) from public, anon, authenticated;
revoke execute on function public.rs_int(jsonb, text, integer, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.rs_next_code(uuid, text) from public, anon, authenticated;
revoke execute on function public.rs_code(text) from public, anon, authenticated;
revoke execute on function public.rs_runnable(uuid, uuid) from public, anon, authenticated;

revoke execute on function public.run_sheet_list(uuid) from public, anon;
revoke execute on function public.create_run_sheet(uuid, text, date, uuid) from public, anon;
revoke execute on function public.update_run_sheet(uuid, text, date) from public, anon;
revoke execute on function public.delete_run_sheet(uuid) from public, anon;
revoke execute on function public.save_cue(uuid, jsonb) from public, anon;
revoke execute on function public.delete_cue(uuid) from public, anon;
revoke execute on function public.move_cue(uuid, integer) from public, anon;
revoke execute on function public.save_movement(uuid, jsonb) from public, anon;
revoke execute on function public.delete_movement(uuid) from public, anon;
revoke execute on function public.run_sheet_moves(uuid) from public, anon;
revoke execute on function public.check_run_sheet(uuid) from public, anon;
revoke execute on function public.mark_run_sheet_ready(uuid) from public, anon;
revoke execute on function public.switch_live_run_sheet(uuid, uuid) from public, anon;
revoke execute on function public.start_event(uuid, uuid) from public, anon;
revoke execute on function public.schedule_event_start(uuid, timestamptz, uuid) from public, anon;
revoke execute on function public.update_group_details(uuid, text, text, text, integer) from public, anon;

grant execute on function public.run_sheet_list(uuid) to authenticated;
grant execute on function public.create_run_sheet(uuid, text, date, uuid) to authenticated;
grant execute on function public.update_run_sheet(uuid, text, date) to authenticated;
grant execute on function public.delete_run_sheet(uuid) to authenticated;
grant execute on function public.save_cue(uuid, jsonb) to authenticated;
grant execute on function public.delete_cue(uuid) to authenticated;
grant execute on function public.move_cue(uuid, integer) to authenticated;
grant execute on function public.save_movement(uuid, jsonb) to authenticated;
grant execute on function public.delete_movement(uuid) to authenticated;
grant execute on function public.run_sheet_moves(uuid) to authenticated;
grant execute on function public.check_run_sheet(uuid) to authenticated;
grant execute on function public.mark_run_sheet_ready(uuid) to authenticated;
grant execute on function public.switch_live_run_sheet(uuid, uuid) to authenticated;
grant execute on function public.start_event(uuid, uuid) to authenticated;
grant execute on function public.schedule_event_start(uuid, timestamptz, uuid) to authenticated;
grant execute on function public.update_group_details(uuid, text, text, text, integer) to authenticated;

-- ============================================================
-- 11. Live switches are kept (a version that ran stays Used after the show switches away from it)
-- ============================================================
-- Switching the live show to another version used to overwrite event_sessions.run_sheet_id, so the version
-- that had been running lost its only link to the session: it went back to Draft / Ready, editable and
-- deletable, and Playback could not say it ran. Each switch is now recorded: which version ran until when.
create table public.run_sheet_switches (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.event_sessions (id) on delete cascade,
  from_sheet uuid references public.run_sheets (id) on delete cascade, -- what ran until now (null = no run sheet)
  to_sheet uuid references public.run_sheets (id) on delete cascade,
  switched_at timestamptz not null default now(),
  switched_by uuid references auth.users (id) on delete set null
);
create index run_sheet_switches_session on public.run_sheet_switches (session_id, switched_at);
create index run_sheet_switches_from on public.run_sheet_switches (from_sheet);
create index run_sheet_switches_to on public.run_sheet_switches (to_sheet);

alter table public.run_sheet_switches enable row level security;
create policy "run sheet switches: root, planners, marshals read" on public.run_sheet_switches
  for select to authenticated
  using (exists (select 1 from public.event_sessions s where s.id = session_id
                 and public.has_event_role(s.event_id, array['root', 'planner', 'marshal'])));

-- Used = a session that has started runs it now, or ran it before a switch
create or replace function public.run_sheet_used_on(p_sheet uuid)
returns timestamptz
language sql stable security definer set search_path = ''
as $$
  select least(
    (select min(s.starts_at) from public.event_sessions s where s.run_sheet_id = p_sheet and s.starts_at <= now()),
    (select min(s.starts_at) from public.run_sheet_switches w join public.event_sessions s on s.id = w.session_id
     where w.from_sheet = p_sheet)
  );
$$;

create or replace function public.switch_live_run_sheet(p_event uuid, p_sheet uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session public.event_sessions;
begin
  if not public.has_event_role(p_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can change the live run sheet' using errcode = '42501';
  end if;
  perform public.rs_runnable(p_event, p_sheet);
  select * into v_session from public.event_sessions
  where event_id = p_event and ended_at is null and starts_at <= now() for update;
  if not found then
    raise exception 'The event is not live';
  end if;
  if v_session.run_sheet_id is not distinct from p_sheet then
    raise exception 'The live show is already running that version';
  end if;
  insert into public.run_sheet_switches (session_id, from_sheet, to_sheet, switched_by)
  values (v_session.id, v_session.run_sheet_id, p_sheet, auth.uid());
  update public.event_sessions set run_sheet_id = p_sheet where id = v_session.id;
end;
$$;

-- What each session ran, in order (Playback: "Ran with: Rehearsal 2, then Rehearsal 2b from 8:14 pm")
create or replace function public.session_run_sheets(p_event uuid)
returns table (session_id uuid, run_sheet_id uuid, name text, from_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event, array['root', 'planner', 'marshal']) then
    raise exception 'Only the root, planners and marshals can see the run sheet' using errcode = '42501';
  end if;
  return query
    with steps as (
      -- the first version of each session: before its first switch, else the current one
      select s.id as sid, coalesce(
               (select w.from_sheet from public.run_sheet_switches w where w.session_id = s.id order by w.switched_at limit 1),
               case when exists (select 1 from public.run_sheet_switches w where w.session_id = s.id) then null else s.run_sheet_id end
             ) as rid, s.starts_at as at, 0 as ord
      from public.event_sessions s where s.event_id = p_event
      union all
      select w.session_id, w.to_sheet, w.switched_at, 1
      from public.run_sheet_switches w join public.event_sessions s on s.id = w.session_id
      where s.event_id = p_event
    )
    select st.sid, st.rid, r.name, st.at
    from steps st left join public.run_sheets r on r.id = st.rid
    order by st.sid, st.at, st.ord;
end;
$$;

revoke execute on function public.run_sheet_used_on(uuid) from public, anon, authenticated;
revoke execute on function public.switch_live_run_sheet(uuid, uuid) from public, anon;
revoke execute on function public.session_run_sheets(uuid) from public, anon;
grant execute on function public.switch_live_run_sheet(uuid, uuid) to authenticated;
grant execute on function public.session_run_sheets(uuid) to authenticated;
