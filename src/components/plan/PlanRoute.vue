<script setup>
// PlanRoute — the follower's own map (step 29): the walk their group is meant to take, drawn on the venue's zones, and
// nothing of any other group's.
//
// WHO THIS IS FOR. Everyone the board is not for — a member, an IC, a group admin. The Map tab used to be a
// placeholder for all of them ("the event map: zones and areas, view only") that drew nothing, because the one read a
// follower has answered the moment's place *name* and not its point (`session_timetable`, 062). Step 29 gives the read
// the point (065) and this file the map. Root and planner keep the zone editor on this tab; this is mounted for
// everyone else.
//
// WHAT IS DRAWN, AND WHAT IS NOT. A moment is a point, and the line between two moments is the walk — the planner's own
// reading of "the frames are the route" (the board draws the same line). So: the zones underneath, one dashed line per
// group in the group's colour, a numbered dot on every stop (`stopsOf`, the same numbers as the Schedule's list) labelled
// with its clock time and its place (no clock unless the event is live: the Schedule's static mode is a view of the plan),
// and the moment the clock is on marked. An off-site statement is a break in the line, not a point to bridge (046, step 10):
// the group is not on the map then, so the walk stops and starts again. Nothing here is live position (that is the Live
// page), nothing here estimates a walk time, and nothing here routes around anything.
//
// WHY IT CANNOT SHOW ANOTHER GROUP. Not because this screen filters: `session_timetable` applies 040's scope inside the
// engine (052), so a member's read answers their group's rows alone, and a planner's answers every group's. The map draws what
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
//
// TWO PLACES. On the Map tab it is the whole page. On the Schedule page it is `embedded`: the map and its cards only,
// drawing the rows that page has already read (`walkRows`), and `showMoment` zooms in on the row somebody picked.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import L from 'leaflet'
import { venueBounds } from '../../utils/venueFrame'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../../utils/onemap'
import { areaStyle, zoneCaption } from '../../utils/areaKinds'
import { escapeHtml } from '../../utils/people'
import { stopsOf, walksOf, whereAt } from '../../utils/planWalk'
import { formatDayTime, formatDuration, formatTime } from '../../utils/time'
import { usePlanWalk } from '../../composables/usePlanWalk'
import { supabase } from '../../lib/supabase'
import '../../assets/planova.css'
import SkeletonLoader from '../SkeletonLoader.vue'
import EmptyState from '../EmptyState.vue'
import { useLoadGate } from '../../composables/usePageReady'

const props = defineProps({
  eventId: { type: String, required: true },
  // The session to read: the live one, the scheduled one, or the last one that ended (EventView picks). Null when the
  // event has never been started, which is the one case with nothing to read.
  session: { type: Object, default: null },
  // True for ops staff (root, planner): the read answers every group, so the map draws every group's walk.
  whole: { type: Boolean, default: false },
  // The caller's group, for the header and for the no-group empty state. The rows are the authority for what is drawn.
  myGroup: { type: Object, default: null },
  // The event's groups, for their colours — the board's palette, so the same group is the same colour on both maps.
  groups: { type: Array, default: () => [] },
  // A moment to open the map on, from the schedule's place link (`?t=300`). Null opens on the whole walk.
  focusT: { type: [String, Number], default: null },
  // The Schedule page's row numbers ('group|frame' -> number), so a pin always matches its row.
  pinNumbers: { type: Map, default: null },
  // True on the Schedule page: the map and its cards, drawing walkRows instead of reading them again.
  embedded: { type: Boolean, default: false },
  walkRows: { type: Array, default: () => [] },
})

const TICK_MS = 1000
const SHOW_ZOOM = 18 // close enough to tell one point from the next

const walk = usePlanWalk({ session: () => props.session, enabled: () => !props.embedded })
const { loaded, errorMsg, readAt } = walk
const rows = computed(() => (props.embedded ? props.walkRows : walk.rows.value))
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => !props.embedded && !loaded.value)
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
let shownT = null // the moment showMoment last centred on: its label stays strong

const sessionId = computed(() => (props.session ? props.session.id : null))
const endedAt = computed(() => (props.session && props.session.endedAt ? props.session.endedAt : null))
const phase = computed(() => {
  const s = props.session
  if (!s) return 'none'
  if (s.endedAt) return 'ended'
  if (s.startsAt && s.startsAt.getTime() > now.value) return 'scheduled'
  return 'live'
})
const phaseWord = computed(() => {
  if (phase.value === 'live' && !isLive.value) return 'not live'
  return { none: 'not started', live: 'live', scheduled: 'scheduled', ended: 'ended' }[phase.value]
})
// What the event header calls live (useEventSessions): a session whose scheduled end has passed is no longer live.
const isLive = computed(() => {
  const end = props.session && props.session.scheduledEnd
  return phase.value === 'live' && !(end && end.getTime() <= now.value)
})

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

