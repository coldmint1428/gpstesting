-- Cleanup after the "10-group rehearsal — 21 Oct demo" simulation that ran for 4 days (approved by Kenneth, 25 Oct 2026).
-- Run each STEP on its own in Supabase -> SQL Editor, in order, and read its result before the next.

-- STEP 0: the simulation must be paused (expect: paused). If it says running, pause it first:
--   update public.sim_runs set status = 'paused' where event_id = 'ea9bd315-f3cd-45bc-8305-7e7389cc32de';
select status, readings from public.sim_runs where event_id = 'ea9bd315-f3cd-45bc-8305-7e7389cc32de';

-- STEP 1: what is KEPT: every other event's readings (expect about 1,200 rows)
select count(*) as rows_kept
from public.locations
where event_id in (select id from public.events where id <> 'ea9bd315-f3cd-45bc-8305-7e7389cc32de');

-- STEP 2: drop the demo's readings and give the space back, in one transaction.
-- Deleting 11 million rows one by one would take long on the Nano machine and would NOT shrink the table
-- (Postgres only marks them dead). Instead: copy the readings worth keeping aside, empty the table with
-- TRUNCATE (instant; the disk space is returned at once), and put them back with their own ids. The insert
-- triggers (zone presence, No-Go alerts, time clamp) are off while they go back in, so old readings do not
-- raise new alerts. If anything fails, the whole step is undone.
begin;
create temp table keep_locations on commit drop as
  select * from public.locations
  where event_id in (select id from public.events where id <> 'ea9bd315-f3cd-45bc-8305-7e7389cc32de');
truncate public.locations;
alter table public.locations disable trigger user;
insert into public.locations overriding system value select * from keep_locations;
alter table public.locations enable trigger user;
commit;

-- STEP 3: check (expect locations in kB, rows = STEP 1's number, database well under 500 MB)
select pg_size_pretty(pg_total_relation_size('public.locations')) as locations_size,
       (select count(*) from public.locations) as rows,
       pg_size_pretty(pg_database_size(current_database())) as database_size;

-- STEP 4: the timers' own log only records past runs; nothing in the app reads it.
delete from cron.job_run_details where end_time < now() - interval '1 day';

-- STEP 5 (run on its own, not inside a transaction): shrink that log table on disk
vacuum full cron.job_run_details;
