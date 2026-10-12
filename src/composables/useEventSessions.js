// useEventSessions - an event's sessions (Start event -> End event) and whether it is LIVE now.
// ICs can only share while live; the database checks this too (007_event_sessions.sql).
//   open session  = scheduled or live (not ended); at most one per event
//   live          = open session whose start time has passed
// A scheduled start turns live by itself: a timer reloads at that moment, so the
// Share button unlocks without anyone refreshing the page.
import { ref, computed, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export function useEventSessions(eventId) {
  const sessions = ref([]) // newest first: { id, startsAt: Date, endedAt: Date|null, endReason }
  const loaded = ref(false)
  const errorMsg = ref('')
  const now = ref(Date.now())

  async function load() {
    const { data, error } = await supabase
      .from('event_sessions')
      .select('id, starts_at, ended_at, end_reason')
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
    }))
    loaded.value = true
    timeStartTimer()
  }

  const openSession = computed(() => sessions.value.find((s) => !s.endedAt) || null)
  const liveSession = computed(() =>
    openSession.value && openSession.value.startsAt.getTime() <= now.value ? openSession.value : null,
  )
  const isLive = computed(() => liveSession.value !== null)
  const scheduledStart = computed(() =>
    openSession.value && openSession.value.startsAt.getTime() > now.value ? openSession.value.startsAt : null,
  )

  // Reload exactly when a scheduled start is reached (also catches a start that was
  // cancelled meanwhile: Realtime doesn't tell other viewers about deleted rows)
  let startTimer = null
  function timeStartTimer() {
    clearTimeout(startTimer)
    const s = openSession.value
    if (!s) return
    const wait = s.startsAt.getTime() - Date.now()
    if (wait > 0) startTimer = setTimeout(load, Math.min(wait + 500, 2147483647)) // setTimeout max ~24 days
  }

  // ---------- Actions (root / planner; the database checks the role) ----------
  async function call(fnName, params) {
    const { data, error } = await supabase.rpc(fnName, { p_event_id: eventId, ...params })
    await load()
    if (error) throw new Error(error.message)
    return data
  }
  const startEvent = () => call('start_event')
  const scheduleStart = (date) => call('schedule_event_start', { p_starts_at: new Date(date).toISOString() })
  const cancelSchedule = () => call('cancel_scheduled_start')
  const endEvent = () => call('end_event') // returns how many people were stopped

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

  // Coming back to a phone/tab that was asleep: timers may not have fired
  function onVisible() {
    if (!document.hidden) load()
  }
  document.addEventListener('visibilitychange', onVisible)

  onUnmounted(() => {
    clearTimeout(startTimer)
    clearTimeout(reloadTimer)
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
    load,
    startEvent,
    scheduleStart,
    cancelSchedule,
    endEvent,
  }
}
