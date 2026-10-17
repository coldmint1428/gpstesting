// useShow - the live show of a session (merger Stage 6, 026_live_show.sql): the board, the server clock and the
// buttons. The engine runs on the server (every 2 s); this page only reads the board, counts down with the
// server's clock, and sends GO / Hold / Resume / +30 s / Skip.
//
//   const show = useShow(sessionIdRef, { onLog })
//   show.board      { state, delay_s, anchor, cues: [...], log: [...] } or null (no run sheet / not live)
//   show.now        Date.now() on the server's clock, ticking 4x a second
//   show.go(cueId), hold(), resume(), addTime(s), skip(cueId)  -> resolve to an error message or ''
//   onLog(entry)    every new log line after the first load (for toasts)
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

const ALERT_KINDS = ['waiting_go', 'waiting_groups', 'anchor_risk', 'anchor_cut', 'finished']

export function useShow(sessionIdRef, { onLog } = {}) {
  const board = ref(null)
  const loading = ref(false)
  const errorMsg = ref('')
  const busy = ref('') // the action being sent
  const offset = ref(0) // server - this device, in ms
  const now = ref(Date.now())
  let lastLogId = null
  let channel = null
  let reloadTimer = null
  let pollTimer = null
  let seq = 0

  // ---------- Server clock: offset = server - (sent + received) / 2 ----------
  async function syncClock() {
    const t0 = Date.now()
    const { data, error } = await supabase.rpc('server_now')
    const t1 = Date.now()
    if (error || !data) return
    offset.value = new Date(data).getTime() - (t0 + t1) / 2
  }
  const clock = setInterval(() => (now.value = Date.now() + offset.value), 250)

  async function load() {
    const id = sessionIdRef.value
    if (!id) {
      board.value = null
      return
    }
    const mine = ++seq
    loading.value = true
    const { data, error } = await supabase.rpc('show_board', { p_session: id })
    if (mine !== seq) return
    loading.value = false
    if (error) {
      errorMsg.value = error.message
      return
    }
    errorMsg.value = ''
    board.value = data && data.state !== 'none' ? data : null
    // New log lines since the last load -> toasts (not on the first load: that is history)
    const log = (data && data.log) || []
    if (lastLogId !== null && onLog) {
      for (const entry of [...log].reverse()) if (entry.id > lastLogId) onLog(entry, ALERT_KINDS.includes(entry.kind))
    }
    if (log.length) lastLogId = Math.max(lastLogId || 0, ...log.map((l) => l.id))
    else if (lastLogId === null) lastLogId = 0
  }
  function reloadSoon() {
    clearTimeout(reloadTimer)
    reloadTimer = setTimeout(load, 250)
  }

  function subscribe(id) {
    if (channel) supabase.removeChannel(channel)
    channel = null
    if (!id) return
    channel = supabase
      .channel('show-' + id + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'show_cues', filter: 'session_id=eq.' + id }, reloadSoon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'show_state', filter: 'session_id=eq.' + id }, reloadSoon)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'show_log', filter: 'session_id=eq.' + id }, reloadSoon)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }

  watch(
    sessionIdRef,
    (id) => {
      board.value = null
      lastLogId = null
      subscribe(id)
      load()
      if (id) syncClock()
    },
    { immediate: true },
  )
  // Waiting cues slide with time and Realtime can miss a message: read the board again every 5 s anyway
  pollTimer = setInterval(() => {
    if (sessionIdRef.value && !document.hidden) load()
  }, 5000)
  const clockTimer = setInterval(syncClock, 60000)
  function onVisible() {
    if (!document.hidden && sessionIdRef.value) {
      syncClock()
      load()
    }
  }
  document.addEventListener('visibilitychange', onVisible)

  onUnmounted(() => {
    clearInterval(clock)
    clearInterval(pollTimer)
    clearInterval(clockTimer)
    clearTimeout(reloadTimer)
    document.removeEventListener('visibilitychange', onVisible)
    if (channel) supabase.removeChannel(channel)
  })

  // ---------- What is where ----------
  const cues = computed(() => (board.value ? board.value.cues || [] : []))
  const running = computed(() => cues.value.find((c) => c.status === 'running') || null)
  const next = computed(() => cues.value.find((c) => c.status === 'pending') || null)
  const upcoming = computed(() => cues.value.filter((c) => c.status === 'pending'))
  const finished = computed(() => cues.value.filter((c) => c.status === 'done' || c.status === 'skipped'))

  // ---------- Buttons (root / planners; the server checks) ----------
  async function act(name, fn, args) {
    busy.value = name
    const { error } = await supabase.rpc(fn, { p_session: sessionIdRef.value, ...args })
    busy.value = ''
    await load()
    return error ? error.message : ''
  }
  const go = (cueId) => act('go', 'show_go', { p_cue: cueId })
  const hold = () => act('hold', 'show_hold', {})
  const resume = () => act('resume', 'show_resume', {})
  const addTime = (seconds) => act('add', 'show_add_time', { p_seconds: seconds })
  const skip = (cueId) => act('skip', 'show_skip', { p_cue: cueId })

  return { board, cues, running, next, upcoming, finished, now, offset, loading, errorMsg, busy, load, go, hold, resume, addTime, skip }
}

// ---------- Formatting ----------
const z2 = (n) => String(n).padStart(2, '0')
// seconds -> "1:05" / "1:02:05"; negative -> "-1:05"
export function mmss(seconds) {
  const neg = seconds < 0
  const s = Math.abs(Math.round(seconds))
  const h = Math.floor(s / 3600)
  const body = h ? h + ':' + z2(Math.floor((s % 3600) / 60)) + ':' + z2(s % 60) : Math.floor(s / 60) + ':' + z2(s % 60)
  return (neg ? '-' : '') + body
}
// a moment -> "18:04:12" in Singapore time (the show's clock)
export function sgClock(at) {
  if (!at) return ''
  return new Date(at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false, timeZone: 'Asia/Singapore' })
}
