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
const ANDROID_INTERVAL_MS = 30000 // Android app: record + upload a position every 30 s, even when standing still
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
  // Phone app only: settings that can slow down or stop background tracking
  const powerSaveOn = ref(false) // Android battery saver / iOS Low Power Mode is on
  const batteryRestricted = ref(false) // Android: app is NOT set to "Unrestricted" battery use

  // ---------- Plain variables ----------
  let nextId = 1 // unique key for each table row
  let watchId = null // web: id from watchPosition
  let lastSentAt = 0 // web: time of the last insert (for throttling)
  let signedIn = false // web: only save after sign-in worked
  let ids = { eventId: null, groupId: null } // which event/group readings belong to
  let bg = null // native: the Transistorsoft plugin (loaded only inside the app)

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
    rememberSharing(eventId, groupId) // browser: restart after refresh; app: know the event after reopening
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
        // Upload readings still queued on the phone while the pass is valid, then clear the
        // queue - otherwise they upload later with the cancelled pass and get rejected (403)
        try {
          await bg.sync()
        } catch {
          // offline: these last readings are dropped
        }
        await bg.destroyLocations()
      }
    } else if (watchId !== null) {
      navigator.geolocation.clearWatch(watchId)
      watchId = null
    }
    if (dbEnabled && savedCount.value > 0) dbStatus.value = 'Stopped'
    if (recordStop && wasTracking) await saveStopMarker()
    // Phone app: cancel the tracking pass so nothing more can be uploaded with it
    if (isNative && dbEnabled) await supabase.rpc('revoke_my_tracking_passes')
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
      // Tracking was started by an older app version (login-token uploads, no tracking pass):
      // stop it cleanly so the screen and the tracker never disagree. The IC just taps Share again.
      const url = (state.http && state.http.url) || ''
      if (!url.includes('/rpc/report_location')) {
        await clearNative()
        return
      }

      // Which event/group? Use what we remembered at Share time, else ask the database
      // which event our active tracking pass belongs to.
      const saved = rememberedSharing()
      if (saved) {
        ids = { eventId: saved.eventId, groupId: saved.groupId }
      } else {
        const { data } = await supabase.rpc('my_active_tracking_pass')
        if (!data || data.length === 0) {
          await clearNative() // no valid pass (stopped/expired): nothing to resume
          return
        }
        ids = { eventId: data[0].event_id, groupId: data[0].group_id }
        rememberSharing(ids.eventId, ids.groupId)
      }
      sharingEventId.value = ids.eventId
      isTracking.value = true
      if (!state.isMoving) await bg.changePace(true) // keep the 30 s timer running (see startNative)
      await checkPhoneSettings()
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
  // keeps uploading); start() then applies our full settings with reset(config).
  let readyPromise = null
  async function ensureReady() {
    if (!bg) bg = await loadBackgroundPlugin()
    if (!readyPromise) {
      addListeners()
      readyPromise = bg.ready({ reset: false })
    }
    return readyPromise
  }

  async function startNative(session) {
    await ensureReady()

    // Ask the database for a TRACKING PASS (needs the user's login, which we have now).
    // The background tracker uploads with this pass instead of the login token, so uploads
    // keep working for hours with the app closed (login tokens expire every hour).
    let pass = null
    if (session) {
      const { data, error } = await supabase.rpc('start_tracking_pass', {
        p_event_id: ids.eventId,
        p_group_id: ids.groupId,
      })
      if (error) {
        errorMsg.value = 'Could not start sharing: ' + error.message
        isTracking.value = false
        sharingEventId.value = null
        forgetSharing()
        return
      }
      pass = data
    }

    // reset() = drop every old setting (e.g. old login tokens) and use exactly this config
    await bg.reset(buildNativeConfig(pass))
    await bg.start()
    // start() begins in "stationary" mode (GPS mostly off) until the phone moves. Switch to
    // "moving" right away so the 30 s timer runs even if the IC is standing still. Stop
    // detection is disabled, so it then stays in moving mode until Stop is pressed.
    await bg.changePace(true)
    await checkPhoneSettings()
  }

  // Apps can't change these settings themselves - we can only detect them and warn the user
  async function checkPhoneSettings() {
    try {
      powerSaveOn.value = await bg.isPowerSaveMode()
      if (Capacitor.getPlatform() === 'android') {
        batteryRestricted.value = !(await bg.deviceSettings.isIgnoringBatteryOptimizations())
      }
    } catch (err) {
      console.error('[tracker] could not check phone settings:', err)
    }
  }

  // Opens Android's battery settings for this app so the user can choose "Unrestricted"
  async function openBatterySettings() {
    try {
      const request = await bg.deviceSettings.showIgnoreBatteryOptimizations()
      await bg.deviceSettings.show(request)
    } catch (err) {
      console.error('[tracker] could not open battery settings:', err)
    }
    setTimeout(checkPhoneSettings, 3000) // re-check after the user comes back
  }

  // Logout: stop, delete the queue, and remove the upload address + tokens
  async function clearNative() {
    await ensureReady()
    await bg.stop()
    await bg.destroyLocations()
    await bg.setConfig({ http: { url: '', autoSync: false, params: {} } })
    isTracking.value = false
    sharingEventId.value = null
  }

  // Called exactly once per app launch (from ensureReady), so listeners are never doubled.
  // (Don't call bg.removeListeners() here: it finishes later and would remove these new ones.)
  function addListeners() {

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
      } else if (!isTracking.value) {
        // Late upload after Stop (pass already cancelled): expected, ignore it
      } else if (response.status === 403 || response.status === 401) {
        // The database said no (pass stopped/expired or not IC any more). The plugin would retry this forever,
        // so stop tracking and clear the queue.
        errorMsg.value =
          'Sharing stopped: your tracking pass is no longer valid (stopped, expired after 24 h, or no longer the IC).'
        isTracking.value = false
        sharingEventId.value = null
        forgetSharing()
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
      // Android records every 30 s natively (see buildNativeConfig), so only iOS needs this
      if (Capacitor.getPlatform() === 'android') return
      console.log('[tracker] heartbeat: taking a position')
      bg.getCurrentPosition({ samples: 1, persist: true, timeout: 30 })
        .then((loc) => console.log('[tracker] heartbeat position saved, accuracy', loc.coords.accuracy))
        .catch((err) => console.error('[tracker] heartbeat position failed:', JSON.stringify(err)))
    })

    // Battery saver switched on/off while sharing: update the warning on the page
    bg.onPowerSaveChange((enabled) => {
      powerSaveOn.value = enabled
    })
  }

  // pass = tracking pass from start_tracking_pass() (null if not logged in: track without uploading)
  function buildNativeConfig(pass) {
    const isAndroid = Capacitor.getPlatform() === 'android'
    const config = {
      logger: {
        debug: false, // true = test sounds on every location (only for pocket testing)
        // Info, not Verbose: Verbose prints the whole config incl. the login token into the phone log
        logLevel: bg.LogLevel.Info,
      },
      geolocation: {
        desiredAccuracy: bg.DesiredAccuracy.High,
        locationAuthorizationRequest: 'Always', // needed for tracking while locked
        pausesLocationUpdatesAutomatically: false, // iOS: don't let iOS pause updates by itself
        // Standing still gives the same coordinates every time; keep them anyway,
        // otherwise they are dropped as "identical" and no row is saved while standing.
        allowIdenticalLocations: true,
        ...(isAndroid
          ? {
              // ANDROID: record on a timer, not by distance: one position every 30 s, moving or
              // not. All native (no app code needed), so it keeps working when locked or swiped away.
              distanceFilter: 0,
              locationUpdateInterval: ANDROID_INTERVAL_MS,
              fastestLocationUpdateInterval: ANDROID_INTERVAL_MS,
            }
          : {
              // iOS: record every ~10 m of movement; the 60 s heartbeat covers standing still
              distanceFilter: 10,
            }),
      },
      activity: {
        // Never switch to "stationary" (GPS off) while sharing. Android: keeps the 30 s timer
        // running. iOS: iOS only keeps a background app alive while it is using location.
        disableStopDetection: true,
      },
      app: {
        stopOnTerminate: false, // keep tracking if the app is swiped away
        startOnBoot: true, // resume tracking after the phone restarts
        heartbeatInterval: 60, // seconds - iOS only (see onHeartbeat above)
        preventSuspend: true, // iOS: needed for heartbeats while locked (uses more battery)
        notification: {
          // Android must show a notification while tracking in the background
          title: 'Event Tracker',
          text: 'Sharing your location with event planners',
        },
      },
      persistence: {
        // Shape of each upload = the inputs of the report_location() database function.
        // Numbers have no quotes; the timestamp is text so it needs quotes.
        locationTemplate:
          '{"p_lat":<%= latitude %>,"p_lng":<%= longitude %>,"p_accuracy":<%= accuracy %>,"p_recorded_at":"<%= timestamp %>"}',
        maxDaysToPersist: 3, // queued locations older than this are dropped
        // Android records an extra "provider change" entry when location permission or GPS
        // settings change; it doesn't fit our table's columns, so don't save/upload it.
        disableProviderChangeRecord: true,
      },
    }

    // Upload straight to the report_location() database function with the tracking pass.
    // No login token is sent, so nothing expires: the database checks the pass + IC role.
    if (pass) {
      config.http = {
        url: supabaseUrl + '/rest/v1/rpc/report_location',
        method: 'POST',
        autoSync: true, // upload each location as soon as it is recorded
        rootProperty: '.', // put p_lat/p_lng/... at the top level of the JSON body
        params: { p_token: pass }, // added to every upload
        headers: { apikey: supabaseAnonKey }, // public key only
      }
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
    powerSaveOn,
    batteryRestricted,
    openBatterySettings,
    start,
    stop,
    resume,
    clearNative,
  }
}
