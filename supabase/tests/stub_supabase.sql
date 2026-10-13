-- A stand-in for what Supabase has already done before any migration in this repository runs, so that
-- the migrations can be applied to a plain Postgres (tools/pgtest.mjs runs them on PGlite, a real
-- Postgres compiled to WebAssembly).
--
-- THIS FILE IS NEVER APPLIED TO THE PROJECT'S DATABASE. It exists only for the local runner, and it
-- fakes exactly three things and nothing else:
--
--   1. the two roles every policy in this schema names (anon, authenticated);
--   2. the `auth` schema: `auth.users`, which 002 puts a trigger on, and `auth.uid()`, which is the
--      identity everything else is decided by -- and which the tests drive with
--      `set local request.jwt.claims = '{"sub": "..."}'`, exactly as the Supabase SQL Editor does;
--   3. the `supabase_realtime` publication, which 007 and 009 add their tables to.
--
-- What it does NOT fake is Postgres itself: the same parser, the same plpgsql, the same RLS, the same
-- constraints. What it cannot cover is Supabase's own parts -- GoTrue, PostgREST, the Realtime socket
-- -- and those are what tools/bench_harness.mjs exercises instead, through two real browsers.

create role anon nologin;
create role authenticated nologin;
-- Supabase has this role too, and the default privileges below name it. Nothing in the bench's schema
-- is granted to it on purpose: it is the key that must never be in the app.
create role service_role nologin;

create schema auth;

-- The columns 002's sign-up trigger reads, and the columns supabase/tests/layouts_rls.sql inserts.
create table auth.users (
  id uuid primary key,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  created_at timestamptz,
  updated_at timestamptz
);

-- Supabase's own function, with the same meaning: the caller's id, read out of the request's JWT
-- claims. `true` for the second argument of current_setting() so a request with no claims at all is
-- NULL rather than an error.
create function auth.uid() returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

create publication supabase_realtime;

grant usage on schema public to anon, authenticated;
grant usage on schema auth to anon, authenticated;

-- Supabase's own default privileges, which is why no migration in this repository ever writes a plain
-- `grant select on table ... to authenticated` for the tables it creates: a table made in `public`
-- already carries ALL for these roles, and each migration REVOKES what it does not want (005 and 009
-- both do exactly that). Without this line a local run would fail on "permission denied for table
-- layouts" in a place where the real project is fine.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
