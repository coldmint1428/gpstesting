<script setup>
// Live map of one event: a round marker with initials for every person I may see,
// in their group's colour (faded when stale, grey when offline), plus a diamond for each
// group with 2+ ICs at the group's combined position.
//
// Motion (utils/liveMotion.js): everyone is drawn ~12 s in the past, sliding between two real
// readings, so markers move steadily along the real path instead of jumping to each new
// reading. Readings that arrive late (tunnel, battery saver, paused tab) slot into place;
// one animation loop moves all markers while the map is on screen.
//
// Tap a person's marker: their info card + their TRAIL for the current live session, drawn
// only up to where the marker is (solid; dashed only over a real gap of 2+ minutes without
// readings, or after Stop; a dot every 2 minutes). Tap the trail or a dot: when they were
// there + the place name. The trail only covers the session that is live now.
//
// Ops view (merger Stage 7) was here: zoomed out, groups gathered into one bubble per zone with the worst movement
// status, and a dashed line along the group's route to its zone. It read `movement_status` through `useOps`, and step
// 25 deleted that engine with the run sheet.
//
// THE PLAN UNDER THE PEOPLE (step 30). While the live session runs a plan, the walk the plan states is drawn under the
// people: one dashed line per group in the group's colour, broken where the plan takes the group off site, and the leg
// the clock is on redrawn bold and solid -- the one comparison this page exists for, "they should be between the gate
// and the stage and they are still at the gate", in one picture instead of a row on one page and a line on another.
// The rows are `session_timetable`'s, through `usePlanWalk` (the follower's map asks the same composable), and the
// rules that turn them into a line are `planWalk`'s. There is no interpolated "should be here" mark between two
// moments: a mark says what the plan states, and a plan states points at moments, not a pace between them (step 20
// refused to invent an ETA for the same reason). The line is `interactive: false` on purpose -- a line across the venue
// must not swallow the taps meant for the people under it, which are this screen's subject.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles + reverse geocoding (c) Singapore Land Authority
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { supabase } from '../lib/supabase'
import { createSingaporeMap } from '../utils/onemap'
import { newTrack, addReading, noteDelay, prune, advance, positionAt, trailUpTo } from '../utils/liveMotion'
import { placeName } from '../composables/useReverseGeocode'
import { usePlanWalk } from '../composables/usePlanWalk'
import { walksOf, legNow } from '../utils/planWalk'
import { weightedMidpoint } from '../utils/groupPosition'
import { initials, escapeHtml, timeAgo, freshness } from '../utils/people'
import BenchAlert from './BenchAlert.vue'
import { formatTime, formatTimeSeconds } from '../utils/time'
import { areaStyle } from '../utils/areaKinds'

const props = defineProps({
  eventId: { type: String, required: true },
  positions: { type: Object, required: true }, // from useLiveLocations (EventView)
  now: { type: Number, required: true }, // ticking clock from useLiveLocations
  liveError: { type: String, default: '' },
  reconnecting: { type: Boolean, default: false }, // connection lost, retrying
  liveSince: { type: Number, default: null }, // start of the live session (ms), null = not live
  onReading: { type: Function, default: null }, // useLiveLocations: subscribe to new readings
  members: { type: Array, required: true }, // from useEventData
  groups: { type: Array, required: true },
  myUserId: { type: String, default: null },
  active: { type: Boolean, default: true }, // false while another tab is shown
  // From the server (useZoneActivity, merger Stage 2)
  zoneStays: { type: Object, default: () => ({}) }, // userId -> [{ zone, enteredAt }]
  zoneCounts: { type: Object, default: () => ({}) }, // zoneId -> { ics, groups }
  noGoOccupied: { type: Array, default: () => [] }, // No-Go zone ids somebody is inside
  groupPositions: { type: Object, default: () => ({}) }, // groupId -> { speedMps, icsSharing, lastSeen }
  // The live session, when it is running a plan: the walk the plan states is drawn under the people (step 30). Null
  // while the event is not live, or is live without a plan -- and then nothing is drawn and nothing is asked for.
  session: { type: Object, default: null },
})

