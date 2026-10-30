-- 040_plan_group_scope.sql
--
-- Step 3 of the planning plan: a member reads only their own group's positions.
--
-- 038 gave plan_positions the same read policy as the plan itself (is_event_member), so the board — which renders
-- for any member on the Timeline page — showed every group's markers to everybody. The app already draws this
-- line in the front end: FEATURE_ACCESS.wholeEvent is root / planner / marshal, and the movements policies (027)
-- say the same in SQL. This file makes plan_positions obey it too.
--
-- What this does NOT change, on purpose:
--   * Writing stays root / planner only (the write policy from 038 is untouched).
--   * Frames (times and notes) are still readable by any member: the strip is the plan's clock, not a position
--     leak. The member's read path is replaced by their own timetable in step 16, which is also where the
--     browser assertion for "only their group appears" lives.
--
-- A member is in at most one group per event (group_members_event_id_user_id_key), so "my group" is a single id
-- and the same rule is used for an IC and a plain member. A group admin sees their group, not the event.

drop policy if exists plan_positions_read on public.plan_positions;
create policy plan_positions_read on public.plan_positions for select to authenticated
  using (
    public.has_event_role(event_id, array['root', 'planner', 'marshal'])
    or group_id = public.my_group_id(event_id)
  );

-- ---------- the other half of finding 20: PUBLIC execute ----------
-- Postgres grants EXECUTE on a new function to PUBLIC unless told otherwise, so every 037/038 plan function was
-- callable by anyone with the anon key. None of them trusted that caller — each checks the role — but the rule
-- (R4, at the bottom of 038 and 039) is an explicit grant to authenticated, and it should be true of the whole
-- plan surface, not only the functions written after the audit. Signature-by-signature, because a revoke on a
-- function that no longer exists aborts the file.
revoke execute on function public.plan_list(uuid) from public, anon;
revoke execute on function public.plan_save(uuid, jsonb) from public, anon;
revoke execute on function public.plan_delete(uuid) from public, anon;
revoke execute on function public.plan_fork(uuid) from public, anon;
revoke execute on function public.plan_publish(uuid) from public, anon;
revoke execute on function public.plan_frames_list(uuid) from public, anon;
revoke execute on function public.frame_save(uuid, jsonb) from public, anon;
revoke execute on function public.frame_move(uuid, integer, integer) from public, anon;
revoke execute on function public.frame_delete(uuid, integer) from public, anon;
revoke execute on function public.frame_shift(uuid, integer, integer) from public, anon;
revoke execute on function public.plan_check(uuid) from public, anon;
revoke execute on function public.plan_clock(integer) from public, anon;
-- Trigger functions: no client ever calls these; they fire with the table. Revoked all the same, so the plan
-- surface has one rule instead of an exception nobody remembers.
revoke execute on function public.plan_frames_check_scope() from public, anon;
revoke execute on function public.plan_positions_check_scope() from public, anon;
revoke execute on function public.activities_check_scope() from public, anon;

grant execute on function public.plan_list(uuid) to authenticated;
grant execute on function public.plan_save(uuid, jsonb) to authenticated;
grant execute on function public.plan_delete(uuid) to authenticated;
grant execute on function public.plan_fork(uuid) to authenticated;
grant execute on function public.plan_publish(uuid) to authenticated;
grant execute on function public.plan_frames_list(uuid) to authenticated;
grant execute on function public.frame_save(uuid, jsonb) to authenticated;
grant execute on function public.frame_move(uuid, integer, integer) to authenticated;
grant execute on function public.frame_delete(uuid, integer) to authenticated;
grant execute on function public.frame_shift(uuid, integer, integer) to authenticated;
grant execute on function public.plan_check(uuid) to authenticated;
grant execute on function public.plan_clock(integer) to authenticated;

comment on policy plan_positions_read on public.plan_positions is
  'Ops staff (root, planner, marshal) read every group; everyone else reads only their own group (040).';
