-- Which database calls used the most time since the counters were last reset. Paste into Supabase -> SQL Editor, Run.
-- Run it right after a stress run (or while the website is slow). To start counting afresh before a run:
--   select extensions.pg_stat_statements_reset();
select round(total_exec_time / 1000) as total_s,
       calls,
       round(mean_exec_time) as mean_ms,
       round(max_exec_time) as max_ms,
       round(100 * total_exec_time / sum(total_exec_time) over ()) as pct_of_all,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) as query
from extensions.pg_stat_statements
order by total_exec_time desc
limit 15;
