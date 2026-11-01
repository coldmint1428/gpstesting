<script setup>
// SkeletonLoader - the grey outline of content that is still on its way from the database.
//
// Instead of a line of "Loading…" text, the page shows soft grey blocks in roughly the shape of what is coming,
// with a light band sweeping across them (motion.css, "Skeletons"). It fades in after a short pause, so an answer
// that arrives quickly never flashes grey boxes. Screen readers hear `label` once.
//
//   variant  rows   a list: a square, two lines of text, a pill on the right (event lists, recordings)
//            lines  a few lines of text of different widths (notes, small panels)
//            board  a plan board: a toolbar, then rows (Timeline, Route, Schedule, Ops)
//            event  a whole event page: the side menu, a heading, cards (EventView while the event loads)
//   rows     how many rows or lines to draw
//   dark     for a dark background (the Join card, the live map's panels)
defineProps({
  variant: { type: String, default: 'rows' },
  rows: { type: Number, default: 3 },
  label: { type: String, default: 'Loading…' },
  dark: { type: Boolean, default: false },
})

// Lines of slightly different lengths look like text; equal ones look like a progress bar.
const widths = ['92%', '78%', '85%', '64%', '88%', '70%']
</script>

<template>
  <div class="skeleton-wrap" :class="['sk-' + variant, { 'skeleton-on-dark': dark }]" role="status" aria-live="polite">
    <span class="visually-hidden">{{ label }}</span>

    <template v-if="variant === 'event'">
      <div class="sk-event" aria-hidden="true">
        <div class="sk-event-nav">
          <span class="skeleton skeleton-line is-title" style="width: 70%"></span>
          <span v-for="n in 6" :key="n" class="skeleton sk-nav-item"></span>
        </div>
        <div class="sk-event-main">
          <span class="skeleton skeleton-line is-title" style="width: 40%"></span>
          <span class="skeleton skeleton-line" style="width: 60%"></span>
          <div class="sk-cards">
            <span v-for="n in 3" :key="n" class="skeleton sk-card"></span>
          </div>
          <span class="skeleton sk-panel"></span>
        </div>
      </div>
    </template>

    <template v-else-if="variant === 'board'">
      <div class="sk-board" aria-hidden="true">
        <div class="sk-toolbar">
          <span class="skeleton sk-field"></span>
          <span class="skeleton sk-btn"></span>
          <span class="skeleton sk-btn"></span>
        </div>
        <div v-for="n in rows" :key="n" class="sk-board-row">
          <span class="skeleton skeleton-line" style="width: 64px"></span>
          <span class="skeleton sk-bar" :style="{ width: widths[n % widths.length] }"></span>
        </div>
      </div>
    </template>

    <template v-else-if="variant === 'lines'">
      <div class="sk-lines" aria-hidden="true">
        <span v-for="n in rows" :key="n" class="skeleton skeleton-line" :style="{ width: widths[(n - 1) % widths.length] }"></span>
      </div>
    </template>

    <template v-else>
      <div class="sk-rows" aria-hidden="true">
        <div v-for="n in rows" :key="n" class="sk-row">
          <span class="skeleton sk-tile"></span>
          <span class="sk-row-text">
            <span class="skeleton skeleton-line" :style="{ width: widths[(n + 1) % widths.length] }"></span>
            <span class="skeleton skeleton-line" style="width: 45%"></span>
          </span>
          <span class="skeleton skeleton-pill" style="width: 64px"></span>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.sk-rows,
.sk-lines,
.sk-board {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.sk-lines {
  gap: 8px;
  padding: 4px 0;
}
.sk-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 0;
}
.sk-row + .sk-row {
  border-top: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.06));
}
.sk-tile {
  flex: none;
  width: 40px;
  height: 40px;
  border-radius: var(--radius-md, 8px);
}
.sk-row-text {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 7px;
}

.sk-toolbar {
  display: flex;
  gap: 8px;
  align-items: center;
  padding-bottom: 6px;
}
.sk-field {
  width: min(320px, 50%);
  height: 32px;
}
.sk-btn {
  width: 88px;
  height: 32px;
}
.sk-board-row {
  display: flex;
  align-items: center;
  gap: 12px;
}
.sk-bar {
  height: 28px;
}

.sk-event {
  display: flex;
  gap: 24px;
  padding: 16px;
  max-width: 1320px;
  margin: 0 auto;
}
.sk-event-nav {
  flex: none;
  width: 200px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.sk-nav-item {
  height: 34px;
}
.sk-event-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.sk-cards {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
  margin-top: 8px;
}
.sk-card {
  height: 96px;
  border-radius: var(--radius-lg, 12px);
}
.sk-panel {
  height: 260px;
  border-radius: var(--radius-lg, 12px);
}
/* On a phone the event's menu is a row of tabs along the bottom, so the outline is the content alone. */
@media (max-width: 767.98px) {
  .sk-event-nav {
    display: none;
  }
  .sk-cards {
    grid-template-columns: 1fr 1fr;
  }
  .sk-cards .sk-card:nth-child(3) {
    display: none;
  }
}
</style>
