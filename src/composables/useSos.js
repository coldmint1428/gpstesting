// useSos - SOS in an event (038_sos.sql). Anyone in the event can call for help; everyone in it sees the SOS on the map
// and as a banner, and gets a phone notification.
//
//   alerts   active SOSs in the event, oldest first:
//            [{ id, userId, groupId, note, lat, lng, accuracy, locatedAt: Date | null, raisedAt: Date, helpers: [{ userId, name }] }]
//   mine     my active SOS, or null
//   gps      while my SOS is active: 'waiting' (no location yet) | 'on' (sending) | 'off' (refused or not available)
//   raise(note) -> '' or an error message. Turns on GPS, waits up to 5 s for a first location, then sends.
//   help(id), resolve(id) -> '' or an error message
//
// While my SOS is active this page keeps sending my location (at most every 10 s) until it ends.
//
// Beyond the course (CLAUDE.md asks for Axios + an Express REST API): this project's backend is Supabase, so these call
// its database functions with supabase.rpc and listen for changes with Supabase Realtime. The location comes from the
// browser's navigator.geolocation (also used inside the phone app), which has no Vue equivalent.
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

const SEND_EVERY_MS = 10000
const FIRST_FIX_MS = 5000

export function useSos(eventIdRef, { myUserIdRef, onNew } = {}) {
  const alerts = ref([])
  const busy = ref(false)
  const gps = ref('waiting')
  let loaded = false

  const mine = computed(() => {
    const uid = myUserIdRef ? myUserIdRef.value : null
    return alerts.value.find((a) => a.userId === uid) || null
  })

  async function load() {
    const eid = eventIdRef.value
    if (!eid) {
      alerts.value = []
      return
    }
    try {
      const { data, error } = await supabase
        .from('sos_alerts')
        .select('id, user_id, group_id, note, lat, lng, accuracy, located_at, raised_at, helpers')
        .eq('event_id', eid)
        .is('resolved_at', null)
        .order('raised_at')
      if (error) throw error
      if (eid !== eventIdRef.value) return
      const before = new Set(alerts.value.map((a) => a.id))
      const hadLoaded = loaded
      alerts.value = data.map((a) => ({
        id: a.id,
        userId: a.user_id,
        groupId: a.group_id,
        note: a.note,
        lat: a.lat,
        lng: a.lng,
        accuracy: a.accuracy,
        locatedAt: a.located_at ? new Date(a.located_at) : null,
        raisedAt: new Date(a.raised_at),
        helpers: (a.helpers || []).map((h) => ({ userId: h.user_id, name: h.name })),
      }))
      loaded = true
      // Someone else's new SOS (not on the first load): tell the page
      const uid = myUserIdRef ? myUserIdRef.value : null
      if (hadLoaded && onNew) {
        for (const a of alerts.value) if (!before.has(a.id) && a.userId !== uid) onNew(a)
      }
    } catch (error) {
      console.log(error.message)
    }
  }

  // ---------- My location while my SOS is active ----------
  let watchId = null
  let lastSent = 0
  let latest = null // the newest position not sent yet

  function startGps() {
    if (watchId !== null) return
    if (!navigator.geolocation) {
      gps.value = 'off'
      return
    }
    gps.value = 'waiting'
    watchId = navigator.geolocation.watchPosition(
      (position) => {
        gps.value = 'on'
        latest = { lat: position.coords.latitude, lng: position.coords.longitude, accuracy: position.coords.accuracy }
        sendLatest()
      },
      (error) => {
        console.log(error.message)
        if (gps.value !== 'on') gps.value = 'off'
      },
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 30000 },
    )
  }
  function stopGps() {
    if (watchId !== null && navigator.geolocation) navigator.geolocation.clearWatch(watchId)
    watchId = null
    latest = null
  }
  async function sendLatest() {
    if (!latest || !mine.value || Date.now() - lastSent < SEND_EVERY_MS) return
    const p = latest
    latest = null
    lastSent = Date.now()
    try {
      const { error } = await supabase.rpc('update_sos_location', { p_id: mine.value.id, p_lat: p.lat, p_lng: p.lng, p_accuracy: p.accuracy })
      if (error) throw error
    } catch (error) {
      console.log(error.message)
    }
  }
  // A position held back by the 10 s limit is sent when the limit is up
  const sender = setInterval(sendLatest, 2000)

  // My SOS is active (sent here, or still active after a reload): GPS on; ended: GPS off
  watch(
    () => (mine.value ? mine.value.id : null),
    (id) => (id ? startGps() : stopGps()),
  )

  // The first location: up to 5 s (an SOS must not wait long), else null
  function firstFix() {
    return new Promise((resolve) => {
      if (!navigator.geolocation) {
        resolve(null)
        return
      }
      navigator.geolocation.getCurrentPosition(
        (position) => resolve({ lat: position.coords.latitude, lng: position.coords.longitude, accuracy: position.coords.accuracy }),
        () => resolve(null),
        { enableHighAccuracy: true, maximumAge: 10000, timeout: FIRST_FIX_MS },
      )
    })
  }

  async function raise(note) {
    busy.value = true
    try {
      const p = await firstFix()
      const { error } = await supabase.rpc('raise_sos', {
        p_event: eventIdRef.value,
        p_lat: p ? p.lat : null,
        p_lng: p ? p.lng : null,
        p_accuracy: p ? p.accuracy : null,
        p_note: note || null,
      })
      if (error) throw error
      if (p) {
        gps.value = 'on'
        lastSent = Date.now()
      }
      await load()
      return ''
    } catch (error) {
      return error.message
    } finally {
      busy.value = false
    }
  }

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
  const help = (id) => call('help_sos', { p_id: id })
  const resolve = (id) => call('resolve_sos', { p_id: id })

  // ---------- Live: an SOS sent, moved, helped or ended ----------
  let channel = null
  let reloadTimer = null
  function reloadSoon() {
    clearTimeout(reloadTimer)
    reloadTimer = setTimeout(load, 200)
  }
  function subscribe() {
    if (channel) supabase.removeChannel(channel)
    channel = null
    loaded = false
    const eid = eventIdRef.value
    if (!eid) return
    channel = supabase
      .channel('sos-' + eid + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sos_alerts', filter: 'event_id=eq.' + eid }, reloadSoon)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }
  watch(eventIdRef, subscribe, { immediate: true })

  onUnmounted(() => {
    stopGps()
    clearInterval(sender)
    clearTimeout(reloadTimer)
    if (channel) supabase.removeChannel(channel)
  })

  return { alerts, mine, gps, busy, load, raise, help, resolve }
}
