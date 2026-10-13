<script setup>
// Live map of one event: a round marker with initials for every person I may see,
// in their group's colour (faded when stale, grey when offline), plus a diamond for
// each group's combined position. Markers glide steadily between readings (markerMotion.js).
//
// Tap a person's marker: their info card + their TRAIL for the current live session
// (solid where readings arrived on time, dashed over gaps, a dot every 2 minutes).
// Hover / tap the trail: when they were there + the place name. The trail only covers the
// session that is live now, so the next event starts with a clean map.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles + reverse geocoding (c) Singapore Land Authority
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { supabase } from '../lib/supabase'
import { createSingaporeMap } from '../utils/onemap'
import { moveMarker, isBadFix } from '../utils/markerMotion'
import { placeName } from '../composables/useReverseGeocode'
import { weightedMidpoint } from '../utils/groupPosition'
import { initials, escapeHtml, timeAgo, freshness } from '../utils/people'
import { formatTime, formatTimeSeconds } from '../utils/time'
import { GAP_MS } from '../utils/playback'

const props = defineProps({
  eventId: { type: String, required: true },
  positions: { type: Object, required: true }, // from useLiveLocations (EventView)
  now: { type: Number, required: true }, // ticking clock from useLiveLocations
  liveError: { type: String, default: '' },
  liveSince: { type: Number, default: null }, // start of the live session (ms), null = not live
  onReading: { type: Function, default: null }, // useLiveLocations: subscribe to new readings
  members: { type: Array, required: true }, // from useEventData
  groups: { type: Array, required: true },
  myUserId: { type: String, default: null },
  active: { type: Boolean, default: true }, // false while another tab is shown
})

const positions = computed(() => props.positions)
const now = computed(() => props.now)
const errorMsg = computed(() => props.liveError)

const mapEl = ref(null) // the <div> Leaflet draws into
let map = null
const personMarkers = {} // userId -> Leaflet marker
const groupMarkers = {} // groupId -> Leaflet marker
const places = {} // userId -> place name text (filled when a tooltip opens)
let fittedOnce = false

// Follow mode: keep one person centred on the map while they move
const followedId = ref(null) // userId being followed (null = not following)
const followedName = computed(() => {
  const p = people.value.find((x) => x.userId === followedId.value)
  return p ? p.name : ''
})

function memberOf(userId) {
  return props.members.find((m) => m.id === userId) || null
}
function groupOf(groupId) {
  return props.groups.find((g) => g.id === groupId) || null
}

// People list under the map (newest first)
const people = computed(() =>
  Object.values(positions.value)
    .map((p) => {
      const member = memberOf(p.userId)
      const group = groupOf(p.groupId)
      return {
        ...p,
        name: member ? member.display_name : 'Unknown',
        username: member ? member.username : '',
        groupName: group ? group.name : '-',
        colour: group ? group.colour : '#6c757d',
        state: freshness(p.time, now.value, p.source),
      }
    })
    .sort((a, b) => b.time - a.time),
)

// ---------- Tooltip text ----------
function tooltipHtml(person) {
  const place = places[person.userId]
  return (
    '<strong>' + escapeHtml(person.name) + '</strong>' +
    (person.username ? ' <span class="text-muted">@' + escapeHtml(person.username) + '</span>' : '') +
    '<br>' + escapeHtml(person.groupName) +
    '<br>' + (place === undefined ? '<em>Finding place name...</em>' : escapeHtml(place || 'Place name unavailable')) +
    '<br>' + person.lat.toFixed(6) + ', ' + person.lng.toFixed(6) +
    ' (±' + Math.round(person.accuracy || 0) + ' m)' +
    (person.state === 'stopped'
      ? '<br><strong>Stopped sharing</strong> at ' + formatTime(person.time)
      : '<br>Last seen ' + timeAgo(person.time, now.value)) +
    (selectedId.value === person.userId && props.liveSince ? '<br><span class="text-muted">Trail shown · tap the map to hide</span>' : '')
  )
}

async function lookUpPlace(userId) {
  const p = positions.value[userId]
  if (!p) return
  places[userId] = await placeName(p.lat, p.lng)
  refreshTooltip(userId)
}

