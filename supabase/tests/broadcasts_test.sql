-- supabase/tests/broadcasts_test.sql -- Message everyone (032_broadcasts.sql), run against the real project.
--
-- One transaction that ends with an exception, so nothing is kept (no push is sent either: the queued rows and the
-- pg_net request are rolled back). "event for testing": komin is root; testuser1 (planner, marshal of North, IC and
-- admin of Test group A) sends; komin2 and testuser2 are planners and in Test group A; testuser3–7 are plain members
-- without a group. testuser1 is also a planner of the simulation event "NDP sim run 1".
do $test$
declare
  ev uuid := 'c128abbf-da4a-4ab8-8a67-7b1ee5df4813';
  ev_sim uuid := '6746043e-d969-4b3b-b649-3a4fbc391ea5';
  u_send uuid := 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7';   -- testuser1
  u_member uuid := '2906655b-33ad-4e9d-a608-f083e43e22d4'; -- testuser3
  u_root uuid := '038d32b0-c00d-4c2c-b418-2619f40330e4';   -- komin
  u_out uuid;                                              -- someone not in the event
  everyone integer;
  id1 bigint;
  n integer; t text; j jsonb;
  passed integer := 0;
  failures text := '';
  err text;
begin
  execute $f$
    create function public.zz_as(p uuid) returns void language plpgsql as $b$
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    end $b$;
  $f$;
  execute $f$
    create function public.zz_err(p_sql text) returns text language plpgsql as $b$
    begin
      execute p_sql;
      return '';
    exception when others then
      return sqlerrm || ' [' || sqlstate || ']';
    end $b$;
  $f$;
  grant execute on function public.zz_err(text) to authenticated;

  select count(distinct user_id) into everyone from public.event_roles where event_id = ev;
  select p.id into u_out from public.profiles p
  where not exists (select 1 from public.event_roles er where er.event_id = ev and er.user_id = p.id) limit 1;

  -- B1 audiences, counted without sending (the sender is never a recipient)
  perform public.zz_as(u_send);
  j := public.broadcast_send(ev, 'everyone', null, 'x', false, true);
  if (j->>'recipients')::int = everyone - 1 then passed := passed + 1; else failures := failures || E'\nB1a everyone ' || j || ' of ' || everyone; end if;
  j := public.broadcast_send(ev, 'ics', null, 'x', false, true);
  if (j->>'recipients')::int = 2 then passed := passed + 1; else failures := failures || E'\nB1b ics ' || j; end if;
  j := public.broadcast_send(ev, 'staff', null, 'x', false, true);
  if (j->>'recipients')::int = 3 then passed := passed + 1; else failures := failures || E'\nB1c staff ' || j; end if;
  j := public.broadcast_send(ev, 'groups', null, 'x', false, true);
  if (j->>'recipients')::int = 2 then passed := passed + 1; else failures := failures || E'\nB1d groups ' || j; end if;

  -- B2 sector and category: Test group A is put in sector North and category Contingent (rolled back)
  execute 'reset role';
  update public.groups set sector = 'North', category = 'Contingent' where event_id = ev and name = 'Test group A';
  perform public.zz_as(u_send);
  j := public.broadcast_send(ev, 'sector', 'north', 'x', false, true);
  if (j->>'recipients')::int = 2 then passed := passed + 1; else failures := failures || E'\nB2a sector ' || j; end if;
  j := public.broadcast_send(ev, 'category', 'Contingent', 'x', false, true);
  if (j->>'recipients')::int = 2 then passed := passed + 1; else failures := failures || E'\nB2b category ' || j; end if;
  err := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'sector', 'Nowhere', 'x')$$);
  if err like '%Nobody would get this message%' then passed := passed + 1; else failures := failures || E'\nB2c empty sector: ' || err; end if;
  err := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'category', '', 'x')$$);
  if err like '%Pick the category%' then passed := passed + 1; else failures := failures || E'\nB2d no category: ' || err; end if;

  -- B3 the message itself
  err := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'everyone', null, '   ')$$);
  t := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'everyone', null, repeat('a', 301))$$);
  if err like '%1 to 300 characters%' and t like '%1 to 300 characters%' then passed := passed + 1; else failures := failures || E'\nB3a ' || err || ' / ' || t; end if;
  err := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'all', null, 'x')$$);
  if err like '%Pick who gets the message%' then passed := passed + 1; else failures := failures || E'\nB3b ' || err; end if;

  -- B4 who may send: a plain member and an outsider may not
  perform public.zz_as(u_member);
  err := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'everyone', null, 'x')$$);
  perform public.zz_as(u_out);
  t := public.zz_err($$select public.broadcast_send('$$ || ev || $$', 'everyone', null, 'x')$$);
  if err like '%[42501]%' and t like '%[42501]%' then passed := passed + 1; else failures := failures || E'\nB4 ' || err || ' / ' || t; end if;

  -- B5 send to everyone: one receipt and one push per person, the sender left out
  perform public.zz_as(u_send);
  j := public.broadcast_send(ev, 'everyone', null, 'Lightning: take shelter now.', true);
  id1 := (j->>'id')::bigint;
  execute 'reset role';
  select count(*) into n from public.broadcast_recipients where broadcast_id = id1;
  if n = everyone - 1 and (j->>'recipients')::int = n then passed := passed + 1; else failures := failures || E'\nB5a receipts ' || n; end if;
  if not exists (select 1 from public.broadcast_recipients where broadcast_id = id1 and user_id = u_send) then passed := passed + 1; else failures := failures || E'\nB5b sender got it'; end if;
  select count(*) into n from public.push_queue where dedup like 'broadcast:' || id1 || ':%';
  select title || '|' || (data->>'kind') || '|' || (data->>'tag') into t from public.push_queue where dedup like 'broadcast:' || id1 || ':%' limit 1;
  if n = everyone - 1 and t = 'URGENT · Message from ' || public.show_who(u_send) || ' to everyone|message|broadcast-' || id1
  then passed := passed + 1; else failures := failures || E'\nB5c pushes ' || n || ' ' || coalesce(t, 'none'); end if;
  if (select urgent and from_user = u_send and cleared_at is null from public.broadcasts where id = id1) then passed := passed + 1; else failures := failures || E'\nB5d row'; end if;

  -- B6 who can read what
  perform public.zz_as(u_member);
  select count(*) into n from public.broadcasts where id = id1;
  if n = 1 then passed := passed + 1; else failures := failures || E'\nB6a recipient sees ' || n; end if;
  select count(*) into n from public.broadcast_recipients where broadcast_id = id1;
  if n = 1 then passed := passed + 1; else failures := failures || E'\nB6b recipient sees receipts ' || n; end if;
  perform public.zz_as(u_out);
  select count(*) into n from public.broadcasts where id = id1;
  if n = 0 then passed := passed + 1; else failures := failures || E'\nB6c outsider sees ' || n; end if;
  perform public.zz_as(u_root);
  select count(*) into n from public.broadcast_recipients where broadcast_id = id1;
  if n = everyone - 1 then passed := passed + 1; else failures := failures || E'\nB6d root sees receipts ' || n; end if;
  perform public.zz_as(u_member);
  err := public.zz_err('insert into public.broadcasts (event_id, audience, body) values (''' || ev || ''', ''everyone'', ''x'')');
  t := public.zz_err('update public.broadcast_recipients set acked_at = now()');
  if err like '%permission denied%' and t like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nB6e writes ' || err || ' / ' || t; end if;

  -- B7 seen, Got it, and the planner's count
  perform public.broadcast_mark(id1, false);
  perform public.broadcast_mark(id1, true);
  perform public.broadcast_mark(id1, true); -- twice: the first time is kept
  err := public.zz_err('select public.broadcast_status(' || id1 || ')');
  if err like '%[42501]%' then passed := passed + 1; else failures := failures || E'\nB7a member reads status: ' || err; end if;
  perform public.zz_as(u_send);
  j := public.broadcast_status(id1);
  if (j->>'total')::int = everyone - 1 and (j->>'seen')::int = 1 and (j->>'acked')::int = 1
     and jsonb_array_length(j->'waiting') = everyone - 2
     and not exists (select 1 from jsonb_array_elements(j->'waiting') w where w->>'name' = 'testuser3')
  then passed := passed + 1; else failures := failures || E'\nB7b status ' || j; end if;

  -- B8 clear: planners only; the recipient can still read it, now cleared
  perform public.zz_as(u_member);
  err := public.zz_err('select public.broadcast_clear(' || id1 || ')');
  if err like '%[42501]%' then passed := passed + 1; else failures := failures || E'\nB8a member clears: ' || err; end if;
  perform public.zz_as(u_send);
  perform public.broadcast_clear(id1);
  perform public.zz_as(u_member);
  select count(*) into n from public.broadcasts where id = id1 and cleared_at is not null;
  if n = 1 then passed := passed + 1; else failures := failures || E'\nB8b cleared ' || n; end if;

  -- B9 a simulation event: receipts but no pushes
  perform public.zz_as(u_send);
  j := public.broadcast_send(ev_sim, 'everyone', null, 'Hold in place.');
  execute 'reset role';
  select count(*) into n from public.push_queue where dedup like 'broadcast:' || (j->>'id') || ':%';
  if n = 0 and (j->>'recipients')::int > 0 then passed := passed + 1; else failures := failures || E'\nB9 sim pushes ' || n || ' ' || j; end if;

  -- B10 helpers and the audience function are not open to anon; the audience list is not callable at all
  perform public.zz_as(u_send);
  err := public.zz_err('select count(*) from public.broadcast_audience(''' || ev || ''', ''everyone'', null, null)');
  if err like '%permission denied%' then passed := passed + 1; else failures := failures || E'\nB10 audience callable: ' || err; end if;

  execute 'reset role';
  raise exception 'RESULTS: % passed, failures: %', passed, coalesce(nullif(failures, ''), 'none');
end $test$;
