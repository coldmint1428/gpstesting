<script setup>
// Replays a recording on the map: drag the timeline to any moment, or press Play.
// Markers look like the live map (initials, group colour, stale / lost contact / stopped).
// Tap a person: info card + their whole trail so far (dashed where the phone lost contact),
// everyone else fades. "Show trails" draws everyone's last 10 minutes.
//
// The recording comes from the database (session or day) or from a CSV file; this
// component doesn't care which (see utils/playback.js).
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { positionAt, trailAt, timelineMarks, TRAIL_MS } from '../utils/playback'
import { weightedMidpoint } from '../utils/groupPosition'
import { initials, escapeHtml } from '../utils/people'
import { placeName } from '../composables/useReverseGeocode'
import { formatTime, formatTimeSeconds, formatDay, formatDuration } from '../utils/time'

const props = defineProps({
  recording: { type: Object, required: true }, // { from, to, tracks, groups } (not reactive: can be large)
  version: { type: Number, default: 0 }, // goes up when the live rewind adds new readings
  live: { type: Boolean, default: false }, // rewinding the session that is still live
  title: { type: String, default: '' },
  fileName: { type: String, default: '' }, // set = replaying a CSV file
  canDownload: { type: Boolean, default: false },
  active: { type: Boolean, default: true }, // false while another tab is shown
})
const emit = defineEmits(['close', 'go-live', 'download'])

const SPEEDS = [1, 2, 5, 10, 30, 60, 120]
const SKIPS = [
  { label: '⏪ 10 min', ms: -10 * 60000 },
  { label: '⏪ 1 min', ms: -60000 },
  { label: '1 min ⏩', ms: 60000 },
  { label: '10 min ⏩', ms: 10 * 60000 },
]

const t = ref(props.recording.from) // the moment being shown (ms)
const playing = ref(false)
const speed = ref(1) // 1x = real time
const showTrails = ref(false)
const groupFilter = ref('') // '' = all groups
const selectedId = ref(null)
const following = ref(false)
const selectedPlace = ref(undefined) // undefined = looking up / not yet, null = unavailable
const peopleNow = ref([]) // list under the map (refreshed a few times per second)
const selectedInfo = ref(null)

// The recording object isn't reactive (it can hold 50 000 readings), so these depend on `version`
const from = computed(() => (props.version, props.recording.from))
const to = computed(() => (props.version, props.recording.to))
const duration = computed(() => Math.max(to.value - from.value, 1000))
const marks = computed(() => (props.version, timelineMarks(props.recording)))
const groups = computed(() => (props.version, props.recording.groups))

const replayLength = computed(() => {
  const real = formatDuration(duration.value)
  return speed.value === 1
    ? 'Full replay: ' + real + ' at 1×'
    : 'Full replay: ' + real + ' at 1× · ' + formatDuration(duration.value / speed.value) + ' at ' + speed.value + '×'
})

function groupOf(groupId) {
  return props.recording.groups.find((g) => g.id === groupId) || null
}

// ---------- Map ----------
const mapEl = ref(null)
let map = null
let trailRenderer = null
let trailLayer = null
const markers = {} // userId -> Leaflet marker
const groupMarkers = {} // groupId -> Leaflet marker
let positionsNow = {} // userId -> position at t (from the last draw)

function personIcon(track, state, colour, faded, selected) {
  const classes = 'pm pm-' + state + (faded ? ' pm-faded' : '') + (selected ? ' pm-selected' : '')
  return L.divIcon({
    className: '',
    html: '<div class="' + classes + '" style="background:' + colour + '">' + escapeHtml(initials(track.name)) + '</div>',
    iconSize: [34, 34],
    iconAnchor: [17, 17],
  })
}

let lastSlowUpdate = 0
let lastTrailDraw = 0