const positions = computed(() => props.positions)
const now = computed(() => props.now)
const errorMsg = computed(() => props.liveError)
const dismissedError = ref('') // the error the viewer closed (a new one shows again)

const mapEl = ref(null) // the <div> Leaflet draws into
let map = null
const personMarkers = {} // userId -> Leaflet marker
const groupMarkers = {} // groupId -> Leaflet marker (groups with 2+ ICs on the map)
const tracks = {} // userId -> recent readings + playhead (liveMotion.js)
const places = {} // userId -> place name text (filled when a tooltip opens)
let framed = false // the camera has been set once
let framedWithPlan = false // ...and the plan's walk was in that frame
let userMoved = false // somebody dragged the map: the view is theirs now, not every read's

// Follow mode: keep one person centred on the map while they move
const followedId = ref(null) // userId being followed (null = not following)
const followedName = computed(() => {
  const p = people.value.find((x) => x.userId === followedId.value)
  return p ? p.name : ''
})

// Looked up for every person on every update, so by id rather than by searching the lists (300+
// members made each lookup a scan of 300+, for each of 300+ people).
const memberById = computed(() => new Map(props.members.map((m) => [m.id, m])))
const groupById = computed(() => new Map(props.groups.map((g) => [g.id, g])))
function memberOf(userId) {
  return memberById.value.get(userId) || null
}
function groupOf(groupId) {
  return groupById.value.get(groupId) || null
}

// People list under the map (newest first)
// Only people who are still in the event: a removed member, or a simulator Reset (303 virtual ICs gone at
// once), used to leave their markers on the map for good, because positions are only ever added to. While
// the member list has not loaded yet there is nothing to check against, so nobody is hidden.
const people = computed(() =>
  Object.values(positions.value)
    .filter((p) => !props.members.length || memberById.value.has(p.userId))
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

// ---------- Readings -> tracks ----------
function trackOf(userId) {
  if (!tracks[userId]) tracks[userId] = newTrack()
  return tracks[userId]
}

function toReading(row) {
  return { t: new Date(row.recorded_at).getTime(), lat: row.lat, lng: row.lng, accuracy: row.accuracy, source: row.source }
}

// Every reading from useLiveLocations (live = arrived on time through Realtime)
function onNewReading(row, live) {
  const track = trackOf(row.user_id)
  const reading = toReading(row)
  if (live) noteDelay(track, Date.now() - reading.t)
  if (addReading(track, reading) && row.user_id === selectedId.value) trailDirty = true
}

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
    (props.zoneStays[person.userId] || [])
      .map((s) => '<br>' + (s.zone.kind === 'no_go' ? '<strong class="text-danger">In No-Go</strong> ' : 'Inside ') +
        escapeHtml(s.zone.name) + ' since ' + formatTimeSeconds(s.enteredAt))
      .join('') +
    (selectedId.value === person.userId && props.liveSince ? '<br><span class="text-muted">Trail shown · tap the map to hide</span>' : '')
  )
}

