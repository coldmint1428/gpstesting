-- How full the free-plan database is (500 MB limit), and what the stress events hold.
-- Paste into Supabase -> SQL Editor before and after each stress run. Stop and ask if database_mb is over 300.
-- The SQL Editor shows only the LAST query's result, so the size is last. To see another table, select it and Run.
select s.relname as table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) as size_with_indexes,
       s.n_live_tup as rows
from pg_class c
join pg_stat_user_tables s on s.relid = c.oid
order by pg_total_relation_size(c.oid) desc
limit 10;

-- Location rows of the stress events: the load test's event and "NDP sim" (the simulator's)
select e.name, count(l.*) as location_rows
from public.events e
left join public.locations l on l.event_id = e.id
where e.name like 'QA-LOADTEST%' or (e.name = 'NDP sim' and e.is_simulation)
group by e.name;

-- How full the database is (shown when you press Run)
select pg_size_pretty(pg_database_size(current_database())) as database_size,
       round(pg_database_size(current_database()) / 1048576.0) as database_mb;
