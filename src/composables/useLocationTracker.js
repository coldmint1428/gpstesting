// useLocationTracker - the ONE place that knows how we get GPS.
//
// - Web (laptop browser, Vercel, graders): navigator.geolocation.watchPosition,
//   and we save readings with supabase-js (at most one insert every 5 s).
// - Native app (Capacitor on Android / iOS): Transistorsoft Background Geolocation.
//   Its native code keeps tracking when the phone is locked, and uploads each location
//   straight to Supabase over native HTTP - so it keeps working even while our
//   JavaScript is paused. Locations are queued on the phone if there is no network.
//
// Views use this composable and never import the plugin directly, so the web build
// keeps working and we can swap to another plugin later if licensing requires it.
//
// There is ONE tracker for the whole app (a singleton): sharing keeps running while the
// user moves between pages, and every page sees the same state. It only stops when the
// user presses Stop, logs out, or closes the app/tab.
//
// Libraries: @capacitor/core (MIT) - https://capacitorjs.com
//            @transistorsoft/capacitor-background-geolocation - https://docs.transistorsoft.com/capacitor/
//            (free in DEBUG builds; release builds need a paid licence key)
import { ref } from 'vue'
import { Capacitor } from '@capacitor/core'
import { supabase, supabaseUrl, supabaseAnonKey } from '../lib/supabase'

const MAX_READINGS = 20 // rows kept for the table
const SAVE_EVERY_MS = 5000 // web only: at most one insert every 5 s

// Load the Transistorsoft plugin only inside the app, so the web bundle never needs it
async function loadBackgroundPlugin() {
  const module = await import('@transistorsoft/capacitor-background-geolocation')
  return module.default
}

// Used on logout: stop native tracking, delete locations still queued on the phone and
// forget the login tokens - otherwise the phone keeps uploading as the previous user
// (it even restarts on boot).
export async function stopBackgroundTracking() {
  if (!Capacitor.isNativePlatform()) return
  await useLocationTracker().clearNative()
}

// Browser only: remember "I am sharing for event X" so sharing restarts by itself after a
// page refresh / reopened tab. Only pressing Stop (or logging out) forgets it.
// (The phone app doesn't need this: Transistorsoft keeps tracking natively.)
const SHARING_KEY = 'gps-sharing'

function rememberSharing(eventId, groupId) {
  try {
    localStorage.setItem(SHARING_KEY, JSON.stringify({ eventId, groupId }))
  } catch {
    // storage blocked (private mode): sharing still works until the page is refreshed
  }
}
function forgetSharing() {
  try {
    localStorage.removeItem(SHARING_KEY)
  } catch {
    // ignore
  }
}
function rememberedSharing() {
  try {
    return JSON.parse(localStorage.getItem(SHARING_KEY))
  } catch {
    return null
  }
}

let tracker = null

// Every page calls this and gets the same tracker
export function useLocationTracker() {
  if (!tracker) tracker = createTracker()
  return tracker
}

