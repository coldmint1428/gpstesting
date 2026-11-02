<script setup>
// The 3D venue object (pure CSS, see kinetic.css): an illustration for the landing, login and next-up bands. Never live data.
defineProps({ labels: { type: Boolean, default: false } })

function sides(colour) {
  const steps = Array.from({ length: 10 }, (_, i) => `${i + 1}px ${i + 1}px 0 ${colour}`)
  return [...steps, '16px 16px 24px rgba(0,0,0,.18)'].join(', ')
}
const ZONES = [
  { label: 'F1 · Formation', left: 66, top: 14, width: 26, height: 26, background: 'rgba(198,243,107,.22)', side: '#3f6a1f' },
  { label: 'H2 · Holding', left: 24, top: 44, width: 22, height: 22, background: 'rgba(198,243,107,.22)', side: '#3f6a1f' },
  { label: 'Stage', left: 8, top: 10, width: 30, height: 16, background: '#c6f36b', side: '#7aa82e' },
  { label: 'No-go', left: 74, top: 58, width: 20, height: 18, background: 'rgba(255,138,101,.4)', side: '#a4513a' },
]
const zoneStyle = (z) => ({ left: z.left + '%', top: z.top + '%', width: z.width + '%', height: z.height + '%', background: z.background, boxShadow: sides(z.side) })
const PINS = [
  { code: 'BS', left: 63, top: 30, colour: '#7dd3fc' },
  { code: 'GC', left: 37, top: 54, colour: '#c6f36b' },
  { code: 'SD', left: 25, top: 66, colour: '#9be7c4' },
  { code: 'MD', left: 82, top: 80, colour: '#ff8a65' },
]
</script>

<template>
  <div class="kl-glow"></div>
  <div class="klm-scene">
    <div class="klm-plane">
      <div class="klm-road" style="left: 0; top: 31%; width: 100%; height: 12px"></div>
      <div class="klm-road" style="left: 0; top: 70%; width: 100%; height: 10px"></div>
      <div class="klm-road" style="left: 50%; top: 0; width: 12px; height: 74%"></div>
      <div class="klm-road" style="left: 14%; top: 0; width: 9px; height: 74%"></div>
      <div class="klm-water"></div>
      <div v-for="z in ZONES" :key="z.label" class="klm-zone" :style="zoneStyle(z)">
        <span v-if="labels" class="klm-zl">{{ z.label }}</span>
      </div>
      <svg class="klm-route" viewBox="0 0 100 100" preserveAspectRatio="none">
        <path d="M28 68 C 34 56, 40 52, 47 48 S 62 38, 74 28" fill="none" stroke="#c6f36b" stroke-width="1.1" stroke-dasharray="1.6 1.6" stroke-linecap="round" vector-effect="non-scaling-stroke" style="stroke-width: 5px; filter: drop-shadow(0 0 6px #c6f36b)" />
        <path d="M8 30 C 30 32, 52 30, 68 34 S 80 38, 86 36" fill="none" stroke="#9be7c4" stroke-width="1" stroke-dasharray="0.4 2" stroke-linecap="round" vector-effect="non-scaling-stroke" style="stroke-width: 7px; opacity: 0.75" />
      </svg>
      <div v-for="p in PINS" :key="p.code" class="klm-pin" :style="{ left: p.left + '%', top: p.top + '%' }">
        <div class="klm-pinb">
          <span class="klm-head" :style="{ background: p.colour }">{{ p.code }}</span>
          <span class="klm-stem"></span>
        </div>
        <span class="klm-shadow"></span>
      </div>
    </div>
  </div>
</template>