// Put every marker where it was at time t
function draw(force = false) {
  if (!map) return
  const time = t.value
  const seen = new Set()
  const byGroup = {}
  positionsNow = {}

  for (const track of props.recording.tracks) {
    const pos = positionAt(track, time)
    if (!pos) continue // hasn't started sharing yet
    const groupId = track.points[pos.index].groupId
    if (groupFilter.value && groupId !== groupFilter.value) continue
    const group = groupOf(groupId)
    const colour = group ? group.colour : '#6c757d'
    const selected = selectedId.value === track.userId
    const faded = selectedId.value !== null && !selected
    const iconKey = pos.state + colour + faded + selected + track.name

    seen.add(track.userId)
    positionsNow[track.userId] = { ...pos, groupId, colour, track }

    let marker = markers[track.userId]
    if (!marker) {
      marker = L.marker([pos.lat, pos.lng], { icon: personIcon(track, pos.state, colour, faded, selected) }).addTo(map)
      marker.on('click', () => select(track.userId))
      marker.iconKey = iconKey
      markers[track.userId] = marker
    } else {
      marker.setLatLng([pos.lat, pos.lng])
      if (marker.iconKey !== iconKey) {
        marker.setIcon(personIcon(track, pos.state, colour, faded, selected))
        marker.iconKey = iconKey
      }
    }
    marker.setZIndexOffset(selected ? 1000 : 0)

    if (pos.state !== 'stopped') {
      if (!byGroup[groupId]) byGroup[groupId] = []
      byGroup[groupId].push({ lat: pos.lat, lng: pos.lng, accuracy: pos.accuracy, time: pos.readingTime })
    }
  }
  for (const userId of Object.keys(markers)) {
    if (!seen.has(userId)) {
      markers[userId].remove()
      delete markers[userId]
    }
  }

  // Group positions (same weighted midpoint as the live map)
  for (const group of props.recording.groups) {
    const mid = weightedMidpoint(byGroup[group.id] || [], time)
    let marker = groupMarkers[group.id]
    if (!mid) {
      if (marker) {
        marker.remove()
        delete groupMarkers[group.id]
      }
      continue
    }
    if (!marker) {
      marker = L.marker([mid.lat, mid.lng], {
        icon: L.divIcon({
          className: '',
          html: '<div class="gm" style="background:' + group.colour + '"></div>',
          iconSize: [18, 18],
          iconAnchor: [9, 9],
        }),
        zIndexOffset: -100,
        interactive: false,
      }).addTo(map)
      groupMarkers[group.id] = marker
    } else {
      marker.setLatLng([mid.lat, mid.lng])
    }
  }

  // Trails are heavier: redraw at most 10 times per second while playing
  const nowMs = performance.now()
  if (force || !playing.value || nowMs - lastTrailDraw > 100) {
    drawTrails(time)
    lastTrailDraw = nowMs
  }

  if (following.value && selectedId.value && markers[selectedId.value]) {
    map.panTo(markers[selectedId.value].getLatLng(), { animate: false })
  }

  // Text under the map: 4 times per second is enough
  if (force || !playing.value || nowMs - lastSlowUpdate > 250) {
    updateLists()
    lastSlowUpdate = nowMs
  }
}

function drawTrails(time) {
  trailLayer.clearLayers()
  if (showTrails.value) {
    for (const userId of Object.keys(positionsNow)) {
      if (userId === selectedId.value) continue
      const p = positionsNow[userId]
      const trail = trailAt(p.track, time - TRAIL_MS, time, p)
      const faded = selectedId.value !== null
      L.polyline(trail.solid, { color: p.colour, weight: 3, opacity: faded ? 0.2 : 0.55, renderer: trailRenderer, interactive: false }).addTo(trailLayer)
      L.polyline(trail.dashed, { color: p.colour, weight: 2, opacity: faded ? 0.15 : 0.4, dashArray: '4 6', renderer: trailRenderer, interactive: false }).addTo(trailLayer)
    }
  }
  const sel = selectedId.value && positionsNow[selectedId.value]
  if (sel) {
    // The selected person's whole trail so far, bold; dashed where the phone lost contact
    const trail = trailAt(sel.track, from.value, time, sel)
    L.polyline(trail.dashed, { color: sel.colour, weight: 4, opacity: 0.8, dashArray: '6 8', renderer: trailRenderer, interactive: false }).addTo(trailLayer)
    L.polyline(trail.solid, { color: sel.colour, weight: 5, opacity: 0.9, renderer: trailRenderer, interactive: false }).addTo(trailLayer)
  }
}

const STATE_TEXT = { live: 'Sharing', stale: 'No update for 2–10 min', offline: 'Lost contact', stopped: 'Stopped sharing' }

