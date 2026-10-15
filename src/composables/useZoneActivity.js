// useZoneActivity - what the server knows about zones during the live session (merger Stage 2, migration 021).
//
// The server works it out on every location reading (trigger on public.locations); this only reads it:
//   - who is inside which zone right now, and since when   (zone_presence, open stays)
//   - one position per group: midpoint, speed, ICs sharing  (group_positions)
//   - No-Go entries                                         (zone_alerts, one per entry)
// RLS decides what each person sees (ops roles: everything; others: their own group; an alert also reaches
// the IC who caused it). Realtime keeps it current; a reconnect or a new session reloads it.
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export function useZoneActivity(eventId, sessionId, { onAlert } = {}) {
  const zones = ref({}) // zone id -> { id, code, name, kind }
  const stays = ref([]) // open stays: { id, zoneId, userId, groupId, enteredAt: Date }
  const groupPositions = ref({}) // group id -> { lat, lng, speedMps, icsSharing, lastSeen: Date }
  let channel = null

  async function loadZones() {
    if (!supabase) return
    const { data, error } = await supabase.rpc('event_zones', { p_event: eventId })
    if (error) return
    const next = {}
    for (const z of data || []) next[z.id] = { id: z.id, code: z.code, name: z.name, kind: z.kind }
    zones.value = next
  }

  async function loadSession() {
    const sid = sessionId.value
    if (!supabase || !sid) {
      stays.value = []
      groupPositions.value = {}
      return
    }
    const [presence, positions] = await Promise.all([
      supabase
        .from('zone_presence')
        .select('id, zone_id, user_id, group_id, entered_at')
        .eq('session_id', sid)
        .is('exited_at', null),
      supabase
        .from('group_positions')
        .select('group_id, lat, lng, speed_mps, ics_sharing, last_seen')
        .eq('session_id', sid),
    ])
    if (sid !== sessionId.value) return // the session changed while loading
    if (!presence.error) {
      stays.value = (presence.data || []).map((p) => ({
        id: p.id,
        zoneId: p.zone_id,
        userId: p.user_id,
        groupId: p.group_id,
        enteredAt: new Date(p.entered_at),
      }))
    }
    if (!positions.error) {
      const next = {}
      for (const row of positions.data || []) next[row.group_id] = toPosition(row)
      groupPositions.value = next
    }
  }

  function toPosition(row) {
    return {
      lat: row.lat,
      lng: row.lng,
      speedMps: row.speed_mps,
      icsSharing: row.ics_sharing,
      lastSeen: row.last_seen ? new Date(row.last_seen) : null,
    }
  }

  // One reload per burst, per KIND of reload. It used to be one timer for both, each change cancelling the
  // other's pending reload: a zone edit followed within 300 ms by a presence change (constant during a
  // simulator run) was never shown. And it starts at the FIRST change of a burst rather than restarting at
  // every one, so a steady stream of changes cannot put the reload off forever.
  const reloadTimers = new Map()
  function reloadSoon(fn) {
    if (reloadTimers.has(fn)) return
    reloadTimers.set(
      fn,
      setTimeout(() => {
        reloadTimers.delete(fn)
        fn()
      }, 300),
    )
  }

  // Every group's position changes on every tick (120 groups -> 120 messages at once). Copying the whole
  // set per message re-ran everything built on it 120 times; they are applied together instead.
  const queuedPositions = new Map()
  let positionsTimer = null
  function queueGroupPosition(row) {
    queuedPositions.set(row.group_id, toPosition(row))
    if (positionsTimer) return
    positionsTimer = setTimeout(() => {
      positionsTimer = null
      const next = { ...groupPositions.value }
      for (const [groupId, position] of queuedPositions) next[groupId] = position
      queuedPositions.clear()
      groupPositions.value = next
    }, 400)
  }

  function subscribe() {
    if (!supabase || channel) return
    const filter = 'event_id=eq.' + eventId
    channel = supabase
      .channel('zone-activity-' + eventId + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'zone_presence', filter }, () => reloadSoon(loadSession))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'zones', filter }, () => reloadSoon(loadZones))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'group_positions', filter }, (payload) => {
        const row = payload.new
        if (!row || row.session_id !== sessionId.value) return
        queueGroupPosition(row)
      })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'zone_alerts', filter }, (payload) => {
        const row = payload.new
        if (!row || row.session_id !== sessionId.value || !onAlert) return
        onAlert({
          id: row.id,
          kind: row.kind,
          zone: zones.value[row.zone_id] || null,
          userId: row.user_id,
          groupId: row.group_id,
          at: new Date(row.at),
        })
      })
      .subscribe((status) => {
        // (Re)joined: anything missed while disconnected is read again
        if (status === 'SUBSCRIBED') {
          loadZones()
          loadSession()
        }
      })
  }

  watch(sessionId, loadSession)
  subscribe()

  onUnmounted(() => {
    clearTimeout(positionsTimer)
    for (const timer of reloadTimers.values()) clearTimeout(timer)
    reloadTimers.clear()
    if (channel && supabase) supabase.removeChannel(channel)
    channel = null
  })

  // userId -> [{ zone, enteredAt }]: "Inside Formation 1 since 18:03:41"
  const staysByUser = computed(() => {
    const out = {}
    for (const s of stays.value) {
      const zone = zones.value[s.zoneId]
      if (!zone) continue
      ;(out[s.userId] = out[s.userId] || []).push({ zone, enteredAt: s.enteredAt })
    }
    return out
  })

  // zone id -> { ics, groups }: "2 ICs · 1 group inside"
  const countsByZone = computed(() => {
    const out = {}
    for (const s of stays.value) {
      const c = (out[s.zoneId] = out[s.zoneId] || { ics: 0, groupIds: new Set() })
      c.ics++
      if (s.groupId) c.groupIds.add(s.groupId)
    }
    const result = {}
    for (const [id, c] of Object.entries(out)) result[id] = { ics: c.ics, groups: c.groupIds.size }
    return result
  })

  // No-Go zones somebody is inside right now (highlighted on the map)
  const noGoOccupied = computed(() =>
    Object.keys(countsByZone.value).filter((id) => zones.value[id] && zones.value[id].kind === 'no_go'),
  )

  return { zones, stays, groupPositions, staysByUser, countsByZone, noGoOccupied, reload: loadSession }
}
