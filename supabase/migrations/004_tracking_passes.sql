-- Step 4: "tracking passes" for the phone app's background uploads.
--
-- Problem: the background tracker (Transistorsoft) uploaded with the user's login token.
-- Supabase login tokens expire every hour, and the tracker's built-in refresh can't talk to
-- Supabase (it sends form data, Supabase wants JSON). After ~1 hour every upload failed (401).
--
-- Fix: when an IC starts sharing, the logged-in app asks for a TRACKING PASS (a random secret
-- for this user + event + group). The tracker sends each location with the pass to
-- report_location(), which checks the pass and that the person is STILL the group's IC.
-- Stop / logout revokes the pass; it also expires by itself after 24 hours.

create table public.tracking_passes (
  token uuid primary key default gen_random_uuid(), -- the secret the phone sends
  user_id uuid not null references public.profiles (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  revoked_at timestamptz
);
create index tracking_passes_user_idx on public.tracking_passes (user_id);

-- Only reachable through the functions below (no policies = no direct access)
alter table public.tracking_passes enable row level security;

-- Called by the logged-in app when the IC presses Share. Cancels older passes of this user
-- for this event, then returns a new one.
create function public.start_tracking_pass(p_event_id uuid, p_group_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_token uuid;
begin
  if not public.is_ic_of(p_event_id, p_group_id) then
    raise exception 'Only the group''s IC can share location' using errcode = '42501';
  end if;

  update public.tracking_passes set revoked_at = now()
  where user_id = auth.uid() and event_id = p_event_id and revoked_at is null;

  insert into public.tracking_passes (user_id, event_id, group_id)
  values (auth.uid(), p_event_id, p_group_id)
  returning token into new_token;
  return new_token;
end;
$$;

-- Called on Stop / logout: cancel all of my passes
create function public.revoke_my_tracking_passes()
returns void
language sql security definer set search_path = ''
as $$
  update public.tracking_passes set revoked_at = now()
  where user_id = auth.uid() and revoked_at is null;
$$;

-- Called by the phone's background tracker for every location (no login token needed).
-- Errors use code PT403 so the API answers HTTP 403, which makes the app stop sharing.
create function public.report_location(
  p_token uuid,
  p_lat double precision,
  p_lng double precision,
  p_accuracy real,
  p_recorded_at timestamptz
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  pass public.tracking_passes;
begin
  select * into pass from public.tracking_passes
  where token = p_token and revoked_at is null and expires_at > now();
  if not found then
    raise exception 'Tracking pass is invalid, stopped or expired' using errcode = 'PT403';
  end if;

  -- Still the IC of that group? (roles can change while sharing)
  if not exists (
    select 1 from public.group_members
    where user_id = pass.user_id and event_id = pass.event_id and group_id = pass.group_id and is_ic
  ) then
    raise exception 'No longer the IC of this group' using errcode = 'PT403';
  end if;

  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;

  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values (pass.event_id, pass.group_id, pass.user_id, p_lat, p_lng, p_accuracy, 'gps', coalesce(p_recorded_at, now()));
end;
$$;

revoke execute on function public.start_tracking_pass(uuid, uuid) from public, anon;
revoke execute on function public.revoke_my_tracking_passes() from public, anon;
grant execute on function public.start_tracking_pass(uuid, uuid) to authenticated;
grant execute on function public.revoke_my_tracking_passes() to authenticated;
-- The tracker calls this without a login, so anon may run it (the pass is the check)
revoke execute on function public.report_location(uuid, double precision, double precision, real, timestamptz) from public;
grant execute on function public.report_location(uuid, double precision, double precision, real, timestamptz) to anon, authenticated;

-- When the phone app is reopened while tracking is still running, it asks which event/group
-- its active pass belongs to (so the page can show "Stop sharing" for the right event).
create function public.my_active_tracking_pass()
returns table (event_id uuid, group_id uuid)
language sql stable security definer set search_path = ''
as $$
  select event_id, group_id from public.tracking_passes
  where user_id = auth.uid() and revoked_at is null and expires_at > now()
  order by created_at desc
  limit 1;
$$;
revoke execute on function public.my_active_tracking_pass() from public, anon;
grant execute on function public.my_active_tracking_pass() to authenticated;
