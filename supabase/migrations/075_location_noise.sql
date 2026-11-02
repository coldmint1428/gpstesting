-- 075 (073 and 074 are Ern's, on event_creation_ern): keep a phone's coarse fixes and repeated uploads out of `locations`.
--
-- 2 Nov, Banana Party: an IC's Android phone indoors sent a real GPS fix (±13-19 m) and a coarse Wi-Fi / cell fix
-- (always the same point, always ±100 m, about 120 m away) in turn, one every 10-14 s. Every map slid the marker back
-- and forth between the two, and zone presence could flip in and out with it. And pressing Stop uploaded the readings
-- still queued on the phone while the plugin was uploading them as well: one reading arrived five times.
--
-- So, before a phone reading ('gps') is stored:
--   * the same reading again (same person, event, time and place) is dropped;
--   * a coarse fix (±50 m or worse) is dropped while the same person has a fix at least 2.5 times as accurate from the
--     minute before it. When the good fixes stop (GPS lost for over a minute), the coarse ones are stored again, so an
--     IC who only has a coarse fix is never hidden.
-- Returning null from a BEFORE trigger skips the row and is not an error: the phone's upload still succeeds, so the
-- plugin deletes it from its queue instead of retrying it.
-- The map applies the same rule when it draws (src/utils/liveMotion.js), for rows stored before this migration.

create or replace function public.locations_drop_noise()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.source is distinct from 'gps' or new.user_id is null then
    return new;
  end if;

  if exists (
    select 1 from public.locations
    where event_id = new.event_id and user_id = new.user_id and recorded_at = new.recorded_at
      and source = 'gps' and lat = new.lat and lng = new.lng
  ) then
    return null;
  end if;

  if new.accuracy >= 50 and exists (
    select 1 from public.locations
    where event_id = new.event_id and user_id = new.user_id and source = 'gps'
      and recorded_at between new.recorded_at - interval '60 seconds' and new.recorded_at
      and accuracy is not null and accuracy * 2.5 <= new.accuracy
  ) then
    return null;
  end if;

  return new;
end
$$;

-- Runs after locations_clamp_time (triggers of one kind fire in name order), so it sees the corrected time
drop trigger if exists locations_drop_noise on public.locations;
create trigger locations_drop_noise
  before insert on public.locations
  for each row execute function public.locations_drop_noise();