/** The one group's next stop: the card says where to go next, and a carried moment ahead is not somewhere to go. */
const nextStop = computed(() => {
  if (props.whole) return null
  const track = [...tracks.value.values()][0]
  return (track && track.stops.find((stop) => new Date(stop.startsAt).getTime() > clockAt.value.getTime())) || null
})

/** The first moment the clock has not reached yet — the one the eye should land on. For one group, the next stop's. */
const nextMoment = computed(() => {
  if (props.whole) return moments.value.find((m) => m.at.getTime() > clockAt.value.getTime()) || null
  const stop = nextStop.value
  return (stop && moments.value.find((m) => m.frameId === stop.rows[0].frame_id)) || null
})

/** What the Next card names: the moment's places for every group, the stop for one. */
const nextPlace = computed(() => {
  const stop = nextStop.value
  if (!stop) return nextMoment.value ? placeOf(nextMoment.value) : ''
  return stop.kind === 'off' ? 'Off site' : stopName(stop)
})

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
  for (const track of walks.values()) {
    track.colour = colourOf(track.id)
    track.stops = stopsOf(track.rows)
  }
  return walks
})

const hasPoints = computed(() => [...tracks.value.values()].some((t) => t.points.length))

/** Where the group should be right now, for the card over the map. Only while the event is live, and only one group. */
const hereNow = computed(() => {
  if (props.whole || !isLive.value) return null
  const track = [...tracks.value.values()][0]
  return track ? whereAt(track.rows, clockAt.value.getTime()) : null
})

/** The card's words for where to be now: the name of the stop that row belongs to. */
const hereText = computed(() => {
  const track = [...tracks.value.values()][0]
  const stop = track && hereNow.value && track.stops.find((s) => s.rows.includes(hereNow.value))
  return stop ? stopName(stop) : ''
})

function stopName(stop) {
  const pin = props.pinNumbers && stop.point ? props.pinNumbers.get(stop.point.group_id + '|' + stop.point.frame_id) : null
  return stop.name || (pin || stop.number ? 'Stop ' + (pin || stop.number) : '')
}

/** What a dot says. Live: its clock time and its place, or the time alone at a route point. Static: just its place. */
function dotText(track, stop) {
  const parts = props.whole ? [track.name] : []
  if (isLive.value) parts.push(formatTime(stop.point.planned_at))
  if (stop.name || !isLive.value) parts.push(stopName(stop))
  return parts.join(' · ')
}

// ---------- the map ----------

