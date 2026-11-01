// useAttendance - roll calls (037_attendance.sql), taken in the mode the organisers chose for the event:
//   manual  the group's IC ticks people present by hand
//   qr      the IC's screen shows a QR code that changes every 5 seconds and each person scans it in the app
//
//   mode       the event's mode: 'manual' | 'qr' (root / planners change it with setMode)
//   rollcalls  the roll calls I may see (staff: every group's; anyone else: my group's), newest first:
//              [{ id, groupId, title, mode, openedAt: Date, closesAt: Date, closedAt: Date | null, open }]
//   checkins   the check-ins I may see (staff and a group's ICs / admins: everyone's; anyone else: my own):
//              [{ rollcallId, userId, status: 'present' | 'excused', method: 'scan' | 'manual', at: Date }]
//   qr         the QR on screen: { rollcallId, text, secondsLeft } or null (showQr / hideQr)
//   now        Date.now(), every second (countdowns and roll calls closing by themselves)
//   open(groupId, title, minutes), close(id), mark(id, userId, status | null), setMode(mode) -> '' or an error message
//   scan(text) -> { ok, title } or { ok: false, message }   (text: what the camera read from the QR)
//
// Beyond the course (CLAUDE.md asks for Axios + an Express REST API): this project's backend is Supabase, so these call
// its database functions with supabase.rpc and listen for changes with Supabase Realtime.
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

// What the QR says: "PLANOVA-ATT|<roll call id>|<token>". The token changes every 5 s (the database makes it).
const QR_PREFIX = 'PLANOVA-ATT|'
export function parseAttendanceQr(text) {
  const parts = String(text || '').split('|')
  if (parts.length !== 3 || parts[0] + '|' !== QR_PREFIX) return null
  return { rollcallId: parts[1], token: parts[2] }
}

