<script setup>
// OpsSummary - the groups at a glance during the live show (merger Stage 7, mock-up screen 5): how many groups are on
// track / at risk / late / without signal (each count is a filter), and search + category + sector + zone + "My
// groups". The filters apply to the problem queue and to the map. A marshal's view opens on their sector.
import { ref, computed } from 'vue'
import { STATUS } from '../utils/opsStatus'

const props = defineProps({
  ops: { type: Object, required: true }, // useOps()
})

const f = computed(() => props.ops.filters.value)
const c = computed(() => props.ops.counts.value)
const choices = computed(() => props.ops.choices.value)

const BUTTONS = ['on_track', 'at_risk', 'late', 'no_signal']
function toggle(status) {
  f.value.status = f.value.status === status ? '' : status
}
// Phone: the search and the four filters fold away behind one button (they would fill the screen above the map)
const filtersOpen = ref(false)
const activeFilters = computed(() => ['search', 'category', 'sector', 'zone', 'mine'].filter((k) => f.value[k]).length)
function clearAll() {
  Object.assign(f.value, { status: '', search: '', category: '', sector: '', zone: '', mine: false })
}
</script>

<template>
  <div class="ops-summary d-flex flex-wrap align-items-center gap-2 px-3 py-2 mb-2 rounded border" data-testid="ops-summary">
    <strong class="me-1" data-testid="ops-total">{{ c.total }} {{ c.total === 1 ? 'group' : 'groups' }}</strong>
    <button
      v-for="s in BUTTONS"
      :key="s"
      type="button"
      class="btn btn-sm ops-pill"
      :class="[STATUS[s].cls, { 'ops-pill-on': f.status === s }]"
      :aria-pressed="f.status === s"
      :data-testid="'ops-count-' + s"
      @click="toggle(s)"
    >
      {{ STATUS[s].symbol }} {{ c[s] }} {{ STATUS[s].label.toLowerCase() }}
    </button>
    <span v-if="c.done" class="small text-muted" data-testid="ops-count-done">✓ {{ c.done }} done</span>
    <button
      type="button"
      class="btn btn-sm d-sm-none ms-auto"
      :class="activeFilters ? 'btn-dark' : 'btn-outline-secondary'"
      :aria-expanded="filtersOpen"
      data-testid="ops-filters-toggle"
      @click="filtersOpen = !filtersOpen"
    >
      Filters{{ activeFilters ? ' (' + activeFilters + ')' : '' }} {{ filtersOpen ? '▴' : '▾' }}
    </button>

    <div class="flex-wrap align-items-center gap-2 ms-lg-auto" :class="filtersOpen ? 'd-flex' : 'd-none d-sm-flex'">
      <input
        v-model="f.search"
        type="search"
        class="form-control form-control-sm ops-search"
        placeholder="Search group or zone"
        aria-label="Search groups"
        data-testid="ops-search"
      />
      <select v-model="f.category" class="form-select form-select-sm w-auto" aria-label="Category" data-testid="ops-category">
        <option value="">All categories</option>
        <option v-for="x in choices.categories" :key="x" :value="x">{{ x }}</option>
      </select>
      <select v-model="f.sector" class="form-select form-select-sm w-auto" aria-label="Sector" data-testid="ops-sector">
        <option value="">All sectors</option>
        <option v-for="x in choices.sectors" :key="x" :value="x">{{ x }}{{ x === ops.mySector.value ? ' (mine)' : '' }}</option>
      </select>
      <select v-model="f.zone" class="form-select form-select-sm w-auto" aria-label="Zone" data-testid="ops-zone">
        <option value="">All zones</option>
        <option v-for="z in choices.zones" :key="z.id" :value="z.id">{{ z.code }}</option>
      </select>
      <button
        type="button"
        class="btn btn-sm"
        :class="f.mine ? 'btn-dark' : 'btn-outline-secondary'"
        :aria-pressed="f.mine"
        title="Problems you said you would handle"
        data-testid="ops-mine"
        @click="f.mine = !f.mine"
      >
        ★ My groups ({{ ops.myCount.value }})
      </button>
      <button v-if="ops.filtering.value" type="button" class="btn btn-sm btn-link px-1" data-testid="ops-clear" @click="clearAll">Clear</button>
    </div>
  </div>
</template>

<style scoped>
.ops-summary {
  background: var(--bs-body-bg);
}
.ops-search {
  width: 11rem;
}
.ops-pill {
  border-radius: 999px;
  font-weight: 600;
  border-width: 1px;
}
.ops-pill-on {
  outline: 2px solid var(--bs-emphasis-color);
  outline-offset: 1px;
}
</style>