function refreshTooltip(userId) {
  const marker = personMarkers[userId]
  const person = people.value.find((x) => x.userId === userId)
  if (marker && person) marker.setTooltipContent(tooltipHtml(person))
}

// ---------- Draw / update markers ----------
function personIcon(person) {
  const me = person.userId === props.myUserId ? ' pm-me' : ''
  const selected = person.userId === selectedId.value ? ' pm-selected' : ''
  return L.divIcon({
    className: '', // no default white square
    html:
      '<div class="pm pm-' + person.state + me + selected + '" style="background:' + person.colour + '">' +
      escapeHtml(initials(person.name)) + '</div>',
    iconSize: [34, 34],
    iconAnchor: [17, 17],
    tooltipAnchor: [0, -18],
  })
}

// While a marker glides: follow mode keeps it centred, and the trail's last piece follows it
function onMarkerStep(userId, latlng) {
  if (followedId.value === userId && map) map.panTo(latlng, { animate: false })
  if (selectedId.value === userId) updateTrailTip(latlng)
}

function render() {
  if (!map) return

  // People
  const seen = new Set()
  for (const person of people.value) {
    seen.add(person.userId)
    let marker = personMarkers[person.userId]
    const iconKey = person.state + person.colour + person.name + (person.userId === selectedId.value)

    if (!marker) {
      marker = L.marker([person.lat, person.lng], { icon: personIcon(person) }).addTo(map)
      marker.bindTooltip('', { direction: 'top' })
      // Look up the place name only when someone actually opens the tooltip
      marker.on('tooltipopen', () => lookUpPlace(person.userId))
      marker.on('click', () => select(person.userId)) // tap = card + trail
      marker.iconKey = iconKey
      marker.readingTime = person.time
      marker.readingAccuracy = person.accuracy
      personMarkers[person.userId] = marker
    } else if (person.time > marker.readingTime) {
      // A new reading: glide to it (or ignore it as GPS wobble / one bad fix)
      const gapMs = person.time - marker.readingTime
      const badFix = isBadFix(person.accuracy, marker.readingAccuracy, gapMs)
      marker.readingTime = person.time
      if (!badFix) {
        marker.readingAccuracy = person.accuracy
        const userId = person.userId
        const moved = moveMarker(marker, L.latLng(person.lat, person.lng), {
          accuracy: person.accuracy,
          gapMs,
          onStep: (latlng) => onMarkerStep(userId, latlng),
        })
        if (moved) {
          delete places[person.userId] // new position = new place name
          if (marker.isTooltipOpen()) lookUpPlace(person.userId)
        }
      }
    }
    if (marker.iconKey !== iconKey) {
      marker.setIcon(personIcon(person))
      marker.iconKey = iconKey
    }
    marker.setZIndexOffset(person.userId === selectedId.value ? 1000 : 0)
    marker.setTooltipContent(tooltipHtml(person))
  }
  // Remove people who are no longer visible (e.g. moved to another group)
  for (const userId of Object.keys(personMarkers)) {
    if (!seen.has(userId)) {
      personMarkers[userId].remove()
      delete personMarkers[userId]
      if (selectedId.value === userId) deselect()
    }
  }

  // Groups: weighted midpoint of each group's ICs
  for (const group of props.groups) {
    // People who pressed Stop don't count towards the group position
    const readings = people.value.filter((p) => p.groupId === group.id && p.state !== 'stopped')
    const mid = weightedMidpoint(readings, now.value)
    let marker = groupMarkers[group.id]
    if (!mid) {
      if (marker) {
        marker.remove()
        delete groupMarkers[group.id]
      }
      continue
    }
    const text = escapeHtml(group.name) + ' position<br>from ' + mid.used + ' IC' + (mid.used > 1 ? 's' : '')
    if (!marker) {
      marker = L.marker([mid.lat, mid.lng], {
        icon: L.divIcon({
          className: '',
          html: '<div class="gm" style="background:' + group.colour + '"></div>',
          iconSize: [18, 18],
          iconAnchor: [9, 9],
        }),
        zIndexOffset: -100, // keep people on top
      }).addTo(map)
      marker.bindTooltip(text, { direction: 'top' })
      groupMarkers[group.id] = marker
    } else {
      moveMarker(marker, L.latLng(mid.lat, mid.lng), { gapMs: 3000 }) // short glide; tiny changes ignored
      marker.setTooltipContent(text)
    }
  }

  if (followedId.value && !personMarkers[followedId.value]) stopFollowing() // they're no longer on the map

  // Zoom to everyone the first time we have data
  if (!fittedOnce && people.value.length > 0) {
    map.fitBounds(L.latLngBounds(people.value.map((p) => [p.lat, p.lng])).pad(0.3), { maxZoom: 17 })
    fittedOnce = true
  }
}

