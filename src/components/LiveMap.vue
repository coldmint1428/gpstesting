<script setup>
// Live map of one event: a round marker with initials for every person I may see,
// in their group's colour (faded when stale, grey when offline), plus a diamond for
// each group's combined position. Hover (or tap) a marker for name, place name,
// coordinates, accuracy and "last seen".
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles + reverse geocoding (c) Singapore Land Authority
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { useLiveLocations } from '../composables/useLiveLocations'
import { placeName } from '../composables/useReverseGeocode'
import { weightedMidpoint } from '../utils/groupPosition'
import { initials, escapeHtml, timeAgo, freshness } from '../utils/people'

const props = defineProps({
  eventId: { type: String, required: true },
  members: { type: Array, required: true }, // from useEventData
  groups: { type: Array, required: true },
  myUserId: { type: String, default: null },
  active: { type: Boolean, default: true }, // false while another tab is shown
})

const { positions, errorMsg, now } = useLiveLocations(props.eventId)

const mapEl = ref(null) // the <div> Leaflet draws into
let map = null
const personMarkers = {} // userId -> Leaflet marker
const groupMarkers = {} // groupId -> Leaflet marker
const places = {} // userId -> place name text (filled when a tooltip opens)
let fittedOnce = false

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
      ? '<br><strong>Stopped sharing</strong> at ' + person.time.toLocaleTimeString('en-SG', { hour: 'numeric', minute: '2-digit' })
      : '<br>Last seen ' + timeAgo(person.time, now.value))
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
  return L.divIcon({
    className: '', // no default white square
    html:
      '<div class="pm pm-' + person.state + me + '" style="background:' + person.colour + '">' +
      escapeHtml(initials(person.name)) + '</div>',
    iconSize: [34, 34],
    iconAnchor: [17, 17],
    tooltipAnchor: [0, -18],
  })
}

function render() {
  if (!map) return

  // People
  const seen = new Set()
  for (const person of people.value) {
    seen.add(person.userId)
    let marker = personMarkers[person.userId]
    const iconKey = person.state + person.colour + person.name

    if (!marker) {
      marker = L.marker([person.lat, person.lng], { icon: personIcon(person) }).addTo(map)
      marker.bindTooltip('', { direction: 'top' })
      // Look up the place name only when someone actually opens the tooltip
      marker.on('tooltipopen', () => lookUpPlace(person.userId))
      marker.on('click', () => marker.toggleTooltip()) // phones have no hover
      marker.iconKey = iconKey
      personMarkers[person.userId] = marker
    } else {
      const moved = !marker.getLatLng().equals([person.lat, person.lng])
      marker.setLatLng([person.lat, person.lng])
      if (marker.iconKey !== iconKey) {
        marker.setIcon(personIcon(person))
        marker.iconKey = iconKey
      }
      if (moved) {
        delete places[person.userId] // new position = new place name
        if (marker.isTooltipOpen()) lookUpPlace(person.userId)
      }
    }
    marker.setTooltipContent(tooltipHtml(person))
  }
  // Remove people who are no longer visible (e.g. moved to another group)
  for (const userId of Object.keys(personMarkers)) {
    if (!seen.has(userId)) {
      personMarkers[userId].remove()
      delete personMarkers[userId]
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
      marker.setLatLng([mid.lat, mid.lng])
      marker.setTooltipContent(text)
    }
  }

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

// Text on the right of the people list
function statusText(p) {
  if (p.state === 'live') return 'Live'
  if (p.state === 'stopped') return 'Stopped ' + p.time.toLocaleTimeString('en-SG', { hour: 'numeric', minute: '2-digit' })
  if (p.state === 'offline') return 'Lost contact · ' + timeAgo(p.time, now.value)
  return timeAgo(p.time, now.value)
}

function focus(person) {
  map.setView([person.lat, person.lng], 18)
  personMarkers[person.userId].openTooltip()
}

onMounted(() => {
  map = L.map(mapEl.value, { minZoom: 11, maxZoom: 19 }).setView([1.3521, 103.8198], 12)
  L.tileLayer('https://www.onemap.gov.sg/maps/tiles/Default/{z}/{x}/{y}.png', {
    detectRetina: true,
    maxZoom: 19,
    minZoom: 11,
    attribution:
      '<img src="https://www.onemap.gov.sg/web-assets/images/logo/om_logo.png" style="height:20px;width:20px;"/>&nbsp;' +
      '<a href="https://www.onemap.gov.sg/" target="_blank" rel="noopener noreferrer">OneMap</a>&nbsp;&copy;&nbsp;contributors&nbsp;&#124;&nbsp;' +
      '<a href="https://www.sla.gov.sg/" target="_blank" rel="noopener noreferrer">Singapore Land Authority</a>',
  }).addTo(map)
  render()
})

onUnmounted(() => {
  if (map) map.remove()
})
</script>

<template>
  <div>
    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert">{{ errorMsg }}</div>
    <div ref="mapEl" class="live-map rounded border mb-3" data-testid="live-map"></div>

    <!-- What the marker styles mean -->
    <div class="d-flex flex-wrap gap-3 small text-muted mb-3" data-testid="map-legend">
      <span><span class="dot d-inline-block align-middle me-1" style="background-color: #0d6efd"></span>Live</span>
      <span><span class="dot dot-stale d-inline-block align-middle me-1" style="background-color: #0d6efd"></span>No update for 2–10 min</span>
      <span><span class="dot dot-offline d-inline-block align-middle me-1"></span>Lost contact (10+ min)</span>
      <span><span class="dot dot-stopped d-inline-block align-middle me-1"></span>Stopped sharing</span>
    </div>

    <h2 class="h6">People on the map</h2>
    <p v-if="people.length === 0" class="text-muted small" data-testid="no-positions">
      No one is sharing yet. Only ICs share their location.
    </p>
    <ul v-else class="list-group small" data-testid="people-list">
      <li
        v-for="p in people"
        :key="p.userId"
        class="list-group-item list-group-item-action d-flex align-items-center gap-2"
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

/* Marker styles are global because Leaflet creates the marker HTML outside Vue */
:global(.pm) {
  width: 34px;
  height: 34px;
  border-radius: 50%;
  border: 2px solid #fff;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.4);
  color: #fff;
  font: 600 12px/30px system-ui, sans-serif;
  text-align: center;
  text-shadow: 0 0 2px rgba(0, 0, 0, 0.6);
}
:global(.pm-me) {
  border-color: #212529;
}
:global(.pm-stale) {
  opacity: 0.55;
}
:global(.pm-offline) {
  background: #adb5bd !important;
  opacity: 0.8;
}
:global(.pm-stopped) {
  /* Pressed Stop: white with a dashed outline (different from grey "lost contact") */
  background: #fff !important;
  color: #495057;
  text-shadow: none;
  border: 2px dashed #6c757d;
}
:global(.gm) {
  width: 18px;
  height: 18px;
  transform: rotate(45deg);
  border: 2px solid #fff;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.4);
}
</style>
