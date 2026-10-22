<script setup>
// Wizard step 2: find people by name (their email tells apart two with the same name), add them, choose their role
import { ref, watch, onUnmounted } from 'vue'
import { useEventWizardStore, ROLE_OPTIONS } from '../../stores/eventWizard'
import { searchPeople } from '../../services/eventService'

const wizard = useEventWizardStore()

const term = ref('')
const results = ref([])
const searching = ref(false)
const searchError = ref('')
let timer = null
let latest = 0 // only the newest search may show its results (older ones can arrive later)

// Search 300 ms after the last key press
watch(term, (value) => {
  clearTimeout(timer)
  searchError.value = ''
  if (value.trim().length < 2) {
    results.value = []
    searching.value = false
    return
  }
  searching.value = true
  timer = setTimeout(() => runSearch(value), 300)
})

async function runSearch(value) {
  const mine = ++latest
  try {
    const found = await searchPeople(value)
    if (mine === latest) results.value = found
  } catch (error) {
    if (mine === latest) searchError.value = error.message
  } finally {
    if (mine === latest) searching.value = false
  }
}

onUnmounted(() => clearTimeout(timer))

const isAdded = (id) => wizard.people.some((p) => p.id === id)
</script>

<template>
  <section>
    <h2 class="h5 mb-1">Add people</h2>
    <p class="text-muted small mb-3">You are the event's Root automatically. People can also join later with the event's code.</p>

    <label for="people-search" class="form-label">Find by name</label>
    <input
      id="people-search"
      v-model="term"
      type="search"
      class="form-control"
      placeholder="e.g. Komin Tan"
      autocomplete="off"
      data-testid="wiz-search"
    />
    <div class="form-text">Type at least 2 characters of their name.</div>

    <p v-if="searchError" class="text-danger small mt-2">{{ searchError }}</p>
    <p v-else-if="searching" class="text-muted small mt-2">Searching...</p>
    <p v-else-if="term.trim().length >= 2 && results.length === 0" class="text-muted small mt-2">No one found.</p>

    <ul v-if="results.length" class="list-group mt-2" data-testid="wiz-results">
      <li v-for="p in results" :key="p.id" class="list-group-item d-flex justify-content-between align-items-center gap-2">
        <span class="text-truncate">
          {{ p.display_name }} <span v-if="p.email" class="text-muted small">{{ p.email }}</span>
        </span>
        <button
          type="button"
          class="btn btn-sm flex-shrink-0"
          :class="isAdded(p.id) ? 'btn-outline-secondary' : 'btn-primary'"
          :disabled="isAdded(p.id)"
          @click="wizard.addPerson(p)"
        >
          {{ isAdded(p.id) ? 'Added' : 'Add' }}
        </button>
      </li>
    </ul>

    <h3 class="h6 mt-4">Added ({{ wizard.people.length }})</h3>
    <p v-if="wizard.people.length === 0" class="text-muted small">No one yet.</p>
    <ul v-else class="list-group" data-testid="wiz-people">
      <li v-for="p in wizard.people" :key="p.id" class="list-group-item">
        <div class="d-flex flex-wrap align-items-center gap-2">
          <span class="me-auto text-truncate">
            {{ p.display_name }} <span v-if="p.email" class="text-muted small">{{ p.email }}</span>
          </span>
          <label class="visually-hidden" :for="'role-' + p.id">Role for {{ p.display_name }}</label>
          <select :id="'role-' + p.id" v-model="p.role" class="form-select form-select-sm w-auto">
            <option v-for="r in ROLE_OPTIONS" :key="r.value" :value="r.value">{{ r.label }}</option>
          </select>
          <button type="button" class="btn btn-sm btn-outline-danger" @click="wizard.removePerson(p.id)">Remove</button>
        </div>
      </li>
    </ul>
    <p class="form-text">
      Planners set up the map and timings. Marshals see every group on the live map.
      Group Admin and IC are chosen in the next step.
    </p>
  </section>
</template>