// Redraw when positions, the clock, members or groups change
watch([people, () => props.groups], render, { deep: true })

// Leaflet measures its box when shown; re-measure after the tab becomes visible again
watch(
  () => props.active,
  (active) => {
    if (active && map) nextTick(() => map.invalidateSize())
  },
)

// ---------- Trail of the selected person (current live session only) ----------
const selectedId = ref(null)
let trailPoints = [] // [{ t, lat, lng, accuracy, source }] oldest first
let trailLayer = null // solid + dashed lines and dots
let trailTip = null // last piece: last reading -> the gliding marker
let hoverLine = null // wide invisible line that catches hover / taps
let hoverMarker = null // small ring on the hovered point
let loadToken = 0

async function select(userId) {
  if (selectedId.value === userId) return deselect() // tap again = hide
  selectedId.value = userId
  render()
  const marker = personMarkers[userId]
  if (marker) marker.openTooltip()
  await loadTrail(userId)
}

function deselect() {
  selectedId.value = null
  trailPoints = []
  clearTrail()
  render()
}

function clearTrail() {
  if (trailLayer) trailLayer.clearLayers()
  if (hoverMarker) hoverMarker.remove()
  trailTip = null
  hoverLine = null
  hoverMarker = null
}

// The person's readings since the live session started (RLS: only people I may see).
// Pages of 1000 (the API's limit per request).
async function loadTrail(userId) {
  clearTrail()
  trailPoints = []
  if (!props.liveSince) return
  const token = ++loadToken
  const since = new Date(props.liveSince).toISOString()
  const rows = []
  for (let from = 0; ; from += 1000) {
    const { data, error } = await supabase
      .from('locations')
      .select('lat, lng, accuracy, source, recorded_at')
      .eq('event_id', props.eventId)
      .eq('user_id', userId)
      .gte('recorded_at', since)
      .order('recorded_at')
      .range(from, from + 999)
    if (error || token !== loadToken) return
    rows.push(...data)
    if (data.length < 1000) break
  }
  if (selectedId.value !== userId) return
  trailPoints = rows.map((r) => ({ t: new Date(r.recorded_at).getTime(), lat: r.lat, lng: r.lng, accuracy: r.accuracy, source: r.source }))
  drawTrail()
}

// New reading for the selected person (from Realtime): extend the trail
function onNewReading(row) {
  if (!selectedId.value || row.user_id !== selectedId.value || !props.liveSince) return
  const t = new Date(row.recorded_at).getTime()
  if (t < props.liveSince) return
  trailPoints.push({ t, lat: row.lat, lng: row.lng, accuracy: row.accuracy, source: row.source })
  trailPoints.sort((a, b) => a.t - b.t)
  drawTrail()
}

function selectedColour() {
  const p = positions.value[selectedId.value]
  const g = p ? groupOf(p.groupId) : null
  return g ? g.colour : '#0d6efd'
}

