-- Why is the website slow right now? Paste into Supabase -> SQL Editor and press Run. One table, one line per check.
-- Read it top to bottom: the first line that looks wrong is usually the cause.
with
  live as (
    select e.name, s.starts_at as started_at
    from public.event_sessions s join public.events e on e.id = s.event_id
    where s.ended_at is null),
  sims as (
    select e.name, r.last_tick_at
    from public.sim_runs r join public.events e on e.id = r.event_id
    where r.status = 'running'),
  recent as (
    select e.name, count(*) as n
    from public.locations l join public.events e on e.id = l.event_id
    where l.recorded_at > now() - interval '10 minutes'
    group by e.name),
  jobs as (
    select j.jobname, count(*) as runs,
           count(*) filter (where d.status <> 'succeeded') as failed,
           max(extract(epoch from d.end_time - d.start_time)) as max_s,
           percentile_cont(0.95) within group (order by extract(epoch from d.end_time - d.start_time)) as p95_s
    from cron.job_run_details d join cron.job j on j.jobid = d.jobid
    where d.start_time > now() - interval '15 minutes'
    group by j.jobname),
  busy as (
    select pid, state, now() - query_start as running_for, left(regexp_replace(query, '\s+', ' ', 'g'), 120) as query
    from pg_stat_activity
    where datname = current_database() and state <> 'idle' and pid <> pg_backend_pid())
select 1 as n, 'Database size' as check_, round(pg_database_size(current_database()) / 1048576.0) || ' MB (free plan limit 500)' as value
union all select 2, 'Live sessions (events still running)', coalesce(string_agg(name || ' since ' || to_char(started_at at time zone 'Asia/Singapore', 'DD Mon HH24:MI'), '; '), 'none') from live
union all select 3, 'Simulators running', coalesce(string_agg(name || ' (last tick ' || to_char(last_tick_at at time zone 'Asia/Singapore', 'HH24:MI:SS') || ')', '; '), 'none') from sims
union all select 4, 'Readings in the last 10 min', coalesce(string_agg(name || ': ' || n, '; '), 'none') from recent
union all select 5, 'Server jobs, last 15 min (p95 / slowest / failed)', coalesce(string_agg(jobname || ' ' || round(p95_s::numeric, 2) || ' s / ' || round(max_s::numeric, 2) || ' s / ' || failed || ' of ' || runs, '; ' order by p95_s desc), 'none') from jobs
union all select 6, 'Cron log rows (old runs kept)', (select count(*)::text from cron.job_run_details)
union all select 7, 'Connections: active / idle / total', (select count(*) filter (where state = 'active') || ' / ' || count(*) filter (where state = 'idle') || ' / ' || count(*) from pg_stat_activity)
union all select 8, 'Longest-running queries now', coalesce((select string_agg(to_char(running_for, 'HH24:MI:SS') || ' ' || state || ': ' || query, ' || ' order by running_for desc) from (select * from busy order by running_for desc limit 5) b), 'none')
order by n;
