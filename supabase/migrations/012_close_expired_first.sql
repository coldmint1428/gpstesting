-- Step 12: Start / Schedule / Change end / End always see the true state.
-- Run AFTER 011_scheduled_end.sql.
--
-- An event stops being live at its scheduled end, but the every-minute job only closes it within
-- the next minute. In that minute "Start event now" said "already live" and "Change end time"
-- could revive an event whose phones had already stopped. Fix: each of these actions first closes
-- any session whose end time has passed (end_scheduled_sessions), then does its work.
--
-- The six functions are re-created from their current definitions with one line added at the
-- top of their body, so their logic stays exactly as in 007 / 011.

do $$
declare
  fn text;
  def text;
begin
  foreach fn in array array[
    'start_event(uuid)',
    'schedule_event_start(uuid, timestamp with time zone)',
    'cancel_scheduled_start(uuid)',
    'schedule_event_end(uuid, timestamp with time zone)',
    'cancel_scheduled_end(uuid)',
    'end_event(uuid)'
  ] loop
    def := pg_get_functiondef(('public.' || fn)::regprocedure);
    if position('perform public.end_scheduled_sessions();' in def) = 0 then
      def := regexp_replace(def, E'\\nbegin\\n', E'\nbegin\n  perform public.end_scheduled_sessions(); -- close events whose end time has passed\n');
      execute def;
    end if;
  end loop;
end $$;