function drawTrail() {
  clearTrail()
  if (!map || trailPoints.length === 0) return
  const colour = selectedColour()

  // Split into solid parts and dashed gaps (> 2 min without readings, or after a Stop)
  const solid = []
  const dashed = []
  let line = []
  let prev = null
  for (const p of trailPoints) {
    if (prev && (p.t - prev.t > GAP_MS || prev.source === 'stop')) {
      if (line.length > 1) solid.push(line)
      dashed.push([[prev.lat, prev.lng], [p.lat, p.lng]])
      line = []
    }
    line.push([p.lat, p.lng])
    prev = p
  }
  if (line.length > 1) solid.push(line)

  L.polyline(dashed, { color: colour, weight: 3, opacity: 0.7, dashArray: '6 8', interactive: false }).addTo(trailLayer)
  L.polyline(solid, { color: colour, weight: 4, opacity: 0.85, interactive: false }).addTo(trailLayer)

  // Breadcrumb dots: the start, then one every 2 minutes
  let lastDot = -Infinity
  trailPoints.forEach((p, i) => {
    const isStart = i === 0
    if (!isStart && p.t - lastDot < 2 * 60 * 1000) return
    lastDot = p.t
    L.circleMarker([p.lat, p.lng], {
      radius: isStart ? 6 : 3.5,
      color: isStart ? '#198754' : colour,
      weight: 2,
      fillColor: '#fff',
      fillOpacity: 1,
      interactive: false,
    }).addTo(trailLayer)
  })

  // Last piece follows the gliding marker
  const last = trailPoints[trailPoints.length - 1]
  const marker = personMarkers[selectedId.value]
  trailTip = L.polyline([[last.lat, last.lng], marker ? marker.getLatLng() : [last.lat, last.lng]], {
    color: colour,
    weight: 4,
    opacity: 0.85,
    interactive: false,
  }).addTo(trailLayer)

  // Hover / tap anywhere along the trail: time + place of the nearest reading
  hoverLine = L.polyline(trailPoints.map((p) => [p.lat, p.lng]), { color: '#000', weight: 22, opacity: 0, className: 'trail-hover', bubblingMouseEvents: false }).addTo(trailLayer)
  hoverLine.on('mousemove click', (e) => showPointInfo(e.latlng))
  hoverLine.on('mouseout', hidePointInfo)
}

function updateTrailTip(latlng) {
  if (!trailTip || trailPoints.length === 0) return
  const last = trailPoints[trailPoints.length - 1]
  trailTip.setLatLngs([[last.lat, last.lng], latlng])
}

// Nearest reading to where the pointer is
function nearestPoint(latlng) {
  let best = null
  let bestDistance = Infinity
  for (const p of trailPoints) {
    const d = map.distance(latlng, [p.lat, p.lng])
    if (d < bestDistance) {
      bestDistance = d
      best = p
    }
  }
  return best
}

let hoverTimer = null
let hoveredPoint = null
function showPointInfo(latlng) {
  const p = nearestPoint(latlng)
  if (!p) return
  if (!hoverMarker) {
    hoverMarker = L.circleMarker([p.lat, p.lng], { radius: 7, color: '#212529', weight: 2, fillColor: selectedColour(), fillOpacity: 1, interactive: false })
      .bindTooltip('', { direction: 'top', offset: [0, -6] })
      .addTo(map)
  }
  hoverMarker.setLatLng([p.lat, p.lng])
  if (hoveredPoint === p) return
  hoveredPoint = p
  const name = memberOf(selectedId.value) ? memberOf(selectedId.value).display_name : ''
  const head = '<strong>' + formatTimeSeconds(p.t) + '</strong>' + (name ? ' · ' + escapeHtml(name) : '')
  hoverMarker.setTooltipContent(head + '<br><em>Finding place name...</em>').openTooltip()
  // Place names cost an API call: only for the point the pointer rests on (cached by position)
  clearTimeout(hoverTimer)
  hoverTimer = setTimeout(async () => {
    const place = await placeName(p.lat, p.lng)
    if (hoveredPoint === p && hoverMarker) hoverMarker.setTooltipContent(head + '<br>' + escapeHtml(place || 'Place name unavailable'))
  }, 250)
}

function hidePointInfo() {
  clearTimeout(hoverTimer)
  hoveredPoint = null
  if (hoverMarker) {
    hoverMarker.remove()
    hoverMarker = null
  }
}

// A new live session (or the event ended): the old trail doesn't belong to it
watch(
  () => props.liveSince,
  () => {
    if (selectedId.value) loadTrail(selectedId.value)
  },
)

// ---------- List under the map ----------
// Text on the right of the people list
function statusText(p) {
  if (p.state === 'live') return 'Live'
  if (p.state === 'stopped') return 'Stopped ' + formatTime(p.time)
  if (p.state === 'offline') return 'Lost contact · ' + timeAgo(p.time, now.value)
  return timeAgo(p.time, now.value)
}

