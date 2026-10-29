-- 043_frames_fill_anon.sql
--
-- 042 left anon able to execute frames_fill.
--
-- WHY. 042's last lines revoked from PUBLIC, and that is not the same thing here: this schema's default privileges
-- already grant EXECUTE on every new function to anon, authenticated and service_role, so a function is born with an
-- anon grant of its own. Revoking PUBLIC removes the implicit one and leaves that. 040 had met this already for the
-- 037/038 surface and revoked from `public, anon`; 042 did not, and reading pg_proc found `anon=X` on the new
-- function while every other plan function was clean.
--
-- It was not a way in: frames_fill checks the caller's role against the event before it touches a row, so an
-- anonymous caller got the same refusal as a participant. It is still the wrong shape, it is exactly what finding 20
-- was about, and the rule is that the only door is authenticated (R4). The check now reads the ACL, so this cannot
-- quietly come back with the next function either.

revoke execute on function public.frames_fill(uuid, uuid, uuid, uuid[]) from public, anon;
grant execute on function public.frames_fill(uuid, uuid, uuid, uuid[]) to authenticated;
