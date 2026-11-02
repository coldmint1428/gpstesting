-- ============================================================
-- Tests for 077_no_marshals.sql: the marshal role is gone.
--
-- Locally: `node tools/pgtest.mjs roles-077`, which applies no_marshals_seed.sql before 077 and then runs this.
-- In the Supabase SQL Editor after 077 it runs too, without the seed: checks 1-2 then skip the seeded event.
-- One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

-- event_sessions comes from 007 (pg_cron, not available locally); my_event_membership only reads it
create table if not exists public.event_sessions (event_id uuid, starts_at timestamptz, ended_at timestamptz);

create function pg_temp.zz_refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end $$;

create function pg_temp.zz_as(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', '{"sub":"' || p_user || '","role":"authenticated"}', true);
$$;

-- "people / group rows / groups / locations"
create function pg_temp.zz_sees(p_user text) returns text language plpgsql as $$
begin
  perform pg_temp.zz_as(p_user);
  return (select count(distinct user_id) from public.event_roles where event_id = '77000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.group_members where event_id = '77000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.groups where event_id = '77000000-0000-0000-0000-0000000000e1') || '/' ||
         (select count(*) from public.locations where event_id = '77000000-0000-0000-0000-0000000000e1');
end $$;

-- 1. The schema: no marshal role, no marshal location source, no marshal calls, no sector column on event_roles
do $$
begin
  if pg_temp.zz_refused($q$insert into public.event_roles (event_id, user_id, role)
                           select id, created_by, 'marshal' from public.events limit 1$q$) not like '%event_roles_role_check%'
     and exists (select 1 from public.events) then
    raise exception 'FAIL 1: the marshal role is still allowed';
  end if;
  if to_regprocedure('public.set_marshal(uuid, uuid, boolean)') is not null
     or to_regprocedure('public.set_marshal_sector(uuid, uuid, text)') is not null then
    raise exception 'FAIL 1: a marshal call is still there';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'event_roles' and column_name = 'sector') then
    raise exception 'FAIL 1: event_roles.sector is still there';
  end if;
  if pg_get_constraintdef((select oid from pg_constraint where conname = 'locations_source_check')) ilike '%marshal%' then
    raise exception 'FAIL 1: locations still allow a marshal source';
  end if;
end $$;

-- 2. Nothing can make a marshal: the event wizard and set_event_role refuse the role
do $$
declare
  v_root uuid := (select created_by from public.events where id = '77000000-0000-0000-0000-0000000000e1');
  v_other uuid := '77000000-0000-0000-0000-000000000007'; -- no group: a planner may not be in one (036)
  e text;
begin
  if v_root is null then return; end if; -- the seed is not here (SQL Editor)
  perform pg_temp.zz_as(v_root::text);
  e := pg_temp.zz_refused(format(
    $q$select public.create_event_with_setup('{"name":"Wizard","starts_at":"2026-11-01T01:00:00Z","ends_at":"2026-11-01T05:00:00Z"}'::jsonb, '[{"user_id":"%s","role":"marshal"}]'::jsonb, '[]'::jsonb)$q$,
    v_other));
  if e not like 'Unknown role%' then raise exception 'FAIL 2: the wizard took a marshal (%)', e; end if;
  e := pg_temp.zz_refused(format($q$select public.set_event_role('77000000-0000-0000-0000-0000000000e1', %L, 'marshal', true)$q$, v_other));
  if e <> 'Role must be planner' then raise exception 'FAIL 2: set_event_role took a marshal (%)', e; end if;
  perform public.set_event_role('77000000-0000-0000-0000-0000000000e1', v_other, 'planner', true);
  if not exists (select 1 from public.event_roles
                 where event_id = '77000000-0000-0000-0000-0000000000e1' and user_id = v_other and role = 'planner') then
    raise exception 'FAIL 2: the root could not make a planner';
  end if;
  perform public.set_event_role('77000000-0000-0000-0000-0000000000e1', v_other, 'planner', false);
