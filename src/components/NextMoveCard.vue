<script setup>
// NextMoveCard - "your next move" for a group's members during the live show (merger Stage 8): where to be, by when
// (as projected), when to leave, at your pace when you arrive, a mini map with the route, what comes after, "Tell
// planner: delayed" and Stop sharing. The server works it all out (my_moves); pushes say Get ready / Leave now /
// Running late at the right moments, and tapping one opens this card.
// Radio (029): the group's channel / call sign; "We're in position" (IC or admin) counts the arrival at once, like a
// radio call (undo within 5 min). While the show is on hold the card says so instead of "Leave now". An IC who is not
// sharing is told: the planners only see the group through the ICs who share.
// Plain layout for now: the phone design comes from the team's Figma.
import { ref, computed, watch, onUnmounted, nextTick } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { mmss, sgClock } from '../composables/useShow'
import { statusOf } from '../utils/opsStatus'
import { askConfirm, toast } from '../composables/useNotify'
import { isNativeApp } from '../lib/platform'
import BottomSheet from './BottomSheet.vue'

const props = defineProps({
  moves: { type: Object, required: true }, // useMyMoves()
  myPosition: { type: Object, default: null }, // { lat, lng } of this person, if sharing
  sharing: { type: Boolean, default: false },
  ring: { type: Boolean, default: false }, // phone app: show the countdown ring
})
const emit = defineEmits(['stop-sharing', 'share'])

const next = computed(() => props.moves.next.value)
const after = computed(() => props.moves.after.value)
const now = computed(() => props.moves.now.value)
const t = (at) => (at ? new Date(at).getTime() : null)
const secsTo = (at) => (at ? Math.round((t(at) - now.value) / 1000) : null)

// What to do now, in one line
const held = computed(() => !!props.moves.heldSince.value)

// The ring (phone app). Before the group has set off it counts down to the leave-by time ("Leave in"), once it is
// moving to the deadline ("Time left"); it is full 10 minutes out and empties as the moment comes. Colour always
// comes with a word: amber in the last minute, red once it has passed, teal when the group has arrived.
const RING_LEN = 2 * Math.PI * 52
const RING_WINDOW_S = 600
const countdown = computed(() => {
  const r = next.value
  if (!r) return null
  if (r.status === 'arrived') return { label: 'Arrived', value: '✓', share: 1, tone: 'ok' }
  if (held.value) return { label: 'On hold', value: 'Wait', share: 1, tone: 'risk' }
  const leaving = !r.moving && r.leave_by
  const s = secsTo(leaving ? r.leave_by : r.deadline)
  if (s == null) return null
  if (s <= 0) return { label: leaving ? 'Leave' : 'Due', value: 'Now', share: 1, tone: 'late' }
  return {
    label: leaving ? 'Leave in' : 'Time left',
    value: mmss(s),
    share: Math.min(1, s / RING_WINDOW_S),
    tone: s <= 60 ? 'risk' : 'go',
  }
})
// "+00:45" when the show's delay moved this deadline from its plan, else ''
const moved = computed(() => {
  const r = next.value
  if (!r || !r.planned_deadline || !r.deadline) return ''
  const s = Math.round((t(r.deadline) - t(r.planned_deadline)) / 1000)
  return Math.abs(s) < 1 ? '' : (s > 0 ? '+' : '−') + mmss(Math.abs(s))
})
const advice = computed(() => {
  const r = next.value
  if (!r) return null
  if (held.value && r.status !== 'arrived') return { cls: 'text-warning-emphasis fw-bold', text: 'The show is on hold: stay where you are and wait.' }
  if (r.status === 'arrived') return { cls: 'text-success', text: 'You are there ✓ (since ' + sgClock(r.arrived_at) + ')' }
  if ((r.inside || 0) > 0 && r.inside >= (r.required || 1)) return { cls: 'text-success', text: 'You are inside: stay ' + (r.dwell_s || 20) + ' s to count as arrived.' }
  if (!r.moving && r.leave_by) {
    const s = secsTo(r.leave_by)
    if (s > 60) return { cls: '', text: 'Leave by ' + sgClock(r.leave_by) + ' (in ' + mmss(s) + ')' }
    if (s > 0) return { cls: 'text-warning-emphasis fw-bold', text: 'Get ready: leave in ' + mmss(s) }
    return { cls: 'text-danger fw-bold', text: 'Leave now' + (s < -10 ? ' (you should have left ' + mmss(-s) + ' ago)' : '') }
  }
  if (r.status === 'no_signal') return { cls: 'text-muted', text: 'We cannot see your group: start sharing your location.' }
  return null
})

