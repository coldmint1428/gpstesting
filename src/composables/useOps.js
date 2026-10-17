// useOps - the groups' movements during the live show (merger Stage 7, 027_movements.sql): the server works out every
// group's deadline, ETA and status every 5 s; this reads them (ops_board), filters them, and sends the queue buttons.
//
//   const ops = useOps(sessionIdRef, { groups, zones, me })
//   ops.rows        every movement row of the show (one per group and movement)
//   ops.active      groupId -> the group's active movement row (what the map and the summary bar show)
//   ops.counts      { total, on_track, at_risk, late, no_signal }   (filtered by everything but the status filter)
//   ops.filters     { status, search, category, sector, zone, mine }  (the summary bar sets them)
//   ops.visibleGroupIds  Set of groups that pass the filters, or null when nothing is filtered (the map)
//   ops.queue       problems, most urgent first (acknowledged and snoozed ones left out)
//   ops.handle / ack / snooze / message / keepHolding
//
// Movement rows change on every tick for groups on the move, so they are read every 4 s while the page is visible
// (not through Realtime: one message per group per tick would use up the Realtime quota at 100+ groups).
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { LIVE_STATUSES, PROBLEMS, statusOf, urgency } from '../utils/opsStatus'

export function useOps(sessionIdRef, { groups, zones, myUserId }) {
  const rows = ref([])
  const mySector = ref(null)
  const errorMsg = ref('')
  const busy = ref('')
  const loaded = ref(false)
  const now = ref(Date.now())
  let pollTimer = null
  let seq = 0

  const filters = ref({ status: '', search: '', category: '', sector: '', zone: '', mine: false })
  let sectorApplied = false

  // Rows by movement + group. After the first full read only the rows changed since the last read come (a full read
  // again every minute, and when the show switches to another version, whose rows replace these).
  let byKey = new Map()
  let asOf = null
  let sheetId = null
  let lastFull = 0
  const keyOf = (r) => r.movement_id + '|' + r.group_id

  async function load(full = false) {
    const id = sessionIdRef.value
    if (!id) {
      rows.value = []
      byKey = new Map()
      asOf = null
      loaded.value = false
      return
    }
    const since = !full && asOf && Date.now() - lastFull < 60000 ? asOf : null
    const mine = ++seq
    const { data, error } = await supabase.rpc('ops_board', { p_session: id, p_since: since })
    if (mine !== seq) return
    if (error) {
      errorMsg.value = error.message
      return
    }
    errorMsg.value = ''
    if (!data.full && data.run_sheet_id !== sheetId) return load(true)
    const next = data.full ? new Map() : new Map(byKey)
    for (const r of data.rows || []) {
      // a group's route is only sent when it is new: keep the one already here
      const old = next.get(keyOf(r))
      if (r.route === undefined && r.route_at && old && old.route_at === r.route_at) r.route = old.route
      next.set(keyOf(r), r)
    }
    byKey = next
    asOf = data.as_of
    sheetId = data.run_sheet_id
    if (data.full) lastFull = Date.now()
    rows.value = [...next.values()].sort(
      (a, b) => (a.group_id < b.group_id ? -1 : a.group_id > b.group_id ? 1 : new Date(a.planned_deadline || 0) - new Date(b.planned_deadline || 0)),
    )
    mySector.value = data.my_sector || null
    // A marshal's view opens on their sector (once: they may clear it)
    if (mySector.value && !sectorApplied) {
      filters.value.sector = mySector.value
      sectorApplied = true
    }
    loaded.value = true
    now.value = Date.now()
  }

  watch(
    sessionIdRef,
    () => {
      rows.value = []
      byKey = new Map()
      asOf = null
      loaded.value = false
      load(true)
    },
    { immediate: true },
  )
  pollTimer = setInterval(() => {
    if (sessionIdRef.value && !document.hidden) load()
  }, 4000)
  function onVisible() {
    if (!document.hidden && sessionIdRef.value) load(true)
  }
  document.addEventListener('visibilitychange', onVisible)
  onUnmounted(() => {
    clearInterval(pollTimer)
    document.removeEventListener('visibilitychange', onVisible)
  })

  // ---------- Lookups ----------
  const groupById = computed(() => new Map((groups.value || []).map((g) => [g.id, g])))
  const zoneById = computed(() => zones.value || {})
  const groupOf = (id) => groupById.value.get(id) || null
  const zoneOf = (id) => zoneById.value[id] || null

  // groupId -> the movement the group is on now (or, when all are done, its last one). Rows come by group and planned
  // deadline.
  const active = computed(() => {
    const out = {}
    for (const r of rows.value) {
      const cur = out[r.group_id]
      if (!cur || (cur.state !== 'active' && (r.state === 'active' || r.state === 'done'))) out[r.group_id] = r
    }
    return out
  })

  // ---------- Filters (everything but the status: the summary bar's counts use these) ----------
  function passes(row, withStatus) {
    const f = filters.value
    const g = groupOf(row.group_id)
    if (f.category && (g ? g.category || '' : '') !== f.category) return false
    if (f.sector && (g ? g.sector || '' : '') !== f.sector) return false
    if (f.zone && row.zone_id !== f.zone) return false
    if (f.mine && !row.handled_mine) return false
    if (f.search) {
      const q = f.search.trim().toLowerCase()
      const z = zoneOf(row.zone_id)
      const text = [g && g.name, g && g.code, row.code, z && z.code, z && z.name].filter(Boolean).join(' ').toLowerCase()
      if (q && !text.includes(q)) return false
    }
    if (withStatus && f.status && row.status !== f.status) return false
    return true
  }

  const counts = computed(() => {
    const c = { total: 0, on_track: 0, at_risk: 0, late: 0, no_signal: 0, done: 0 }
    for (const r of Object.values(active.value)) {
      if (!passes(r, false)) continue
      c.total++
      if (LIVE_STATUSES.includes(r.status)) c[r.status]++
      else c.done++
    }
    return c
  })

  const filtering = computed(() => {
    const f = filters.value
    return !!(f.status || f.search.trim() || f.category || f.sector || f.zone || f.mine)
  })
  const visibleGroupIds = computed(() => {
    if (!filtering.value) return null
    const out = new Set()
    for (const r of Object.values(active.value)) if (passes(r, true)) out.add(r.group_id)
    return out
  })

  // Problems, most urgent first: not acknowledged at this status (or a better one), not snoozed
  const queue = computed(() => {
    const t = now.value
    return Object.values(active.value)
      .filter((r) => r.state === 'active' && PROBLEMS.includes(r.status) && passes(r, true))
      .filter((r) => !(r.acked_status && statusOf(r.acked_status).rank >= statusOf(r.status).rank))
      .filter((r) => !(r.snoozed_until && new Date(r.snoozed_until).getTime() > t))
      .sort(urgency)
  })
  const hidden = computed(
    () => Object.values(active.value).filter((r) => r.state === 'active' && PROBLEMS.includes(r.status) && passes(r, true)).length - queue.value.length,
  )

  // Filter choices from the groups in the show
  const choices = computed(() => {
    const cats = new Set()
    const sectors = new Set()
    const zoneIds = new Set()
    for (const r of rows.value) {
      const g = groupOf(r.group_id)
      if (g && g.category) cats.add(g.category)
      if (g && g.sector) sectors.add(g.sector)
      if (r.zone_id) zoneIds.add(r.zone_id)
    }
    if (mySector.value) sectors.add(mySector.value)
    return {
      categories: [...cats].sort(),
      sectors: [...sectors].sort(),
      zones: [...zoneIds].map((id) => zoneOf(id)).filter(Boolean).sort((a, b) => a.code.localeCompare(b.code)),
    }
  })
  const myCount = computed(() => rows.value.filter((r) => r.handled_mine && r.state === 'active').length)

  // ---------- Buttons ----------
  async function act(name, fn, args, okText) {
    busy.value = name
    const { data, error } = await supabase.rpc(fn, { p_session: sessionIdRef.value, ...args })
    busy.value = ''
    await load()
    return error ? { error: error.message } : { data, ok: okText }
  }
  const handle = (r) => act('handle', 'ops_handle', { p_movement: r.movement_id, p_group: r.group_id })
  const ack = (r) => act('ack', 'ops_ack', { p_movement: r.movement_id, p_group: r.group_id })
  const snooze = (r, seconds = 120) => act('snooze', 'ops_snooze', { p_movement: r.movement_id, p_group: r.group_id, p_seconds: seconds })
  const message = (groupId, body) => act('message', 'message_group', { p_group: groupId, p_body: body })
  const keepHolding = (cueId) => act('hold', 'show_keep_holding', { p_cue: cueId })

  return {
    rows, active, counts, filters, filtering, visibleGroupIds, queue, hidden, choices, mySector, myCount, loaded, errorMsg, busy,
    groupOf, zoneOf, load, handle, ack, snooze, message, keepHolding, myUserId,
  }
}