async function lookUpPlace(userId) {
  const p = positions.value[userId]
  if (!p) return
  const key = p.lat + ',' + p.lng
  if (places[userId + '@'] === key) return // already looked up for this reading
  places[userId + '@'] = key
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

// Groups whose combined position is shown: ICs that count (not stopped, fresh, accurate enough)
let groupIcs = {} // groupId -> [person] (2+ only)

// Markers, icons and texts (runs when readings, the clock, members or groups change).
// Where markers are drawn is decided by the animation loop (frame) below.
function render() {
  if (!map) return

  // People
  const seen = new Set()
  for (const person of people.value) {
    seen.add(person.userId)
    let marker = personMarkers[person.userId]
    const iconKey = person.state + person.colour + person.name + (person.userId === selectedId.value)
    // The newest reading is also in the track (covers readings loaded before the map existed)
    const track = trackOf(person.userId)
    addReading(track, { t: person.time.getTime(), lat: person.lat, lng: person.lng, accuracy: person.accuracy, source: person.source })

    if (!marker) {
      const start = positionAt(track, advance(track, Date.now(), 0)) || person
      marker = L.marker([start.lat, start.lng], { icon: personIcon(person) }).addTo(map)
      marker.bindTooltip('', { direction: 'top' })
      // Look up the place name only when someone actually opens the tooltip
      marker.on('tooltipopen', () => lookUpPlace(person.userId))
      marker.on('click', () => select(person.userId)) // tap = card + trail
      marker.iconKey = iconKey
      personMarkers[person.userId] = marker
    }
    if (marker.iconKey !== iconKey) {
      marker.setIcon(personIcon(person))
      marker.iconKey = iconKey
    }
    marker.setZIndexOffset(person.userId === selectedId.value ? 1000 : 0)
    if (marker.isTooltipOpen()) lookUpPlace(person.userId)
    marker.setTooltipContent(tooltipHtml(person))
  }
  // Remove people who are no longer visible (e.g. moved to another group)
  for (const userId of Object.keys(personMarkers)) {
    if (!seen.has(userId)) {
      personMarkers[userId].remove()
      delete personMarkers[userId]
      delete tracks[userId]
      if (selectedId.value === userId) deselect()
    }
  }

  // Groups: a diamond only for groups with 2+ ICs (with one IC it would sit on their marker)
  groupIcs = {}
  for (const group of props.groups) {
    // People who pressed Stop don't count towards the group position
    const readings = people.value.filter((p) => p.groupId === group.id && p.state !== 'stopped')
    const mid = weightedMidpoint(readings, now.value)
    let marker = groupMarkers[group.id]
    if (!mid || mid.used < 2) {
      if (marker) {
        marker.remove()
        delete groupMarkers[group.id]
      }
      continue
    }
    groupIcs[group.id] = readings
    const server = props.groupPositions[group.id]
    const text = escapeHtml(group.name) + ' position<br>from ' + mid.used + ' ICs' +
      (server && server.speedMps != null ? '<br>Moving ' + Number(server.speedMps).toFixed(1) + ' m/s' : '')
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
      marker.setTooltipContent(text)
    }
  }

  if (followedId.value && !personMarkers[followedId.value]) stopFollowing() // they're no longer on the map

  // Zoom to everyone the first time we have data (with the plan's walk in the frame, when there is one: `frameOnce`).
  frameOnce()
  startLoop()
}

// Redraw when positions, the clock, members or groups change
watch([people, () => props.groups], render, { deep: true })
// ...and when someone enters or leaves a zone, or a group's server position changes (tooltips)
watch(() => [props.zoneStays, props.groupPositions], render)

// ---------- Animation loop: move every marker to where its playhead is ----------
let frameId = null
let lastFrame = 0
let lastPrune = 0

function frame(ts) {
  frameId = null
  if (!map || !props.active || document.hidden) return // stops; restarted when shown again
  const elapsed = lastFrame ? Math.min(ts - lastFrame, 60000) : 0
  lastFrame = ts
  const nowMs = Date.now()
  const shown = {} // userId -> drawn { lat, lng }

  for (const userId of Object.keys(personMarkers)) {
    const track = tracks[userId]
    if (!track) continue
    const pos = positionAt(track, advance(track, nowMs, elapsed))
    if (!pos) continue
    shown[userId] = pos
    const marker = personMarkers[userId]
    const old = marker.getLatLng()
    if (Math.abs(old.lat - pos.lat) > 1e-7 || Math.abs(old.lng - pos.lng) > 1e-7) {
      marker.setLatLng([pos.lat, pos.lng])
      if (followedId.value === userId) map.panTo([pos.lat, pos.lng], { animate: false })
    }
    if (userId === selectedId.value) drawTrailTo(track, pos)
  }

  // Group diamonds follow their ICs' drawn positions (same accuracy weighting)
  for (const [groupId, readings] of Object.entries(groupIcs)) {
    const marker = groupMarkers[groupId]
    if (!marker) continue
    const mid = weightedMidpoint(readings.map((r) => ({ ...r, ...(shown[r.userId] || {}) })), nowMs)
    if (mid) marker.setLatLng([mid.lat, mid.lng])
  }

  if (nowMs - lastPrune > 5000) {
    lastPrune = nowMs
    for (const track of Object.values(tracks)) prune(track, nowMs)
  }
  frameId = requestAnimationFrame(frame)
}