function drawZones() {
  if (!map || !zoneLayer) return
  zoneLayer.clearLayers()
  for (const zone of zones.value) {
    if (!zone.geojson) continue
    const shape = L.geoJSON(zone.geojson, { style: areaStyle(zone.kind), interactive: false })
    shape.addTo(zoneLayer)
    const caption = zoneCaption(L, shape, zone.kind, zone.name)
    if (caption) caption.addTo(zoneLayer)
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

    // The large dot is where the group should be now. A moment that only carries the group has no dot of its own, so
    // this is the last point it stated, not the frame the clock is on.
    const here = isLive.value ? whereAt(track.rows, clockAt.value.getTime()) : null
    for (const stop of track.stops) {
      if (stop.kind !== 'place') continue
      const row = stop.point
      const current = stop.rows.includes(here)
      const next = isLive.value && nextMoment.value && stop.rows.some((r) => r.lat != null && r.frame_id === nextMoment.value.frameId)
      const focused = stop.rows.some((r) => shownT === r.t_s || (props.focusT != null && String(props.focusT) === String(r.t_s)))
      const classes = ['pv-route-dot']
      if (current) classes.push('is-current')
      if (next) classes.push('is-next')
      if (focused) classes.push('is-focused')
      const icon = L.divIcon({
        className: 'pv-route-pin',
        html:
          `<span class="${classes.join(' ')}" style="--pv-dot:${track.colour}"` +
          ` data-testid="route-dot" data-group="${track.id}" data-t="${row.t_s}">` +
          `<span class="pv-route-dot-mark">${(props.pinNumbers && props.pinNumbers.get(track.id + '|' + row.frame_id)) || stop.number}</span>` +
          `<span class="pv-route-dot-label" data-testid="route-dot-label">${escapeHtml(dotText(track, stop))}</span>` +
          `</span>`,
        iconSize: [20, 20],
        iconAnchor: [10, 10],
      })
      // Later stops stand on top of earlier ones, as they would in the plan
      const order = (props.pinNumbers && props.pinNumbers.get(track.id + '|' + row.frame_id)) || stop.number || 0
      const marker = L.marker([row.lat, row.lng], { icon, keyboard: false, autoPan: true, title: dotText(track, stop), zIndexOffset: order * 100 })
      marker.bindTooltip(dotText(track, stop), { direction: 'top', offset: [0, -12] })
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
  const points = []
  for (const track of tracks.value.values()) for (const point of track.points) points.push([point.lat, point.lng])
  const hasPoint = points.length > 0
  // The zones, widened only by the walk near them (utils/venueFrame)
  const bounds = venueBounds(L, zoneLayer ? zoneLayer.getBounds() : null, points)
  if (!bounds || !bounds.isValid()) return
  // An empty plan with zones is framed on the zones and reframed when the walk arrives; the walk itself is the subject.
  map.fitBounds(bounds.pad(0.25), { animate: false })
  fittedWithPoints = hasPoint
}

/** Centre the map on a moment somebody tapped: its own point, at the zoom a person reads a place at. */
function focusMoment(moment) {
  if (moment && moment.rows.length) showMoment(moment.t_s, moment.rows[0].group_id)
}

/** Zoom in on where a group should be at one of its moments. A carried moment shows the last point the group stated. */
function showMoment(t_s, groupId) {
  const track = tracks.value.get(groupId)
  const row = track && track.rows.find((r) => r.t_s === t_s)
  const point = row && whereAt(track.rows, new Date(row.planned_at).getTime())
  if (!map || !point) return
  shownT = point.t_s
  draw()
  map.flyTo([point.lat, point.lng], SHOW_ZOOM, {
    duration: 0.6,
    animate: !window.matchMedia('(prefers-reduced-motion: reduce)').matches,
  })
}

watch(() => props.pinNumbers, () => draw())

defineExpose({ showMoment, zones })

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
watch(isLive, () => draw(), { flush: 'post' })
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
    <section class="pv-route" :class="{ 'is-embedded': embedded }" data-testid="plan-route">
      <header v-if="!embedded" class="pv-route-head">
        <div class="pv-route-id">
          <h2 class="pv-route-title">{{ whole ? 'The route' : 'Your route' }}</h2>
          <p class="pv-route-sub">
            <span class="pv-badge" :class="{ 'is-live': isLive }" data-testid="route-phase">{{ phaseWord }}</span>
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

      <p v-if="!embedded && phase === 'scheduled'" class="pv-route-line" data-testid="route-scheduled">
        Starts {{ formatDayTime(session.startsAt) }}.
      </p>
      <p v-if="!embedded && phase === 'ended'" class="pv-route-line" data-testid="route-ended">
        Ended {{ formatTime(endedAt) }}.
      </p>

      <!-- A read that failed says so and keeps the last answer: a map that blanks itself is worse than an old one. -->
      <p v-if="!embedded && errorMsg" class="pv-route-line is-warn" data-testid="route-error">
        {{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template>
      </p>

      <!-- The stage holds the map and the card that floats over it. v-show, not v-if: Leaflet holds the element, so it is
           taken out of the layout when there is nothing to draw rather than torn down and rebuilt. -->
      <div v-show="rows.length && (!embedded || hasPoints)" class="pv-route-stage">
        <div ref="mapEl" class="pv-map" data-testid="route-map"></div>

        <!-- Over the map: where to be now, then the next moment. Tapping a card centres the map on it. -->
        <div class="pv-route-cards">
          <button
            v-if="hereNow"
            type="button"
            class="pv-route-next is-here"
            data-testid="route-here"
            @click="showMoment(hereNow.t_s, hereNow.group_id)"
          >
            <span class="pv-route-next-kicker">Be here now</span>
            <strong class="pv-route-next-place">{{ hereText }}</strong>
          </button>
          <button
            v-if="nextMoment && isLive"
            type="button"
            class="pv-route-next"
            data-testid="route-next"
            @click="focusMoment(nextMoment)"
          >
            <span class="pv-route-next-kicker">Next</span>
            <strong class="pv-route-next-at">{{ formatTime(nextMoment.at) }}</strong>
            <span v-if="nextPlace" class="pv-route-next-place">{{ nextPlace }}</span>
            <span class="pv-route-next-in">{{ nextIn }}</span>
          </button>
        </div>
      </div>

      <SkeletonLoader v-if="!embedded && !loaded" variant="map" height="clamp(340px, 66vh, 780px)" :rows="3" label="Reading your route…" data-testid="route-loading" />

      <EmptyState
        v-else-if="!embedded && !rows.length"
        compact
        icon="route"
        :title="phase === 'none' ? 'No route yet' : !session.planId ? 'No plan running' : !whole && !groupName ? 'Not in a group' : 'Nothing planned'"
        :text="phase === 'none' ? 'The route appears once the event starts with a plan.' : !session.planId ? 'This event is running without a plan.' : !whole && !groupName ? 'Ask a planner to add you to a group.' : 'This plan has no moments for ' + (whole ? 'any group' : groupName) + '.'"
        data-testid="route-empty"
      />

      <p v-else-if="rows.length && !hasPoints" class="pv-route-note" data-testid="route-nopoints">
        {{ whole ? 'No group has a place on the map yet.' : 'Your group has no places on the map yet.' }}
      </p>
    </section>
  </div>
</template>
