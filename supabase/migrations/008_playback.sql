-- Step 8: playback. Root and planners can replay a session (Start -> End) on the map,
-- download it as CSV, and it is deleted 7 days after the day it ended (Singapore time).
-- Run AFTER 007_event_sessions.sql.
--
-- Example: a session that ends Sat 9 Aug 21:30 stays online until Sat 16 Aug 23:59,
-- and the cleanup job deletes it just after midnight.
-- Readings from before sessions existed (no session) are kept per day with the same rule.

-- When does a recording that ended at p_end disappear? = midnight (SGT) starting day +8
create function public.playback_available_until(p_end timestamptz)
returns timestamptz
language sql immutable set search_path = ''
as $$
  select (((p_end at time zone 'Asia/Singapore')::date + 8)::timestamp) at time zone 'Asia/Singapore';
$$;

-- The Playback tab list: every started session + days with readings outside any session.
-- Root / planners only.
create function public.playback_list(p_event_id uuid)
returns table (
  kind text,                -- 'session' | 'day'
  session_id uuid,          -- null for 'day'
  starts_at timestamptz,
  ended_at timestamptz,     -- null = still live
  end_reason text,          -- 'ended' | 'auto' | null
  available_until timestamptz, -- null while live
  readings bigint,
  people bigint
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can see playback' using errcode = '42501';
  end if;

  return query
  select 'session'::text, s.id, s.starts_at, s.ended_at, s.end_reason,
    case when s.ended_at is null then null else public.playback_available_until(s.ended_at) end,
    count(l.id), count(distinct l.user_id)
  from public.event_sessions s
  left join public.locations l
    on l.event_id = s.event_id and l.recorded_at >= s.starts_at and l.recorded_at <= coalesce(s.ended_at, now())
  where s.event_id = p_event_id and s.starts_at <= now()
  group by s.id

  union all

  select 'day'::text, null::uuid, min(l.recorded_at), max(l.recorded_at), null::text,
    public.playback_available_until(max(l.recorded_at)), count(*), count(distinct l.user_id)
  from public.locations l
  where l.event_id = p_event_id
    and not exists (
      select 1 from public.event_sessions s
      where s.event_id = l.event_id and s.starts_at <= l.recorded_at
        and l.recorded_at <= coalesce(s.ended_at, 'infinity'::timestamptz)
    )
  group by (l.recorded_at at time zone 'Asia/Singapore')::date

  order by 3 desc;
end;
$$;

-- Readings for the player / CSV, in pages of 10 000 (ordered by id; the app sorts by time).
-- Returns { rows: [[id, user_id, group_id, lat, lng, accuracy, source, epoch_ms], ...],
--           next_after_id: id to ask for the next page (null = done),
--           people: [{id, username, display_name}], groups: [{id, name, colour}] (first page only) }
-- Root / planners only. Names come from here (not the member list) so people who have left
-- the event still have a name in the replay.
create function public.location_history(
  p_event_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_after_id bigint default 0
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  page_size constant integer := 10000;
  page jsonb;
  last_id bigint;
  page_count integer;
  result jsonb;
begin
  if not public.has_event_role(p_event_id, array['root', 'planner']) then
    raise exception 'Only the root or a planner can see playback' using errcode = '42501';
  end if;

  select
    coalesce(jsonb_agg(jsonb_build_array(
      r.id, r.user_id, r.group_id, r.lat, r.lng, r.accuracy, r.source,
      (extract(epoch from r.recorded_at) * 1000)::bigint
    ) order by r.id), '[]'::jsonb),
    max(r.id), count(*)
  into page, last_id, page_count
  from (
    select * from public.locations l
    where l.event_id = p_event_id and l.recorded_at >= p_from and l.recorded_at <= p_to and l.id > p_after_id
    order by l.id
    limit page_size
  ) r;

  result := jsonb_build_object(
    'rows', page,
    'next_after_id', case when page_count = page_size then last_id else null end
  );

  if p_after_id = 0 then
    result := result || jsonb_build_object(
      'people', (
        select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name)), '[]'::jsonb)
        from public.profiles p
        where p.id in (
          select distinct l.user_id from public.locations l
          where l.event_id = p_event_id and l.recorded_at >= p_from and l.recorded_at <= p_to
        )
      ),
      'groups', (
        select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'colour', g.colour) order by g.created_at), '[]'::jsonb)
        from public.groups g where g.event_id = p_event_id
      )
    );
  end if;
  return result;
end;
$$;

-- Run by pg_cron every night at 00:05 Singapore time (16:05 UTC):
-- delete readings whose session (or day, if not in a session) has passed its "available until",
-- and old tracking passes. Returns how many readings were deleted.
create function public.cleanup_expired_locations()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  deleted integer;
begin
  delete from public.locations l
  where l.recorded_at < now() - interval '7 days' -- nothing younger can have expired
    and now() >= coalesce(
      -- in a session: that session's end decides
      (select public.playback_available_until(coalesce(s.ended_at, 'infinity'::timestamptz))
       from public.event_sessions s
       where s.event_id = l.event_id and s.starts_at <= l.recorded_at
         and l.recorded_at <= coalesce(s.ended_at, 'infinity'::timestamptz)
       order by s.starts_at desc limit 1),
      -- not in a session: its own day decides
      public.playback_available_until(l.recorded_at)
    );
  get diagnostics deleted = row_count;

  delete from public.tracking_passes where coalesce(revoked_at, expires_at) < now() - interval '8 days';
  return deleted;
end;
$$;

select cron.schedule('gps-cleanup-expired-locations', '5 16 * * *', 'select public.cleanup_expired_locations()');

revoke execute on function public.playback_available_until(timestamptz) from public, anon;
revoke execute on function public.playback_list(uuid) from public, anon;
revoke execute on function public.location_history(uuid, timestamptz, timestamptz, bigint) from public, anon;
grant execute on function public.playback_available_until(timestamptz) to authenticated;
grant execute on function public.playback_list(uuid) to authenticated;
grant execute on function public.location_history(uuid, timestamptz, timestamptz, bigint) to authenticated;
revoke execute on function public.cleanup_expired_locations() from public, anon, authenticated;
