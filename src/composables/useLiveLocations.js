// useLiveLocations - the latest position of every person I'm allowed to see in one event.
// 1. Load the latest reading per person (database function latest_locations).
// 2. Subscribe to Supabase Realtime: every new row in "locations" for this event moves a marker.
// RLS decides WHO I see (root/planner/marshal: everyone; others: own group only),
// for both the first load and the realtime updates.
import { ref, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export function useLiveLocations(eventId) {
  const positions = ref({}) // { userId: { userId, groupId, lat, lng, accuracy, source, time } }
  const errorMsg = ref('')
  const now = ref(Date.now()) // ticks so "last seen" texts and stale colours update

  function apply(row) {
    const time = new Date(row.recorded_at)
    const old = positions.value[row.user_id]
    if (old && old.time >= time) return // ignore older readings arriving late

    positions.value[row.user_id] = {
      userId: row.user_id,
      groupId: row.group_id,
      lat: row.lat,
      lng: row.lng,
      accuracy: row.accuracy,
      source: row.source, // 'gps' or 'stop' (pressed Stop sharing)
      time,
    }
  }

  async function load() {
    const { data, error } = await supabase.rpc('latest_locations', { p_event_id: eventId })
    if (error) {
      errorMsg.value = error.message
      return
    }
    data.forEach(apply)
  }

  const channel = supabase
    // Unique name per map (see useEventData.js: same-name channels are shared and would throw)
    .channel('event-locations-' + eventId + '-' + Math.random().toString(36).slice(2))
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'locations', filter: 'event_id=eq.' + eventId },
      (payload) => apply(payload.new),
    )
    .subscribe((status) => {
      // Re-load after (re)connecting so nothing sent while disconnected is missed
      if (status === 'SUBSCRIBED') load()
    })

  const timer = setInterval(() => (now.value = Date.now()), 15000)

  onUnmounted(() => {
    clearInterval(timer)
    supabase.removeChannel(channel)
  })

  return { positions, errorMsg, now, reload: load }
}
