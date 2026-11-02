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
//            event  a whole event page in its real frame; `page` shapes the body like that page (EventView)
//            map    a map at `height`, then `rows` lines (route, zone editor)
//   rows     how many rows or lines to draw
//   dark     for a dark background (the Join card, the live map's panels)
defineProps({
  variant: { type: String, default: 'rows' },
  rows: { type: Number, default: 3 },
  label: { type: String, default: 'Loading…' },
  dark: { type: Boolean, default: false },
  page: { type: String, default: '' }, // event: which page is loading
  status: { type: Boolean, default: false }, // event: that page has the status bar on top
  height: { type: String, default: '60vh' }, // map: the map's height
})

// Lines of slightly different lengths look like text; equal ones look like a progress bar.
const widths = ['92%', '78%', '85%', '64%', '88%', '70%']
</script>

<template>
  <div class="skeleton-wrap" :class="['skw-' + variant, { 'skeleton-on-dark': dark }]" role="status" aria-live="polite">
    <span class="visually-hidden">{{ label }}</span>

    <template v-if="variant === 'event'">
      <!-- The event page's own frame: the side menu, the status bar, the title, then a body shaped like the page -->
      <div class="sk-event" aria-hidden="true">
        <div class="sk-event-nav">
          <span v-for="n in 8" :key="n" class="skeleton sk-nav-item"></span>
        </div>
        <div class="sk-event-main">
          <span v-if="status" class="skeleton sk-status"></span>
          <span class="skeleton sk-head"></span>
          <div v-if="page === 'overview'" class="sk-overview">
            <span class="skeleton sk-card is-tall"></span>
            <span class="skeleton sk-card"></span>
          </div>
          <div v-else-if="page === 'live'" class="sk-live">
            <span class="skeleton sk-map"></span>
            <span class="skeleton sk-side"></span>
          </div>
          <template v-else-if="page === 'map'">
            <div class="sk-chips"><span v-for="n in 3" :key="n" class="skeleton sk-chip"></span></div>
            <span class="skeleton sk-map is-bench"></span>
          </template>
          <span v-else-if="page === 'timeline'" class="skeleton sk-board-block"></span>
          <div v-else-if="page === 'groups'" class="sk-grid">
            <span v-for="n in 6" :key="n" class="skeleton sk-card is-group"></span>
          </div>
          <div v-else class="sk-list-card">
            <div v-for="n in rows + 2" :key="n" class="sk-row">
              <span class="skeleton sk-tile"></span>
              <span class="sk-row-text">
                <span class="skeleton skeleton-line" :style="{ width: widths[(n + 1) % widths.length] }"></span>
                <span class="skeleton skeleton-line" style="width: 45%"></span>
              </span>
              <span class="skeleton skeleton-pill" style="width: 64px"></span>
            </div>
          </div>
        </div>
      </div>
    </template>

    <template v-else-if="variant === 'map'">
      <!-- A map panel: the map at its own height, then a few rows under it -->
      <div class="sk-mapwrap" aria-hidden="true">
        <span class="skeleton sk-map" :style="{ height }"></span>
        <span v-for="n in rows" :key="n" class="skeleton skeleton-line" :style="{ width: widths[(n - 1) % widths.length] }"></span>
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
  display: grid;
  grid-template-columns: 248px minmax(0, 1fr);
  min-height: calc(100vh - 73px);
}
.sk-event-nav {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 20px 14px;
}
.sk-nav-item {
  height: 48px;
  border-radius: var(--radius-pill, 999px);
}
.sk-event-main {
  display: flex;
  flex-direction: column;
  gap: 16px;
  min-width: 0;
  max-width: 1320px;
  padding: 26px 32px 60px;
}
.sk-status {
  height: 56px;
  border-radius: 20px;
}
.sk-head {
  width: min(240px, 60%);
  height: 40px;
  border-radius: 12px;
}
.sk-card,
.sk-map,
.sk-side,
.sk-board-block,
.sk-list-card {
  border-radius: 22px;
}
.sk-overview {
  display: grid;
  grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr);
  gap: 16px;
  align-items: start;
}
.sk-card {
  height: 150px;
}
.sk-card.is-tall {
  height: 300px;
}
.sk-card.is-group {
  height: 132px;
}
.sk-live {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 380px;
  gap: 16px;
}
.sk-map {
  display: block;
  height: 600px;
}
.sk-map.is-bench {
  height: 70vh;
  min-height: 360px;
}
.sk-side {
  height: 600px;
}
.sk-chips {
  display: flex;
  gap: 8px;
}
.sk-chip {
  width: 132px;
  height: 40px;
  border-radius: var(--radius-pill, 999px);
}
.sk-board-block {
  height: 620px;
}
.sk-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 16px;
}
/* A list page: one white card holding the rows, like the page's own card */
.sk-list-card {
  padding: 8px 20px;
  background: var(--surface, #fff);
}
.sk-mapwrap {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.sk-mapwrap .sk-map {
  border-radius: var(--radius-lg, 18px);
}
/* On a phone the event's menu is the bar along the bottom, so the outline is the content alone, stacked */
@media (max-width: 767.98px) {
  .sk-event {
    grid-template-columns: minmax(0, 1fr);
  }
  .sk-event-nav {
    display: none;
  }
  .sk-event-main {
    padding: 16px 16px 96px;
  }
  .sk-overview,
  .sk-live {
    grid-template-columns: minmax(0, 1fr);
  }
  .sk-map {
    height: 60vh;
    min-height: 320px;
  }
  .sk-side {
    height: 160px;
  }
  .sk-board-block {
    height: 480px;
  }
}
</style>
