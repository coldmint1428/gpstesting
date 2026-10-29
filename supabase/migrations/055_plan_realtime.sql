-- 055_plan_realtime.sql
--
-- Step 19 of the planning plan: a published change reaches the other screens.
--
-- WHAT WAS WRONG. Nothing subscribed to a plan. The board, the strip and the timetable each had a different partial
-- answer to "did anything change": a 30-second poll (052), the hand-over a publish writes onto the open session
-- (051, which useEventSessions does listen to), and a button. Everything else -- a moment another planner added, a
-- note they wrote, a group they dragged, a frame they deleted, a plan somebody renamed or threw away -- reached a
-- second tab only when somebody reloaded the page. The product's premise (step 1) is that two people can work on one
-- plan; a screen that hears about the other person's work only on F5 is not that.
--
-- WHAT THIS FILE DOES.
--
--   1. `plans` joins supabase_realtime, and gets `replica identity full`.
--
--   2. NOTHING ELSE JOINS IT, and that is the design, not an omission. Every write to a frame or a position ends by
--      touching its plan row -- `update public.plans set updated_at = now()` in 038, 041, 042, 044, 045, 046 and
--      047, once per create, move, delete, shift, hold, fill and verify patch -- and plan_save and plan_publish touch
--      it too. So an event's `plans` rows are a complete change log for that event's plans, and one table is one
--      channel instead of three.
--
--      Listening to plan_frames and plan_positions directly was the obvious alternative and is worse in three ways.
--      It is three subscriptions where one will do. Every frame_save replaces a frame's positions wholesale (046), so
--      each drag would emit a DELETE per position that merely stayed -- traffic about rows that did not change. And
--      Realtime does not apply RLS to DELETE events at all ("there is no way for Postgres to verify that a user has
--      access to a deleted record", its documentation), so a plan_positions DELETE would carry every group's
--      coordinates to anyone who knows the event id. A plan row carries an event id, a name and a number.
--
--   3. `replica identity full` is what makes a DELETE visible at all: with the default identity a DELETE event
--      carries the primary key and nothing else, so a filter on `event_id` can never match it -- and a plan deleted
--      in another tab would stay in this one's picker for ever. The same setting also sends the old row on UPDATE;
--      the client only ever reads `new`, so that costs bytes and no behaviour.
--
-- WHAT THE CLIENT DOES WITH IT lives in src/composables/usePlan.js, because that file is the only place the board
-- talks to the database. A change to the plan on screen whose revision did not move is content: the frames are
-- re-read and the board redraws. A change whose revision moved is a publish or a rename, which is exactly the
-- decision the live strip was built to make (steps 15 and 18): a background reload must not swap the picture under
-- a planner's hands and silence the warning that their revision is not the one people are following.
--
-- WHO HEARS WHAT. Realtime filters by RLS on every event except DELETE: a planner or marshal of the event, and a
-- member while the plan is live (plans_read, 038), receive its updates. A DELETE event is sent to any subscriber
-- whose filter matches -- the row is already gone, so there is nothing to check -- which is why the filter here is
-- the event id and the table is the one whose row says nothing about the walk.

-- ---------- 1. the channel ----------
do $$
begin
  -- A plain Postgres has no supabase_realtime publication; on one, plans simply are not live (and every screen
  -- still has its poll or its button).
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'plans'
  ) then
    alter publication supabase_realtime add table public.plans;
  end if;
end $$;

-- ---------- 2. a deleted plan has to say which event it belonged to ----------
alter table public.plans replica identity full;

comment on table public.plans is
  'A timetable of frames over a locked map. The row is also the event''s plan change log: every frame and position '
  'write bumps updated_at, and the client listens to it (055, step 19).';