// Tap a person in the list: zoom to them, follow them as they move, and show their trail
function focus(person) {
  followedId.value = person.userId
  const marker = personMarkers[person.userId]
  map.setView(marker ? marker.getLatLng() : [person.lat, person.lng], 18)
  if (selectedId.value !== person.userId) select(person.userId)
  else if (marker) marker.openTooltip()
}

function stopFollowing() {
  followedId.value = null
}

let unsubscribe = null
onMounted(() => {
  // Centre on Singapore with the OneMap basemap (shared setup in utils/onemap.js)
  map = createSingaporeMap(mapEl.value)
  trailLayer = L.layerGroup().addTo(map)
  // Dragging the map yourself means "let me look around": stop following
  map.on('dragstart', stopFollowing)
  // Tap empty map: hide the trail
  map.on('click', () => {
    if (selectedId.value) deselect()
  })
  if (props.onReading) unsubscribe = props.onReading(onNewReading)
  render()
})

onUnmounted(() => {
  if (unsubscribe) unsubscribe()
  clearTimeout(hoverTimer)
  if (map) map.remove()
})
</script>

<template>
  <div>
    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert">{{ errorMsg }}</div>
    <div class="position-relative mb-3">
      <div ref="mapEl" class="live-map rounded border" data-testid="live-map"></div>
      <!-- Shown while following someone (on top of the map) -->
      <div v-if="followedId" class="follow-bar shadow-sm" data-testid="follow-bar">
        <span class="text-truncate">Following <strong>{{ followedName }}</strong></span>
        <button class="btn btn-sm btn-outline-secondary py-0" data-testid="stop-follow-btn" @click="stopFollowing">Stop</button>
      </div>
    </div>

    <!-- What the marker styles mean -->
    <div class="d-flex flex-wrap gap-3 small text-muted mb-3" data-testid="map-legend">
      <span><span class="dot d-inline-block align-middle me-1" style="background-color: #0d6efd"></span>Live</span>
      <span><span class="dot dot-stale d-inline-block align-middle me-1" style="background-color: #0d6efd"></span>No update for 2–10 min</span>
      <span><span class="dot dot-offline d-inline-block align-middle me-1"></span>Lost contact (10+ min)</span>
      <span><span class="dot dot-stopped d-inline-block align-middle me-1"></span>Stopped sharing</span>
      <span v-if="liveSince">Tap a marker to see their trail</span>
    </div>

    <h2 class="h6 mb-0">People on the map</h2>
    <p class="small text-muted mb-2">Tap a person to follow them and see their trail.</p>
    <p v-if="people.length === 0" class="text-muted small" data-testid="no-positions">
      No one is sharing yet. Only ICs share their location.
    </p>
    <ul v-else class="list-group small" data-testid="people-list">
      <li
        v-for="p in people"
        :key="p.userId"
        class="list-group-item list-group-item-action d-flex align-items-center gap-2"
        :class="{ active: p.userId === followedId }"
        role="button"
        :data-testid="'person-' + p.username"
        @click="focus(p)"
      >
        <span class="dot" :class="'dot-' + p.state" :style="{ backgroundColor: p.colour }"></span>
        <span class="flex-grow-1 text-truncate">
          <strong>{{ p.name }}</strong>
          <span class="text-muted"> · {{ p.groupName }}</span>
        </span>
        <span class="text-nowrap" :class="{ 'text-muted': p.state !== 'live' }" data-testid="last-seen">
          {{ statusText(p) }}
        </span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.follow-bar {
  /* Floats over the top of the map, above Leaflet's layers (z-index 400+) */
  position: absolute;
  top: 10px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 1000;
  max-width: calc(100% - 100px); /* leave room for the zoom buttons on small screens */
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0.5rem 0.25rem 0.75rem;
  background: #fff;
  border-radius: 999px;
  font-size: 0.875rem;
}
.live-map {
  height: 60vh;
  min-height: 320px;
}
.dot {
  width: 0.75rem;
  height: 0.75rem;
  border-radius: 50%;
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
:global(.trail-hover) {
  cursor: pointer;
}
</style>
