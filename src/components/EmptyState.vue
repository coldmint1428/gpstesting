<script setup>
// EmptyState - what a page shows when there is nothing in it yet, or when it could not load.
//
// One look everywhere: an icon tile, a short title, one line of help and, if useful, a button. Pages that people
// rarely see empty (a new event with no plan, an event that failed to open) get the same finish as the busy ones.
//
//   icon    plan | route | clock | map | play | people | search | alert
//   title   a few words ("No plans yet")
//   text    one short sentence (or the default slot, for a link inside it)
//   tone    'danger' for an error
//   compact less padding, for a panel inside a card
//   #actions  buttons under the text
defineProps({
  icon: { type: String, default: 'plan' },
  title: { type: String, required: true },
  text: { type: String, default: '' },
  tone: { type: String, default: '' },
  compact: { type: Boolean, default: false },
})

const PATHS = {
  plan: 'M4 5h16v14H4zM4 10h16M9 10v9',
  route: 'M6 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM18 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM8 17h7a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h7',
  clock: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2',
  map: 'M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2zM9 4v14M15 6v14',
  play: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM10 8.5v7l5.5-3.5z',
  people: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 6.5M18 14a6 6 0 0 1 3.5 6',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4',
  alert: 'M12 3 2 20h20L12 3zM12 10v4M12 17h.01',
}
</script>

<template>
  <div class="es" :class="{ 'is-danger': tone === 'danger', 'is-compact': compact }" :role="tone === 'danger' ? 'alert' : null">
    <span class="es-icon" aria-hidden="true">
      <svg viewBox="0 0 24 24"><path :d="PATHS[icon] || PATHS.plan" /></svg>
    </span>
    <h3 class="es-title">{{ title }}</h3>
    <p v-if="text || $slots.default" class="es-text"><slot>{{ text }}</slot></p>
    <div v-if="$slots.actions" class="es-actions"><slot name="actions" /></div>
  </div>
</template>

<style scoped>
.es {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  padding: 40px 20px;
  text-align: center;
}
.es.is-compact {
  padding: 24px 16px;
}
.es-icon {
  display: grid;
  place-items: center;
  width: 52px;
  height: 52px;
  margin-bottom: 4px;
  border-radius: var(--radius-md, 14px);
  background: var(--lime, #c6f36b);
  color: var(--ink, #0a1f17);
}
.is-compact .es-icon {
  width: 44px;
  height: 44px;
}
.is-danger .es-icon {
  background: var(--danger-bg, #ffe4d9);
  color: var(--danger-strong, #9a330a);
}
.es-icon svg {
  width: 24px;
  height: 24px;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.es-title {
  margin: 0;
  font: 700 19px/1.2 var(--font-display, inherit);
  letter-spacing: -0.03em;
  color: var(--ink, #0a1f17);
}
.is-compact .es-title {
  font-size: 16px;
}
.es-text {
  max-width: 44ch;
  margin: 0;
  font-size: 14px;
  line-height: 1.5;
  color: var(--muted, #56685f);
}
.es-text :deep(a) {
  color: var(--ink, #0a1f17);
  font-weight: 700;
}
.es-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 8px;
  margin-top: 8px;
}
</style>
