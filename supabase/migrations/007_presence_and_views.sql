-- Step 7: presence on the bench, and a view of my own.
-- Run AFTER 006_floor_plan_bounds.sql (Supabase -> SQL Editor, or apply as a migration).
--
-- Where this is going, in one paragraph. 005 decided who may edit the bench: exactly ONE
-- person, holding a token in public.layout_claims. That is about to become a lock PER OBJECT,
-- so that two planners can work on the same bench at once and neither can touch what the other
-- is holding. Two things have to exist before such a lock is worth anything, and both of them
-- are in this file:
--
--   1. PRESENCE. Without it, a lock is a refusal with no explanation: the loser presses a shape
--      and is simply told no. public.layout_presence is one row per open page, written straight
--      from the browser under RLS, and published to Realtime -- so every planner can see who
--      else is on the bench, and what each of them has selected, within about a second.
--
--   2. A VIEW OF MY OWN. The map view lives inside the canvas document today, shared by
--      everyone: one planner panning moves the next planner's map. That is merely odd while
--      one person edits at a time, and wrong the moment two do. Each planner now keeps their
--      own, and the copy inside the document becomes a one-time default (see section 4).
--
-- NEITHER OF THESE GIVES ANYONE THE RIGHT TO CHANGE THE CANVAS. The claim, save_bench() and
-- everything they enforce are untouched here, so after this step the bench behaves exactly as
-- it did -- except that the planners can see each other and stop fighting over the camera.
--
-- THE ONE RULE THAT MAKES PUBLISHING SAFE, worth stating once and loudly: THE ID YOU PUBLISH
-- MUST NOT BE THE ID YOU ARE AUTHORISED BY. public.layout_claims is deliberately unpublishable
-- (its token IS the authority, so any select policy on it would hand the bench to every
-- signed-in user). public.layout_presence is publishable precisely because it holds nothing
-- that authorises anything: presence_id is a per-page tag, and knowing somebody's tag wins you
-- nothing at all.

-- ============================================================
-- 1. Who is on the bench. One row per open page, keyed by a tag the PAGE mints (presence_id):
--    a reload keeps its tag, a second tab has its own, and two tabs of one account are two
--    planners as far as this table is concerned -- which is the point.
--
--    `selected_object_id` is the shape that page has open; `active_object_id` is the shape it
--    is actually holding (step 8 fills that in; until the locks exist nothing sets it).
--
--    Both are TEXT, not uuid, and both have no foreign key, on purpose. They name an object
--    inside the canvas JSON document, which is not a table, so there is nothing to point at --
--    and the document's ids are not always uuids. The page prefers crypto.randomUUID() and
--    falls back to an 'x' + base36 id wherever it is missing, which includes every plain-HTTP
--    origin. A uuid column here would turn "a planner over http selected an area" into a
--    failed write, so the type of somebody else's identifier is not this table's business.
-- ============================================================
create table public.layout_presence (
  presence_id uuid primary key,
  layout_id uuid not null references public.layouts (id) on delete cascade,
  -- Defaulted from the session rather than sent by the page, so the ordinary write is one
  -- column and the RLS policy below has something honest to check.
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  -- Filled in by the trigger, never by the client. See section 2.
  display_name text not null default '',
  selected_object_id text,
  active_object_id text,
  last_seen timestamptz not null default now()
);

-- Everyone reads the whole bench's presence at once (there is one bench), so the index is for
-- the ordering and for the stale-row sweep in section 3.
create index layout_presence_live_idx on public.layout_presence (layout_id, last_seen desc);

-- ============================================================
-- 2. The row tells the truth about who wrote it.
--
--    Two fields are copied from the profile and the clock rather than accepted from the
--    browser: the NAME, so a planner cannot announce themselves as somebody else, and the
--    TIMESTAMP, so a client cannot look alive while it is gone (everyone else decides who is
--    present from last_seen -- see the composable, which measures it against the freshest row
--    rather than against its own clock, so a phone with the wrong time still sees the bench
--    the way everybody else does).
--
--    SECURITY DEFINER so reading public.profiles here cannot be blocked by that table's own
--    policies, the same pattern as the helpers in 002.
-- ============================================================
create function public.presence_is_truthful()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.display_name := (select p.display_name from public.profiles p where p.id = new.user_id);
  new.last_seen := now();
  return new;
