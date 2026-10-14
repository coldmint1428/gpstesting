-- Step 10: "Stop sharing" from the phone's notification while the app is closed.
-- Run AFTER 009_push_reminders.sql.
--
-- The app isn't running then, so there is no login - only the tracking pass the phone uploads
-- with (android/.../BackgroundGeolocationHeadlessTask.java). Same result as pressing Stop in the
-- app: the pass is cancelled and the map shows "Stopped sharing" at the last position.

create function public.stop_sharing_with_pass(p_token uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  pass public.tracking_passes;
  last_loc public.locations;
begin
  update public.tracking_passes set revoked_at = now()
  where token = p_token and revoked_at is null
  returning * into pass;
  if not found then
    return; -- already stopped / unknown pass: nothing to do
  end if;

  select * into last_loc from public.locations
  where event_id = pass.event_id and user_id = pass.user_id
  order by recorded_at desc limit 1;
  if found and last_loc.source <> 'stop' then
    insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
    values (last_loc.event_id, last_loc.group_id, last_loc.user_id, last_loc.lat, last_loc.lng, last_loc.accuracy, 'stop', now());
  end if;
end;
$$;

-- Called without a login (the pass is the check), like report_location
revoke execute on function public.stop_sharing_with_pass(uuid) from public;
grant execute on function public.stop_sharing_with_pass(uuid) to anon, authenticated;