function startLoop() {
  if (frameId || !map || !props.active || document.hidden) return
  lastFrame = 0
  frameId = requestAnimationFrame(frame)
}

// Leaflet measures its box when shown; re-measure after the tab becomes visible again
watch(
  () => props.active,
  (active) => {
    if (active && map) nextTick(() => map.invalidateSize())
    if (active) startLoop()
  },
)

// ---------- Trail of the selected person (current live session only) ----------
const selectedId = ref(null)
let trailLayer = null // solid + dashed lines, dots and the invisible tap line (up to the last reading passed)
let trailTip = null // last piece: last reading passed -> the marker (updated every frame)
let trailIndex = -1 // reading the trail is drawn up to
let trailDirty = false // readings changed: redraw the trail
let trailPoints = [] // readings drawn in the trail (for taps)
let loadToken = 0

async function select(userId) {
  if (selectedId.value === userId) return deselect() // tap again = hide
  if (selectedId.value && tracks[selectedId.value]) tracks[selectedId.value].keepAll = false
  selectedId.value = userId
  clearTrail()
  render()
  const marker = personMarkers[userId]
  if (marker) marker.openTooltip()
  await loadTrail(userId)
}

function deselect() {
  if (selectedId.value && tracks[selectedId.value]) tracks[selectedId.value].keepAll = false
  selectedId.value = null
  clearTrail()
  render()
}

function clearTrail() {
  if (trailLayer) trailLayer.clearLayers()
  if (trailTip) trailTip.remove()
  trailTip = null
  trailIndex = -1
  trailPoints = []
  closePointInfo()
}

// The person's readings since the live session started (RLS: only people I may see),
// in pages of 1000 (the API's limit per request). Merged into their track.
async function loadTrail(userId) {
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
    if (error || token !== loadToken) return // (a network error: the next resume tries again)
    rows.push(...data)
    if (data.length < 1000) break
  }
  if (selectedId.value !== userId) return
  const track = trackOf(userId)
  track.keepAll = true
  for (const row of rows) addReading(track, toReading(row))
  trailDirty = true
}

function selectedColour() {
  const p = positions.value[selectedId.value]
  const g = p ? groupOf(p.groupId) : null
  return g ? g.colour : '#0d6efd'
}

// Called every frame for the selected person: the trail ends exactly at the marker
function drawTrailTo(track, pos) {
  if (!props.liveSince || !map) return
  if (trailDirty || pos.index !== trailIndex) {
    trailDirty = false
    trailIndex = pos.index
    drawTrailBody(track)
  }
  const last = trailPoints[trailPoints.length - 1]
  const tip = last ? [[last.lat, last.lng], [pos.lat, pos.lng]] : []
  if (!trailTip) {
    trailTip = L.polyline(tip, { color: selectedColour(), weight: 4, opacity: 0.85, interactive: false }).addTo(map)
  } else {
    trailTip.setLatLngs(tip)
  }
}

function drawTrailBody(track) {
  trailLayer.clearLayers()
  const from = props.liveSince
  trailPoints = track.points.slice(0, trailIndex + 1).filter((p) => p.t >= from)
  if (!trailPoints.length) return
  const colour = selectedColour()
  const { solid, dashed } = trailUpTo(track, from, trailIndex)

  L.polyline(dashed, { color: colour, weight: 3, opacity: 0.7, dashArray: '6 8', interactive: false }).addTo(trailLayer)
  L.polyline(solid, { color: colour, weight: 4, opacity: 0.85, interactive: false }).addTo(trailLayer)

  // Wide invisible line on top: hover (mouse) or tap (touch) anywhere along the trail
  const tapLine = L.polyline(trailPoints.map((p) => [p.lat, p.lng]), {
    color: '#000',
    weight: 24,
    opacity: 0,
    className: 'trail-hover',
    bubblingMouseEvents: false, // a tap here is not a tap on the empty map
  }).addTo(trailLayer)
  tapLine.on('click', (e) => showPointInfo(nearestPoint(e.latlng), true))
  tapLine.on('mousemove', (e) => showPointInfo(nearestPoint(e.latlng), false))
  tapLine.on('mouseout', hoverOut)

  // Dots: the start (green), then one every 2 minutes. Tap a dot: when + where.
  let lastDot = -Infinity
  trailPoints.forEach((p, i) => {
    const isStart = i === 0
    if (!isStart && p.t - lastDot < 2 * 60 * 1000) return
    lastDot = p.t
    const dot = L.circleMarker([p.lat, p.lng], {
      radius: isStart ? 6 : 4,
      color: isStart ? '#198754' : colour,
      weight: 2,
      fillColor: '#fff',
      fillOpacity: 1,
      className: 'trail-hover',
      bubblingMouseEvents: false,
    }).addTo(trailLayer)
    dot.on('click', () => showPointInfo(p, true))
  })
}

