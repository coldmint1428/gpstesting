-- 068_find_person_by_email.sql -- add people by their full email address only, never by a name search.
--
-- QA-04 (31 Oct) and the 1 Nov bug list: search_people (034) matched any two letters of a display name and returned
-- up to ten accounts WITH their email addresses, to anyone signed in. Typing "an" listed strangers' emails. Adding a
-- person now works the way email to someone outside your organisation does: you must already know their exact
-- address, nothing is suggested, and the answer is that one account's name or nothing.
--
--  1. find_person_by_email(email): the one account whose email is exactly this (case-insensitive), as { id,
--     display_name }. The email is not returned -- the caller typed it. Not the caller, not a simulated person.
--  2. search_people is dropped, so no client (the website, or an older phone app build) can list accounts any more.

create or replace function public.find_person_by_email(p_email text)
returns table (id uuid, display_name text)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.display_name
  from auth.users u
  join public.profiles p on p.id = u.id
  where auth.uid() is not null
    and trim(coalesce(p_email, '')) ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    and lower(u.email) = lower(trim(p_email))
    and p.id <> auth.uid()
    and not p.is_simulated
  limit 1;
$$;

revoke execute on function public.find_person_by_email(text) from public, anon;
grant execute on function public.find_person_by_email(text) to authenticated;

drop function if exists public.search_people(text);