function updateLists() {
  peopleNow.value = Object.values(positionsNow)
    .map((p) => ({
      userId: p.track.userId,
      name: p.track.name,
      groupName: groupOf(p.groupId) ? groupOf(p.groupId).name : '-',
      colour: p.colour,
      state: p.state,
      readingTime: p.readingTime,
    }))
    .sort((a, b) => a.name.localeCompare(b.name))

  const sel = selectedId.value && positionsNow[selectedId.value]
  selectedInfo.value = sel
    ? {
        name: sel.track.name,
        username: sel.track.username,
        groupName: groupOf(sel.groupId) ? groupOf(sel.groupId).name : '-',
        colour: sel.colour,
        state: sel.state,
        stateText: STATE_TEXT[sel.state],
        readingTime: sel.readingTime,
        lat: sel.lat,
        lng: sel.lng,
        accuracy: sel.accuracy,
      }
    : null
}

// ---------- Selecting / following ----------
function select(userId) {
  if (selectedId.value !== userId) {
    selectedId.value = userId
    following.value = false
  }
  draw(true)
  lookUpPlace()
}

function deselect() {
  selectedId.value = null
  following.value = false
  draw(true)
}

function toggleFollow() {
  following.value = !following.value
  draw(true)
}

// Place names cost an API call each, so only look them up while paused
let placeTimer = null
function lookUpPlace() {
  clearTimeout(placeTimer)
  selectedPlace.value = undefined
  if (playing.value || !selectedInfo.value) return
  placeTimer = setTimeout(async () => {
    const info = selectedInfo.value
    if (!info || playing.value) return
    const name = await placeName(info.lat, info.lng)
    if (selectedInfo.value === info || (selectedInfo.value && selectedInfo.value.name === info.name)) selectedPlace.value = name
  }, 500)
}

// ---------- Play / pause / seek ----------
let frame = null
let lastFrame = 0

function loop(nowMs) {
  if (playing.value) {
    let next = t.value + (nowMs - lastFrame) * speed.value
    if (next >= to.value) {
      next = to.value
      playing.value = false
      t.value = next
      draw(true)
      if (props.live) emit('go-live') // caught up with now: back to the live map
    } else {
      t.value = next
      draw()
    }
  }
  lastFrame = nowMs
  frame = requestAnimationFrame(loop)
}

function togglePlay() {
  if (!playing.value && t.value >= to.value) t.value = from.value // at the end: start again
  playing.value = !playing.value
  lastFrame = performance.now()
  if (!playing.value) {
    draw(true)
    lookUpPlace()
  }
}

function seek(ms) {
  t.value = Math.min(Math.max(ms, from.value), to.value)
  draw(true)
  if (!playing.value) lookUpPlace()
}

function onSlider(event) {
  seek(Number(event.target.value))
}

function percent(ms) {
  return ((ms - from.value) / duration.value) * 100 + '%'
}

watch([groupFilter, showTrails], () => draw(true))
// Leaflet measures its box when shown; re-measure after coming back to the tab (and pause meanwhile)
watch(
  () => props.active,
  (active) => {
    if (!active) playing.value = false
    else if (map) nextTick(() => map.invalidateSize())
  },
)
watch(
  () => props.version,
  () => draw(true),
)

function onKey(event) {
  if (event.key === 'Escape' && selectedId.value) deselect()
}

onMounted(() => {
  map = createSingaporeMap(mapEl.value)
  trailRenderer = L.canvas({ padding: 0.5 })
  trailLayer = L.layerGroup().addTo(map)
  map.on('click', deselect) // tap empty map = put the person down
  map.on('dragstart', () => (following.value = false)) // looking around yourself = stop following

  // Zoom to everything in the recording
  let minLat = Infinity
  let maxLat = -Infinity
  let minLng = Infinity
  let maxLng = -Infinity
  for (const track of props.recording.tracks) {
    for (const p of track.points) {
      if (p.lat < minLat) minLat = p.lat
      if (p.lat > maxLat) maxLat = p.lat
      if (p.lng < minLng) minLng = p.lng
      if (p.lng > maxLng) maxLng = p.lng
    }
  }
  if (minLat !== Infinity) map.fitBounds(L.latLngBounds([minLat, minLng], [maxLat, maxLng]).pad(0.2), { maxZoom: 17 })

  draw(true)
  frame = requestAnimationFrame(loop)
  document.addEventListener('keydown', onKey)
})

