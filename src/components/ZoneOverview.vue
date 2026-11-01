<script setup>
// ZoneOverview - the event's zones at a glance, above the bench on the Zones page: each area's name, the code it is
// called by, its type, and how many of each kind there are. Drawing and editing stay on the bench below (the polygon
// bench writes the zones; 020's trigger keeps them in step).
//
// It used to say how many run-sheet movements sent groups to each zone and how many versions they came from. Step 25
// deleted the movements with the run sheet, and a plan states a position as lat/lng rather than as a zone, so the
// count had no honest replacement: the card lists the zones and says what each kind is for.
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { areaKind } from '../utils/areaKinds'
import { useLoadGate } from '../composables/usePageReady'

const props = defineProps({ eventId: { type: String, required: true } })

const zones = ref([])
const loaded = ref(false)
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => !loaded.value)

async function load() {
  const z = await supabase.from('zones').select('id, code, name, kind').eq('event_id', props.eventId).order('code')
  // A failed look (no signal) keeps what is shown rather than claiming there are no zones
  if (z.error) return
  zones.value = z.data || []
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
  <div data-testid="zone-overview">
    <p v-if="loaded && !zones.length" class="kp-note mt-0" data-testid="zone-overview-empty">No zones yet. Press <strong>Draw areas</strong> to add one.</p>
    <ul v-else class="kp-zones" :aria-label="zones.length + ' zones: ' + summary.join(', ')">
      <li v-for="z in zones" :key="z.id" class="kp-zone" :data-testid="'zone-' + z.code" :title="areaKind(z.kind).label">
        <span class="kp-zone-sw" :style="{ background: areaKind(z.kind).colour }" aria-hidden="true"></span>
        <span :class="{ 'text-danger': z.kind === 'no_go' }">{{ z.name }}</span>
        <code>{{ z.code }}</code>
      </li>
    </ul>
  </div>
</template>
