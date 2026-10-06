-- Step 3: show "stopped sharing" on the map.
-- When an IC presses Stop, the app saves one extra row with source = 'stop' at their last
-- position. Viewers can then tell "chose to stop" apart from "lost contact" (phone died).

-- Only these sources are allowed ('marshal' = manual marks, coming later)
alter table public.locations
  add constraint locations_source_check check (source in ('gps', 'marshal', 'stop'));

-- latest_locations now also returns the source, so the map can show the "stopped" state.
-- (Changing a function's returned columns needs drop + create.)
drop function public.latest_locations(uuid);

create function public.latest_locations(p_event_id uuid)
returns table (
  user_id uuid,
  group_id uuid,
  lat double precision,
  lng double precision,
  accuracy real,
  source text,
  recorded_at timestamptz
)
language sql stable set search_path = ''
as $$
  select distinct on (l.user_id) l.user_id, l.group_id, l.lat, l.lng, l.accuracy, l.source, l.recorded_at
  from public.locations l
  where l.event_id = p_event_id
  order by l.user_id, l.recorded_at desc;
$$;

revoke execute on function public.latest_locations(uuid) from public, anon;
grant execute on function public.latest_locations(uuid) to authenticated;