export function useAttendance(eventIdRef, { myUserIdRef, myGroupIdRef, onOpened } = {}) {
  const mode = ref('manual')
  const rawRollcalls = ref([])
  const checkins = ref([])
  const qr = ref(null)
  const now = ref(Date.now())
  const busy = ref(false)
  let loaded = false // the first load is done (a roll call that appears after it has just opened)

  // Open = not closed by hand and not past its time (it closes by itself on every screen when the time is up)
  const rollcalls = computed(() =>
    rawRollcalls.value.map((r) => ({ ...r, open: !r.closedAt && r.closesAt.getTime() > now.value })),
  )

  // My group's open roll call, and my check-in for it (for the banner and the Check in card)
  const myOpen = computed(() => {
    const gid = myGroupIdRef ? myGroupIdRef.value : null
    return gid ? rollcalls.value.find((r) => r.open && r.groupId === gid) || null : null
  })
  const myCheckin = computed(() => {
    const uid = myUserIdRef ? myUserIdRef.value : null
    return myOpen.value ? checkins.value.find((c) => c.rollcallId === myOpen.value.id && c.userId === uid) || null : null
  })

  async function load() {
    const eid = eventIdRef.value
    if (!eid) {
      rawRollcalls.value = []
      checkins.value = []
      return
    }
    try {
      const [ev, rc, ci] = await Promise.all([
        supabase.from('events').select('attendance_mode').eq('id', eid).maybeSingle(),
        supabase
          .from('attendance_rollcalls')
          .select('id, group_id, title, mode, opened_at, closes_at, closed_at')
          .eq('event_id', eid)
          .order('opened_at', { ascending: false })
          .limit(50),
        supabase.from('attendance_checkins').select('rollcall_id, user_id, status, method, at').eq('event_id', eid),
      ])
      for (const r of [ev, rc, ci]) if (r.error) throw r.error
      if (eid !== eventIdRef.value) return
      const before = new Set(rawRollcalls.value.map((r) => r.id))
      const hadLoaded = loaded
      mode.value = ev.data ? ev.data.attendance_mode : 'manual'
      rawRollcalls.value = rc.data.map((r) => ({
        id: r.id,
        groupId: r.group_id,
        title: r.title,
        mode: r.mode,
        openedAt: new Date(r.opened_at),
        closesAt: new Date(r.closes_at),
        closedAt: r.closed_at ? new Date(r.closed_at) : null,
      }))
      checkins.value = ci.data.map((c) => ({ rollcallId: c.rollcall_id, userId: c.user_id, status: c.status, method: c.method, at: new Date(c.at) }))
      loaded = true
      // A roll call just opened for my group (not on the first load): tell the page
      const mine = myOpen.value
      if (hadLoaded && mine && !before.has(mine.id) && !myCheckin.value && onOpened) onOpened(mine)
    } catch (error) {
      console.log(error.message)
    }
  }

  // ---------- The QR on screen (whoever runs a QR roll call) ----------
  let qrExpires = 0 // when the QR on screen changes (from the server's seconds_left, so a phone's clock does not matter)
  let qrFor = null
  async function fetchQr() {
    const id = qrFor
    if (!id) return
    try {
      const { data, error } = await supabase.rpc('rollcall_qr', { p_rollcall: id })
      if (error) throw error
      if (id !== qrFor) return
      qrExpires = Date.now() + data.seconds_left * 1000
      qr.value = { rollcallId: id, text: QR_PREFIX + id + '|' + data.token, secondsLeft: data.seconds_left }
    } catch (error) {
      console.log(error.message)
      if (id === qrFor) qr.value = null // closed, or no longer allowed
      qrFor = null
    }
  }
  function showQr(id) {
    if (qrFor === id) return
    qrFor = id
    qr.value = null
    fetchQr()
  }
  function hideQr() {
    qrFor = null
    qr.value = null
  }

  // Every second: the countdowns, and a new QR when the old one runs out
  const ticker = setInterval(() => {
    now.value = Date.now()
    if (!qr.value) return
    const left = Math.ceil((qrExpires - now.value) / 1000)
    if (left <= 0) fetchQr()
    else qr.value = { ...qr.value, secondsLeft: left }
  }, 1000)

  // ---------- Changes ----------
  async function call(fn, params) {
    busy.value = true
    try {
      const { error } = await supabase.rpc(fn, params)
      if (error) throw error
      await load()
      return ''
    } catch (error) {
      return error.message
    } finally {
      busy.value = false
    }
  }
  const open = (groupId, title, minutes) => call('open_rollcall', { p_group: groupId, p_title: title, p_minutes: minutes })
  const close = (id) => call('close_rollcall', { p_rollcall: id })
  const mark = (id, userId, status) => call('mark_attendance', { p_rollcall: id, p_user: userId, p_status: status })
  const setMode = (value) => call('set_attendance_mode', { p_event: eventIdRef.value, p_mode: value })

  async function scan(text) {
    const parsed = parseAttendanceQr(text)
    if (!parsed) return { ok: false, message: 'This is not an attendance QR code. Scan the code on your IC’s screen.' }
    busy.value = true
    try {
      const { data, error } = await supabase.rpc('scan_rollcall', { p_rollcall: parsed.rollcallId, p_token: parsed.token })
      if (error) throw error
      if (data.ok) await load()
      return data
    } catch (error) {
      return { ok: false, message: error.message }
    } finally {
      busy.value = false
    }
  }

  // ---------- Live: a roll call opened or closed, someone checked in, the mode changed ----------
  let channel = null
  let reloadTimer = null
  function reloadSoon() {
    clearTimeout(reloadTimer)
    reloadTimer = setTimeout(load, 300) // many check-ins at once = one reload
  }
  function subscribe() {
    if (channel) supabase.removeChannel(channel)
    channel = null
    loaded = false
    const eid = eventIdRef.value
    if (!eid) return
    channel = supabase
      .channel('attendance-' + eid + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance_rollcalls', filter: 'event_id=eq.' + eid }, reloadSoon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance_checkins', filter: 'event_id=eq.' + eid }, reloadSoon)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }
  watch(eventIdRef, subscribe, { immediate: true })
  // Moved to another group: their roll calls are the ones I may see now
  if (myGroupIdRef) watch(myGroupIdRef, () => load())

  onUnmounted(() => {
    clearInterval(ticker)
    clearTimeout(reloadTimer)
    if (channel) supabase.removeChannel(channel)
  })

  return { mode, rollcalls, checkins, qr, now, busy, myOpen, myCheckin, load, showQr, hideQr, open, close, mark, setMode, scan }
}
