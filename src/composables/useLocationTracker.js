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
// Libraries: @capacitor/core (MIT) - https://capacitorjs.com
//            @transistorsoft/capacitor-background-geolocation - https://docs.transistorsoft.com/capacitor/
//            (free in DEBUG builds; release builds need a paid licence key)
import { ref } from 'vue'
import { Capacitor } from '@capacitor/core'
import { supabase, supabaseUrl, supabaseAnonKey } from '../lib/supabase'

const MAX_READINGS = 20 // rows kept for the table
const SAVE_EVERY_MS = 5000 // web only: at most one insert every 5 s

export function useLocationTracker() {
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

  // Saving needs a signed-in user (RLS checks user_id = auth.uid()).
  // Sandbox: anonymous sign-in. Returns the session, or null if it failed.
  async function ensureSignedIn() {
    const { data } = await supabase.auth.getSession()
    if (data.session) return data.session

    const { data: signInData, error } = await supabase.auth.signInAnonymously()
    if (error) {
      dbStatus.value = 'Sign-in failed: ' + error.message
      return null
    }
    return signInData.session
  }

  // ---------- Start / stop (what the page calls) ----------
  async function start(eventId, groupId) {
    errorMsg.value = ''
    ids = { eventId, groupId }
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

  async function stop() {
    isTracking.value = false
    if (isNative) {
      if (bg) await bg.stop()
    } else if (watchId !== null) {
      navigator.geolocation.clearWatch(watchId)
      watchId = null
    }
    if (dbEnabled && savedCount.value > 0) dbStatus.value = 'Stopped'
  }

  // Called when the page closes. On the web we stop GPS. In the app we only remove
  // the listeners - native tracking keeps running in the background on purpose.
  async function dispose() {
    if (isNative) {
      if (bg) await bg.removeListeners()
      if (authSub) authSub.unsubscribe()
      authSub = null
    } else {
      stop()
    }
  }

  // App only: if tracking was left running (e.g. the app was reopened), show it again
  async function resume() {
    if (!isNative) return
    await loadPlugin()
    const state = await bg.getState()
    if (state.enabled) {
      addListeners()
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
      return
    }
    if (!('geolocation' in navigator)) {
      errorMsg.value = 'This browser does not support location.'
      isTracking.value = false
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

    if (error) dbStatus.value = 'Save failed: ' + error.message
    else markSaved()
  }

  function markSaved() {
    savedCount.value++
    lastSavedAt.value = new Date()
    dbStatus.value = 'Saving'
  }

  // ====================== NATIVE (Android / iOS app) ======================
  // Load the plugin only inside the app, so the web bundle never needs it
  async function loadPlugin() {
    if (!bg) {
      const module = await import('@transistorsoft/capacitor-background-geolocation')
      bg = module.default
    }
  }

  async function startNative(session) {
    await loadPlugin()
    addListeners()

    // ready() applies our config; reset: true means "always use exactly this config"
    await bg.ready(buildNativeConfig(session))
    await bg.start()

    // Keep the plugin's tokens in step when supabase-js refreshes them (app in foreground)
    if (session && !authSub) {
      const { data } = supabase.auth.onAuthStateChange((event, newSession) => {
        if (event === 'TOKEN_REFRESHED' && newSession && bg) {
          bg.setConfig({ authorization: buildAuthConfig(newSession) })
        }
      })
      authSub = data.subscription
    }
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
      if (response.success) markSaved()
      else dbStatus.value = 'Save failed: HTTP ' + response.status + ' (kept on phone, will retry)'
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
      reset: true,
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
    start,
    stop,
    dispose,
    resume,
  }
}
