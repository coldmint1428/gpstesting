<script setup>
// GPS test page (Komin).
// Uses the browser Geolocation API to watch this device's position, shows it on a
// Leaflet map with OneMap tiles, and saves a reading to Supabase about every 5 s.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles (c) Singapore Land Authority - https://www.onemap.gov.sg
import { ref, computed, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { supabase } from '../lib/supabase'

const MAX_READINGS = 20 // rows kept in the table
const SAVE_EVERY_MS = 5000 // throttle: at most one database insert every 5 s

// Test IDs from .env until real events/groups exist
const EVENT_ID = import.meta.env.VITE_TEST_EVENT_ID
const GROUP_ID = import.meta.env.VITE_TEST_GROUP_ID

// ---------- Reactive state ----------
const isTracking = ref(false)
const current = ref(null) // latest reading { lat, lng, accuracy, time }
const readings = ref([]) // newest first
const errorMsg = ref('')

// Database status shown on the page
const dbEnabled = supabase !== null
const dbStatus = ref(dbEnabled ? 'Not started' : 'Off (no .env)')
const savedCount = ref(0)
const lastSavedAt = ref(null)

// ---------- Plain (non-reactive) variables ----------
let watchId = null // id returned by watchPosition, needed to stop it
let lastSentAt = 0 // time (ms) of the last insert, for throttling
let signedIn = false // only try to save after a successful sign-in
let nextId = 1 // unique key for each table row
let map = null
let marker = null
let accuracyCircle = null

// Good <= 20 m, Fair <= 100 m, Poor > 100 m
const accuracyLabel = computed(() => {
  if (!current.value) return ''
  const acc = current.value.accuracy
  if (acc <= 20) return 'Good'
  if (acc <= 100) return 'Fair'
  return 'Poor'
})

const accuracyBadgeClass = computed(() => {
  if (accuracyLabel.value === 'Good') return 'text-bg-success'
  if (accuracyLabel.value === 'Fair') return 'text-bg-warning'
  return 'text-bg-danger'
})

function formatTime(date) {
  return date ? date.toLocaleTimeString('en-SG') : '-'
}

// ---------- Map ----------
onMounted(() => {
  // Centre on Singapore; OneMap tiles only cover Singapore
  map = L.map('gps-map', { minZoom: 11, maxZoom: 19 }).setView([1.3521, 103.8198], 12)

  L.tileLayer('https://www.onemap.gov.sg/maps/tiles/Default/{z}/{x}/{y}.png', {
    detectRetina: true,
    maxZoom: 19,
    minZoom: 11,
    // OneMap requires this attribution
    attribution:
      '<img src="https://www.onemap.gov.sg/web-assets/images/logo/om_logo.png" style="height:20px;width:20px;"/>&nbsp;' +
      '<a href="https://www.onemap.gov.sg/" target="_blank" rel="noopener noreferrer">OneMap</a>&nbsp;&copy;&nbsp;contributors&nbsp;&#124;&nbsp;' +
      '<a href="https://www.sla.gov.sg/" target="_blank" rel="noopener noreferrer">Singapore Land Authority</a>',
  }).addTo(map)
})

onUnmounted(() => {
  stopSharing()
  if (map) map.remove()
})

function updateMap(lat, lng, accuracy) {
  if (!marker) {
    // First reading: create the blue dot and the accuracy circle, then zoom in
    accuracyCircle = L.circle([lat, lng], { radius: accuracy, weight: 1, fillOpacity: 0.15 }).addTo(map)
    marker = L.circleMarker([lat, lng], {
      radius: 8,
      color: '#fff',
      weight: 2,
      fillColor: '#0d6efd',
      fillOpacity: 1,
    }).addTo(map)
    map.setView([lat, lng], 17)
  } else {
    marker.setLatLng([lat, lng])
    accuracyCircle.setLatLng([lat, lng])
    accuracyCircle.setRadius(accuracy)
  }
}

// ---------- Supabase ----------
// Inserts need a signed-in user (RLS checks user_id = auth.uid()).
// For this sandbox we use Supabase anonymous sign-in; real login comes later.
async function ensureSignedIn() {
  const { data } = await supabase.auth.getSession()
  if (data.session) return true

  const { error } = await supabase.auth.signInAnonymously()
  if (error) {
    dbStatus.value = 'Sign-in failed: ' + error.message
    return false
  }
  return true
}

// Called on every GPS reading, but only inserts if 5 s have passed since the last insert
async function saveReading(reading) {
  if (!dbEnabled || !signedIn) return

  const now = Date.now()
  if (now - lastSentAt < SAVE_EVERY_MS) return
  lastSentAt = now

  const { error } = await supabase.from('locations').insert({
    event_id: EVENT_ID,
    group_id: GROUP_ID,
    lat: reading.lat,
    lng: reading.lng,
    accuracy: reading.accuracy,
    source: 'gps',
    recorded_at: reading.time.toISOString(),
  })

  if (error) {
    dbStatus.value = 'Save failed: ' + error.message
  } else {
    savedCount.value++
    lastSavedAt.value = new Date()
    dbStatus.value = 'Saving'
  }
}

// ---------- Geolocation ----------
function onPosition(position) {
  errorMsg.value = ''
  const reading = {
    id: nextId++,
    lat: position.coords.latitude,
    lng: position.coords.longitude,
    accuracy: position.coords.accuracy, // metres
    time: new Date(position.timestamp),
  }

  current.value = reading
  readings.value.unshift(reading) // newest first
  if (readings.value.length > MAX_READINGS) readings.value.pop()

  updateMap(reading.lat, reading.lng, reading.accuracy)
  saveReading(reading)
}

function onError(err) {
  if (err.code === err.PERMISSION_DENIED) {
    errorMsg.value = 'Location permission denied. Allow location for this site in your browser settings.'
    stopSharing()
  } else if (err.code === err.POSITION_UNAVAILABLE) {
    errorMsg.value = 'No GPS fix yet. Move to an open area and wait a moment.'
  } else if (err.code === err.TIMEOUT) {
    errorMsg.value = 'Location request timed out. Still trying...'
  } else {
    errorMsg.value = 'Location error: ' + err.message
  }
}

async function startSharing() {
  errorMsg.value = ''

  // GPS only works on https pages (or localhost)
  if (!window.isSecureContext) {
    errorMsg.value = 'Location needs a secure (https) page. Open the Vercel https link instead.'
    return
  }
  if (!('geolocation' in navigator)) {
    errorMsg.value = 'This browser does not support location.'
    return
  }

  isTracking.value = true

  if (dbEnabled) {
    dbStatus.value = 'Signing in...'
    signedIn = await ensureSignedIn()
    if (signedIn) dbStatus.value = 'Waiting for first reading'
  }

  // The user may have pressed Stop while we were signing in
  if (!isTracking.value) return

  watchId = navigator.geolocation.watchPosition(onPosition, onError, {
    enableHighAccuracy: true, // use GPS, not just Wi-Fi/cell towers
    timeout: 15000,
    maximumAge: 0, // never use a cached position
  })
}

function stopSharing() {
  if (watchId !== null) {
    navigator.geolocation.clearWatch(watchId)
    watchId = null
  }
  isTracking.value = false
  if (dbEnabled && savedCount.value > 0) dbStatus.value = 'Stopped'
}
</script>

<template>
  <main class="container py-3">
    <div class="d-flex flex-wrap align-items-center justify-content-between gap-2 mb-3">
      <h1 class="h4 mb-0">GPS test</h1>
      <button
        v-if="!isTracking"
        class="btn btn-success"
        data-testid="start-btn"
        @click="startSharing"
      >
        Start sharing
      </button>
      <button v-else class="btn btn-danger" data-testid="stop-btn" @click="stopSharing">
        Stop sharing
      </button>
    </div>

    <div v-if="errorMsg" class="alert alert-danger" role="alert" data-testid="error-msg">
      {{ errorMsg }}
    </div>

    <div class="row g-3">
      <!-- Map: full width on phones, 2/3 on large screens -->
      <div class="col-12 col-lg-8">
        <div id="gps-map" class="gps-map rounded border" data-testid="gps-map"></div>
      </div>

      <!-- Current position + database status -->
      <div class="col-12 col-lg-4">
        <div class="card mb-3">
          <div class="card-body">
            <h2 class="h6 card-title">Current position</h2>
            <p v-if="!current" class="text-muted mb-0" data-testid="no-reading">
              {{ isTracking ? 'Waiting for first reading...' : 'Press Start sharing.' }}
            </p>
            <dl v-else class="row mb-0 small">
              <dt class="col-5">Latitude</dt>
              <dd class="col-7" data-testid="current-lat">{{ current.lat.toFixed(6) }}</dd>
              <dt class="col-5">Longitude</dt>
              <dd class="col-7" data-testid="current-lng">{{ current.lng.toFixed(6) }}</dd>
              <dt class="col-5">Accuracy</dt>
              <dd class="col-7" data-testid="current-accuracy">
                {{ Math.round(current.accuracy) }} m
                <span class="badge" :class="accuracyBadgeClass">{{ accuracyLabel }}</span>
              </dd>
              <dt class="col-5">Updated</dt>
              <dd class="col-7 mb-0">{{ formatTime(current.time) }}</dd>
            </dl>
          </div>
        </div>

        <div class="card">
          <div class="card-body">
            <h2 class="h6 card-title">Database</h2>
            <dl class="row mb-0 small">
              <dt class="col-5">Status</dt>
              <dd class="col-7" data-testid="db-status">{{ dbStatus }}</dd>
              <dt class="col-5">Saved</dt>
              <dd class="col-7" data-testid="db-saved-count">{{ savedCount }}</dd>
              <dt class="col-5">Last saved</dt>
              <dd class="col-7 mb-0">{{ formatTime(lastSavedAt) }}</dd>
            </dl>
          </div>
        </div>
      </div>
    </div>

    <!-- Last 20 readings -->
    <h2 class="h6 mt-4">Last {{ MAX_READINGS }} readings</h2>
    <div class="table-responsive">
      <table class="table table-sm table-striped small" data-testid="readings-table">
        <thead>
          <tr>
            <th>Time</th>
            <th>Lat</th>
            <th>Lng</th>
            <th>Acc (m)</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in readings" :key="r.id">
            <td>{{ formatTime(r.time) }}</td>
            <td>{{ r.lat.toFixed(6) }}</td>
            <td>{{ r.lng.toFixed(6) }}</td>
            <td>{{ Math.round(r.accuracy) }}</td>
          </tr>
          <tr v-if="readings.length === 0">
            <td colspan="4" class="text-muted">No readings yet.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </main>
</template>

<style scoped>
/* Leaflet needs an explicit height */
.gps-map {
  height: 60vh;
  min-height: 300px;
}
</style>
