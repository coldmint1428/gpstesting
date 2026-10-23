-- 031: a group whose signal comes back is shown at once, not two checks later.
--
-- Found on 19 Oct 2026 (NDP rehearsal 1): an IC pressed Share, readings arrived every ~12 s with 7-33 m accuracy, and
-- the planners still saw "Test group 1 · No signal". The movements engine (move_step, 027/028) changes a status only when
-- two checks in a row agree, so that one jumpy reading cannot flip a group between on track and at risk. That is right for
-- guesses (ETAs), but "the group is heard again" is a fact: a group starts every show as no signal until its first
-- reading (about 10-15 s after Share), and then waited two more checks (up to ~10 s) before showing on track.
--
-- Now a group that is "no signal" takes its new status on the very next check, as arriving and missing already did.
-- Going INTO no signal still needs two checks in a row (a single late upload must not raise an alarm).
--
-- move_step is ~16 KB; this patches the one condition in the live definition instead of repeating the whole function,
-- and refuses to run if that line has changed. Safe to run again (it does nothing once applied). Grants are kept:
-- CREATE OR REPLACE does not touch a function's privileges.
do $migration$
declare
  d text := pg_get_functiondef('public.move_step(uuid, timestamptz)'::regprocedure);
  old_line text := 'if v_raw in (''arrived'', ''arrived_late'', ''missed'') or r.status = ''pending'' then';
  new_line text := 'if v_raw in (''arrived'', ''arrived_late'', ''missed'') or r.status in (''pending'', ''no_signal'') then';
begin
  if position(new_line in d) > 0 then
    return; -- already applied
  end if;
  if position(old_line in d) = 0 then
    raise exception '031: move_step has changed since 028 - the status rule to patch was not found, nothing was changed';
  end if;
  execute replace(d, old_line, new_line);
end
$migration$;
