// useMyMoves - my group's movements in the live show (merger Stage 8, 028_ic_moves.sql: my_moves): where we must
// be, by when (as projected: it moves with the show's delay), when to leave, our ETA and status, worked out on the
// server every 5 s. Read every 5 s while the page is visible; the clock counts with the server's time.
//
//   const moves = useMyMoves(sessionIdRef, enabledRef)
//   moves.next     the group's current movement (or null)      moves.after   the ones after it
//   moves.now      the server's clock (ms), ticking each second  moves.reportDelay(note) -> '' or an error message
//   moves.radio    the group's radio channel / call sign (029)   moves.canReport  IC or admin: may say "in position"
//   moves.isIc     this person is one of the group's ICs         moves.heldSince  the show is on hold since (or null)
//   moves.inPosition(undo) -> '' or an error message: "We're in position" (counts at once; undo within 5 min)
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export function useMyMoves(sessionIdRef, enabledRef) {
  const rows = ref([])
  const groupId = ref(null)
  const radio = ref(null)
  const canReport = ref(false)
  const isIc = ref(false)
  const heldSince = ref(null)
  const loaded = ref(false)
  const errorMsg = ref('')
  const offset = ref(0) // server - this device
  const now = ref(Date.now())
  let seq = 0

  async function load() {
    const id = sessionIdRef.value
    if (!id || !enabledRef.value) {
      rows.value = []
      loaded.value = false
      return
    }
    const mine = ++seq
    const t0 = Date.now()
    const { data, error } = await supabase.rpc('my_moves', { p_session: id })
    if (mine !== seq) return
    if (error) {
      errorMsg.value = error.message
      return
    }
    errorMsg.value = ''
    offset.value = new Date(data.server_now).getTime() - (t0 + Date.now()) / 2
    groupId.value = data.group_id
    radio.value = data.radio || null
    canReport.value = !!data.can_report
    isIc.value = !!data.is_ic
    heldSince.value = data.held_since || null
    rows.value = data.rows || []
    loaded.value = true
  }

  watch([sessionIdRef, enabledRef], load, { immediate: true })
  const poll = setInterval(() => {
    if (!document.hidden) load()
  }, 5000)
  const clock = setInterval(() => (now.value = Date.now() + offset.value), 1000)
  function onVisible() {
    if (!document.hidden) load()
  }
  document.addEventListener('visibilitychange', onVisible)
  onUnmounted(() => {
    clearInterval(poll)
    clearInterval(clock)
    document.removeEventListener('visibilitychange', onVisible)
  })

  const next = computed(() => rows.value.find((r) => r.state === 'active') || null)
  const after = computed(() => rows.value.filter((r) => r.state === 'waiting'))
  const done = computed(() => rows.value.filter((r) => r.state === 'done'))

  // "Tell planner: delayed" on the current movement
  const busy = ref(false)
  async function reportDelay(note) {
    const r = next.value
    if (!r) return 'There is no movement to report on.'
    busy.value = true
    const { error } = await supabase.rpc('report_delay', {
      p_session: sessionIdRef.value,
      p_movement: r.movement_id,
      p_group: groupId.value,
      p_note: note || null,
    })
    busy.value = false
    await load()
    return error ? error.message : ''
  }

  // "We're in position" (the group's IC or admin): the arrival counts at once, without waiting for GPS
  const lastReported = computed(() =>
    rows.value
      .filter((r) => r.state === 'done' && r.basis === 'reported' && r.arrived_at && now.value - new Date(r.arrived_at).getTime() < 300000)
      .sort((a, b) => new Date(b.arrived_at) - new Date(a.arrived_at))[0] || null,
  )
  async function inPosition(undo = false) {
    const r = undo ? lastReported.value : next.value
    if (!r) return 'There is no movement to report on.'
    busy.value = true
    const { error } = await supabase.rpc('mark_in_position', {
      p_session: sessionIdRef.value,
      p_movement: r.movement_id,
      p_group: groupId.value,
      p_undo: undo,
    })
    busy.value = false
    await load()
    return error ? error.message : ''
  }

  return {
    rows, next, after, done, now, loaded, errorMsg, busy, load, reportDelay,
    radio, canReport, isIc, heldSince, lastReported, inPosition,
  }
}
