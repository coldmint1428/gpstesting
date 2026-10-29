<script setup>
// ZoneOverview - the event's zones at a glance, above the bench on the Zones page: each area's name, the code the
// run sheet uses, its type, and how many run sheet movements send groups there. Drawing and editing stay on the
// bench below (the polygon bench writes the zones; 020's trigger keeps them in step).
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { areaKind } from '../utils/areaKinds'

const props = defineProps({ eventId: { type: String, required: true } })

const zones = ref([])
const uses = ref({}) // zone id -> number of movements (every version)
const versions = ref(0) // run sheet versions with movements (the counts add them all up)
const loaded = ref(false)

async function load() {
  const [z, m] = await Promise.all([
    supabase.from('zones').select('id, code, name, kind').eq('event_id', props.eventId).order('code'),
    supabase.from('movements').select('zone_id, run_sheet_id, run_sheets!inner(event_id)').eq('run_sheets.event_id', props.eventId),
  ])
  // A failed look (no signal) keeps what is shown rather than claiming there are no zones
  if (z.error || m.error) return
  zones.value = z.data || []
  const count = {}
  for (const row of m.data || []) if (row.zone_id) count[row.zone_id] = (count[row.zone_id] || 0) + 1
  uses.value = count
  versions.value = new Set((m.data || []).map((row) => row.run_sheet_id)).size
  loaded.value = true
}

// The bench saves as you draw: look again every 10 s while the page is open
let timer = null
onMounted(() => {
  load()
  timer = setInterval(() => {
    if (!document.hidden) load()
  }, 10000)
})
onUnmounted(() => clearInterval(timer))

const summary = computed(() => {
  const byKind = {}
  for (const z of zones.value) byKind[z.kind] = (byKind[z.kind] || 0) + 1
  return Object.entries(byKind).map(([k, n]) => n + ' ' + areaKind(k).label + (n === 1 ? '' : k === 'no_go' ? '' : 's'))
})
</script>

<template>
  <div class="ev-surface zo" data-testid="zone-overview">
    <div class="d-flex flex-wrap align-items-baseline gap-2 mb-2">
      <span class="ev-label">This event's zones</span>
      <span v-if="zones.length" class="small text-muted">{{ zones.length }} in all · {{ summary.join(' · ') }}</span>
    </div>
    <p v-if="loaded && !zones.length" class="small text-muted mb-2" data-testid="zone-overview-empty">
      No zones yet. Press <strong>Draw areas</strong> below and draw the formations, holding areas and doors groups must
      reach, and any No-Go areas.
    </p>
    <ul v-else class="zo-list list-unstyled mb-2">
      <li v-for="z in zones" :key="z.id" class="zo-item" :data-testid="'zone-' + z.code">
        <span class="zo-swatch" :style="{ background: areaKind(z.kind).colour }" aria-hidden="true"></span>
        <span class="zo-text">
          <strong class="text-truncate">{{ z.name }}</strong>
          <span class="small"><span class="mono">{{ z.code }}</span> · {{ areaKind(z.kind).label }}</span>
          <span class="small" :class="uses[z.id] ? 'text-success' : 'text-muted'">
            {{ uses[z.id] ? 'In the run sheet: ' + uses[z.id] + (uses[z.id] === 1 ? ' movement' : ' movements') + (versions > 1 ? ' (all versions)' : '') : z.kind === 'no_go' ? 'Groups are warned inside' : 'Not in the run sheet yet' }}
          </span>
        </span>
      </li>
    </ul>
    <p class="small text-muted mb-0">
      Draw, move or rename areas on the map below. The code (e.g. <span class="mono">FORMATION_1</span>) is what the run
      sheet's movements point to; a zone the live show still needs cannot be deleted.
    </p>
  </div>
</template>

<style scoped>
.zo-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 8px;
}
.zo-item {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  border: 1px solid var(--border-subtle);
  border-radius: 10px;
  padding: 8px 10px;
  min-width: 0;
}
.zo-swatch {
  flex: none;
  width: 12px;
  height: 12px;
  border-radius: 3px;
  margin-top: 4px;
}
.zo-text {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
</style>
