<script setup>
// ShowBar - the live show's top bar (merger Stage 6; look from the "Live Timeline + Map" concept): which run sheet,
// what is on now (cue n of N), the server's clock, ON TIME / RUNNING BEHIND / CRITICAL / HELD with ± m:ss, and the
// next anchor with its countdown. Everyone who sees the show sees the same second.
import { computed } from 'vue'
import { mmss, sgClock } from '../composables/useShow'

const props = defineProps({
  show: { type: Object, required: true }, // useShow()
  eventName: { type: String, default: '' },
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

// The status box: a word, the offset, and a colour (never the colour alone)
const status = computed(() => {
  const s = b.value
  if (!s) return null
  if (s.state === 'finished') return { label: 'FINISHED', big: '', tone: 'off', sub: '' }
  if (s.state === 'held') {
    return { label: 'HELD', big: mmss((now.value - new Date(s.held_since).getTime()) / 1000), tone: 'risk', sub: 'by ' + (s.held_by || 'a planner') }
  }
  if (s.state === 'before' && next.value) {
    return { label: 'STARTS IN', big: mmss((new Date(next.value.projected_start).getTime() - now.value) / 1000), tone: 'info', sub: '' }
  }
  if (s.anchor && s.anchor.risk_s > 0) return { label: 'CRITICAL', big: '+' + mmss(delay.value), tone: 'late', sub: 'runs ' + mmss(s.anchor.risk_s) + ' into the anchor' }
  if (delay.value >= 10) return { label: 'RUNNING BEHIND', big: '+' + mmss(delay.value), tone: 'risk', sub: '' }
  if (delay.value <= -10) return { label: 'AHEAD', big: '−' + mmss(-delay.value), tone: 'info', sub: '' }
  return { label: 'ON TIME', big: (delay.value > 0 ? '+' : delay.value < 0 ? '−' : '±') + mmss(Math.abs(delay.value)), tone: 'ok', sub: '' }
})

// "cue 3 of 12"
const position = computed(() => {
  const all = props.show.finished.value.length + props.show.upcoming.value.length + (running.value ? 1 : 0)
  return running.value ? props.show.finished.value.length + 1 + ' of ' + all : ''
})

const anchorIn = computed(() => {
  const a = b.value && b.value.anchor
  return a ? (new Date(a.at).getTime() - now.value) / 1000 : null
})
</script>

<template>
  <div v-if="b" class="show-bar" data-testid="show-bar">
    <div class="sb-what">
      <div class="d-flex align-items-center gap-2 flex-wrap">
        <span v-if="b.state !== 'finished'" class="sb-live">● LIVE</span>
        <strong class="sb-name" data-testid="show-version">{{ b.run_sheet_name }}</strong>
      </div>
      <span class="sb-sub" data-testid="show-now-line">
        <template v-if="running">Now: {{ running.title }}<template v-if="position"> · cue {{ position }}</template></template>
        <template v-else-if="next && next.wait_kind === 'go'">Waiting for GO: {{ next.title }}</template>
        <template v-else-if="next && next.wait_kind === 'groups'">Holding for groups: {{ next.title }}</template>
        <template v-else-if="next">Next: {{ next.title }} at {{ sgClock(next.projected_start) }}</template>
        <template v-else>The run sheet has finished.</template>
      </span>
    </div>

    <div class="sb-clock-box">
      <span class="sb-clock mono" title="Show time (the server's clock)" data-testid="show-clock">{{ sgClock(now) }}</span>
      <span class="sb-sub">Show clock · server time</span>
    </div>

    <div v-if="status" class="sb-status" :class="'sb-' + status.tone" data-testid="show-status">
      <span class="sb-status-label">{{ status.label }}</span>
      <span v-if="status.big" class="sb-status-big mono">{{ status.big }}</span>
      <span v-if="status.sub" class="sb-status-sub" data-testid="show-status-sub">{{ status.sub }}</span>
    </div>

    <div class="sb-anchor" data-testid="show-anchor">
      <template v-if="b.anchor">
        <span class="sb-sub">Next fixed time (anchor)</span>
        <span><strong>⚓ {{ b.anchor.title }} {{ sgClock(b.anchor.at) }}</strong>
          <template v-if="anchorIn !== null && anchorIn > 0"> · <span class="mono">{{ mmss(anchorIn) }}</span> left</template></span>
        <span :class="b.anchor.risk_s > 0 ? 'sb-warn' : 'sb-good'">
          {{ b.anchor.risk_s > 0 ? 'At risk: the show runs ' + mmss(b.anchor.risk_s) + ' into it' : 'Buffer OK' }}
        </span>
      </template>
      <span v-else class="sb-sub">No anchor (fixed time) ahead</span>
    </div>
  </div>
</template>

<style scoped>
.show-bar {
  background: var(--bg-chrome);
  color: var(--text-on-chrome);
  border-radius: 12px;
  padding: 14px 20px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px 28px;
}
.sb-what {
  display: flex;
  flex-direction: column;
  gap: 2px;
  flex: 1 1 220px;
  min-width: 0;
}
.sb-live {
  background: var(--danger-solid);
  color: #fff;
  font-size: 12px;
  font-weight: 700;
  padding: 2px 8px;
  border-radius: 4px;
  letter-spacing: 0.04em;
}
.sb-name {
  font-size: 16px;
}
.sb-sub {
  font-size: 13px;
  color: var(--text-on-chrome-muted);
}
.sb-clock-box {
  display: flex;
  flex-direction: column;
}
.sb-clock {
  font-size: 36px;
  line-height: 1;
  font-weight: 600;
  letter-spacing: 0.02em;
}
.sb-status {
  border-radius: 8px;
  padding: 6px 14px;
  display: flex;
  flex-direction: column;
  min-width: 132px;
}
.sb-status-label {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.06em;
}
.sb-status-big {
  font-size: 22px;
  font-weight: 600;
  line-height: 1.2;
}
.sb-status-sub {
  font-size: 12px;
}
.sb-ok {
  background: var(--status-info-bg);
  color: var(--status-info-fg);
}
.sb-risk {
  background: var(--status-warning-bg);
  color: var(--status-warning-fg);
}
.sb-late {
  background: var(--status-error-bg);
  color: var(--status-error-fg);
}
.sb-info {
  background: var(--brand-primary-subtle);
  color: var(--text-link);
}
.sb-off {
  background: var(--chrome-hover);
  color: var(--text-on-chrome-muted);
}
.sb-anchor {
  display: flex;
  flex-direction: column;
  gap: 2px;
  flex: 1 1 220px;
  font-size: 14px;
}
.sb-good {
  font-size: 13px;
  color: var(--accent-300);
}
.sb-warn {
  font-size: 13px;
  color: var(--status-error-border);
  font-weight: 600;
}
/* Phone: the clock and the status side by side, so the bar stays a few lines tall and the map is close below */
@media (max-width: 575.98px) {
  .show-bar {
    padding: 12px 14px;
    gap: 10px 14px;
  }
  .sb-what,
  .sb-anchor {
    flex-basis: 100%;
  }
  .sb-clock {
    font-size: 30px;
  }
  .sb-clock-box .sb-sub {
    font-size: 12px;
  }
  .sb-status {
    min-width: 0;
    padding: 4px 10px;
  }
  .sb-status-big {
    font-size: 19px;
  }
  .sb-anchor {
    font-size: 13px;
  }
}
</style>
