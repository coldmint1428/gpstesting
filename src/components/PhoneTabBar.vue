<script setup>
// PhoneTabBar - the phone app's bottom navigation (Material 3 navigation bar, Figma "Tab bar / …" components).
// The tabs are given by the page: outside an event Events · Phone · Me (App.vue), inside one they follow the role
// (EventView: ICs and members: Now · Map · Group · Info; root / planners / marshals: Ops · Map · Timeline · People · More).
// A tab is either a page of the current screen (`key`, reported with `select`) or a route (`to`).
import { RouterLink } from 'vue-router'

defineProps({
  items: { type: Array, required: true }, // [{ key, label, icon, to?, dot? }]
  active: { type: String, default: '' },
})
const emit = defineEmits(['select'])

// Lucide-style outline icons, 24 px, drawn with currentColor
const ICONS = {
  events: ['M3 10h18', 'M16 2v4', 'M8 2v4', 'M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z'],
  phone: ['M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z', 'M11 18h2'],
  me: ['M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z', 'M4 21a8 8 0 0 1 16 0'],
  now: ['M3 11 22 2 13 21 11 13 3 11z'],
  map: ['M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3z', 'M9 3v15', 'M15 6v15'],
  group: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z', 'M22 21v-2a4 4 0 0 0-3-3.87', 'M16 3.13a4 4 0 0 1 0 7.75'],
  info: ['M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z', 'M12 16v-4', 'M12 8h.01'],
  ops: ['M22 12h-4l-3 9L9 3l-3 9H2'],
  timeline: ['M8 6h13', 'M8 12h13', 'M8 18h13', 'M3 6h.01', 'M3 12h.01', 'M3 18h.01'],
  more: ['M5 12h.01', 'M12 12h.01', 'M19 12h.01'],
}
</script>

<template>
  <nav class="pv-tabbar" aria-label="Main" data-testid="phone-tabbar">
    <template v-for="t in items" :key="t.key">
      <RouterLink v-if="t.to" :to="t.to" class="pv-tab" :aria-current="active === t.key ? 'page' : undefined" :data-testid="'ptab-' + t.key">
        <span class="pv-tab-pill">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path v-for="(d, i) in ICONS[t.icon]" :key="i" :d="d" />
          </svg>
          <span v-if="t.dot" class="pv-tab-dot" aria-hidden="true"></span>
        </span>
        <span>{{ t.label }}</span>
      </RouterLink>
      <button
        v-else
        type="button"
        class="pv-tab"
        :aria-current="active === t.key ? 'page' : undefined"
        :data-testid="'ptab-' + t.key"
        @click="emit('select', t.key)"
      >
        <span class="pv-tab-pill">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path v-for="(d, i) in ICONS[t.icon]" :key="i" :d="d" />
          </svg>
          <span v-if="t.dot" class="pv-tab-dot" aria-hidden="true"></span>
        </span>
        <span>{{ t.label }}</span>
      </button>
    </template>
  </nav>
</template>
