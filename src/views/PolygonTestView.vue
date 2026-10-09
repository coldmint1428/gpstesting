<script setup>
// The planner drawing bench at /polygon.
//
// A standalone showcase: it is NOT tied to an event, and it touches none of the tables the
// event pages use. There is ONE bench, shared by everyone who signs in, and only one person
// may edit it at a time -- see composables/useBenchClaim.js for how that is arbitrated.
//
// This page owns the data and the saving. AreaBench only draws it and reports what the
// planner did, so there is exactly one place that writes.
//
// EVERY LOCK IS A SAVE. `mode` going back to null is the only save trigger there is, which
// is why there is no Save button anywhere on this page.
import { ref, computed, watch, nextTick, onMounted } from 'vue'
import { useBenchClaim } from '../composables/useBenchClaim'
import AreaBench from '../components/AreaBench.vue'
import AreaList from '../components/AreaList.vue'

const {
  data: layout,
  loading,
  errorMsg,
  save,
  saving,
  open,
  startEditing,
  stopEditing,
  editing,
  claiming,
  lostClaim,
  heldBy,
  claimExpiresAt,
} = useBenchClaim()

// null | 'map' | 'floorplan:<id>' | 'polygons' -- exactly one thing is unlocked at a time.
const mode = ref(null)

const plans = computed(() => layout.value.floorPlans)
const areas = computed(() => layout.value.polygons)

function formatClock(date) {
  if (!date) return ''
  return new Date(date).toLocaleTimeString('en-SG', { hour: 'numeric', minute: '2-digit' })
}

const heldByText = computed(() => {
  if (!heldBy.value) return ''
  const until = formatClock(claimExpiresAt.value)
  return until
    ? heldBy.value + ' is editing this bench (until ' + until + ')'
    : heldBy.value + ' is editing this bench'
})

// A plain, serialisable copy for the database. JSON round-trip also strips Vue's reactive
// proxies, which keeps supabase-js from serialising anything unexpected.
function buildPayload() {
  return JSON.parse(JSON.stringify(layout.value))
}

async function saveNow() {
  await save(buildPayload())
}

// The one and only save trigger: leaving an editing mode.
watch(mode, async (value, oldValue) => {
  if (oldValue !== null && value === null) await saveNow()
})

// If the claim goes away (taken over, or released), nothing may stay unlocked.
watch(editing, (isEditing) => {
  if (!isEditing) mode.value = null
})

// ---------- What AreaBench reports ----------
function addPlan(plan) {
  layout.value.floorPlans = [...layout.value.floorPlans, plan]
}

function updatePlan({ id, patch }) {
  layout.value.floorPlans = layout.value.floorPlans.map((p) => (p.id === id ? { ...p, ...patch } : p))
}

function deletePlan(id) {
  layout.value.floorPlans = layout.value.floorPlans.filter((p) => p.id !== id)
}

function addArea(area) {
  layout.value.polygons = [...layout.value.polygons, area]
}

function updateArea({ id, patch }) {
  layout.value.polygons = layout.value.polygons.map((a) => (a.id === id ? { ...a, ...patch } : a))
}

function deleteArea(id) {
  layout.value.polygons = layout.value.polygons.filter((a) => a.id !== id)
}

function setView(view) {
  layout.value.view = view
}

// The id of the area being worked on, for highlighting its row in the list. Empty when the
// bench is not in an area mode.
const selectedAreaId = computed(() => {
  const value = mode.value
  return typeof value === 'string' && value.startsWith('area:') ? value.slice('area:'.length) : ''
})

// Clicking an area -- on the map or in the list -- selects it. Clicking it again puts it
// back down, which is a lock, which is the save.
function selectArea(id) {
  mode.value = mode.value === 'area:' + id ? null : 'area:' + id
}

// ---------- Claiming ----------
async function beginEditing() {
  // Already asking, or already mine: pressing again must not start a second claim.
  if (claiming.value || editing.value) return
  const granted = await startEditing()
  if (granted) mode.value = null // editing starts with the map locked
}

async function endEditing() {
  mode.value = null // putting it down is the save, and the watcher above does it
  await nextTick() // ...on the next tick, so wait for it to be queued
  // Releasing is queued behind that save, so the save still has a claim to present.
  await stopEditing()
}

onMounted(open)
</script>

<template>
  <main class="container py-3">
    <div class="d-flex flex-wrap align-items-start justify-content-between gap-2 mb-2">
      <div>
        <h1 class="h4 mb-1">Polygon bench</h1>
      </div>

      <div class="d-flex flex-wrap align-items-center gap-2">
        <span v-if="saving" class="badge text-bg-light" data-testid="saving-badge">Saving...</span>

        <button
          v-if="editing"
          class="btn btn-outline-danger"
          :disabled="saving"
          data-testid="stop-editing"
          @click="endEditing"
        >
          Stop editing
        </button>
        <button
          v-else
          class="btn btn-success"
          :disabled="claiming || saving || !!heldBy || loading"
          data-testid="start-editing"
          @click="beginEditing"
        >
          {{ claiming ? 'Asking...' : 'Start editing' }}
        </button>
      </div>
    </div>

    <div v-if="!editing && heldBy" class="alert alert-warning py-2" role="status" data-testid="held-by">
      {{ heldByText }}. You can look around, but not change anything.
    </div>

    <div v-if="lostClaim" class="alert alert-danger py-2" role="alert" data-testid="lost-claim">
      <strong>Your editing claim expired.</strong> Someone else took the bench over, so your last
      changes were not saved. Reload the page to see their version.
    </div>

    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="page-error">
      {{ errorMsg }}
    </div>

    <p v-if="loading" class="text-muted">Loading the bench...</p>

    <AreaBench
      v-else
      v-model:mode="mode"
      :plans="plans"
      :areas="areas"
      :view="layout.view"
      :can-edit="editing"
      @plan-added="addPlan"
      @plan-updated="updatePlan"
      @plan-deleted="deletePlan"
      @area-added="addArea"
      @area-updated="updateArea"
      @view-changed="setView"
    >
      <AreaList
        :areas="areas"
        :editable="editing"
        :selected="selectedAreaId"
        @area-updated="updateArea"
        @area-deleted="deleteArea"
        @area-edit="selectArea"
      />
    </AreaBench>
  </main>
</template>
