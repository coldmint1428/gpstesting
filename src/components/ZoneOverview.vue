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
  <div class="zo-card" data-testid="zone-overview">
    <div class="d-flex flex-wrap align-items-baseline gap-2 mb-2">
      <span class="zo-label">This event's zones</span>
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
          <span class="small" :class="z.kind === 'no_go' ? 'text-danger' : 'text-muted'">
            {{ z.kind === 'no_go' ? 'Groups are warned inside it' : 'A place groups are sent to' }}
          </span>
        </span>
      </li>
    </ul>
    <p class="small text-muted mb-0">
      Draw, move or rename areas on the map below. The code (e.g. <span class="mono">FORMATION_1</span>) is how a place
      is named in the plan and on the radio.
    </p>
  </div>
</template>

<style scoped>
/* The event workspace this card was built for is gone, so it carries its own surface: the same values the shell's
   .ev .ev-surface and .ev-label used, to keep the look it had. */
.zo-card {
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 16px;
}
.zo-label {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--muted);
}
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