// Nearest reading to where the pointer / finger is
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

// ---------- Info for one trail point: time + place ----------
// Mouse hover: a ring with a small label. Tap / click: a popup that stays until closed.
let infoRing = null
let infoPopup = null
let infoPoint = null
let infoPinned = false
let infoTimer = null
let popupClosedAt = 0

function pointHead(p) {
  const member = memberOf(selectedId.value)
  return '<strong>' + formatTimeSeconds(p.t) + '</strong>' + (member ? ' · ' + escapeHtml(member.display_name) : '')
}

function showPointInfo(p, pin) {
  if (!p || (infoPinned && !pin)) return // a pinned popup wins over hovering
  if (!infoRing) {
    infoRing = L.circleMarker([p.lat, p.lng], { radius: 7, color: '#212529', weight: 2, fillColor: selectedColour(), fillOpacity: 1, interactive: false }).addTo(map)
  }
  infoRing.setLatLng([p.lat, p.lng])
  if (infoPoint === p && infoPinned === pin) return
  infoPoint = p
  infoPinned = pin
  const head = pointHead(p)
  const html = (place) => head + '<br>' + place
  if (pin) {
    infoRing.unbindTooltip()
    if (!infoPopup) {
      infoPopup = L.popup({ offset: [0, -4], autoPanPadding: [20, 20] })
      infoPopup.on('remove', () => {
        popupClosedAt = Date.now()
        closePointInfo()
      })
    }
    infoPopup.setLatLng([p.lat, p.lng]).setContent(html('<em>Finding place name...</em>')).openOn(map)
  } else {
    if (!infoRing.getTooltip()) infoRing.bindTooltip('', { direction: 'top', offset: [0, -6] })
    infoRing.setTooltipContent(html('<em>Finding place name...</em>')).openTooltip()
  }
  // Place names cost an API call: only for the point the pointer rests on (cached by position)
  clearTimeout(infoTimer)
  infoTimer = setTimeout(async () => {
    const place = escapeHtml((await placeName(p.lat, p.lng)) || 'Place name unavailable')
    if (infoPoint !== p) return
    if (infoPinned && infoPopup) infoPopup.setContent(html(place))
    else if (infoRing && infoRing.getTooltip()) infoRing.setTooltipContent(html(place))
  }, pin ? 0 : 250)
}

function hoverOut() {
  if (!infoPinned) closePointInfo()
}

function closePointInfo() {
  clearTimeout(infoTimer)
  infoPoint = null
  const wasPinned = infoPinned
  infoPinned = false
  if (infoRing) {
    infoRing.remove()
    infoRing = null
  }
  if (wasPinned && infoPopup && map && map.hasLayer(infoPopup)) map.closePopup(infoPopup)
}

// A new live session (or the event ended): the old trail doesn't belong to it
watch(
  () => props.liveSince,
  () => {
    clearTrail()
    if (selectedId.value) loadTrail(selectedId.value)
  },
)

// Back on the page after a while: refetch the selected trail (readings sent meanwhile)
let hiddenAt = 0
function onVisibility() {
  if (document.hidden) {
    hiddenAt = Date.now()
    return
  }
  if (selectedId.value && Date.now() - hiddenAt > 30000) loadTrail(selectedId.value)
  startLoop()
}

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

