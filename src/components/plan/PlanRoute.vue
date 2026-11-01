<script setup>
// PlanRoute — the follower's own map (step 29): the walk their group is meant to take, drawn on the venue's zones, and
// nothing of any other group's.
//
// WHO THIS IS FOR. Everyone the board is not for — a member, an IC, a group admin, a marshal. The Map tab used to be a
// placeholder for all of them ("the event map: zones and areas, view only") that drew nothing, because the one read a
// follower has answered the moment's place *name* and not its point (`session_timetable`, 062). Step 29 gives the read
// the point (065) and this file the map. Root and planner keep the zone editor on this tab; this is mounted for
// everyone else.
//
// WHAT IS DRAWN, AND WHAT IS NOT. A moment is a point, and the line between two moments is the walk — the planner's own
// reading of "the frames are the route" (the board draws the same line). So: the zones underneath, one dashed line per
// group in the group's colour, a dot on every stated on-site moment labelled with its clock time and its place, and the
// moment the clock is on marked. An off-site statement is a break in the line, not a point to bridge (046, step 10):
// the group is not on the map then, so the walk stops and starts again. Nothing here is live position (that is the Live
// page), nothing here estimates a walk time, and nothing here routes around anything.
//
// WHY IT CANNOT SHOW ANOTHER GROUP. Not because this screen filters: `session_timetable` applies 040's scope inside the
// engine (052), so a member's read answers their group's rows alone, and a marshal's answers both. The map draws what
// arrived. A client-side filter would look identical in a browser and be a different rule.
//
// ONE READ, THE SAME ONE THE SCHEDULE MAKES. The timetable, every 30 s, woken at each moment, and on a publish (the
// session's revision moves and useEventSessions already listens to event_sessions). The read, its guards and its wake
// live in `usePlanWalk` (step 30), which the live map asks too: one implementation, two screens. The zones are the one
// extra call `event_zones`, which the Live map already makes for the same person, read once. A second read for the
// route was rejected: two doors is two places the scope can drift (step 16's finding 48).
//
// A ROW WITH NO POINT IS STILL A ROW. A carried frame and an off-site statement answer null coordinates (065), and
// they are what tells the map where the walk stops. The rules that turn rows into a line are `planWalk`'s (a run, a
// break at an off-site statement, a single point with no line), because the live map draws the same walk and the same
// rules must not exist twice.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../../utils/onemap'
import { areaStyle } from '../../utils/areaKinds'
import { escapeHtml } from '../../utils/people'
import { walksOf } from '../../utils/planWalk'
import { formatDayTime, formatDuration, formatTime } from '../../utils/time'
import { usePlanWalk } from '../../composables/usePlanWalk'
import { supabase } from '../../lib/supabase'
import '../../assets/planova.css'
import SkeletonLoader from '../SkeletonLoader.vue'
import { useLoadGate } from '../../composables/usePageReady'

const props = defineProps({
  eventId: { type: String, required: true },
  // The session to read: the live one, the scheduled one, or the last one that ended (EventView picks). Null when the
  // event has never been started, which is the one case with nothing to read.
  session: { type: Object, default: null },
  // True for ops staff (root, planner, marshal): the read answers every group, so the map draws every group's walk.
  whole: { type: Boolean, default: false },
  // The caller's group, for the header and for the no-group empty state. The rows are the authority for what is drawn.
  myGroup: { type: Object, default: null },
  // The event's groups, for their colours — the board's palette, so the same group is the same colour on both maps.
  groups: { type: Array, default: () => [] },
  // A moment to open the map on, from the schedule's place link (`?t=300`). Null opens on the whole walk.
  focusT: { type: [String, Number], default: null },
})

const TICK_MS = 1000

const { rows, loaded, errorMsg, readAt } = usePlanWalk({ session: () => props.session })
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => !loaded.value)
const zones = ref([])
const now = ref(Date.now())
const mapEl = ref(null)
let map = null
let zoneLayer = null
let routeLayer = null
let dotLayer = null
let fittedWithPoints = false // the camera is set once the walk is in hand, then it is the follower's
let appliedFocus = null // the `?t=` moment this map has already opened on
let retries = 0 // frames spent waiting for the stage to be laid out (see draw)
let tickTimer = null

const sessionId = computed(() => (props.session ? props.session.id : null))
const endedAt = computed(() => (props.session && props.session.endedAt ? props.session.endedAt : null))
const phase = computed(() => {
  const s = props.session
  if (!s) return 'none'
  if (s.endedAt) return 'ended'
  if (s.startsAt && s.startsAt.getTime() > now.value) return 'scheduled'
  return 'live'
})
const phaseWord = computed(() => ({ none: 'not started', live: 'live', scheduled: 'scheduled', ended: 'ended' })[phase.value])

