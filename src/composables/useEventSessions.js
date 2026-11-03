// useEventSessions - an event's sessions (Start event -> End event) and whether it is LIVE now.
// ICs can only share while live; the database checks this too (007_event_sessions.sql).
//   open session  = scheduled or live (not ended); at most one per event
//   live          = open session whose start time has passed and scheduled end (if any) hasn't
// A scheduled start turns live by itself: a timer reloads at that moment, so the
// Share button unlocks without anyone refreshing the page.
import { ref, computed, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

const MAP_CLEAR_AFTER_MS = 60 * 1000 // an ended run's markers stay on the Live map this long

export function useEventSessions(eventId) {
  const sessions = ref([]) // newest first: { id, startsAt: Date, endedAt: Date|null, endReason, scheduledEnd, planId, t0At, planRev }
  const loaded = ref(false)
  const errorMsg = ref('')
  const now = ref(Date.now())

  async function load() {
    const { data, error } = await supabase
      .from('event_sessions')
      .select('id, starts_at, ended_at, end_reason, scheduled_end, plan_id, t0_at, plan_rev')
      .eq('event_id', eventId)
      .order('starts_at', { ascending: false })
    if (error) {
      errorMsg.value = error.message
      return
    }
    errorMsg.value = ''
    now.value = Date.now()
    sessions.value = data.map((s) => ({
      id: s.id,
      startsAt: new Date(s.starts_at),
      endedAt: s.ended_at ? new Date(s.ended_at) : null,
      endReason: s.end_reason,
      scheduledEnd: s.scheduled_end ? new Date(s.scheduled_end) : null,
      planId: s.plan_id, // 039: the plan it runs with (step 24: a plan or nothing)
      t0At: s.t0_at ? new Date(s.t0_at) : null, // when the plan's clock read T+0 (null = starts_at)
      planRev: s.plan_rev,
    }))
    loaded.value = true
    timeStartTimer()
  }

  const openSession = computed(() => sessions.value.find((s) => !s.endedAt) || null)
  const liveSession = computed(() => {
    const s = openSession.value
    if (!s || s.startsAt.getTime() > now.value) return null
    if (s.scheduledEnd && s.scheduledEnd.getTime() <= now.value) return null // its end time has passed
    return s
  })
  const isLive = computed(() => liveSession.value !== null)
  const scheduledStart = computed(() =>
    openSession.value && openSession.value.startsAt.getTime() > now.value ? openSession.value.startsAt : null,
  )
  const scheduledEnd = computed(() => (openSession.value ? openSession.value.scheduledEnd : null))

  // Whose markers the Live map shows: readings from this time (ms) on, or null for nobody. Positions are only ever
  // added to, so without this every IC of the last rehearsal stayed on the map until the next one replaced them.
  // The run that is live shows its own readings; one that ended stays up for MAP_CLEAR_AFTER_MS (so a planner sees
  // everyone stop), then the map is empty until the next run starts. Same cut as Playback: recorded_at >= starts_at.
  const mapSince = computed(() => {
    if (liveSession.value) return liveSession.value.startsAt.getTime()
    if (!loaded.value) return errorMsg.value ? 0 : null // not read yet: no stale flash; unreadable: hide nobody
    const last = sessions.value.find((s) => s.startsAt.getTime() <= now.value) // newest run that started
    const end = last && (last.endedAt || last.scheduledEnd)
    if (end && now.value - end.getTime() < MAP_CLEAR_AFTER_MS) return last.startsAt.getTime()
    return null
  })

  // Reload exactly when a scheduled start or end is reached (also catches a start that was
  // cancelled meanwhile: Realtime doesn't tell other viewers about deleted rows)
  let startTimer = null
  function timeStartTimer() {
    clearTimeout(startTimer)
    const s = openSession.value
    if (!s) return
    const next = [s.startsAt, s.scheduledEnd]
      .filter((d) => d && d.getTime() > Date.now())
      .map((d) => d.getTime() - Date.now())
    if (next.length) startTimer = setTimeout(load, Math.min(Math.min(...next) + 500, 2147483647)) // setTimeout max ~24 days
  }

  // ---------- Actions (root / planner; the database checks the role) ----------
  async function call(fnName, params) {
    const { data, error } = await supabase.rpc(fnName, { p_event_id: eventId, ...params })
    await load()
    if (error) throw new Error(error.message)
    return data
  }
  // The plan to run with, or null for tracking only. Since 060 there is no run-sheet parameter to pass: a session
  // runs a plan or nothing, and the run-sheet engine can no longer be started at all.
  const startEvent = (planId = null) =>
    call('start_event', { p_plan: planId || null })
  const scheduleStart = (date, planId = null) =>
    call('schedule_event_start', {
      p_starts_at: new Date(date).toISOString(),
      p_plan: planId || null,
    })
  const cancelSchedule = () => call('cancel_scheduled_start')
  const endEvent = () => call('end_event') // returns how many people were stopped
  const scheduleEnd = (date) => call('schedule_event_end', { p_ends_at: new Date(date).toISOString() })
  const cancelScheduledEnd = () => call('cancel_scheduled_end')

  // ---------- Live updates ----------
  let reloadTimer = null
  function reloadSoon() {
    clearTimeout(reloadTimer)
    reloadTimer = setTimeout(load, 300)
  }
  const channel = supabase
    .channel('event-sessions-' + eventId + '-' + Math.random().toString(36).slice(2)) // unique name (see useEventData.js)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'event_sessions', filter: 'event_id=eq.' + eventId }, reloadSoon)
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') load() // (re)connected: nothing missed
    })
  // Load straight away too: the Live panel waits for this, and the live connection takes a moment to open
  load()

  // Coming back to a phone/tab that was asleep: timers may not have fired
  function onVisible() {
    if (!document.hidden) load()
  }
  document.addEventListener('visibilitychange', onVisible)

  // A start or an end must reach a screen that is already open without a refresh, whatever the live connection did
  // (it can drop quietly, or be refused for a role). So the clock ticks, to turn "scheduled" into "live" the second the
  // start passes even when this device's clock is a little behind the server's, and the sessions are read again every
  // few seconds while the page is on screen: a missed push costs at most that long.
  const tick = setInterval(() => {
    now.value = Date.now()
  }, 1000)
  const poll = setInterval(() => {
    if (!document.hidden) load()
  }, 10000)

  onUnmounted(() => {
    clearTimeout(startTimer)
    clearTimeout(reloadTimer)
    clearInterval(tick)
    clearInterval(poll)
    document.removeEventListener('visibilitychange', onVisible)
    supabase.removeChannel(channel)
  })

  return {
    sessions,
    loaded,
    errorMsg,
    openSession,
    liveSession,
    isLive,
    scheduledStart,
    scheduledEnd,
    mapSince,
    load,
    startEvent,
    scheduleStart,
    cancelSchedule,
    endEvent,
    scheduleEnd,
    cancelScheduledEnd,
  }
}
