-- How long each server job took during one stress run. Paste into Supabase -> SQL Editor and press Run.
-- (cron.job_run_details can only be read here, not with the app's public key.) The results file of a run has this
-- with the run's times already filled in; by hand, replace {{FROM}} and {{TO}} with the run's start and end.
-- Pass for ST1 ("engine tick on time"): gps-plan-push p95 under 2 s (it runs every 5 s), and nothing failed.
select j.jobname,
       j.schedule,
       count(*)                                                                         as runs,
       count(*) filter (where d.status <> 'succeeded')                                   as failed,
       round(percentile_cont(0.5) within group (order by extract(epoch from d.end_time - d.start_time))::numeric, 3) as median_s,
       round(percentile_cont(0.95) within group (order by extract(epoch from d.end_time - d.start_time))::numeric, 3) as p95_s,
       round(max(extract(epoch from d.end_time - d.start_time))::numeric, 3)             as max_s,
       min(d.return_message) filter (where d.status <> 'succeeded')                      as first_error
from cron.job_run_details d
join cron.job j on j.jobid = d.jobid
where j.jobname like 'gps-%'
  and d.start_time between '{{FROM}}'::timestamptz and '{{TO}}'::timestamptz
group by j.jobname, j.schedule
order by j.jobname;