end $$;

set local role authenticated;

do $$
declare
  t text;
  j jsonb;
  v_id bigint;
begin
  if not exists (select 1 from public.events where id = '77000000-0000-0000-0000-0000000000e1') then
    raise notice 'no_marshals_test: no seed, checks 3-6 skipped';
    return;
  end if;

  -- 3. Each former marshal is a plain member of the event, and still in it
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000004');
  j := public.my_event_membership('77000000-0000-0000-0000-0000000000e1');
  if j ->> 'role' <> 'member' or not (j ->> 'is_ic')::boolean or j ? 'is_marshal' then
    raise exception 'FAIL 3: the IC who was a marshal has membership %', j;
  end if;
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000007');
  j := public.my_event_membership('77000000-0000-0000-0000-0000000000e1');
  if j is null or j ->> 'role' <> 'member' then
    raise exception 'FAIL 3: the person with only a marshal row has membership %', j;
  end if;

  -- 4. They see what the people beside them see; the root, planners and group admins as before (073)
  t := pg_temp.zz_sees('77000000-0000-0000-0000-000000000004');
  if t <> '3/3/1/1' or t <> pg_temp.zz_sees('77000000-0000-0000-0000-000000000005') then
    raise exception 'FAIL 4: a former marshal in a group sees %', t;
  end if;
  t := pg_temp.zz_sees('77000000-0000-0000-0000-000000000007');
  if t <> '1/0/0/0' then raise exception 'FAIL 4: a former marshal without a group sees %', t; end if;
  t := pg_temp.zz_sees('77000000-0000-0000-0000-000000000001');
  if t <> '7/4/2/2' then raise exception 'FAIL 4: the root sees %', t; end if;
  t := pg_temp.zz_sees('77000000-0000-0000-0000-000000000002');
  if t <> '7/4/2/2' then raise exception 'FAIL 4: a planner sees %', t; end if;
  t := pg_temp.zz_sees('77000000-0000-0000-0000-000000000003');
  if t <> '7/4/2/1' then raise exception 'FAIL 4: a group admin sees %', t; end if;

  -- 5. The role check: yes to the root and planners, no to anyone else
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000002');
  if not public.has_event_role('77000000-0000-0000-0000-0000000000e1', array['root', 'planner']) then
    raise exception 'FAIL 5: a planner fails the role check';
  end if;
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000007');
  if public.has_event_role('77000000-0000-0000-0000-0000000000e1', array['root', 'planner']) then
    raise exception 'FAIL 5: a member passes the role check';
  end if;

  -- 6. An SOS in group H: a former marshal elsewhere cannot end it; a planner can
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000006');
  v_id := public.raise_sos('77000000-0000-0000-0000-0000000000e1', 1.3, 103.8, 10, null);
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000007');
  if pg_temp.zz_refused(format('select public.resolve_sos(%s)', v_id)) not like 'Only the person who sent it%' then
    raise exception 'FAIL 6: a former marshal ended an SOS in another group';
  end if;
  perform pg_temp.zz_as('77000000-0000-0000-0000-000000000002');
  perform public.resolve_sos(v_id);
  if (select resolution from public.sos_alerts where id = v_id) is distinct from 'handled' then
    raise exception 'FAIL 6: a planner could not end the SOS';
  end if;

  raise notice 'no_marshals_test: all checks passed';
end $$;

reset role;

-- 7. The manual-mark location kept its place, as a GPS fix
do $$
begin
  if exists (select 1 from public.events where id = '77000000-0000-0000-0000-0000000000e1')
     and (select string_agg(source, ',' order by source) from public.locations
          where event_id = '77000000-0000-0000-0000-0000000000e1') <> 'gps,gps' then
    raise exception 'FAIL 7: locations are %',
      (select string_agg(source, ',' order by source) from public.locations where event_id = '77000000-0000-0000-0000-0000000000e1');
  end if;
end $$;

rollback;