end;
$$;

create trigger layout_presence_truthful
  before insert or update on public.layout_presence
  for each row execute function public.presence_is_truthful();

-- ============================================================
-- 3. Row Level Security: everyone can see who is here, only I can speak for me.
-- ============================================================
alter table public.layout_presence enable row level security;

create policy "planners see who is on the bench" on public.layout_presence
  for select to authenticated using (true);

create policy "I announce myself" on public.layout_presence
  for insert to authenticated with check (user_id = auth.uid());

create policy "I keep myself alive" on public.layout_presence
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Leaving is ordinary. The second policy is the interesting one: a page whose tab was killed,
-- or whose phone went into a bag, leaves its row behind for ever, because a browser that is
-- gone cannot delete anything. Rather than run a cron job to sweep them, ANY signed-in planner
-- may delete a row that has been silent for five minutes -- which can only ever be a ghost, so
-- the sweep is safe and it costs nothing when nobody bothers. Policies are OR-ed, so this adds
-- to the right to delete my own row rather than replacing it.
create policy "I leave" on public.layout_presence
  for delete to authenticated using (user_id = auth.uid());

create policy "anyone may clear a ghost" on public.layout_presence
  for delete to authenticated using (last_seen < now() - interval '5 minutes');

-- ============================================================
-- 4. Where I left the map. One row per planner per bench.
--
--    The Singapore box and the zoom range are the SAME rule 005 applies to `view` inside the
--    canvas (the OneMap basemap covers nothing else), restated here rather than referenced,
--    because that validator is internal to save_bench(). A write that would break it is meant
--    to fail; the page treats this upsert as a convenience, not as something worth an error.
--
--    The copy of the view still inside the canvas document is now a HOME view: the page falls
--    back to it when a planner has no row here yet, which is what stops the first planner after
--    this change from being thrown at a default location. Nothing writes it any more.
-- ============================================================
create table public.layout_views (
  layout_id uuid not null references public.layouts (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  zoom double precision not null,
  updated_at timestamptz not null default now(),
  primary key (layout_id, user_id),
  constraint layout_views_in_sg check (lat between 1.1 and 1.5 and lng between 103.5 and 104.2),
  constraint layout_views_zoom check (zoom between 0 and 25)
);

create function public.layout_view_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger layout_views_touch
  before insert or update on public.layout_views
  for each row execute function public.layout_view_touch();

alter table public.layout_views enable row level security;

-- My view is mine: not merely read-only to others, invisible to them. A planner's camera is
-- not the bench's business, which is the whole reason it left the shared document.
create policy "I read my own view" on public.layout_views
  for select to authenticated using (user_id = auth.uid());

create policy "I save my own view" on public.layout_views
  for insert to authenticated with check (user_id = auth.uid());

create policy "I move my own view" on public.layout_views
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "I forget my own view" on public.layout_views
  for delete to authenticated using (user_id = auth.uid());

-- ============================================================
-- 5. Realtime, and permissions.
--
--    Only presence is published. layout_views is nobody else's business (nothing subscribes to
--    it either); presence is the one table where a change is news to everyone at once.
-- ============================================================
alter publication supabase_realtime add table public.layout_presence;

-- Nobody anonymous reaches either table, and no table here is reachable by a function that
-- forgot to say who it is. RLS still decides which rows.
revoke all on table public.layout_presence from anon, public;
revoke all on table public.layout_views from anon, public;
grant select, insert, update, delete on table public.layout_presence to authenticated;
grant select, insert, update, delete on table public.layout_views to authenticated;

-- Internal only: reached by the triggers above, never from the app. (A trigger function cannot
-- be called directly anyway; this keeps that accidental door shut as well.)
revoke execute on function public.presence_is_truthful() from public, anon, authenticated;
revoke execute on function public.layout_view_touch() from public, anon, authenticated;

-- Next: step 8 adds public.layout_locks (one row per object) and removes the claim from 005.
