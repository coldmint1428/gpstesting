<script setup>
// CueChips - the movements due at one cue (merger Stage 7), as chips under the cue in the run sheet panel:
// "Bands → FORMATION_1: 2 ✓ · 1 late". The chip takes the colour of its worst status; tap it for every group.
import { ref, computed } from 'vue'
import { statusOf, statusText } from '../utils/opsStatus'

const props = defineProps({
  ops: { type: Object, required: true }, // useOps()
  cueId: { type: String, required: true },
})

const open = ref('') // the chip shown in full

const ORDER = ['arrived', 'arrived_late', 'on_track', 'at_risk', 'late', 'no_signal', 'missed', 'pending']
const SHORT = { arrived: '✓', arrived_late: '✓ late', on_track: 'on track', at_risk: 'at risk', late: 'late', no_signal: 'no signal', missed: 'missed', pending: 'waiting' }

const chips = computed(() => {
  const byLabel = new Map()
  for (const r of props.ops.rows.value) {
    if (r.cue_id !== props.cueId || r.status === 'skipped') continue
    const z = props.ops.zoneOf(r.zone_id)
    const g = props.ops.groupOf(r.group_id)
    const label = (r.category || (g ? g.name : 'A group')) + ' → ' + (z ? z.code : '?')
    if (!byLabel.has(label)) byLabel.set(label, [])
    byLabel.get(label).push(r)
  }
  return [...byLabel.entries()].map(([label, rows]) => {
    const worst = rows.reduce((w, r) => (statusOf(r.status).rank > statusOf(w.status).rank ? r : w), rows[0])
    const counts = ORDER.map((s) => {
      const n = rows.filter((r) => r.status === s).length
      return n ? (s === 'arrived' ? n + ' ✓' : n + ' ' + SHORT[s]) : ''
    }).filter(Boolean)
    return { label, rows, cls: statusOf(worst.status).cls, text: counts.join(' · ') }
  })
})
const groupName = (r) => {
  const g = props.ops.groupOf(r.group_id)
  return g ? g.name : 'A group'
}
</script>

<template>
  <div v-if="chips.length" class="d-flex flex-wrap gap-1 mt-1">
    <div v-for="c in chips" :key="c.label" class="w-100">
      <button
        type="button"
        class="btn btn-sm ops-chip border py-0 px-2 fw-semibold"
        :class="c.cls"
        :aria-expanded="open === c.label"
        :data-testid="'chip-' + c.label"
        @click="open = open === c.label ? '' : c.label"
      >
        {{ c.label }}: {{ c.text }} {{ open === c.label ? '▴' : '▾' }}
      </button>
      <ul v-if="open === c.label" class="list-unstyled small mb-0 mt-1 ps-2">
        <li v-for="r in c.rows" :key="r.group_id + r.movement_id" class="d-flex gap-2">
          <span class="flex-grow-1 text-truncate">{{ groupName(r) }}</span>
          <span class="text-nowrap" :class="statusOf(r.status).cls">{{ statusText(r) }}</span>
        </li>
      </ul>
    </div>
  </div>
</template>

<style scoped>
.ops-chip {
  border-radius: 999px;
  font-size: 0.75rem;
  text-align: left;
  white-space: normal;
}
</style>