function createTracker() {
  const isNative = Capacitor.isNativePlatform() // true inside the Android/iOS app
  const dbEnabled = supabase !== null

  // ---------- Reactive state the page can show ----------
  const isTracking = ref(false)
  const current = ref(null) // latest reading { id, lat, lng, accuracy, time }
  const readings = ref([]) // newest first
  const errorMsg = ref('')
  const dbStatus = ref(dbEnabled ? 'Not started' : 'Off (no .env)')
  const savedCount = ref(0)
  const lastSavedAt = ref(null)
  const sharingEventId = ref(null) // which event I'm sharing for (null = not sharing)

  // ---------- Plain variables ----------
  let nextId = 1 // unique key for each table row
  let watchId = null // web: id from watchPosition
  let lastSentAt = 0 // web: time of the last insert (for throttling)
  let signedIn = false // web: only save after sign-in worked
  let ids = { eventId: null, groupId: null } // which event/group readings belong to
  let bg = null // native: the Transistorsoft plugin (loaded only inside the app)
  let authSub = null // native: supabase auth listener (to share refreshed tokens)

  // Add a reading to current + the table (used by both web and native)
  function addReading(lat, lng, accuracy, time) {
    const reading = { id: nextId++, lat, lng, accuracy, time }
    current.value = reading
    readings.value.unshift(reading)
    if (readings.value.length > MAX_READINGS) readings.value.pop()
  }

  // Saving needs the logged-in user's session (RLS checks they are this group's IC).
  // Returns the session, or null if nobody is logged in.
  async function ensureSignedIn() {
    const { data } = await supabase.auth.getSession()
    if (!data.session) dbStatus.value = 'Not signed in'
    return data.session
  }

  // ---------- Start / stop (what the page calls) ----------
  async function start(eventId, groupId) {
    if (isTracking.value && ids.eventId === eventId && ids.groupId === groupId) return // already sharing here
    if (isTracking.value) await stop() // sharing for another event/group: stop that first

    errorMsg.value = ''
    if (ids.eventId !== eventId) {
      // New event: start with an empty table
      readings.value = []
      current.value = null
      savedCount.value = 0
      lastSavedAt.value = null
    }
    ids = { eventId, groupId }
    sharingEventId.value = eventId
    if (!isNative) rememberSharing(eventId, groupId)
    isTracking.value = true

    let session = null
    if (dbEnabled) {
      dbStatus.value = 'Signing in...'
      session = await ensureSignedIn()
      if (session) dbStatus.value = 'Waiting for first reading'
    }

    // The user may have pressed Stop while we were signing in
    if (!isTracking.value) return

    if (isNative) await startNative(session)
    else startWeb(session)
  }

  // recordStop = false when the database already refused us (not IC any more)
  async function stop(recordStop = true) {
    const wasTracking = isTracking.value
    isTracking.value = false
    sharingEventId.value = null
    forgetSharing()
    if (isNative) {
      if (bg) {
        await ensureReady()
        await bg.stop()
      }
    } else if (watchId !== null) {
      navigator.geolocation.clearWatch(watchId)
      watchId = null
    }
    if (dbEnabled && savedCount.value > 0) dbStatus.value = 'Stopped'
    if (recordStop && wasTracking) await saveStopMarker()
  }

  // Save one "stop" row at my last position, so viewers see "Stopped sharing"
  // (on purpose) instead of a grey "lost contact" marker (phone died / no signal).
  async function saveStopMarker() {
    const last = current.value
    if (!dbEnabled || !last || !ids.eventId || !ids.groupId) return

    const { error } = await supabase.from('locations').insert({
      event_id: ids.eventId,
      group_id: ids.groupId,
      lat: last.lat,
      lng: last.lng,
      accuracy: last.accuracy,
      source: 'stop',
      recorded_at: new Date().toISOString(),
    })
    if (!error) dbStatus.value = 'Stopped (others see "Stopped sharing")'
  }

  // Called once when the app opens (App.vue).
  // Browser: restart sharing if it was on before a refresh (until the user presses Stop).
  // Phone app: Transistorsoft requires ready() on EVERY launch, even when not tracking.
  // If tracking is still running from before (app closed and reopened), show it again.
  async function resume(isLoggedIn) {
    if (!isNative) {
      // Browser: restart sharing that was on before a refresh / reopened tab
      const saved = rememberedSharing()
      if (saved && isLoggedIn) start(saved.eventId, saved.groupId)
      else forgetSharing()
      return
    }
    await ensureReady()
    const state = await bg.getState()
    if (state.enabled && !isLoggedIn) {
      await clearNative() // nobody is logged in: never keep uploading for an old login
      return
    }
    if (state.enabled) {
      // Tracking was started earlier: get the event/group back from its upload settings
      const params = state.http && state.http.params
      if (params) ids = { eventId: params.event_id, groupId: params.group_id }
      sharingEventId.value = ids.eventId
      isTracking.value = true
      dbStatus.value = 'Tracking in background'
    }
  }

  // ====================== WEB (browser) ======================
  function startWeb(session) {
    signedIn = session !== null

    // GPS only works on https pages (or localhost)
    if (!window.isSecureContext) {
      errorMsg.value = 'Location needs a secure (https) page. Open the https link instead.'
      isTracking.value = false
      sharingEventId.value = null
      forgetSharing()
      return
    }
    if (!('geolocation' in navigator)) {
      errorMsg.value = 'This browser does not support location.'
      isTracking.value = false
      sharingEventId.value = null
      forgetSharing()
      return
    }

    watchId = navigator.geolocation.watchPosition(onWebPosition, onWebError, {
      enableHighAccuracy: true, // use GPS, not just Wi-Fi/cell towers
      timeout: 15000,
      maximumAge: 0, // never use a cached position
    })
  }

  function onWebPosition(position) {
    errorMsg.value = ''
    const c = position.coords
    addReading(c.latitude, c.longitude, c.accuracy, new Date(position.timestamp))
    saveWebReading(current.value)
  }

  function onWebError(err) {
    if (err.code === err.PERMISSION_DENIED) {
      errorMsg.value = 'Location permission denied. Allow location for this site in your browser settings.'
      stop()
    } else if (err.code === err.POSITION_UNAVAILABLE) {
      errorMsg.value = 'No GPS fix yet. Move to an open area and wait a moment.'
    } else if (err.code === err.TIMEOUT) {
      errorMsg.value = 'Location request timed out. Still trying...'
    } else {
      errorMsg.value = 'Location error: ' + err.message
    }
  }

  // Called on every reading, but only inserts if 5 s have passed since the last insert
  async function saveWebReading(reading) {
    if (!dbEnabled || !signedIn) return

    const now = Date.now()
    if (now - lastSentAt < SAVE_EVERY_MS) return
    lastSentAt = now

    const { error } = await supabase.from('locations').insert({
      event_id: ids.eventId,
      group_id: ids.groupId,
      lat: reading.lat,
      lng: reading.lng,
      accuracy: reading.accuracy,
      source: 'gps',
      recorded_at: reading.time.toISOString(),
    })

    if (!error) {
      markSaved()
    } else if (error.code === '42501') {
      // RLS said no: this user is not (or no longer) the group's IC
      errorMsg.value = 'You are not allowed to share for this group any more (IC removed?). Sharing stopped.'
      stop(false)
    } else {
      dbStatus.value = 'Save failed: ' + error.message
    }
  }

  function markSaved() {
    savedCount.value++
    lastSavedAt.value = new Date()
    dbStatus.value = 'Saving'
  }

  // ====================== NATIVE (Android / iOS app) ======================
  // ready() must run exactly ONCE per app launch (Transistorsoft rule). Listeners are added
  // before it, because the plugin holds events from app start-up until ready() finishes.
  // reset: false = keep the settings saved from last time (so tracking that was running
  // keeps uploading); start() then applies our full settings with setConfig().
  let readyPromise = null
  async function ensureReady() {
    if (!bg) bg = await loadBackgroundPlugin()
    if (!readyPromise) {
      addListeners()
      readyPromise = bg.ready({ reset: false })

      // Keep the plugin's tokens in step when supabase-js refreshes them (app in foreground)
      const { data } = supabase.auth.onAuthStateChange((event, newSession) => {
        if (event === 'TOKEN_REFRESHED' && newSession && isTracking.value) {
          bg.setConfig({ authorization: buildAuthConfig(newSession) })
        }
      })
      authSub = data.subscription
    }
    return readyPromise
  }

  async function startNative(session) {
    await ensureReady()
    await bg.setConfig(buildNativeConfig(session)) // this event/group + fresh login tokens
    await bg.start()
  }

  // Logout: stop, delete the queue, and remove the upload address + tokens
  async function clearNative() {
    await ensureReady()
    await bg.stop()
    await bg.destroyLocations()
    await bg.setConfig({ http: { url: '', autoSync: false }, authorization: { strategy: 'jwt', accessToken: '' } })
    isTracking.value = false
    sharingEventId.value = null
  }

  function addListeners() {
    bg.removeListeners() // never attach the same listener twice

    // Every location the native tracker records (also shown on our page)
    bg.onLocation(
      (location) => {
        errorMsg.value = ''
        const c = location.coords
        addReading(c.latitude, c.longitude, c.accuracy, new Date(location.timestamp))
      },
      (errorCode) => {
        errorMsg.value =
          'Location error (code ' + errorCode + '). Check location permission is "Allow all the time".'
      },
    )

    // Result of each native upload to Supabase (2xx = saved)
    bg.onHttp((response) => {
      if (response.success) {
        markSaved()
      } else if (response.status === 403) {
        // RLS said no (not IC any more). The plugin would retry this forever,
        // so stop tracking and clear the queue.
        errorMsg.value = 'You are not allowed to share for this group any more (IC removed?). Sharing stopped.'
        isTracking.value = false
        sharingEventId.value = null
        bg.stop()
        bg.destroyLocations()
      } else if (response.status === 400) {
        // Supabase could not read this record (bad data). The plugin only deletes a record
        // after a 2xx reply and uploads in order, so ONE bad record would block every location
        // behind it forever. Drop the queue so new locations can upload again.
        console.error('[tracker] upload rejected (400):', response.responseText)
        dbStatus.value = 'Upload rejected (400): ' + response.responseText
        bg.destroyLocations()
      } else {
        console.error('[tracker] upload failed:', response.status, response.responseText)
        dbStatus.value = 'Save failed: HTTP ' + response.status + ' (kept on phone, will retry)'
      }
    })

    // Heartbeat: when the phone is standing still the plugin turns GPS off to save battery,
    // so every 60 s we record one position anyway. This lets the dashboard tell
    // "standing still" apart from "phone died".
    bg.onHeartbeat(() => {
      bg.getCurrentPosition({ samples: 1, persist: true }).catch(() => {})
    })

    // When the plugin refreshes the Supabase token itself (e.g. while locked),
    // give the new tokens to supabase-js too, so both keep using the same login session
    bg.onAuthorization((event) => {
      if (event.success && event.response && event.response.access_token) {
        supabase.auth.setSession({
          access_token: event.response.access_token,
          refresh_token: event.response.refresh_token,
        })
      }
    })
  }

  // Login token settings for native uploads.
  // The plugin adds "Authorization: Bearer <accessToken>" to each upload. Supabase tokens
  // expire after ~1 hour: when an upload gets 401, the plugin calls refreshUrl with the
  // refresh token, saves the new tokens and retries.
  function buildAuthConfig(session) {
    return {
      strategy: 'jwt',
      accessToken: session.access_token,
      refreshToken: session.refresh_token,
      refreshUrl: supabaseUrl + '/auth/v1/token?grant_type=refresh_token',
      refreshPayload: { refresh_token: '{refreshToken}' }, // plugin fills in {refreshToken}
      refreshHeaders: { apikey: supabaseAnonKey },
    }
  }

  function buildNativeConfig(session) {
    const config = {
      logger: {
        debug: true, // TESTING ONLY: plays sounds on each location so you can hear it in a pocket
        logLevel: bg.LogLevel.Verbose,
      },
      geolocation: {
        desiredAccuracy: bg.DesiredAccuracy.High,
        distanceFilter: 10, // record a new location every ~10 m of movement
        locationAuthorizationRequest: 'Always', // needed for tracking while locked
        pausesLocationUpdatesAutomatically: false, // iOS: don't let iOS pause updates by itself
      },
      app: {
        stopOnTerminate: false, // keep tracking if the app is swiped away
        startOnBoot: true, // resume tracking after the phone restarts
        heartbeatInterval: 60, // seconds (see onHeartbeat above)
        preventSuspend: true, // iOS: needed for heartbeats while locked (uses more battery)
        notification: {
          // Android must show a notification while tracking in the background
          title: 'Event Tracker',
          text: 'Sharing your location with event planners',
        },
      },
      persistence: {
        // Shape of each uploaded location = the columns of our "locations" table.
        // Numbers have no quotes; the timestamp is text so it needs quotes.
        locationTemplate:
          '{"lat":<%= latitude %>,"lng":<%= longitude %>,"accuracy":<%= accuracy %>,"recorded_at":"<%= timestamp %>"}',
        maxDaysToPersist: 3, // queued locations older than this are dropped
        // Android records an extra "provider change" entry when location permission or GPS
        // settings change; it doesn't fit our table's columns, so don't save/upload it.
        disableProviderChangeRecord: true,
      },
    }

    // Upload straight to Supabase (only if we have a login session)
    if (session) {
      config.http = {
        url: supabaseUrl + '/rest/v1/locations',
        method: 'POST',
        autoSync: true, // upload each location as soon as it is recorded
        rootProperty: '.', // put lat/lng/... at the top level of the JSON body
        params: { event_id: ids.eventId, group_id: ids.groupId, source: 'gps' }, // added to every upload
        headers: {
          apikey: supabaseAnonKey, // public key; the user's token is added by "authorization"
          Prefer: 'return=minimal', // Supabase: don't send the new row back
        },
      }
      config.authorization = buildAuthConfig(session)
    }
    return config
  }

  return {
    isNative,
    isTracking,
    current,
    readings,
    errorMsg,
    dbStatus,
    savedCount,
    lastSavedAt,
    sharingEventId,
    start,
    stop,
    resume,
    clearNative,
  }
}
