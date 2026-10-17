<script setup>
// ShowBar - the live show's top bar (merger Stage 6): the server's clock, ON TIME / RUNNING BEHIND / CRITICAL /
// HELD with ± m:ss, and the next anchor with its countdown. Everyone who sees the show sees the same second.
import { computed } from 'vue'
import { mmss, sgClock } from '../composables/useShow'

const props = defineProps({
  show: { type: Object, required: true }, // useShow()
})

const b = computed(() => props.show.board.value)
const now = computed(() => props.show.now.value)
const next = computed(() => props.show.next.value)
const running = computed(() => props.show.running.value)

// How far behind right now: a cue that is due but not started grows late every second
const delay = computed(() => {
  if (!b.value) return 0
  const n = next.value
  if (n && !running.value && n.due_at && new Date(n.due_at).getTime() <= now.value) {
    return Math.round((now.value - new Date(n.planned_start).getTime()) / 1000)
  }
  return b.value.delay_s || 0
})

const status = computed(() => {
  const s = b.value
  if (!s) return null
  if (s.state === 'finished') return { label: 'FINISHED', cls: 'text-bg-secondary', sub: '' }
  if (s.state === 'held') {
    return { label: 'HELD', cls: 'text-bg-warning', sub: 'by ' + (s.held_by || 'a planner') + ' · ' + mmss((now.value - new Date(s.held_since).getTime()) / 1000) }
  }
  if (s.state === 'before' && next.value) {
    return { label: 'STARTS IN ' + mmss((new Date(next.value.projected_start).getTime() - now.value) / 1000), cls: 'text-bg-info', sub: '' }
  }
  if (s.anchor && s.anchor.risk_s > 0) {
    return { label: 'CRITICAL', cls: 'text-bg-danger', sub: 'runs ' + mmss(s.anchor.risk_s) + ' into the anchor' }
  }
  if (delay.value >= 10) return { label: 'RUNNING BEHIND +' + mmss(delay.value), cls: 'text-bg-warning', sub: '' }
  if (delay.value <= -10) return { label: 'AHEAD ' + mmss(delay.value), cls: 'text-bg-info', sub: '' }
  return { label: 'ON TIME', cls: 'text-bg-success', sub: delay.value ? (delay.value > 0 ? '+' : '') + mmss(delay.value) : '' }
})

const anchorIn = computed(() => {
  const a = b.value && b.value.anchor
  return a ? (new Date(a.at).getTime() - now.value) / 1000 : null
})
</script>

<template>
  <div v-if="b" class="show-bar d-flex flex-wrap align-items-center gap-2 gap-md-3 px-3 py-2 mb-2 rounded border" data-testid="show-bar">
    <div class="show-clock" title="Show time (the server's clock)" data-testid="show-clock">{{ sgClock(now) }}</div>
    <div v-if="status" class="d-flex align-items-center gap-2">
      <span class="badge fs-6" :class="status.cls" data-testid="show-status">{{ status.label }}</span>
      <span v-if="status.sub" class="small text-muted" data-testid="show-status-sub">{{ status.sub }}</span>
    </div>
    <div v-if="b.anchor" class="small ms-md-auto" :class="b.anchor.risk_s > 0 ? 'text-danger fw-semibold' : ''" data-testid="show-anchor">
      ⚓ {{ b.anchor.code }} {{ b.anchor.title }} {{ sgClock(b.anchor.at) }}
      <span v-if="anchorIn !== null && anchorIn > 0"> · in {{ mmss(anchorIn) }}</span>
      <span v-if="b.anchor.risk_s > 0"> · at risk by {{ mmss(b.anchor.risk_s) }}</span>
    </div>
    <div class="small text-muted" :class="{ 'ms-auto': !b.anchor }" data-testid="show-version">{{ b.run_sheet_name }}</div>
  </div>
</template>

<style scoped>
.show-bar {
  background: var(--bs-tertiary-bg);
}
.show-clock {
  font-variant-numeric: tabular-nums;
  font-size: 1.5rem;
  font-weight: 600;
  letter-spacing: 0.02em;
}
</style>
