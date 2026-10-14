// useLiveLocations - the latest position of every person I'm allowed to see in one event.
// 1. Load the latest reading per person (database function latest_locations).
// 2. Subscribe to Supabase Realtime: every new row in "locations" for this event moves a marker.
// 3. Stay in sync: browsers pause background tabs and drop the connection (phone screen off,
//    tab switched, Wi-Fi to 4G). When the page is shown again, the connection comes back or
//    a check every minute runs, we fetch what was missed and rebuild a dead channel. Network
//    errors show "Reconnecting..." and are retried; they are not shown as errors.
// RLS decides WHO I see (root/planner/marshal: everyone; others: own group only),
// for both the first load and the realtime updates.
import { ref, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

const CATCH_UP_LIMIT_MS = 3 * 60 * 1000 // missed longer than this: only the latest positions matter
const CHECK_EVERY_MS = 60 * 1000

// "Failed to fetch", timeouts, offline: worth retrying quietly
function isNetworkError(error) {
  const text = String((error && (error.message || error)) || '')
  return !navigator.onLine || /fetch|network|timed? ?out|load failed|abort/i.test(text)
}

export function useLiveLocations(eventId) {
  const positions = ref({}) // { userId: { userId, groupId, lat, lng, accuracy, source, time } }
  const errorMsg = ref('')
  const reconnecting = ref(false)
  const now = ref(Date.now()) // ticks so "last seen" texts and stale colours update
  const listeners = new Set() // functions called with every new row (e.g. the live map's tracks)
  let channel = null
  let lastRowAt = 0 // newest reading time we have (ms)
  let hiddenAt = 0
  let retryTimer = null
  let retryDelay = 2000
  let stopped = false

  // Subscribe to new readings: fn(row, live). live = false for readings fetched after a
  // pause (they arrived late, in a batch). Returns a function that unsubscribes.
  function onReading(fn) {
    listeners.add(fn)
    return () => listeners.delete(fn)
  }

  function apply(row) {
    const time = new Date(row.recorded_at)
    if (time.getTime() > lastRowAt) lastRowAt = time.getTime()
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

  function receive(row, live) {
    apply(row)
    for (const fn of listeners) fn(row, live)
  }

  function failed(error) {
    if (stopped) return
    if (isNetworkError(error)) {
      reconnecting.value = true
      errorMsg.value = ''
    } else {
      errorMsg.value = error.message || String(error)
    }
    // Try again soon (2 s, 4 s, ... up to 30 s)
    clearTimeout(retryTimer)
    retryTimer = setTimeout(sync, retryDelay)
    retryDelay = Math.min(retryDelay * 2, 30000)
  }

  function succeeded() {
    errorMsg.value = ''
    reconnecting.value = false
    retryDelay = 2000
    clearTimeout(retryTimer)
  }

  async function load() {
    const { data, error } = await supabase.rpc('latest_locations', { p_event_id: eventId })
    if (error) throw error
    data.forEach((row) => receive(row, false))
  }

  // Every reading since `since` (ms), oldest first, so the map can replay what it missed
  async function loadSince(since) {
    for (let from = 0; from < 5000; from += 1000) {
      const { data, error } = await supabase
        .from('locations')
        .select('user_id, group_id, lat, lng, accuracy, source, recorded_at')
        .eq('event_id', eventId)
        .gt('recorded_at', new Date(since).toISOString())
        .order('recorded_at')
        .range(from, from + 999)
      if (error) throw error
      data.forEach((row) => receive(row, false))
      if (data.length < 1000) break
    }
  }

  // Fetch what was missed (recent readings, or just the latest positions after a long gap)
  let syncing = null
  function sync(catchUp = true) {
    if (syncing) return syncing
    syncing = (async () => {
      try {
        const since = lastRowAt - 30000
        if (catchUp && lastRowAt && Date.now() - since < CATCH_UP_LIMIT_MS) await loadSince(since)
        await load()
        succeeded()
      } catch (error) {
        failed(error)
      } finally {
        syncing = null
      }
    })()
    return syncing
  }

  function connect() {
    const old = channel
    channel = null
    if (old) supabase.removeChannel(old)
    const mine = supabase
      // Unique name per map (see useEventData.js: same-name channels are shared and would throw)
      .channel('event-locations-' + eventId + '-' + Math.random().toString(36).slice(2))
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'locations', filter: 'event_id=eq.' + eventId },
        (payload) => receive(payload.new, true),
      )
      .subscribe((status) => {
        if (stopped || mine !== channel) return // an old channel closing
        if (status === 'SUBSCRIBED') {
          sync() // (re)connected: fetch anything sent while disconnected
        } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
          reconnecting.value = true
          clearTimeout(retryTimer)
          retryTimer = setTimeout(connect, retryDelay)
          retryDelay = Math.min(retryDelay * 2, 30000)
        }
      })
    channel = mine
  }

  // Back on the page / back online: rebuild the channel if it died, then catch up
  function wake() {
    if (stopped || document.hidden) return
    now.value = Date.now()
    if (!channel || channel.state !== 'joined') connect()
    else sync()
  }
  function onVisibility() {
    if (document.hidden) hiddenAt = Date.now()
    else if (Date.now() - hiddenAt > 5000) wake()
  }

  connect()
  document.addEventListener('visibilitychange', onVisibility)
  window.addEventListener('online', wake)
  const timer = setInterval(() => (now.value = Date.now()), 15000)
  // Safety net: a channel can die silently; check every minute while the page is shown
  const checkTimer = setInterval(() => {
    if (document.hidden || stopped) return
    if (!channel || channel.state !== 'joined') connect()
    else sync(false) // latest positions only (cheap)
  }, CHECK_EVERY_MS)

  onUnmounted(() => {
    stopped = true
    clearInterval(timer)
    clearInterval(checkTimer)
    clearTimeout(retryTimer)
    document.removeEventListener('visibilitychange', onVisibility)
    window.removeEventListener('online', wake)
    if (channel) supabase.removeChannel(channel)
  })

  return { positions, errorMsg, reconnecting, now, reload: sync, onReading }
}