// The instant the screen is speaking about: the end of a closed show, otherwise the clock on the wall (050's p_at rule,
// as the schedule reads it).
const clockAt = computed(() => (endedAt.value ? endedAt.value : new Date(now.value)))
const planName = computed(() => (rows.value.length ? rows.value[0].plan_name : ''))
const rev = computed(() => (rows.value.length ? rows.value[0].plan_rev : props.session ? props.session.planRev : null))
const groupName = computed(() => {
  if (props.whole) return ''
  return rows.value.length ? rows.value[0].group_name : props.myGroup ? props.myGroup.name : ''
})

/** One entry per frame: its clock time, its place(s), and the rows that mention it. */
const moments = computed(() => {
  const out = []
  const byFrame = new Map()
  for (const row of rows.value) {
    let moment = byFrame.get(row.frame_id)
    if (!moment) {
      moment = { frameId: row.frame_id, t_s: row.t_s, at: new Date(row.planned_at), rows: [] }
      byFrame.set(row.frame_id, moment)
      out.push(moment)
    }
    moment.rows.push(row)
  }
  return out
})

/** The places the moment names, one per group that has one: "Main Gate", or "Main Gate / Stage". */
function placeOf(moment) {
  const seen = []
  for (const row of moment.rows) if (row.place && !seen.includes(row.place)) seen.push(row.place)
  return seen.join(' / ')
}

/** The first moment the clock has not reached yet — the one the eye should land on. */
const nextMoment = computed(() => moments.value.find((m) => m.at.getTime() > clockAt.value.getTime()) || null)

/** The moment the clock is on: the last one whose time has come. */
const currentFrameId = computed(() => {
  let id = null
  for (const moment of moments.value) {
    if (moment.at.getTime() <= clockAt.value.getTime()) id = moment.frameId
  }
  return id
})

/** "in 12 min" for the next moment, on the same planned_at the read gave. */
const nextIn = computed(() => {
  const moment = nextMoment.value
  if (!moment) return ''
  const wait = moment.at.getTime() - clockAt.value.getTime()
  return wait <= 0 ? 'due now' : 'in ' + formatDuration(wait)
})

function colourOf(groupId) {
  const group = props.groups.find((g) => g.id === groupId)
  return (group && group.colour) || '#244f3f'
}

/**
 * The walks, one per group, with each group's colour from the event's palette. The rules are `planWalk`'s: a run is a
 * stretch of on-site statements, an off-site moment breaks it exactly as the board breaks its line (PlanBoard's
 * drawLines), and a carried frame has no point of its own but does not break the line -- the walk continues from the
 * statement it carries.
 */
const tracks = computed(() => {
  const walks = walksOf(rows.value)
  for (const track of walks.values()) track.colour = colourOf(track.id)
  return walks
})

/** What a dot says: its clock time and its place, or the time alone at a route point. */
function dotText(track, row) {
  const when = formatTime(row.planned_at)
  if (props.whole) return track.name + ' · ' + when + (row.place ? ' · ' + row.place : '')
  return when + (row.place ? ' · ' + row.place : '')
}

// ---------- the map ----------

function drawZones() {
  if (!map || !zoneLayer) return
  zoneLayer.clearLayers()
  for (const zone of zones.value) {
    if (!zone.geojson) continue
    const shape = L.geoJSON(zone.geojson, { style: areaStyle(zone.kind), interactive: false })
    shape.bindTooltip(escapeHtml(zone.name) + (zone.code ? ' · ' + escapeHtml(zone.code) : ''), { sticky: true })
    shape.addTo(zoneLayer)
  }
}

function draw() {
  if (!ensureMap()) {
    // A walk is waiting and only the layout is not: try again on the next frame, a handful of times. (The stage is
    // shown in the same flush that told us the rows arrived, so this is one frame at most; the cap is for safety.)
    if (rows.value.length && retries < 10) {
      retries += 1
      requestAnimationFrame(() => draw())
    }
    return
  }
  retries = 0
  // The stage may have been resized between polls (a phone turned, a page that was hidden): measure again, without
  // moving the camera.
  map.invalidateSize({ pan: false })
  routeLayer.clearLayers()
  dotLayer.clearLayers()

  for (const track of tracks.value.values()) {
    for (const run of track.runs) {
      if (run.length < 2) continue
      const line = L.polyline(run, {
        color: track.colour,
        weight: 2.5,
        opacity: 0.6,
        dashArray: '5 5',
        interactive: false,
      }).addTo(routeLayer)
      // The seam the browser check reads: which group's walk this line is. A path element is the only handle Leaflet
      // gives a test, and a test that counted every path would count the zones too.
      const element = line.getElement()
      if (element) element.setAttribute('data-route', track.id)
    }

    for (const row of track.points) {
      const current = row.frame_id === currentFrameId.value
      const next = nextMoment.value && row.frame_id === nextMoment.value.frameId
      const focused = props.focusT != null && String(props.focusT) === String(row.t_s)
      const classes = ['pv-route-dot']
      if (current) classes.push('is-current')
      if (next) classes.push('is-next')
      if (focused) classes.push('is-focused')
      const icon = L.divIcon({
        className: 'pv-route-pin',
        html:
          `<span class="${classes.join(' ')}" style="--pv-dot:${track.colour}"` +
          ` data-testid="route-dot" data-group="${track.id}" data-t="${row.t_s}">` +
          `<span class="pv-route-dot-mark"></span>` +
          `<span class="pv-route-dot-label" data-testid="route-dot-label">${escapeHtml(dotText(track, row))}</span>` +
          `</span>`,
        iconSize: [12, 12],
        iconAnchor: [6, 6],
      })
      const marker = L.marker([row.lat, row.lng], { icon, keyboard: false, autoPan: true, title: dotText(track, row) })
      marker.bindTooltip(dotText(track, row), { direction: 'top', offset: [0, -8] })
      marker.addTo(dotLayer)
    }
  }

  fit()
  applyFocus()
}