// ---------- Zones layer (merger Stage 1) ----------
// The event's zones, drawn under the people: outlines in their kind's colour (the same colours as the
// Zones tab), No-Go dashed red, with "Name · CODE" labels once zoomed in. Not clickable, so tapping a
// person or a trail inside a zone works as before. Redrawn when a planner changes a zone.
const showZones = ref(true)
const zoneCount = ref(0)
let zoneLayer = null
let zoneLabels = []
let zoneShapes = {} // zone id -> { shape, kind }
let zoneChannel = null
let zoneTimer = null
const LABEL_ZOOM = 16

async function loadZones() {
  if (!map || !supabase) return
  const { data, error } = await supabase.rpc('event_zones', { p_event: props.eventId })
  if (error || !map) return
  zoneLayer.clearLayers()
  for (const label of zoneLabels) label.remove() // labels sit on the map itself, not in zoneLayer
  zoneLabels = []
  zoneShapes = {}
  for (const z of data || []) {
    const shape = L.geoJSON(z.geojson, { style: areaStyle(z.kind), interactive: false })
    shape.addTo(zoneLayer)
    const label = L.tooltip({ permanent: true, direction: 'center', className: 'zone-label', interactive: false })
      .setLatLng(shape.getBounds().getCenter())
    label.zone = z
    zoneLabels.push(label)
    zoneShapes[z.id] = { shape, kind: z.kind }
  }
  zoneCount.value = (data || []).length
  refreshZoneState()
  placeZoneLabels()
}

// "Formation 1 · FORM_A · 2 ICs (1 group)", and a No-Go zone with somebody inside drawn bold red.
function refreshZoneState() {
  for (const label of zoneLabels) {
    const z = label.zone
    const c = props.zoneCounts[z.id]
    label.setContent(
      escapeHtml(z.name) + ' · <b>' + escapeHtml(z.code) + '</b>' +
        (c ? ' · ' + c.ics + (c.ics === 1 ? ' IC' : ' ICs') + ' (' + c.groups + (c.groups === 1 ? ' group' : ' groups') + ')' : ''),
    )
  }
  const occupied = new Set(props.noGoOccupied)
  for (const [id, entry] of Object.entries(zoneShapes)) {
    const alarm = occupied.has(id)
    entry.shape.setStyle(alarm ? { ...areaStyle(entry.kind), weight: 4, fillOpacity: 0.45, dashArray: null } : areaStyle(entry.kind))
  }
}

watch(() => [props.zoneCounts, props.noGoOccupied], refreshZoneState, { deep: true })

function placeZoneLabels() {
  if (!map) return
  const show = showZones.value && map.getZoom() >= LABEL_ZOOM
  for (const label of zoneLabels) {
    if (show && !map.hasLayer(label)) label.addTo(map)
    else if (!show && map.hasLayer(label)) label.remove()
  }
}

watch(showZones, (on) => {
  if (!map || !zoneLayer) return
  if (on) zoneLayer.addTo(map)
  else zoneLayer.remove()
  placeZoneLabels()
})

function watchZones() {
  if (!supabase) return
  zoneChannel = supabase
    .channel('event-zones-' + props.eventId + '-' + Math.random().toString(36).slice(2))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'zones', filter: 'event_id=eq.' + props.eventId }, () => {
      clearTimeout(zoneTimer)
      zoneTimer = setTimeout(loadZones, 300) // one redraw for a burst of changes
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') loadZones()
    })
}

// ---------- The plan's walk under the people (step 30) ----------
// The read is `session_timetable` (065) through usePlanWalk, which the follower's map asks too, and it is enabled only
// while this is the page on show: the Live page is `v-show`n, so this panel is mounted on every page of the event and a
// read from it would otherwise poll behind whatever the person is looking at (finding 72).
const plan = usePlanWalk({
  session: () => props.session,
  enabled: () => props.active && !!props.session && !!props.session.planId,
})
const showPlan = ref(true) // a layer, not a preference: not remembered across a reload (the same as Zones)
let planLayer = null