// "At your pace you arrive 18:04:20 · 35 s spare" / "+0:28 late"
const pace = computed(() => {
  const r = next.value
  // only once moving: before that the ETA is "if you left now", and the leave-by line says what matters
  if (!r || !r.eta || r.status === 'arrived' || (!r.moving && !(r.late_s > 0))) return null
  const late = r.late_s && r.late_s > 0
  return {
    late,
    text: 'At your pace you arrive ' + sgClock(r.eta) + (late ? ' · +' + mmss(r.late_s) + ' late' : r.spare_s != null ? ' · ' + mmss(r.spare_s) + ' spare' : ''),
  }
})

// ---------- Mini map: the zone, the route, me ----------
const mapEl = ref(null)
let map = null
let layer = null
let fittedFor = null
function draw() {
  if (!map || !layer) return
  layer.clearLayers()
  const r = next.value
  if (!r) return
  const shapes = []
  if (r.zone) shapes.push(L.geoJSON(r.zone, { style: { color: '#0f766e', weight: 2, fillOpacity: 0.15 }, interactive: false }).addTo(layer))
  if (r.route) shapes.push(L.geoJSON(r.route, { style: { color: '#0d6efd', weight: 4, opacity: 0.8, dashArray: '6 6' }, interactive: false }).addTo(layer))
  if (props.myPosition) {
    L.circleMarker([props.myPosition.lat, props.myPosition.lng], { radius: 7, color: '#fff', weight: 2, fillColor: '#0d6efd', fillOpacity: 1 }).addTo(layer)
  }
  // fit once per movement (not on every position: the person may be panning)
  if (fittedFor !== r.movement_id) {
    const bounds = L.latLngBounds([])
    for (const s of shapes) bounds.extend(s.getBounds())
    if (props.myPosition) bounds.extend([props.myPosition.lat, props.myPosition.lng])
    if (bounds.isValid()) {
      map.fitBounds(bounds.pad(0.25), { maxZoom: 18 })
      fittedFor = r.movement_id
    }
  }
}
// The map's box only exists while there is a next move: a map for each box that appears
watch(
  mapEl,
  (el) => {
    if (map) map.remove()
    map = null
    layer = null
    fittedFor = null
    if (!el) return
    map = createSingaporeMap(el)
    layer = L.layerGroup().addTo(map)
    draw()
  },
  { flush: 'post' },
)
onUnmounted(() => {
  if (map) map.remove()
  map = null
})
watch(() => [next.value, props.myPosition], draw, { deep: true })

// ---------- Tell planner: delayed ----------
// The button opens a short "why?" box with its own Tell button. On the website it opens just under the buttons; on
// the phone that spot is often below the screen (behind the bottom tabs), so pressing the button seemed to do nothing.
// The phone uses a bottom sheet with one-tap reasons instead, and the website box scrolls into view with the cursor in it.
const writing = ref(false)
const note = ref('')
const noteEl = ref(null)
const REASONS = ['Stuck at a gate', 'Crowd in the way', 'Waiting for our people', 'Route blocked']
function openDelay() {
  writing.value = !writing.value
  if (writing.value && !isNativeApp)
    nextTick(() => {
      if (!noteEl.value) return
      noteEl.value.scrollIntoView({ block: 'center', behavior: 'smooth' })
      noteEl.value.focus({ preventScroll: true })
    })
}
async function sendDelay() {
  const err = await props.moves.reportDelay(note.value)
  if (err) return toast(err, 'danger', 8000)
  toast('The planners have been told.', 'success', 4000)
  writing.value = false
  note.value = ''
}
const reportedRecently = computed(() => next.value && next.value.delay_at && now.value - t(next.value.delay_at) < 60000)