/** Frame the venues and the walk once; after that the view is the follower's, not every poll's. */
function fit() {
  if (!map || fittedWithPoints) return
  // A map measured while the stage was still hidden has no size to frame anything in; the next draw, once the stage is
  // in the layout, fits it properly.
  const size = map.getSize()
  if (!size.x || !size.y) return
  const bounds = L.latLngBounds([])
  if (zoneLayer) {
    const zoneBounds = zoneLayer.getBounds()
    if (zoneBounds.isValid()) bounds.extend(zoneBounds)
  }
  let hasPoint = false
  for (const track of tracks.value.values()) {
    for (const point of track.points) {
      bounds.extend([point.lat, point.lng])
      hasPoint = true
    }
  }
  if (!bounds.isValid()) return
  // An empty plan with zones is framed on the zones and reframed when the walk arrives; the walk itself is the subject.
  map.fitBounds(bounds.pad(0.25), { animate: false })
  fittedWithPoints = hasPoint
}

/** Centre the map on a moment somebody tapped: its own point, at the zoom a person reads a place at. */
function focusMoment(moment) {
  if (!map || !moment) return
  const row = moment.rows.find((r) => r.lat != null)
  if (!row) return
  map.setView([row.lat, row.lng], 17, { animate: false })
}

/** Open on the moment the schedule's link named, once, and mark it. */
function applyFocus() {
  if (!map || props.focusT == null) return
  const wanted = String(props.focusT)
  if (appliedFocus === wanted) return
  const row = rows.value.find((r) => String(r.t_s) === wanted && r.lat != null)
  if (!row) return
  appliedFocus = wanted
  map.setView([row.lat, row.lng], 17, { animate: false })
}

/**
 * Build the map the first time there is something to draw. Deliberately NOT at mount: the stage is `v-show`n only once
 * a walk exists, and Leaflet measured inside a `display:none` box records a zero size — the fit then frames the walk for
 * a viewport nobody has, and the map opens at the minimum zoom on the wrong part of the island.
 */
function ensureMap() {
  if (map) return true
  const element = mapEl.value
  // No element, nothing to draw, or a stage that is still `display:none`: the next draw tries again.
  if (!element || !rows.value.length || !element.clientWidth) return false
  map = createSingaporeMap(element)
  // No animation: an animated first view leaves the map at its old zoom while the animation runs, and the walk is
  // drawn (and framed) during it -- the fit below then lands on layers placed for the zoom the map was leaving.
  map.setView([1.3521, 103.8198], 16, { animate: false })  // A feature group, not a layer group: the fit asks the zones for their bounds.
  zoneLayer = L.featureGroup().addTo(map)
  routeLayer = L.layerGroup().addTo(map)
  dotLayer = L.layerGroup().addTo(map)
  map.invalidateSize()
  drawZones()
  return true
}

// ---------- the geography and the clock ----------

/** The event's zones, once: the geography under the walk, not a live layer (a planner's zone edit is a reload away). */
async function readZones() {
  try {
    const { data, error } = await supabase.rpc('event_zones', { p_event: props.eventId })
    if (error || !data) return
    zones.value = data
    drawZones()
    draw()
  } catch {
    // The walk is the subject: a zone read that fails leaves the map with the walk on it rather than nothing.
  }
}

function onTick() {
  now.value = Date.now()
}

onMounted(() => {
  readZones()
  tickTimer = setInterval(onTick, TICK_MS)
})

onBeforeUnmount(() => {
  clearInterval(tickTimer)
  if (map) {
    map.remove()
    map = null
  }
})

// A different session is a different walk: the read starts again in usePlanWalk, and the camera forgets the moment it
// was opened on.
watch(sessionId, () => {
  appliedFocus = null
})

