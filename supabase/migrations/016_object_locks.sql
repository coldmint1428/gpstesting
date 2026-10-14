-- Step 8: a lock per OBJECT, and a save that merges.
-- Run AFTER 015_presence_and_views.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- RE-RUNNABLE, deliberately: every statement is `if not exists`, `if exists` or `create or replace`,
-- so applying this file a second time after an edit replaces a function in place rather than dying
-- halfway on a table that already exists or a function that was already dropped. Nothing in it
-- deletes data.
--
-- WHAT THIS REPLACES. 005 decided who may edit the bench by handing out ONE claim for the whole
-- canvas: a token in public.layout_claims, and only the holder could save. That has two faults
-- that cannot be fixed from inside it. A second browser signed in as the SAME account satisfies
-- the conflict rule (it is the same user, so it looks like a renewal), is handed the SAME token,
-- and can therefore save over the first one -- two editors, one document, last write wins. And
-- even between different accounts it is the wrong shape: a planner who wants to nudge one dot
-- locks everybody out of the whole bench to do it.
--
-- So: nothing is claimed as a whole any more. Any signed-in planner may work on the bench, and
-- exclusion happens one OBJECT at a time (an area, a floor plan), enforced here.
--
-- THE SESSION IS THE UNIT, NOT THE PLANNER. A lock is held by a SESSION -- one per open tab,
-- minted by the page and kept in sessionStorage -- because the user id cannot do this job: it is
-- already what the server must use to recognise "this is my own renewal", so it cannot also be
-- what tells two of my tabs apart. Two tabs of one account are two editors here, which is the
-- whole point, and the count of that fix lives in this column and nowhere else.
--
-- THE SESSION IS A SECRET. public.layout_locks holds it, so that table is NEVER published, has
-- no policies and no grants, and is reached only through the functions below. This is the same
-- rule 015 states for presence, from the other side: the id a page PUBLISHES (its presence tag)
-- is never the id it is AUTHORISED by.
--
-- AND THE SAVE MERGES, WHICH IS WHAT MAKES ALL OF IT SAFE. save_bench() no longer writes whatever
-- it is sent. It walks the document object by object and:
--
--     * objects I hold the lock on are taken from me (and a new object is nobody else's);
--     * everything else keeps the STORED version -- even if my copy differs, and even if I hold
--       no lock at all -- and each such object is named in the reply;
--     * an object missing from my copy is only treated as deleted if I hold its lock.
--
-- That last pair is the important part. A page with a stale copy of somebody else's work cannot
-- overwrite it and cannot delete it, whether or not it manages to take a lock, and whether or not
-- the other planner has already finished and let go. Being refused is a report, not silence: the
-- ids come back, so the page can say what happened and re-read.
--
-- Still to come, and worth knowing while reading this: step 9 will stream the changes as they
-- happen (so a planner watches a shape move rather than seeing it on their next save), and step 10
-- will split the canvas into one row per object, at which point a version number per object can
-- replace the merge and the 4 MB whole-document write.

-- ============================================================
-- 1. The locks. One row per object, owned by a session.
-- ============================================================
create table if not exists public.layout_locks (
  -- The shape's id inside the canvas document, which is not a table and whose ids are not always
  -- uuids (see 015), so this is text and has no foreign key to point at.
  object_id text primary key,
  layout_id uuid not null references public.layouts (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  session_id uuid not null,
  last_seen timestamptz not null default now(),
  -- Deliberately short. It is renewed by the page while the planner is working, and by
  -- save_bench() as a side effect of saving, so the only way to reach it is to stop.
  expires_at timestamptz not null default now() + interval '45 seconds',
  constraint layout_locks_object_len check (char_length(object_id) between 1 and 200)
);

create index if not exists layout_locks_session_idx on public.layout_locks (session_id);
create index if not exists layout_locks_user_idx on public.layout_locks (user_id);

-- ============================================================
-- 1b. Two things that make this file safe against the way a JSON null behaves -- which is the one
--     thing about `->` that is genuinely easy to get wrong, and which this file does NOT try to
--     settle.
--
--     1. The bench's default document has no `view` key rather than a null one. There is a reading
--        under which `{"view": null}` is not what 005's validator expects (and the bench's own
--        default was exactly that); with the key ABSENT there is nothing to interpret, and a new
--        bench means "no view stored" under either reading.
--
--     2. layout_list() below, used for every list this file reads.
-- ============================================================
alter table public.layouts alter column data set default '{"floorPlans": [], "polygons": []}'::jsonb;

-- The lists inside a document, as arrays, whatever the document actually holds: absent, a JSON null,
-- or a real array.
--
-- `coalesce(p_data -> 'floorPlans', '[]'::jsonb)` is NOT the same thing, and that is the trap: if
-- `->` hands back a JSON null rather than a SQL NULL, coalesce keeps it, and jsonb_array_elements()
-- then either fails on a scalar or yields one null element -- which reads as a shape with no id, and
-- turns an empty document into "every shape needs an id". Asking jsonb_typeof is right either way.
create or replace function public.layout_list(p_data jsonb, p_key text)
returns jsonb
language sql immutable set search_path = ''
as $$
  select case when jsonb_typeof(p_data -> p_key) = 'array' then p_data -> p_key else '[]'::jsonb end;
$$;

-- ============================================================
-- 2. No policies and no grants: this table is only ever reached through the functions below, and
--    never published. A planner who could read it would learn other planners' session ids, which
--    are the credential.
-- ============================================================
alter table public.layout_locks enable row level security;

revoke all on table public.layout_locks from anon, authenticated, public;

-- ============================================================
-- 3. Taking, keeping and letting go of a lock.
--
--    claim_object() is the machine; lock_object() and take_over_object() are the two ways in. It
--    is revoked from authenticated (section 5), so the only way to force a quiet lock away is
--    through take_over_object(), which carries the rules.
-- ============================================================
create or replace function public.claim_object(p_object text, p_session uuid, p_force boolean)
returns table (
  granted boolean,
  held_by text,          -- display name of whoever has it, when it is not mine
  mine_elsewhere boolean, -- ...and whether "whoever" is me in another window
  expires_at timestamptz,
  idle_seconds int        -- how long the holder has been quiet (for the take-over decision)
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_layout uuid;
  v_object text := nullif(trim(coalesce(p_object, '')), '');
  v_expires timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  if v_object is null or char_length(v_object) > 200 then
    raise exception 'That is not a shape on this bench' using errcode = '22023';
  end if;

  -- A page with no session cannot hold anything. This is the one hard refusal left: everything
  -- else is decided per object, and a lock that cannot be taken only means the save will not
  -- include that object.
  if p_session is null then
    raise exception 'This page has no session, so nothing can be held' using errcode = 'PT409';
  end if;

  select l.id into v_layout from public.layouts l order by l.created_at limit 1;
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;

  -- One atomic statement, exactly as 005 did for the whole bench: two presses in the same
  -- millisecond cannot both succeed, because Postgres serialises them on the primary key.
  insert into public.layout_locks (object_id, layout_id, user_id, session_id)
  values (v_object, v_layout, auth.uid(), p_session)
  on conflict (object_id) do update
    set user_id = excluded.user_id,
        session_id = excluded.session_id,
        last_seen = now(),
        expires_at = now() + interval '45 seconds'
    -- The WHERE decides whether the conflict is resolved at all. A live lock held by another
    -- session matches no row, so nothing is returned and nothing changes.
    where layout_locks.expires_at < now()                    -- the holder stopped
       or layout_locks.session_id = p_session                -- it is me again (a heartbeat)
       -- Forcing is only offered against a lock that is already quiet, or one of my own windows:
       -- yanking a planner who is working right now is not a thing this bench does.
       or (p_force and (layout_locks.user_id = auth.uid()
                        or layout_locks.last_seen < now() - interval '90 seconds'))
  returning layout_locks.expires_at into v_expires;

  if v_expires is not null then
    return query select true, null::text, false, v_expires, 0;
    return;
  end if;

  -- Refused: say who has it. Written as a left join against a one-row table so that this always
  -- returns exactly one row -- if the lock expired between the two statements there is nobody to
  -- name, and the caller simply tries again rather than being handed an empty result to interpret.
  return query
    select false,
           p.display_name,
           (c.user_id = auth.uid()),
           c.expires_at,
           greatest(0, extract(epoch from (now() - c.last_seen))::int)
    from (select 1) as one
    left join public.layout_locks c on c.object_id = v_object
    left join public.profiles p on p.id = c.user_id;
end;
$$;

-- I am starting to work on this object.
create or replace function public.lock_object(p_object text, p_session uuid)
returns table (granted boolean, held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int)
language sql security definer set search_path = ''
as $$
  select * from public.claim_object(p_object, p_session, false);
$$;

-- It is my own other window, or whoever has it has gone quiet: take it.
create or replace function public.take_over_object(p_object text, p_session uuid)
returns table (granted boolean, held_by text, mine_elsewhere boolean, expires_at timestamptz, idle_seconds int)
language sql security definer set search_path = ''
as $$
  select * from public.claim_object(p_object, p_session, true);
$$;

-- I have finished with this object (put it down, or left the mode).
create or replace function public.unlock_object(p_object text, p_session uuid)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.layout_locks
  where object_id = p_object and session_id = p_session;
$$;

-- Everything this tab was holding, at once: a page that goes away cannot be trusted to walk its
-- own list, and a hidden tab is not working on anything.
create or replace function public.release_my_locks(p_session uuid)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.layout_locks where session_id = p_session;
$$;

-- ============================================================
-- 4. Saving, which is now a merge.
--
--    Replaces the token version: the signature changes (the credential is a session, and the
--    argument order moves the document first), so the old function is dropped rather than
--    replaced -- `create or replace` would otherwise leave a second, token-based save_bench()
--    alive next to this one, which is exactly the kind of door that gets used by accident.
-- ============================================================
drop function if exists public.save_bench(uuid, jsonb);

create or replace function public.save_bench(p_data jsonb, p_session uuid)
returns text[]                 -- the object ids where the STORED version won over mine
language plpgsql security definer set search_path = ''
as $$
declare
  v_layout uuid;
  v_stored jsonb;
  v_kind text;
  v_incoming jsonb;
  v_stored_map jsonb;
  v_out jsonb;
  v_item jsonb;
  v_stored_item jsonb;
  v_id text;
  v_mine boolean;
  v_sent text[];
  v_data jsonb;
  v_plans jsonb := '[]'::jsonb;
  v_areas jsonb := '[]'::jsonb;
  v_overruled text[] := '{}';
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  if p_session is null then
    raise exception 'This page has no session, so nothing can be saved' using errcode = 'PT409';
  end if;

  select l.id, l.data into v_layout, v_stored
  from public.layouts l order by l.created_at limit 1;
  if v_layout is null then raise exception 'The bench does not exist yet'; end if;

  -- Size cap lives here rather than in the check constraint: pg_column_size/octet_length are not
  -- immutable, so they cannot back a constraint. 54000 = program_limit_exceeded.
  if octet_length(p_data::text) > 4194304 then
    raise exception 'That layout is too large (4 MB maximum)' using errcode = '54000';
  end if;

  -- Checked on what I SENT, so the sentence the planner gets is about their own document -- but
  -- WITHOUT its `view`: the stored view is the bench's home view and is never taken from the caller
  -- (see the update at the end of this function), so refusing a save over a field that is going to
  -- be ignored would be refusing it for a reason that does not exist.
  if not public.layout_data_ok(p_data - 'view') then
    raise exception 'The layout data is not valid' using errcode = '22023';
  end if;

  -- The merge is BY ID -- an object I hold is mine to say, anything else is matched against the
  -- stored document by its id -- so an object without one can neither be recognised nor replaced,
  -- and every save would copy it again. The page has always set one on everything it makes, so
  -- this is a refusal of something that cannot be meant, rather than a rule anybody has to meet.
  if exists (
    select 1
    from jsonb_array_elements(
      public.layout_list(p_data, 'floorPlans') || public.layout_list(p_data, 'polygons')
    ) s
    where jsonb_typeof(s -> 'id') is distinct from 'string' or s ->> 'id' = ''
  ) then
    raise exception 'Every shape needs an id' using errcode = '22023';
  end if;

  foreach v_kind in array array['floorPlans', 'polygons'] loop
    v_incoming := public.layout_list(p_data, v_kind);
    v_out := '[]'::jsonb;
    v_sent := '{}';

    -- The stored side as a lookup keyed by object id, so "is this mine to say" is one lookup
    -- instead of a scan of the whole document for every object in it.
    select coalesce(jsonb_object_agg(s ->> 'id', s), '{}'::jsonb)
    into v_stored_map
    from jsonb_array_elements(public.layout_list(v_stored, v_kind)) s;

    -- Everything I sent: mine to say if I hold the lock, or if the bench has never seen it.
    -- Anything else keeps the stored version, and is named in the reply.
    for v_item in select * from jsonb_array_elements(v_incoming) loop
      v_id := v_item ->> 'id';
      v_sent := v_sent || v_id;
      v_stored_item := v_stored_map -> v_id; -- SQL NULL when the bench has never seen this id

      select exists (
        select 1 from public.layout_locks k
        where k.object_id = v_id and k.session_id = p_session and k.expires_at > now()
      ) into v_mine;

      if v_mine or v_stored_item is null then
        v_out := v_out || jsonb_build_array(v_item);
      else
        v_out := v_out || jsonb_build_array(v_stored_item);
        v_overruled := v_overruled || v_id;
      end if;
    end loop;

    -- Everything the bench has that I did not send. Keeping it is the default; dropping it is a
    -- deletion, and only the holder of that object's lock may delete it.
    for v_id, v_stored_item in select key, value from jsonb_each(v_stored_map) loop
      if v_id = any (v_sent) then continue; end if;

      select exists (
        select 1 from public.layout_locks k
        where k.object_id = v_id and k.session_id = p_session and k.expires_at > now()
      ) into v_mine;

      if not v_mine then
        v_out := v_out || jsonb_build_array(v_stored_item);
      end if;
    end loop;

    if v_kind = 'floorPlans' then
      v_plans := v_out;
    else
      v_areas := v_out;
    end if;
  end loop;

  -- The view inside the document is the bench's HOME view now; a planner's camera lives in
  -- public.layout_views (015) and nothing writes this one any more, so it is preserved as it is
  -- rather than taken from whoever saves last.
  --
  -- Carried over only when the stored document really HAS the key. jsonb_build_object turns a SQL
  -- NULL into the JSON value `null`, so a bench with no view would otherwise come back with a null
  -- to interpret instead of no key at all (see 1b). jsonb_exists() is the function form of the `?`
  -- operator, spelled out because `?` means "bind parameter" to some of the tools that read this
  -- file.
  v_data := jsonb_build_object('floorPlans', v_plans, 'polygons', v_areas);
  if jsonb_exists(v_stored, 'view') then
    v_data := v_data || jsonb_build_object('view', v_stored -> 'view');
  end if;

  update public.layouts
  set data = v_data,
      updated_at = now()
  where id = v_layout;

  -- A save is also a sign of life for everything this session is holding, the way it used to be
  -- for the claim.
  update public.layout_locks
  set last_seen = now(), expires_at = now() + interval '45 seconds'
  where session_id = p_session;

  return v_overruled;
end;
$$;

-- ============================================================
-- 5. The claim is gone: the table, and both of its doors.
-- ============================================================
drop function if exists public.release_bench(uuid);
drop function if exists public.claim_bench();
drop table if exists public.layout_claims;

-- open_bench() has nothing left to say about a claim, so its shape changes and it is dropped and
-- rebuilt rather than replaced (create or replace cannot change a return type).
drop function if exists public.open_bench();

create or replace function public.open_bench()
returns table (
  id uuid,
  data jsonb,
  updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  -- Safe under concurrency: the singleton index makes the loser a no-op.
  insert into public.layouts (created_by) values (auth.uid()) on conflict do nothing;

  select l.id into v_id from public.layouts l order by l.created_at limit 1;

  return query
    select l.id, l.data, l.updated_at
    from public.layouts l
    where l.id = v_id;
end;
$$;

-- ============================================================
-- 6. Permissions, the same pattern as 005's section 5 and 015's.
--    The machine is internal; the two doors to it, the release, the save and the read are not.
-- ============================================================
revoke execute on function public.claim_object(text, uuid, boolean) from public, anon, authenticated;
revoke execute on function public.layout_list(jsonb, text) from public, anon, authenticated;
revoke execute on function public.lock_object(text, uuid) from public, anon;
revoke execute on function public.take_over_object(text, uuid) from public, anon;
revoke execute on function public.unlock_object(text, uuid) from public, anon;
revoke execute on function public.release_my_locks(uuid) from public, anon;
revoke execute on function public.save_bench(jsonb, uuid) from public, anon;
revoke execute on function public.open_bench() from public, anon;

grant execute on function public.lock_object(text, uuid) to authenticated;
grant execute on function public.take_over_object(text, uuid) to authenticated;
grant execute on function public.unlock_object(text, uuid) to authenticated;
grant execute on function public.release_my_locks(uuid) to authenticated;
grant execute on function public.save_bench(jsonb, uuid) to authenticated;
grant execute on function public.open_bench() to authenticated;

-- Next: step 9 streams the changes, so a shape is seen moving rather than discovered on the next
-- save; step 10 gives every object its own row and its own version.