const planWalks = computed(() => walksOf(plan.rows.value))
const planRev = computed(() => {
  const rows = plan.rows.value
  return rows.length ? rows[0].plan_rev : props.session ? props.session.planRev : null
})
/** Whether there is a line at all: a group whose whole walk is one stated point draws a mark, not a road. */
const planLine = computed(() => [...planWalks.value.values()].some((walk) => walk.runs.some((run) => run.length > 1)))
/** The points the walk stands on, for framing the map when nobody is sharing yet. */
const planPoints = computed(() => {
  const out = []
  for (const walk of planWalks.value.values()) for (const row of walk.points) out.push([row.lat, row.lng])
  return out
})
/**
 * Which two statements the clock is between, per group, as a string. The bold leg moves only when the clock crosses a
 * moment, so this is what the redraw watches: the map ticks every second and the line must not be rebuilt every tick.
 */
const legKey = computed(() => {
  const parts = []
  for (const walk of planWalks.value.values()) {
    const leg = legNow(walk.rows, props.now)
    parts.push(walk.id + ':' + (leg ? leg[0].t_s + '-' + leg[1].t_s : '-'))
  }
  return parts.join('|')
})

/**
 * Draw the walk, or clear it. A run is a dashed line in the group's colour at 55 %; the leg the clock is on is the same
 * line again, bold and solid, over it -- the stretch the group is meant to be walking right now. Every path says which
 * group and which revision it is, which is the only handle a browser check has on a Leaflet line.
 */
function drawPlan() {
  if (!map || !planLayer) return
  planLayer.clearLayers()
  frameOnce() // the walk may be the first thing that arrived; the camera waits for it
  if (!showPlan.value) return
  for (const walk of planWalks.value.values()) {
    const group = groupOf(walk.id)
    const colour = group ? group.colour : '#244f3f'
    for (const run of walk.runs) {
      if (run.length < 2) continue
      const line = L.polyline(run, {
        color: colour,
        weight: 2,
        opacity: 0.55,
        dashArray: '5 6',
        interactive: false, // a line must not swallow the taps meant for the people under it
      }).addTo(planLayer)
      const element = line.getElement()
      if (element) {
        element.setAttribute('data-plan-line', walk.id)
        if (planRev.value != null) element.setAttribute('data-plan-rev', String(planRev.value))
      }
    }
    const leg = legNow(walk.rows, props.now)
    if (!leg) continue
    const [from, to] = leg
    const bold = L.polyline(
      [
        [from.lat, from.lng],
        [to.lat, to.lng],
      ],
      { color: colour, weight: 4, opacity: 0.95, interactive: false },
    ).addTo(planLayer)
    const element = bold.getElement()
    if (element) {
      element.setAttribute('data-plan-leg', walk.id)
      element.setAttribute('data-leg-from', String(from.t_s))
      element.setAttribute('data-leg-to', String(to.t_s))
    }
  }
}

// The walk is drawn from the read, the clock's leg and the toggle -- not on every tick, which is what `legKey` is for.
watch([planWalks, legKey, showPlan, () => props.groups], drawPlan, { flush: 'post' })

/**
 * Frame the map once -- the people and the plan's walk together when there is a walk, because 80 m of line inside a
 * 1.5 km viewport is a picture of a neighbourhood rather than of the venue. The people's answer may land first, so the
 * camera is allowed one refit when the walk arrives; after somebody has dragged the map the view is theirs, not every
 * read's.
 */
function frameOnce() {
  if (!map || userMoved) return
  const walk = planPoints.value
  if (framed && (framedWithPlan || !walk.length)) return
  const size = map.getSize()
  if (!size.x || !size.y) return // measured while the page was hidden: the next draw frames it properly
  const bounds = L.latLngBounds([])
  for (const person of people.value) bounds.extend([person.lat, person.lng])
  for (const point of walk) bounds.extend(point)
  if (!bounds.isValid()) return
  map.fitBounds(bounds.pad(walk.length ? 0.2 : 0.3), { maxZoom: walk.length ? 20 : 17, animate: false })
  framed = true
  if (walk.length) framedWithPlan = true
}

