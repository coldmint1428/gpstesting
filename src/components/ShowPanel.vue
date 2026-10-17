<script setup>
// ShowPanel - the run sheet beside the live map (merger Stage 6): NOW (progress, time left) with GO / Hold / +30 s,
// UP NEXT (planned -> projected, anchors), and what has run. Root and planners press; marshals only see.
// The server runs the show (026_live_show.sql); every button answers with what happened or why not.
// Under each cue, its groups' movements as chips (merger Stage 7): "Bands → FORMATION_1: 2 ✓ · 1 late".
import { ref, computed } from 'vue'
import { askConfirm, toast } from '../composables/useNotify'
import { mmss, sgClock } from '../composables/useShow'
import CueChips from './CueChips.vue'

const props = defineProps({
  show: { type: Object, required: true }, // useShow()
  canRun: { type: Boolean, default: false }, // root / planner
  ops: { type: Object, default: null }, // useOps() (movements), when the show has any
})

const b = computed(() => props.show.board.value)
const now = computed(() => props.show.now.value)
const running = computed(() => props.show.running.value)
const next = computed(() => props.show.next.value)
const busy = computed(() => props.show.busy.value)
const held = computed(() => b.value && b.value.state === 'held')

const SHOWN = 8
const showAllNext = ref(false)
const upcoming = computed(() => props.show.upcoming.value)
const visibleNext = computed(() => (showAllNext.value ? upcoming.value : upcoming.value.slice(0, SHOWN)))
const finished = computed(() => [...props.show.finished.value].reverse())

const t = (at) => (at ? new Date(at).getTime() : null)
const secs = (ms) => Math.round(ms / 1000)

// ---------- NOW ----------
const nowInfo = computed(() => {
  const r = running.value
  if (!r) return null
  const start = t(r.started_at)
  const end = t(r.natural_end)
  const total = Math.max(1, end - start)
  const left = end - now.value
  return {
    elapsed: secs(now.value - start),
    left: secs(left),
    over: left < 0,
    pct: Math.min(100, Math.max(0, ((now.value - start) / total) * 100)),
  }
})
const nextIn = computed(() => (next.value ? secs(t(next.value.projected_start) - now.value) : null))
const waitingFor = computed(() => (next.value && next.value.waiting_since ? secs(now.value - t(next.value.waiting_since)) : 0))

function typeLabel(c) {
  const out = []
  if (c.type === 'anchor') out.push('⚓ Anchor')
  if (c.type === 'flexible') out.push('Flexible −' + mmss(c.can_shorten_s))
  if (c.type !== 'anchor' && c.start_mode === 'manual') out.push('GO')
  if (c.type !== 'anchor' && c.start_mode === 'auto_ready') out.push('When ready')
  return out
}

// ---------- Buttons ----------
async function report(promise, okText) {
  const err = await promise
  if (err) toast(err, 'danger', 8000)
  else if (okText) toast(okText, 'success')
}

async function pressGo() {
  const n = next.value
  if (!n) return
  if (n.type === 'anchor') return toast(n.code + ' is an anchor: it starts by itself at ' + sgClock(n.planned_start) + '.', 'warning', 6000)
  const r = running.value
  // early = before its PLANNED time (a cue only delayed by the one running is not early)
  const early = t(n.planned_start) > now.value + 1000
  if (r || early) {
    const ok = await askConfirm({
      title: 'GO: ' + n.code + ' ' + n.title + '?',
      message: (r ? r.code + ' "' + r.title + '" ends now (' + mmss(nowInfo.value ? nowInfo.value.left : 0) + ' early). ' : '') +
        (early ? n.code + ' is planned for ' + sgClock(n.planned_start) + ': it starts ' + mmss((t(n.planned_start) - now.value) / 1000) + ' early.' : ''),
      confirmText: 'GO',
    })
    if (!ok) return
  }
  report(props.show.go(n.cue_id))
}
function pressHold() {
  report(held.value ? props.show.resume() : props.show.hold())
}
function pressAdd(seconds) {
  report(props.show.addTime(seconds))
}
async function pressSkip(c) {
  const isRunning = c.status === 'running'
  const ok = await askConfirm({
    title: (isRunning ? 'End ' : 'Skip ') + c.code + ' "' + c.title + '"?',
    message: isRunning
      ? 'It ends now and the next cue follows.'
      : c.type === 'anchor'
        ? 'This is an anchor (fixed time). Skipped, it will not start at ' + sgClock(c.planned_start) + '.'
        : 'It will not run in this show.',
    confirmText: isRunning ? 'End now' : 'Skip',
    danger: true,
  })
  if (ok) report(props.show.skip(c.cue_id))
}
</script>