// The read and the zones both feed the picture: redraw when either answers, never on the tick (the dots are the plan's
// moments, not the second hand's). `flush: 'post'` so the stage has been taken out of or put back into the layout before
// Leaflet measures it -- a map measured while its container is still `display:none` opens on a corner of the world.
watch(rows, () => draw(), { flush: 'post' })
watch(
  () => zones.value.length,
  () => {
    drawZones()
    draw()
  },
  { flush: 'post' },
)
watch(
  () => props.focusT,
  () => {
    appliedFocus = null
    draw()
  },
  { flush: 'post' },
)
</script>

<template>
  <div class="pv">
    <section class="pv-route" data-testid="plan-route">
      <header class="pv-route-head">
        <div class="pv-route-id">
          <h2 class="pv-route-title">{{ whole ? 'The route' : 'Your route' }}</h2>
          <p class="pv-route-sub">
            <span class="pv-badge" :class="{ 'is-live': phase === 'live' }" data-testid="route-phase">{{ phaseWord }}</span>
            <template v-if="planName">
              <span class="pv-route-plan" data-testid="route-plan">{{ planName }}</span>
              <span v-if="rev != null"> · version <strong data-testid="route-rev">{{ rev }}</strong></span>
            </template>
            <span v-if="!whole && groupName" class="pv-route-group-name" data-testid="route-group">
              · your group <strong>{{ groupName }}</strong>
            </span>
            <span v-else-if="whole"> · every group</span>
            <span v-if="readAt" class="pv-route-asof"> · as of {{ formatTime(readAt) }}</span>
          </p>
        </div>
      </header>

      <p v-if="phase === 'scheduled'" class="pv-route-line" data-testid="route-scheduled">
        The event starts {{ formatDayTime(session.startsAt) }}. This is the walk as planned; nothing has been walked yet.
      </p>
      <p v-if="phase === 'ended'" class="pv-route-line" data-testid="route-ended">
        The event ended {{ formatTime(endedAt) }}. This is the walk as it stood when it closed.
      </p>

      <!-- A read that failed says so and keeps the last answer: a map that blanks itself is worse than an old one. -->
      <p v-if="errorMsg" class="pv-route-line is-warn" data-testid="route-error">
        {{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template>
      </p>

      <!-- The stage holds the map and the card that floats over it. v-show, not v-if: Leaflet holds the element, so it is
           taken out of the layout when there is nothing to draw rather than torn down and rebuilt. -->
      <div v-show="rows.length" class="pv-route-stage">
        <div ref="mapEl" class="pv-map" data-testid="route-map"></div>

        <!-- The next moment, floating over the map: tapping it centres on the moment it names. -->
        <button
          v-if="nextMoment"
          type="button"
          class="pv-route-next"
          data-testid="route-next"
          @click="focusMoment(nextMoment)"
        >
          <span class="pv-route-next-kicker">Next</span>
          <strong class="pv-route-next-at">{{ formatTime(nextMoment.at) }}</strong>
          <span v-if="placeOf(nextMoment)" class="pv-route-next-place">{{ placeOf(nextMoment) }}</span>
          <span class="pv-route-next-in">{{ nextIn }}</span>
        </button>
      </div>

      <SkeletonLoader v-if="!loaded" variant="lines" :rows="4" label="Reading your route…" data-testid="route-loading" />

      <div v-else-if="!rows.length" class="pv-route-empty" data-testid="route-empty">
        <template v-if="phase === 'none'">
          No schedule yet, so there is no walk to draw. It appears here when a planner starts the event on a plan.
        </template>
        <template v-else-if="!session.planId">
          This event is running without a plan, so there is no route to show.
        </template>
        <template v-else-if="!whole && !groupName">
          You are not in a group yet. Ask the root, a planner or a group admin to add you, and your walk appears here.
        </template>
        <template v-else-if="phase === 'live'">
          Nothing to draw. This plan has no moments for {{ whole ? 'any group' : groupName }} — or the plan the session
          was running has been removed.
        </template>
        <template v-else>This plan has no moments for {{ whole ? 'any group' : groupName }}.</template>
      </div>

      <p v-else-if="!tracks.size || ![...tracks.values()].some((t) => t.points.length)" class="pv-route-note" data-testid="route-nopoints">
        {{ whole ? 'No group has a stated point yet.' : 'Your group has no stated points yet.' }}
        A moment that only carries the group forward, or an off-site moment, is not a point on the map.
      </p>

      <p v-else class="pv-route-foot">
        The line joins the moments of {{ whole ? 'each group' : 'your group' }}; a dashed line is the plan, not a
        route to be navigated. It breaks where {{ whole ? 'a group is' : 'you are' }} off site, because that is not a
        place on the map. Positions on the Live page are where people are now; this is where the plan says to be.
      </p>
    </section>
  </div>
</template>
