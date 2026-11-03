-- ============================================================
-- 086: rename a recording.
--   A recording is a session (or a day of readings outside any session), listed by playback_list with a title made from
--   its times. A name is kept beside it, keyed by the session id, or 'day-YYYY-MM-DD' (Singapore date) for a day.
--   Root / planners read and set names; an empty name puts the times back. The recording itself is not touched, and a
--   name goes when its event does.
-- ============================================================

create table if not exists public.recording_names (
  event_id uuid not null references public.events (id) on delete cascade,
  key text not null check (char_length(key) between 1 and 80),
  name text not null check (char_length(name) between 1 and 80),
  updated_at timestamptz not null default now(),
  primary key (event_id, key)
);

alter table public.recording_names enable row level security;

drop policy if exists "recording names: root and planners read" on public.recording_names;
create policy "recording names: root and planners read" on public.recording_names
  for select to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']));

revoke all on table public.recording_names from anon, authenticated, public;
grant select on table public.recording_names to authenticated;

create or replace function public.rename_recording(p_event_id uuid, p_key text, p_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can rename a recording' using errcode = '42501';
  end if;
  if p_key is null or char_length(p_key) not between 1 and 80 then
    raise exception 'That recording does not exist';
  end if;
  if char_length(v_name) > 80 then
    raise exception 'A name can be at most 80 characters';
  end if;
  if v_name = '' then
    delete from public.recording_names where event_id = p_event_id and key = p_key;
  else
    insert into public.recording_names (event_id, key, name) values (p_event_id, p_key, v_name)
    on conflict (event_id, key) do update set name = excluded.name, updated_at = now();
  end if;
end;
$$;

revoke execute on function public.rename_recording(uuid, text, text) from public, anon;
grant execute on function public.rename_recording(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