// ---------- We're in position ----------
async function inPosition() {
  const ok = await askConfirm({
    title: 'In position at ' + next.value.zone_code + '?',
    message: 'The planners will see your group in position at once. You can undo it for 5 minutes.',
    confirmText: "We're in position",
  })
  if (!ok) return
  const err = await props.moves.inPosition(false)
  if (err) return toast(err, 'danger', 8000)
  toast('The planners see your group in position.', 'success', 4000)
}
async function undoInPosition() {
  const err = await props.moves.inPosition(true)
  if (err) return toast(err, 'danger', 8000)
  toast('Taken back: your group is not in position.', 'warning', 4000)
}
</script>

<template>
  <div v-if="next || after.length" class="card mb-3 next-move" data-testid="next-move">
    <div class="card-body">
      <div class="d-flex align-items-center gap-2 mb-1">
        <span class="small text-muted text-uppercase fw-semibold flex-grow-1">Your next move</span>
        <span v-if="next" class="badge border" :class="statusOf(next.status).cls" data-testid="next-status">
          {{ statusOf(next.status).symbol }} {{ statusOf(next.status).label }}
        </span>
      </div>

      <div v-if="moves.radio.value" class="small text-muted mb-1" data-testid="next-radio">📻 Radio: {{ moves.radio.value }}</div>
      <div v-if="moves.isIc.value && !sharing" class="alert alert-warning py-2 px-2 small d-flex align-items-center gap-2 mb-2" data-testid="next-not-sharing">
        <span class="flex-grow-1">You are an IC but not sharing your location: the planners only see your group through the other ICs.</span>
        <button type="button" class="btn btn-sm btn-warning" @click="emit('share')">Share</button>
      </div>
      <div v-if="moves.lastReported.value && moves.canReport.value" class="small mb-2" data-testid="next-reported">
        ✓ You said in position at {{ moves.lastReported.value.zone_code }} ({{ sgClock(moves.lastReported.value.arrived_at) }}).
        <button type="button" class="btn btn-link btn-sm p-0 align-baseline" :disabled="moves.busy.value" data-testid="next-undo" @click="undoInPosition">Undo</button>
      </div>

      <template v-if="next">
        <!-- Phone app: the countdown ring beside where to go (Figma screen 4). The ring empties as the moment nears. -->
        <div v-if="ring && countdown" class="nm-hero" data-testid="next-ring">
          <svg class="nm-ring" viewBox="0 0 120 120" role="img" :aria-label="countdown.label + ' ' + countdown.value">
            <circle cx="60" cy="60" r="52" class="nm-ring-track" />
            <circle
              cx="60"
              cy="60"
              r="52"
              class="nm-ring-arc"
              :class="'nm-ring-' + countdown.tone"
              :stroke-dasharray="RING_LEN"
              :stroke-dashoffset="RING_LEN * (1 - countdown.share)"
              transform="rotate(-90 60 60)"
            />
            <text x="60" y="52" text-anchor="middle" class="nm-ring-label">{{ countdown.label }}</text>
            <text x="60" y="78" text-anchor="middle" class="nm-ring-value" :class="'nm-ring-' + countdown.tone">{{ countdown.value }}</text>
          </svg>
          <div class="nm-hero-text">
            <div class="nm-where" data-testid="next-where">Be inside {{ next.zone_name }}</div>
            <div class="small text-muted">{{ next.zone_code }}</div>
          </div>
        </div>
        <div v-else class="nm-where" data-testid="next-where">
          Be inside {{ next.zone_name }} <span class="text-muted small fw-normal">({{ next.zone_code }})</span>
        </div>
        <div class="next-num small" data-testid="next-by">
          by <strong>{{ sgClock(next.deadline) }}</strong>
          <span v-if="next.cue_title" class="text-muted"> ({{ next.cue_code }} {{ next.cue_title }}<template v-if="moved"> · moved {{ moved }}</template>)</span>
          <span v-else-if="moved" class="text-muted"> (moved {{ moved }})</span>
        </div>

        <!-- The two numbers an IC needs at a glance -->
        <div v-if="next.status !== 'arrived'" class="nm-tiles mt-2">
          <div class="nm-tile" :class="secsTo(next.deadline) <= 0 ? 'nm-tile-late' : ''" data-testid="next-time-left">
            <span class="nm-tile-label">Time left</span>
            <span class="nm-tile-big next-num">{{ secsTo(next.deadline) > 0 ? mmss(secsTo(next.deadline)) : 'Due now' }}</span>
          </div>
          <div class="nm-tile" data-testid="next-distance">
            <span class="nm-tile-label">Distance</span>
            <span class="nm-tile-big next-num">{{ next.remaining_m != null ? Math.round(next.remaining_m) + ' m' : '—' }}</span>
          </div>
        </div>

        <div v-if="advice" class="mt-2 fs-6" :class="advice.cls" data-testid="next-advice">{{ advice.text }}</div>
        <div v-if="pace && !held" class="small mt-1" :class="pace.late ? 'text-danger fw-semibold' : ''" data-testid="next-pace">
          {{ pace.text }}<template v-if="pace.late"> Walk faster or tell your planner.</template>
        </div>
        <div v-if="next.remaining_m != null && next.status !== 'arrived' && (next.basis === 'route' || (next.moving && next.speed_mps) || next.required > 1)" class="small text-muted">
          <template v-if="next.basis === 'route'">Measured along the walking route</template>
          <template v-if="next.moving && next.speed_mps">{{ next.basis === 'route' ? ' · ' : '' }}moving {{ Number(next.speed_mps).toFixed(1) }} m/s</template>
          <template v-if="next.required > 1">{{ next.basis === 'route' || (next.moving && next.speed_mps) ? ' · ' : '' }}{{ next.inside || 0 }} of {{ next.required }} ICs inside</template>
        </div>

        <div ref="mapEl" class="next-map rounded border mt-2" aria-label="Map of where to go" data-testid="next-map"></div>

        <div class="d-flex flex-wrap gap-2 mt-2">
          <button
            v-if="next.status !== 'arrived'"
            type="button"
            class="btn btn-sm btn-outline-danger"
            :disabled="moves.busy.value || reportedRecently"
            data-testid="tell-delayed"
            @click="openDelay"
          >
            {{ reportedRecently ? 'Planners told ✓' : 'Tell planner: delayed' }}
          </button>
          <button
            v-if="moves.canReport.value && next.status !== 'arrived'"
            type="button"
            class="btn btn-sm btn-outline-success"
            :disabled="moves.busy.value"
            data-testid="next-in-position"
            @click="inPosition"
          >
            We're in position
          </button>
          <button v-if="sharing" type="button" class="btn btn-sm btn-outline-secondary" data-testid="next-stop-sharing" @click="emit('stop-sharing')">
            Stop sharing
          </button>
        </div>
        <form v-if="writing && !isNativeApp" class="d-flex gap-1 mt-2" @submit.prevent="sendDelay">
          <input ref="noteEl" v-model="note" class="form-control form-control-sm" maxlength="200" placeholder="Why? (optional, e.g. stuck at the gate)" aria-label="Why are you delayed" data-testid="delay-note" />
          <button type="submit" class="btn btn-sm btn-danger" :disabled="moves.busy.value" data-testid="delay-send">Tell</button>
        </form>
      </template>
      <p v-else class="text-muted small mb-0">Nothing to do right now.</p>

      <BottomSheet v-if="isNativeApp" :open="writing && !!next" title="Tell the planners you're delayed" @close="writing = false">
        <p v-if="next" class="text-muted mb-2">
          Due in {{ next.zone_name }} ({{ next.zone_code }}) by {{ sgClock(next.deadline) }}. They see it at once on their Ops page.
        </p>
        <div class="d-flex flex-wrap gap-2 mb-2" role="group" aria-label="Quick reasons">
          <button
            v-for="r in REASONS"
            :key="r"
            type="button"
            class="btn btn-sm rounded-pill"
            :class="note === r ? 'btn-dark' : 'btn-outline-secondary'"
            @click="note = note === r ? '' : r"
          >
            {{ r }}
          </button>
        </div>
        <form @submit.prevent="sendDelay">
          <input v-model="note" class="form-control mb-3" maxlength="200" placeholder="Or say why (optional)" aria-label="Why are you delayed" data-testid="delay-note" />
          <button type="submit" class="btn btn-danger w-100 py-2" :disabled="moves.busy.value" data-testid="delay-send">
            {{ moves.busy.value ? 'Sending…' : 'Tell the planners' }}
          </button>
        </form>
      </BottomSheet>

      <div v-if="after.length" class="mt-3">
        <div class="small text-muted text-uppercase fw-semibold mb-1">After that</div>
        <ul class="list-unstyled small mb-0 d-grid gap-1" data-testid="next-after">
          <li v-for="r in after" :key="r.movement_id" class="d-flex gap-2">
            <span class="flex-grow-1">{{ r.zone_name }} <span class="text-muted">({{ r.zone_code }})</span></span>
            <strong class="next-num">{{ sgClock(r.deadline) }}</strong>
          </li>
        </ul>
      </div>
    </div>
  </div>