onUnmounted(() => {
  cancelAnimationFrame(frame)
  clearTimeout(placeTimer)
  document.removeEventListener('keydown', onKey)
  if (map) map.remove()
})
</script>

<template>
  <div data-testid="playback-player">
    <!-- Header -->
    <div class="d-flex flex-wrap align-items-center gap-2 mb-2">
      <button class="btn btn-sm btn-outline-secondary" data-testid="playback-back" @click="emit('close')">← All recordings</button>
      <h2 class="h6 mb-0 flex-grow-1">{{ title }}</h2>
      <button v-if="canDownload" class="btn btn-sm btn-outline-primary" data-testid="player-download" @click="emit('download')">
        Download CSV
      </button>
      <button v-if="live" class="btn btn-sm btn-danger" data-testid="go-live-btn" @click="emit('go-live')">● Live</button>
    </div>
    <div v-if="fileName" class="alert alert-info py-2 small" role="status" data-testid="file-banner">
      Replaying from file: <strong>{{ fileName }}</strong> (not the live record). The file stays on this computer.
    </div>

    <!-- Map + selected person's card -->
    <div class="position-relative mb-2">
      <div ref="mapEl" class="playback-map rounded border" data-testid="playback-map"></div>
      <div v-if="selectedInfo" class="person-card shadow-sm small" data-testid="person-card">
        <div class="d-flex align-items-start gap-2">
          <div class="flex-grow-1">
            <strong>{{ selectedInfo.name }}</strong>
            <span v-if="selectedInfo.username" class="text-muted"> @{{ selectedInfo.username }}</span>
            <div>
              <span class="dot me-1" :style="{ backgroundColor: selectedInfo.colour }"></span>{{ selectedInfo.groupName }}
            </div>
          </div>
          <button class="btn-close" aria-label="Close" @click="deselect"></button>
        </div>
        <div class="mt-1">
          {{ selectedInfo.stateText }} · reading at {{ formatTimeSeconds(selectedInfo.readingTime) }}
        </div>
        <div>
          <template v-if="playing">Pause to see the place name</template>
          <template v-else-if="selectedPlace === undefined"><em>Finding place name...</em></template>
          <template v-else>{{ selectedPlace || 'Place name unavailable' }}</template>
        </div>
        <div class="text-muted">
          {{ selectedInfo.lat.toFixed(6) }}, {{ selectedInfo.lng.toFixed(6) }} (±{{ Math.round(selectedInfo.accuracy || 0) }} m)
        </div>
        <button class="btn btn-sm mt-1" :class="following ? 'btn-primary' : 'btn-outline-primary'" data-testid="follow-btn" @click="toggleFollow">
          {{ following ? 'Following' : 'Follow' }}
        </button>
      </div>
    </div>

    <!-- Controls -->
    <div class="card mb-2">
      <div class="card-body py-2">
        <div class="d-flex align-items-baseline gap-2 mb-1">
          <span class="fs-4 fw-semibold" data-testid="playback-time">{{ formatTimeSeconds(t) }}</span>
          <span class="text-muted small">{{ formatDay(t) }}</span>
        </div>

        <!-- Timeline with start (green) / stop (grey) marks -->
        <div class="timeline">
          <div class="marks">
            <span
              v-for="(m, i) in marks"
              :key="i"
              class="mark"
              :class="'mark-' + m.kind"
              :style="{ left: percent(m.t) }"
              :title="m.name + (m.kind === 'stop' ? ' stopped sharing ' : ' started sharing ') + formatTime(m.t)"
            ></span>
          </div>
          <input
            type="range"
            class="form-range"
            :min="from"
            :max="to"
            step="1000"
            :value="t"
            aria-label="Playback time"
            data-testid="timeline"
            @input="onSlider"
          />
        </div>
        <div class="d-flex justify-content-between small text-muted mb-2">
          <span>{{ formatTime(from) }}</span>
          <span>{{ live ? 'now' : formatTime(to) }}</span>
        </div>

        <div class="d-flex flex-wrap align-items-center gap-1 mb-2">
          <button v-for="s in SKIPS.slice(0, 2)" :key="s.label" class="btn btn-sm btn-outline-secondary" @click="seek(t + s.ms)">
            {{ s.label }}
          </button>
          <button class="btn btn-sm btn-primary px-3" data-testid="play-btn" @click="togglePlay">
            {{ playing ? '⏸ Pause' : '▶ Play' }}
          </button>
          <button v-for="s in SKIPS.slice(2)" :key="s.label" class="btn btn-sm btn-outline-secondary" @click="seek(t + s.ms)">
            {{ s.label }}
          </button>
        </div>

        <div class="d-flex flex-wrap align-items-center gap-3">
          <div class="btn-group btn-group-sm" role="group" aria-label="Speed">
            <button
              v-for="s in SPEEDS"
              :key="s"
              class="btn"
              :class="speed === s ? 'btn-dark' : 'btn-outline-dark'"
              :data-testid="'speed-' + s"
              @click="speed = s"
            >
              {{ s }}×
            </button>
          </div>
          <div class="form-check form-switch mb-0">
            <input id="show-trails" v-model="showTrails" class="form-check-input" type="checkbox" data-testid="trails-switch" />
            <label class="form-check-label small" for="show-trails">Show trails (last 10 min)</label>
          </div>
          <select v-model="groupFilter" class="form-select form-select-sm w-auto" aria-label="Group filter" data-testid="group-filter">
            <option value="">All groups</option>
            <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
          </select>
        </div>
        <div class="small text-muted mt-1" data-testid="replay-length">{{ replayLength }}</div>
      </div>
    </div>

    <div class="d-flex flex-wrap gap-3 small text-muted mb-2">
      <span><span class="dot me-1" style="background-color: #0d6efd"></span>Sharing</span>
      <span><span class="dot dot-stale me-1" style="background-color: #0d6efd"></span>No update for 2–10 min</span>
      <span><span class="dot dot-offline me-1"></span>Lost contact (10+ min)</span>
      <span><span class="dot dot-stopped me-1"></span>Stopped sharing</span>
      <span>Dashed trail = no readings (e.g. tunnel)</span>
    </div>

    <p class="small text-muted mb-1">Tap a person to see their trail.</p>
    <p v-if="peopleNow.length === 0" class="small text-muted" data-testid="playback-nobody">Nobody is sharing at this moment.</p>
    <ul v-else class="list-group small" data-testid="playback-people">
      <li
        v-for="p in peopleNow"
        :key="p.userId"
        class="list-group-item list-group-item-action d-flex align-items-center gap-2"
        :class="{ active: p.userId === selectedId }"
        role="button"
        @click="select(p.userId)"
      >
        <span class="dot" :class="'dot-' + p.state" :style="{ backgroundColor: p.colour }"></span>
        <span class="flex-grow-1 text-truncate"><strong>{{ p.name }}</strong><span class="opacity-75"> · {{ p.groupName }}</span></span>
        <span class="text-nowrap">{{ STATE_TEXT[p.state] }}</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.playback-map {
  height: 60vh;
  min-height: 320px;
}
.person-card {
  position: absolute;
  left: 10px;
  bottom: 24px;
  z-index: 1000; /* above Leaflet's layers */
  width: min(300px, calc(100% - 20px));
  padding: 0.5rem 0.75rem;
  background: #fff;
  border-radius: 0.5rem;
}
.timeline {
  position: relative;
  padding-top: 10px;
}
.marks {
  position: absolute;
  top: 0;
  left: 8px; /* line up with the slider track */
  right: 8px;
  height: 10px;
}
.mark {
  position: absolute;
  width: 2px;
  height: 10px;
  transform: translateX(-1px);
}
.mark-start {
  background: #198754;
}
.mark-stop {
  background: #6c757d;
}
.dot {
  display: inline-block;
  width: 0.75rem;
  height: 0.75rem;
  border-radius: 50%;
  vertical-align: middle;
  flex-shrink: 0;
}
.dot-stale {
  opacity: 0.5;
}
.dot-offline {
  background-color: #adb5bd !important;
}
.dot-stopped {
  background-color: transparent !important;
  border: 2px dashed #6c757d;
}
</style>