let unsubscribe = null
let resizeObserver = null
onMounted(() => {
  // Centre on Singapore with the OneMap basemap (shared setup in utils/onemap.js)
  map = createSingaporeMap(mapEl.value)
  zoneLayer = L.layerGroup().addTo(map) // under the trail and the markers
  planLayer = L.layerGroup().addTo(map) // the plan's walk: over the zones, under the people and their trails
  trailLayer = L.layerGroup().addTo(map)
  map.on('zoomend', placeZoneLabels)
  watchZones()
  // Dragging the map yourself means "let me look around": stop following, and keep the camera where it is put.
  map.on('dragstart', () => {
    userMoved = true
    stopFollowing()
  })
  // Tap empty map: hide the trail (the first tap only closes an open trail popup)
  map.on('click', () => {
    if (Date.now() - popupClosedAt < 400) return
    if (selectedId.value) deselect()
  })
  if (props.onReading) unsubscribe = props.onReading(onNewReading)
  document.addEventListener('visibilitychange', onVisibility)
  // The map's box changes size when the page it sits in is resized (a phone turning, the window changing shape): Leaflet
  // must be told, or it keeps drawing for the box it was last measured in.
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(() => map && map.invalidateSize())
    resizeObserver.observe(mapEl.value)
  }
  render()
})

onUnmounted(() => {
  if (unsubscribe) unsubscribe()
  if (resizeObserver) resizeObserver.disconnect()
  clearTimeout(zoneTimer)
  if (zoneChannel && supabase) supabase.removeChannel(zoneChannel)
  document.removeEventListener('visibilitychange', onVisibility)
  if (frameId) cancelAnimationFrame(frameId)
  clearTimeout(infoTimer)
  if (map) map.remove()
  map = null
})
</script>

<template>
  <div>
    <BenchAlert v-if="errorMsg && errorMsg !== dismissedError" @dismiss="dismissedError = errorMsg">{{ errorMsg }}</BenchAlert>
    <div class="position-relative mb-3">
      <div ref="mapEl" class="live-map rounded border" data-testid="live-map"></div>
      <!-- Connection dropped (tab was in the background, network changed): retrying by itself -->
      <div v-if="reconnecting" class="reconnect-pill shadow-sm" role="status" data-testid="reconnecting">
        <span class="spinner-border spinner-border-sm" aria-hidden="true"></span> Reconnecting…
      </div>
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
      <!-- The plan under the people (step 30): what a dashed line is, and which one is loud. -->
      <span v-if="planLine" data-testid="map-plan-legend">
        <span class="plan-swatch" aria-hidden="true"></span>a group’s plan · the bold one is due now
      </span>
      <span v-if="liveSince">Tap a marker to see their trail · tap the trail for times</span>
      <label v-if="zoneCount" class="form-check form-check-inline mb-0 ms-auto" data-testid="zones-toggle">
        <input v-model="showZones" class="form-check-input" type="checkbox" />
        <span class="form-check-label">Zones ({{ zoneCount }})</span>
      </label>
      <label
        v-if="planLine"
        class="form-check form-check-inline mb-0"
        :class="{ 'ms-auto': !zoneCount }"
        data-testid="plan-toggle"
      >
        <input v-model="showPlan" class="form-check-input" type="checkbox" />
        <span class="form-check-label">Plan<template v-if="planRev != null"> (v{{ planRev }})</template></span>
      </label>
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
.reconnect-pill {
  position: absolute;
  bottom: 10px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 1000;
  display: flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.25rem 0.75rem;
  background: #fff3cd;
  color: #664d03;
  border-radius: 999px;
  font-size: 0.8125rem;
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
/* The plan's line in the legend: the same dashed stroke the map draws it with. */
.plan-swatch {
  display: inline-block;
  width: 18px;
  height: 0;
  margin-right: 0.25rem;
  vertical-align: middle;
  border-top: 2px dashed #244f3f;
}
:global(.trail-hover) {
  cursor: pointer;
}
:global(.zone-label) {
  background: rgba(255, 255, 255, 0.85);
  border: 0;
  box-shadow: none;
  padding: 0 4px;
  font-size: 11px;
  color: #212529;
}
:global(.zone-label::before) {
  display: none;
}
</style>
