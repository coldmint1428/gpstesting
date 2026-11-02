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
import { computed, ref, watch, onMounted, onUnmounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { setArrivalTolerance } from '../services/memberService'
import { useLocationTracker } from '../composables/useLocationTracker'
import SharingWarnings from '../components/SharingWarnings.vue'
import { usePhoneReadiness } from '../composables/usePhoneReadiness'
import BenchAlert from '../components/BenchAlert.vue'
import { useEventData } from '../composables/useEventData'

const props = defineProps({ id: { type: String, required: true } }) // event id from the URL
const MAX_READINGS = 20

const { event, loading, me, myGroup, load } = useEventData(props.id)

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

// ---------- My arrival radius (063) ----------
// How close my phone has to be to a moment's drawn point for the tick to close that moment for my group. The zone the
// point stands in already counts; this is the other half, because a phone in a pocket is not a polygon. Only an IC has
// one, so this card is the IC's own -- a planner sets anybody's from the event's People page.
const tolerance = ref(null)
const tolSaving = ref(false)
const tolMsg = ref('')
const tolOk = ref(false)
const tolDirty = computed(() => !!me.value && tolerance.value != null && Number(tolerance.value) !== me.value.toleranceM)

watch(me, (m) => { if (m && m.toleranceM != null) tolerance.value = m.toleranceM }, { immediate: true })

async function saveTolerance() {
  const metres = Math.round(Number(tolerance.value))
  if (!Number.isFinite(metres)) {
    tolOk.value = false
    tolMsg.value = 'Say how many metres.'
    return
  }
  tolSaving.value = true
  tolMsg.value = ''
  const message = await setArrivalTolerance(props.id, null, metres)
  tolSaving.value = false
  if (message) {
    tolOk.value = false
    tolMsg.value = message
    return
  }
  tolOk.value = true
  tolMsg.value = 'Saved: ' + metres + ' m.'
  await load() // the membership row is what the rest of the app reads
}

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

const router = useRouter()
const readiness = usePhoneReadiness()
// Phone app: missing settings open "Set up sharing" first (see EventView)
async function startSharing() {
  if (readiness.isNative) {
    const ready = await readiness.check()
    if (!ready.allOk) {
      router.push({ name: 'phone-check', query: { event: props.id, group: myGroup.value.id, share: '1' } })
      return
    }
  }
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
  <main class="kp-page kp-page-wide kp-stack">
    <div>
      <RouterLink :to="{ name: 'event', params: { id } }" class="kp-back">‹ Back to event</RouterLink>
      <div class="kp-head mb-0">
        <h1>My GPS</h1>
        <button v-if="!sharingHere" class="btn btn-success" :disabled="!canShare" data-testid="start-btn" @click="startSharing">Start sharing</button>
        <button v-else class="btn btn-outline-danger" data-testid="stop-btn" @click="stop">Stop sharing</button>
      </div>
      <div class="kp-inline mt-1" style="flex-wrap: wrap">
        <span v-if="event" class="small text-muted" data-testid="share-context">{{ event.name }}<span v-if="myGroup"> · {{ myGroup.name }}</span></span>
        <span class="kp-chip" data-testid="tracker-mode">{{ isNative ? 'App (background GPS)' : 'Browser' }}</span>
      </div>
    </div>

    <div v-if="!loading && !canShare" class="kp-banner kp-banner-danger" role="alert" data-testid="not-ic-msg">Only your group's IC shares location.</div>
    <div v-if="isTracking && !sharingHere" class="kp-banner" role="status">You are sharing for another event. Starting here stops that one.</div>
    <div v-if="sharingHere" class="kp-banner" style="background: var(--mint)" role="status" data-testid="sharing-banner">
      <span class="kp-dot" style="background: var(--live)"></span>Sharing live with your planners and group.
    </div>
    <SharingWarnings v-if="sharingHere" />
    <BenchAlert v-if="errorMsg" data-testid="error-msg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <div class="kp-share">
      <div id="gps-map" class="gps-map" data-testid="gps-map"></div>

      <div class="kp-stack">
        <section class="kp-card">
          <h2 class="kp-title mb-2">Position</h2>
          <p v-if="!current" class="text-muted mb-0" data-testid="no-reading">{{ isTracking ? 'Waiting for first reading...' : 'Press Start sharing.' }}</p>
          <dl v-else class="kp-dl kp-mono">
            <dt>Latitude</dt>
            <dd data-testid="current-lat">{{ current.lat.toFixed(6) }}</dd>
            <dt>Longitude</dt>
            <dd data-testid="current-lng">{{ current.lng.toFixed(6) }}</dd>
            <dt>Accuracy</dt>
            <dd data-testid="current-accuracy">
              {{ Math.round(current.accuracy) }} m
              <span class="badge" :class="accuracyBadgeClass">{{ accuracyLabel }}</span>
            </dd>
            <dt>Updated</dt>
            <dd>{{ formatTime(current.time) }}</dd>
          </dl>
        </section>

        <section class="kp-card">
          <h2 class="kp-title mb-2">Uploads</h2>
          <dl class="kp-dl kp-mono">
            <dt>Status</dt>
            <dd data-testid="db-status">{{ dbStatus }}</dd>
            <dt>Saved</dt>
            <dd data-testid="db-saved-count">{{ savedCount }}</dd>
            <dt>Last saved</dt>
            <dd>{{ formatTime(lastSavedAt) }}</dd>
          </dl>
        </section>

        <!-- My arrival radius: the IC's own number. The zone a moment stands in already counts; this is the rest. -->
        <section v-if="canShare" class="kp-card" data-testid="tolerance-card">
          <h2 class="kp-title">Arrival radius</h2>
          <p class="kp-sub mb-2">How close counts as arrived.</p>
          <div class="kp-inline">
            <label for="tolerance-input" class="visually-hidden">Arrival radius in metres</label>
            <input id="tolerance-input" v-model.number="tolerance" type="number" min="5" max="100" step="5" class="form-control form-control-sm" style="flex: 0 0 6rem" data-testid="tolerance-input" />
            <span class="small text-muted me-auto">metres</span>
            <button class="btn btn-sm btn-primary" :disabled="tolSaving || !tolDirty" data-testid="tolerance-save" @click="saveTolerance">Save</button>
          </div>
          <p v-if="tolMsg" class="small mb-0 mt-2" :class="tolOk ? 'text-success' : 'text-danger'" data-testid="tolerance-msg">{{ tolMsg }}</p>
        </section>
      </div>
    </div>

    <!-- Last 20 readings -->
    <section class="kp-card">
      <h2 class="kp-title mb-2">Last {{ MAX_READINGS }} readings</h2>
      <div class="table-responsive">
        <table class="table table-sm small mb-0 kp-mono" data-testid="readings-table">
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
    </section>
  </main>
</template>
