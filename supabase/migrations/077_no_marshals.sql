-- 077_no_marshals.sql -- the marshal role is gone: every person is the root, a planner, a group admin or a member.
-- Run AFTER 076_session_marks.sql (Supabase -> SQL Editor). Can be re-run.
--
-- 074 already made 'marshal' open nothing (has_event_role ignored it) apart from ending an SOS. This removes the rest:
-- the rows, the check constraints, the two calls that set a marshal and a marshal's sector, the sector column, and
-- every 'marshal' left in a function or a policy.
--
-- Most of those are a role list -- has_event_role(x, array['root', 'planner', 'marshal']) -- in some twenty functions
-- and policies written over 002-076. Section 5 rewrites each one from its definition as the database holds it now, with
-- only 'marshal' taken out, so nothing else about them can change. Section 6 refuses the whole migration if any
-- function, policy, constraint, view or comment still says 'marshal'.

-- ============================================================
-- 1. The rows: a marshal stays in the event as a participant
-- ============================================================
-- Every marshal row came with a participant row (030, 033); this covers any that did not.
insert into public.event_roles (event_id, user_id, role)
select event_id, user_id, 'participant' from public.event_roles where role = 'marshal'
on conflict do nothing;
delete from public.event_roles where role = 'marshal';

-- 003 kept 'marshal' as a location source for manual marks that were never built
update public.locations set source = 'gps' where source = 'marshal';

-- ============================================================
-- 2. The constraints
-- ============================================================
alter table public.event_roles drop constraint if exists event_roles_role_check;
alter table public.event_roles add constraint event_roles_role_check check (role in ('root', 'planner', 'participant'));

alter table public.locations drop constraint if exists locations_source_check;
alter table public.locations add constraint locations_source_check check (source in ('gps', 'stop'));

-- ============================================================
-- 3. The marshal calls and the marshal's sector (033, 027). A group's sector (024) stays.
-- ============================================================
drop function if exists public.set_marshal(uuid, uuid, boolean);
drop function if exists public.set_marshal_sector(uuid, uuid, text);

