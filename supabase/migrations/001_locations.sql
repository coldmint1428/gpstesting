-- Live GPS readings table (step 1 of the GPS feature).
-- Run this in Supabase -> SQL Editor.

create table if not exists locations (
  id bigint generated always as identity primary key,
  event_id uuid not null,
  group_id uuid not null,
  user_id uuid not null default auth.uid(),
  lat double precision not null,
  lng double precision not null,
  accuracy real,
  source text not null default 'gps',   -- 'gps' | 'marshal'
  recorded_at timestamptz not null default now()
);

-- Speeds up "latest readings for this event" queries for the viewer (step 2).
create index if not exists locations_event_time_idx on locations (event_id, recorded_at desc);

-- Row Level Security: nobody can read/write unless a policy allows it.
alter table locations enable row level security;

-- A signed-in user may only insert rows as themselves.
create policy "insert own locations"
  on locations for insert
  to authenticated
  with check (user_id = auth.uid());

-- SANDBOX ONLY: any signed-in user can read all locations.
-- Later: restrict to members of the same event (needs an event_members table).
create policy "read locations (sandbox)"
  on locations for select
  to authenticated
  using (true);

-- Let Supabase Realtime broadcast new rows (used by the viewer in step 2).
alter publication supabase_realtime add table locations;
