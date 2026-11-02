-- ============================================================
-- Tests for 075_location_noise.sql: coarse fixes between good ones, and repeated uploads, are not stored.
--
-- The readings are the real ones from "Banana Party" (2 Nov): an Android phone indoors sent a GPS fix (±13-19 m) and
-- a Wi-Fi / cell fix (always 1.298275, 103.848980, ±100 m) in turn, and Stop uploaded one reading five times.
-- Run locally with `node tools/pgtest.mjs`. One transaction that ends in ROLLBACK; each check raises 'FAIL n: ...'.
-- ============================================================
begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('73000000-0000-0000-0000-000000000001', 'ln-a@example.test', '{"username":"ln_a","display_name":"Ln Ic"}'),
  ('73000000-0000-0000-0000-000000000002', 'ln-b@example.test', '{"username":"ln_b","display_name":"Ln Other"}');
insert into public.events (id, name, created_by) values
  ('73000000-0000-0000-0000-0000000000e1', 'Noise test', '73000000-0000-0000-0000-000000000001');
insert into public.groups (id, event_id, name) values
  ('73000000-0000-0000-0000-0000000000a1', '73000000-0000-0000-0000-0000000000e1', 'G');

create function pg_temp.zz_put(p_user text, p_s numeric, p_lat float8, p_lng float8, p_acc real, p_source text default 'gps')
returns void language sql as $$
  insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at)
  values ('73000000-0000-0000-0000-0000000000e1', '73000000-0000-0000-0000-0000000000a1', p_user::uuid,
          p_lat, p_lng, p_acc, p_source, timestamptz '2026-11-02 03:04:57+00' + p_s * interval '1 second');
$$;

create function pg_temp.zz_count(p_user text, p_where text default 'true') returns int language plpgsql as $$
declare n int;
begin
  execute format('select count(*) from public.locations where user_id = %L and (%s)', p_user, p_where) into n;
  return n;
end $$;

do $$
declare
  a constant text := '73000000-0000-0000-0000-000000000001';
  b constant text := '73000000-0000-0000-0000-000000000002';
begin
  -- The phone alternates: GPS, Wi-Fi, GPS, Wi-Fi ...
  perform pg_temp.zz_put(a, 0, 1.297435, 103.849695, 17);
  perform pg_temp.zz_put(a, 10.8, 1.298275, 103.848980, 100);
  perform pg_temp.zz_put(a, 21, 1.297435, 103.849705, 15);
  perform pg_temp.zz_put(a, 35, 1.298275, 103.848980, 100);
  perform pg_temp.zz_put(a, 45.2, 1.297453, 103.849702, 13);
  if pg_temp.zz_count(a) <> 3 then raise exception 'FAIL 1: the coarse fixes between good ones were stored (% rows)', pg_temp.zz_count(a); end if;
  if pg_temp.zz_count(a, 'accuracy >= 50') <> 0 then raise exception 'FAIL 2: a ±100 m fix was stored'; end if;

  -- Stop uploads the same reading again (and again): stored once
  perform pg_temp.zz_put(a, 45.2, 1.297453, 103.849702, 13);
  perform pg_temp.zz_put(a, 45.2, 1.297453, 103.849702, 13);
  if pg_temp.zz_count(a, 'recorded_at = timestamptz ''2026-11-02 03:04:57+00'' + interval ''45.2 seconds''') <> 1 then
    raise exception 'FAIL 3: a repeated upload was stored twice';
  end if;

  -- A fix only a little worse (±40 m after ±13 m) is real movement information: kept
  perform pg_temp.zz_put(a, 55, 1.2976, 103.8497, 40);
  if pg_temp.zz_count(a, 'accuracy = 40') <> 1 then raise exception 'FAIL 4: a ±40 m fix was dropped'; end if;

  -- GPS lost for over a minute: the coarse fix is all there is, and it is stored
  perform pg_temp.zz_put(a, 130, 1.298275, 103.848980, 100);
  if pg_temp.zz_count(a, 'accuracy = 100') <> 1 then raise exception 'FAIL 5: a coarse fix was dropped with no good fix in the last minute'; end if;

  -- The Stop marker is never dropped, whatever its accuracy
  perform pg_temp.zz_put(a, 132, 1.298275, 103.848980, 100, 'stop');
  if pg_temp.zz_count(a, 'source = ''stop''') <> 1 then raise exception 'FAIL 6: the Stop marker was dropped'; end if;

  -- Somebody else's good fix does not hide my coarse one
  perform pg_temp.zz_put(b, 200, 1.297435, 103.849695, 10);
  perform pg_temp.zz_put(a, 205, 1.2983, 103.8490, 100);
  if pg_temp.zz_count(a, 'accuracy = 100 and source = ''gps''') <> 2 then raise exception 'FAIL 7: another person''s fix filtered mine'; end if;
end $$;

rollback;