-- ============================================================
-- 4. The functions whose logic changes
-- ============================================================
-- has_event_role: the plain check again (074 stripped 'marshal' out of every list it was given)
create or replace function public.has_event_role(p_event_id uuid, p_roles text[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.event_roles
    where event_id = p_event_id and user_id = auth.uid() and role = any (p_roles)
  );
$$;

-- resolve_sos (074 without the marshal): the person who sent it, the root, a planner, or their group's IC or admin
create or replace function public.resolve_sos(p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sos_alerts;
  v_me uuid := auth.uid();
begin
  select * into s from public.sos_alerts where id = p_id;
  if s.id is null or not public.is_event_member(s.event_id) then
    raise exception 'This SOS no longer exists';
  end if;
  if s.resolved_at is not null then
    return; -- someone else ended it first
  end if;
  if s.user_id <> v_me
     and not public.has_event_role(s.event_id, array['root', 'planner'])
     and not (s.group_id is not null and exists (
       select 1 from public.group_members
       where group_id = s.group_id and user_id = v_me and (is_ic or is_admin)
     )) then
    raise exception 'Only the person who sent it, a planner, or their group''s IC or admin can end an SOS'
      using errcode = '42501';
  end if;
  update public.sos_alerts
  set resolved_at = now(), resolved_by = v_me, resolution = case when s.user_id = v_me then 'safe' else 'handled' end
  where id = p_id;
end;
$$;

-- set_event_role (002): the only event-level role left to give is planner. Root only.
create or replace function public.set_event_role(p_event_id uuid, p_user_id uuid, p_role text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root']) then
    raise exception 'Only the root can change planners';
  end if;
  if p_role is distinct from 'planner' then
    raise exception 'Role must be planner';
  end if;

  if p_enabled then
    insert into public.event_roles (event_id, user_id, role) values (p_event_id, p_user_id, p_role)
    on conflict do nothing;
  else
    delete from public.event_roles where event_id = p_event_id and user_id = p_user_id and role = p_role;
  end if;
end;
$$;

-- my_event_membership (033) without 'is_marshal'
create or replace function public.my_event_membership(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_role text := public.member_top_role(p_event_id, auth.uid());
  v_gm record;
  v_live boolean;
begin
  if auth.uid() is null or v_role is null then
    return null;
  end if;
  select group_id, is_admin, is_ic into v_gm
  from public.group_members where event_id = p_event_id and user_id = auth.uid();
  select exists (
    select 1 from public.event_sessions where event_id = p_event_id and starts_at <= now() and ended_at is null
  ) into v_live;
  return jsonb_build_object(
    'role', v_role,
    'group_id', v_gm.group_id,
    'is_admin', coalesce(v_gm.is_admin, false),
    'is_ic', coalesce(v_gm.is_ic, false),
    'is_simulation', (select coalesce((to_jsonb(e) ->> 'is_simulation')::boolean, false) from public.events e where e.id = p_event_id),
    'live', v_live
  );
end;
$$;

-- ============================================================
-- 5. Every other function and policy: the same definition, without 'marshal'
-- ============================================================
do $rewrite$
declare
  v_fn record;
  v_pol record;
  v_com record;
  v_def text;
  v_new text;
  v_using text;
  v_check text;
begin
  -- Functions, from pg_get_functiondef: the body is the stored source text, so only these edits differ
  for v_fn in
    select p.oid, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%marshal%'
  loop
    v_def := v_fn.def;
    v_new := v_def;
    -- role lists: array['root', 'planner', 'marshal'] and in ('root', 'planner', 'marshal')
    v_new := replace(v_new, $s$, 'marshal']$s$, $s$]$s$);
    v_new := replace(v_new, $s$, 'marshal')$s$, $s$)$s$);
    -- broadcast_audience (032): the marshals of a sector (the sector's groups stay)
    v_new := regexp_replace(v_new,
      $r$\s*union all\s*select er\.user_id from public\.event_roles er\s*where [^\n]*er\.role = 'marshal'[^\n]*$r$, '');
    -- set_member_role (036): becoming a planner no longer has a marshal row to end
    v_new := regexp_replace(v_new,
      $r$\n[ \t]*delete from public\.event_roles where event_id = p_event_id and user_id = p_user_id and role = 'marshal';\r?$r$, '');
    -- what the messages say
    v_new := replace(v_new, $s$'the planners and marshals'$s$, $s$'the planners'$s$);
    v_new := replace(v_new, $s$Only the root, a planner or a marshal can$s$, $s$Only the root or a planner can$s$);
    v_new := replace(v_new, $s$root, planners and marshals can$s$, $s$root and planners can$s$);
    if v_new <> v_def then
      execute v_new;
    end if;
  end loop;

  -- Policies, from pg_policies: ARRAY['root'::text, 'planner'::text, 'marshal'::text]
  for v_pol in
    select tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public' and (coalesce(qual, '') || coalesce(with_check, '')) ilike '%marshal%'
  loop
    v_using := regexp_replace(v_pol.qual, $r$, 'marshal'::text$r$, '', 'g');
    v_check := regexp_replace(v_pol.with_check, $r$, 'marshal'::text$r$, '', 'g');
    execute format('alter policy %I on public.%I', v_pol.policyname, v_pol.tablename)
      || coalesce(' using (' || v_using || ')', '')
      || coalesce(' with check (' || v_check || ')', '');
  end loop;

  -- Comments on policies (040: plan_positions_read)
  for v_com in
    select pol.polname, cls.relname, d.description
    from pg_description d
    join pg_policy pol on d.classoid = 'pg_policy'::regclass and d.objoid = pol.oid
    join pg_class cls on cls.oid = pol.polrelid
    where d.description ilike '%marshal%'
  loop
    execute format('comment on policy %I on public.%I is %L', v_com.polname, v_com.relname,
      replace(v_com.description, '(root, planner, marshal)', '(root, planner)'));
  end loop;
end;
$rewrite$;

-- The sector column held only a marshal's sector; broadcast_audience no longer reads it (section 5)
alter table public.event_roles drop column if exists sector;

-- ============================================================
-- 6. The post-check: nothing in the schema says 'marshal' any more
-- ============================================================
do $post$
declare
  v_left text;
begin
  select string_agg(what, E'\n  ' order by what) into v_left from (
    select 'function ' || p.oid::regprocedure::text as what
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind in ('f', 'p') and pg_get_functiondef(p.oid) ilike '%marshal%'
    union all
    select 'policy ' || tablename || '.' || policyname
    from pg_policies
    where schemaname = 'public' and (policyname || coalesce(qual, '') || coalesce(with_check, '')) ilike '%marshal%'
    union all
    select 'constraint ' || conrelid::regclass::text || '.' || conname
    from pg_constraint where pg_get_constraintdef(oid) ilike '%marshal%'
    union all
    select 'view ' || viewname from pg_views where schemaname = 'public' and definition ilike '%marshal%'
    union all
    select 'column ' || table_name || '.' || column_name
    from information_schema.columns where table_schema = 'public' and column_name ilike '%marshal%'
    union all
    select 'comment on ' || classoid::regclass::text || ' ' || objoid
    from pg_description where description ilike '%marshal%' and classoid <> 'pg_collation'::regclass
    union all
    select 'event_roles rows' where exists (select 1 from public.event_roles where role = 'marshal')
  ) x;
  if v_left is not null then
    raise exception E'STILL SAYS marshal after 077:\n  %', v_left;
  end if;
end;
$post$;

notify pgrst, 'reload schema';