<template>
  <div v-if="b" class="card show-panel" data-testid="show-panel">
    <!-- NOW -->
    <div class="card-body border-bottom">
      <div class="d-flex align-items-center mb-1">
        <span class="small text-muted text-uppercase fw-semibold flex-grow-1">Now</span>
        <span v-if="held" class="badge text-bg-warning" data-testid="show-held">Held · next waits for Resume</span>
      </div>

      <template v-if="running">
        <div class="fw-semibold" data-testid="show-now">
          <span class="text-muted small me-1">{{ running.code }}</span>{{ running.title }}
          <span v-for="l in typeLabel(running)" :key="l" class="badge text-bg-light border ms-1">{{ l }}</span>
        </div>
        <div class="progress my-2" role="progressbar" :aria-valuenow="Math.round(nowInfo.pct)" aria-valuemin="0" aria-valuemax="100" style="height: 0.6rem">
          <div class="progress-bar" :class="nowInfo.over ? 'bg-warning' : ''" :style="{ width: nowInfo.pct + '%' }"></div>
        </div>
        <div class="d-flex small">
          <span class="flex-grow-1 text-muted">Started {{ sgClock(running.started_at) }}{{ running.started_by ? ' by ' + running.started_by : '' }}</span>
          <span class="show-num fw-semibold" :class="{ 'text-warning-emphasis': nowInfo.over }" data-testid="show-left">
            {{ nowInfo.over ? 'over ' + mmss(-nowInfo.left) : mmss(nowInfo.left) + ' left' }}
          </span>
        </div>
        <div v-if="running.absorbed_s || running.added_s" class="small text-muted">
          <span v-if="running.absorbed_s">Shortened {{ mmss(running.absorbed_s) }} to catch up. </span>
          <span v-if="running.added_s">{{ running.added_s > 0 ? '+' : '' }}{{ mmss(running.added_s) }} added.</span>
        </div>
        <CueChips v-if="ops" :ops="ops" :cue-id="running.cue_id" />
      </template>
      <div v-else-if="b.state === 'finished'" class="text-muted" data-testid="show-now">The run sheet has finished.</div>
      <div v-else class="text-muted small" data-testid="show-now">Nothing is running.</div>

      <!-- What comes next, when nothing runs -->
      <div v-if="!running && next" class="mt-2 small" data-testid="show-next-state">
        <div v-if="next.wait_kind === 'go'" class="alert alert-warning py-2 mb-0">
          <strong>{{ next.code }} {{ next.title }}</strong> is ready and waits for GO ({{ mmss(waitingFor) }}).
        </div>
        <div v-else-if="next.wait_kind === 'groups'" class="alert alert-warning py-2 mb-0">
          <strong>{{ next.code }} {{ next.title }}</strong> is holding ({{ mmss(waitingFor) }}): waiting for
          {{ (next.missing || []).slice(0, 6).join(', ') }}<template v-if="(next.missing || []).length > 6"> and {{ next.missing.length - 6 }} more</template>.
          <template v-if="canRun"> GO starts it anyway.</template>
        </div>
        <div v-else-if="nextIn > 0">Next: <strong>{{ next.code }} {{ next.title }}</strong> in {{ mmss(nextIn) }}</div>
      </div>

      <!-- Buttons -->
      <div v-if="canRun && b.state !== 'finished'" class="d-flex flex-wrap gap-2 mt-3">
        <button
          class="btn btn-success flex-grow-1"
          :class="{ 'show-pulse': next && next.wait_kind }"
          :disabled="!!busy || !next || next.type === 'anchor'"
          data-testid="show-go"
          @click="pressGo"
        >
          {{ busy === 'go' ? 'Starting…' : next ? (next.type === 'anchor' ? '⚓ ' + next.code + ' starts by itself' : 'GO ▶ ' + next.code + ' ' + next.title) : 'GO' }}
        </button>
        <button class="btn" :class="held ? 'btn-warning' : 'btn-outline-warning'" :disabled="!!busy" data-testid="show-hold" @click="pressHold">
          {{ held ? 'Resume' : 'Hold' }}
        </button>
        <button class="btn btn-outline-secondary" :disabled="!!busy || !running" title="Add 30 seconds to the cue that is running" data-testid="show-add30" @click="pressAdd(30)">+30 s</button>
        <button class="btn btn-outline-secondary" :disabled="!!busy || !running" title="Take 30 seconds off the cue that is running" data-testid="show-sub30" @click="pressAdd(-30)">−30 s</button>
        <button v-if="running" class="btn btn-outline-danger btn-sm" :disabled="!!busy" data-testid="show-end-now" @click="pressSkip(running)">End now</button>
      </div>
    </div>

    <!-- UP NEXT -->
    <div class="card-body border-bottom">
      <div class="small text-muted text-uppercase fw-semibold mb-2">Up next</div>
      <p v-if="!upcoming.length" class="small text-muted mb-0">Nothing left.</p>
      <ul class="list-unstyled mb-0 d-grid gap-2" data-testid="show-upcoming">
        <li v-for="c in visibleNext" :key="c.cue_id" class="show-row" :class="{ 'show-anchor': c.type === 'anchor' }" :data-testid="'show-cue-' + c.code">
          <div class="d-flex align-items-start gap-2">
            <div class="show-num small text-nowrap">
              <div>{{ sgClock(c.planned_start) }}</div>
              <div v-if="c.delay_s && c.type !== 'anchor'" :class="c.delay_s > 0 ? 'text-warning-emphasis' : 'text-info-emphasis'">
                → {{ sgClock(c.projected_start) }} ({{ c.delay_s > 0 ? '+' : '' }}{{ mmss(c.delay_s) }})
              </div>
            </div>
            <div class="flex-grow-1 small">
              <span class="text-muted me-1">{{ c.code }}</span><span class="fw-semibold">{{ c.title }}</span>
              <span class="text-muted"> · {{ mmss(c.length_s) }}</span>
              <div>
                <span v-for="l in typeLabel(c)" :key="l" class="badge text-bg-light border me-1">{{ l }}</span>
                <span v-if="c.type === 'anchor' && c.risk_s > 0" class="badge text-bg-danger">At risk by {{ mmss(c.risk_s) }}</span>
                <span v-if="c.absorbed_s" class="badge text-bg-light border">absorbs {{ mmss(c.absorbed_s) }}</span>
              </div>
              <CueChips v-if="ops" :ops="ops" :cue-id="c.cue_id" />
            </div>
            <button v-if="canRun" class="btn btn-link btn-sm p-0 text-muted" :disabled="!!busy" :data-testid="'show-skip-' + c.code" @click="pressSkip(c)">Skip</button>
          </div>
        </li>
      </ul>
      <button v-if="upcoming.length > SHOWN" class="btn btn-link btn-sm p-0 mt-1" @click="showAllNext = !showAllNext">
        {{ showAllNext ? 'Show fewer' : 'Show all ' + upcoming.length }}
      </button>
    </div>

    <!-- Done -->
    <div class="card-body">
      <details data-testid="show-done">
        <summary class="small text-muted text-uppercase fw-semibold">Done ({{ finished.length }}) and the log</summary>
        <ul class="list-unstyled small mb-2 mt-2 d-grid gap-1">
          <li v-for="c in finished" :key="c.cue_id" :class="{ 'text-muted': c.status === 'skipped' }">
            <span class="show-num">{{ c.status === 'skipped' ? 'skipped' : sgClock(c.started_at) + '–' + sgClock(c.ended_at) }}</span>
            <span class="ms-1">{{ c.code }} {{ c.title }}</span>
            <span v-if="c.status === 'done' && c.delay_s" class="text-muted"> ({{ c.delay_s > 0 ? '+' : '' }}{{ mmss(c.delay_s) }})</span>
            <span v-if="c.note" class="text-muted"> · {{ c.note }}</span>
          </li>
        </ul>
        <div class="small fw-semibold mt-2">Log</div>
        <ul class="list-unstyled small mb-0 d-grid gap-1" data-testid="show-log">
          <li v-for="l in b.log" :key="l.id"><span class="show-num text-muted">{{ sgClock(l.at) }}</span> {{ l.message }}</li>
        </ul>
      </details>
    </div>
  </div>
</template>

<style scoped>
.show-num {
  font-variant-numeric: tabular-nums;
}
.show-row {
  border-left: 3px solid var(--bs-border-color);
  padding-left: 0.5rem;
}
.show-anchor {
  border-left-color: var(--bs-dark);
}
.show-pulse {
  animation: show-pulse 1.2s ease-in-out infinite;
}
@keyframes show-pulse {
  50% {
    box-shadow: 0 0 0 0.35rem rgba(var(--bs-success-rgb), 0.35);
  }
}
@media (prefers-reduced-motion: reduce) {
  .show-pulse {
    animation: none;
  }
}
</style>
