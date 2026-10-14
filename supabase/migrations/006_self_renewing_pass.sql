-- Step 6: tracking passes renew themselves + planners can stop someone's sharing.
-- Run AFTER 004_tracking_passes.sql (005 = teammate's polygon bench, independent of this).
--
-- 1. Self-renewing pass: every accepted upload pushes the pass's expiry to 24 h after that
--    upload, so a phone that keeps sharing never expires - even if the app is never opened.
--    It only expires after 24 h without uploads, and never later than 7 days after Share.
-- 2. stop_member_sharing(): root / planner (anyone in the event) or a group admin (own group)
--    cancels a person's pass and leaves a "Stopped sharing" marker on the map.

create or replace function public.report_location(
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

  -- Self-renewing: still sharing = still valid for another 24 h (max 7 days after Share)
  update public.tracking_passes
  set expires_at = least(now() + interval '24 hours', created_at + interval '7 days')
  where token = p_token;
end;
$$;

-- Stop one person's sharing (phone app) from the Members tab.
-- Returns true if they were sharing (a pass was cancelled), false if not.
create function public.stop_member_sharing(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  member_group uuid;
  cancelled int;
  last_loc public.locations;
begin
  select group_id into member_group from public.group_members
  where event_id = p_event_id and user_id = p_user_id;

  if not (
    p_user_id = auth.uid()
    or public.has_event_role(p_event_id, array['root', 'planner'])
    or (member_group is not null and public.is_group_admin(member_group))
  ) then
    raise exception 'Only the root, a planner or their group admin can stop this person''s sharing'
      using errcode = '42501';
  end if;

  update public.tracking_passes set revoked_at = now()
  where event_id = p_event_id and user_id = p_user_id and revoked_at is null and expires_at > now();
  get diagnostics cancelled = row_count;

  if cancelled = 0 then
    return false;
  end if;

  -- Leave a "Stopped sharing" marker at their last position, like pressing Stop does
  select * into last_loc from public.locations
  where event_id = p_event_id and user_id = p_user_id
  order by recorded_at desc limit 1;
  if found and last_loc.source <> 'stop' then
    insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
    values (last_loc.event_id, last_loc.group_id, last_loc.user_id, last_loc.lat, last_loc.lng, last_loc.accuracy, 'stop', now());
  end if;
  return true;
end;
$$;

revoke execute on function public.stop_member_sharing(uuid, uuid) from public, anon;
grant execute on function public.stop_member_sharing(uuid, uuid) to authenticated;

-- 3. Repair function permissions.
--    005_layouts.sql ends with "revoke execute on ALL functions ... from anon" + "grant ... to
--    authenticated", which also hit functions from 002/004. Put back what those need:
--      report_location    - called by the phone's background tracker WITHOUT a login (anon)
--      username_available - called by the sign-up form before the user exists (anon)
--      handle_new_user / generate_join_code - internal only, nobody calls them directly
grant execute on function public.report_location(uuid, double precision, double precision, real, timestamptz) to anon;
grant execute on function public.username_available(text) to anon;
revoke execute on function public.handle_new_user() from authenticated;
revoke execute on function public.generate_join_code() from authenticated;