</template>

<style scoped>
.next-num {
  font-variant-numeric: tabular-nums;
}
.next-map {
  height: 180px;
}
.next-move {
  border-radius: 12px;
}
.nm-where {
  font-size: 22px;
  font-weight: 700;
  line-height: 1.2;
}
.nm-hero {
  display: flex;
  align-items: center;
  gap: 16px;
  margin: 4px 0 6px;
}
.nm-ring {
  flex: none;
  width: 112px;
  height: 112px;
}
.nm-ring-track {
  fill: none;
  stroke: #e2e8f0;
  stroke-width: 10;
}
.nm-ring-arc {
  fill: none;
  stroke-width: 10;
  stroke-linecap: round;
  transition: stroke-dashoffset 1s linear;
}
circle.nm-ring-go {
  stroke: #f97316;
}
circle.nm-ring-risk {
  stroke: #d97706;
}
circle.nm-ring-late {
  stroke: #dc2626;
}
circle.nm-ring-ok {
  stroke: #0f766e;
}
.nm-ring-label {
  font-size: 12px;
  fill: #64748b;
  font-weight: 500;
}
.nm-ring-value {
  font-size: 26px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  fill: #c2410c;
}
text.nm-ring-risk {
  fill: #b45309;
}
text.nm-ring-late {
  fill: #dc2626;
}
text.nm-ring-ok {
  fill: #0f766e;
}
.nm-hero-text {
  min-width: 0;
}
@media (prefers-reduced-motion: reduce) {
  .nm-ring-arc {
    transition: none;
  }
}
.nm-tiles {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}
.nm-tile {
  display: flex;
  flex-direction: column;
  background: #f1f5f9;
  border-radius: 8px;
  padding: 8px 12px;
}
.nm-tile-late {
  background: #fee2e2;
  color: #991b1b;
}
.nm-tile-label {
  font-size: 12px;
  color: #475569;
}
.nm-tile-late .nm-tile-label {
  color: inherit;
}
.nm-tile-big {
  font-family: 'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 26px;
  font-weight: 600;
  line-height: 1.2;
}
</style>
