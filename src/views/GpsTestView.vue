<script setup>
// My GPS details for one event (Komin): my own position, accuracy, save status and
// recent readings. Sharing itself is started from the event page ("Share my location")
// or here; both use the same app-wide tracker, so it keeps running between pages.
// Only the group's IC may share (the database rejects everyone else).
// HOW we get GPS (browser vs Transistorsoft in the phone app) and how readings are
// saved lives in useLocationTracker.js - this page shows my own position and status.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles (c) Singapore Land Authority - https://www.onemap.gov.sg
import { computed, watch, onMounted, onUnmounted } from 'vue'
import { RouterLink } from 'vue-router'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { useLocationTracker } from '../composables/useLocationTracker'
import SharingWarnings from '../components/SharingWarnings.vue'
import { useEventData } from '../composables/useEventData'

const props = defineProps({ id: { type: String, required: true } }) // event id from the URL
const MAX_READINGS = 20

const { event, loading, me, myGroup } = useEventData(props.id)

const {
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
} = useLocationTracker()

const canShare = computed(() => !!(me.value && me.value.isIC && myGroup.value))
const sharingHere = computed(() => isTracking.value && sharingEventId.value === props.id)

// ---------- Map objects (plain variables, not reactive) ----------
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

function startSharing() {
  start(props.id, myGroup.value.id)
}

// If I stop being IC while sharing (someone changed my role), stop sharing
watch(canShare, (allowed) => {
  if (!allowed && sharingHere.value) stop(false)
})

// ---------- Map ----------
onMounted(() => {
  // Centre on Singapore with the OneMap basemap (shared setup in utils/onemap.js)
  map = createSingaporeMap('gps-map')

  // Already sharing (started on the event page)? Show where I am straight away
  if (current.value) updateMap(current.value.lat, current.value.lng, current.value.accuracy)
})

// Leaving this page does NOT stop sharing - the tracker is shared by the whole app
onUnmounted(() => {
  if (map) map.remove()
})

// Move the marker whenever there is a new reading
watch(current, (reading) => {
  if (reading) updateMap(reading.lat, reading.lng, reading.accuracy)
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
</script>

<template>
  <main class="container py-3">
    <RouterLink :to="{ name: 'event', params: { id } }" class="small">&larr; Back to event</RouterLink>

    <div class="d-flex flex-wrap align-items-center justify-content-between gap-2 my-2">
      <div>
        <h1 class="h4 mb-0">
          My GPS details
          <span class="badge text-bg-secondary fw-normal fs-6" data-testid="tracker-mode">
            {{ isNative ? 'App (background GPS)' : 'Browser' }}
          </span>
        </h1>
        <div v-if="event" class="small text-muted" data-testid="share-context">
          {{ event.name }}<span v-if="myGroup"> · {{ myGroup.name }}</span>
        </div>
      </div>
      <button
        v-if="!sharingHere"
        class="btn btn-success"
        :disabled="!canShare"
        data-testid="start-btn"
        @click="startSharing"
      >
        Start sharing
      </button>
      <button v-else class="btn btn-danger" data-testid="stop-btn" @click="stop">Stop sharing</button>
    </div>

    <div v-if="!loading && !canShare" class="alert alert-warning py-2" role="alert" data-testid="not-ic-msg">
      Only your group's IC shares location. Ask the root, a planner or your group admin to make you IC.
    </div>
    <div v-if="isTracking && !sharingHere" class="alert alert-info py-2" role="status">
      You are sharing for another event. Starting here will stop that one.
    </div>
    <div v-if="sharingHere" class="alert alert-success py-2" role="status" data-testid="sharing-banner">
      You are sharing your live location with this event's planners and your group.
    </div>
    <SharingWarnings v-if="sharingHere" />
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
