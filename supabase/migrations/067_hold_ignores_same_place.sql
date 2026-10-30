-- 067_hold_ignores_same_place.sql
--
-- QA 31 Oct (QA-07): Hold refused a group that was standing still.
--
-- frame_hold refuses a hold when the group is stated again between the frame and the hold's target ("X moves before
-- +5:00: it is somewhere else at +3:00"), because a statement in between is a move. But a statement at the SAME place,
-- in the same state, is not a move -- and every plan made from a sheet, or with Copy/Paste of a frame, states every
-- group in every frame. On those plans Hold refused every group, standing or not. Now only a statement somewhere else
-- (or in another state) counts as a move.
--
-- One condition changes, so the function is rewritten from its own live definition instead of being copied here in
-- full: the rest of it stays exactly as 049's latest version has it.
do $migration$
declare
  v_def text := pg_get_functiondef('public.frame_hold(uuid, uuid, integer, uuid[])'::regprocedure);
  v_old text := E'       and f.t_s > v_src.t_s and f.t_s < v_target\n     order by f.t_s';
  v_new text := E'       and f.t_s > v_src.t_s and f.t_s < v_target\n       and (p.lat <> v_lat_one or p.lng <> v_lng_one or p.state <> v_state_one)\n     order by f.t_s';
begin
  if strpos(v_def, v_old) = 0 then
    raise exception 'frame_hold no longer has the condition 067 changes; read it again before applying.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$migration$;
