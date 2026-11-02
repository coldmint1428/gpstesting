<script setup>
// The Planova map-pin mark: forest pin with a lime face on light grounds, lime pin with a forest face on forest.
defineProps({ onForest: { type: Boolean, default: false } })
</script>

<template>
  <svg viewBox="0 0 32 32" width="30" height="30" aria-hidden="true">
    <path d="M16 2.5c-5.8 0-10.5 4.6-10.5 10.3 0 7.4 8.6 15.2 9.6 16.1.5.4 1.3.4 1.8 0 1-.9 9.6-8.7 9.6-16.1C26.5 7.1 21.8 2.5 16 2.5Z" :fill="onForest ? '#c6f36b' : '#0b3d2e'" />
    <path d="M11 15.5c2.2-3.6 7.6-3.6 10 0" :stroke="onForest ? '#0b3d2e' : '#c6f36b'" stroke-width="2.4" fill="none" stroke-linecap="round" />
    <circle cx="16" cy="11.2" r="2.4" :fill="onForest ? '#0b3d2e' : '#c6f36b'" />
  </svg>
</template>
