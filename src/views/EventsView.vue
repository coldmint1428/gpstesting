<script setup>
// My events + create an event + join one with a code
import { ref, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { getMyEvents, createQuickEvent, joinEventByCode } from '../services/eventService'
import BenchAlert from '../components/BenchAlert.vue'
import { eventRoleLabel } from '../utils/people'

const auth = useAuthStore()
const router = useRouter()

const events = ref([]) // [{ id, name, roles: ['root', ...] }]
const loading = ref(true)
const simName = ref('') // merger Stage 3: a name-only test event for virtual groups
const joinCode = ref('')
const errorMsg = ref('')

async function loadEvents() {
  loading.value = true
  try {
    events.value = await getMyEvents(auth.user.id)
  } catch (error) {
    errorMsg.value = error.message
  } finally {
    loading.value = false
  }
}

async function createSimulation() {
  errorMsg.value = ''
  try {
    const id = await createQuickEvent(simName.value, true)
    router.push({ name: 'event', params: { id } })
  } catch (error) {
    errorMsg.value = error.message
  }
}

async function joinEvent() {
  errorMsg.value = ''
  try {
    const id = await joinEventByCode(joinCode.value)
    router.push({ name: 'event', params: { id } })
  } catch (error) {
    errorMsg.value = error.message
  }
}

onMounted(loadEvents)
</script>

<template>
  <main class="container py-3">
    <h1 class="h4 mb-3">My events</h1>

    <BenchAlert v-if="errorMsg" data-testid="events-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <div class="row g-3 mb-4">
      <div class="col-12 col-md-6">
        <form class="card h-100" @submit.prevent="joinEvent">
          <div class="card-body">
            <h2 class="h6">Join with a code</h2>
            <div class="input-group">
              <input
                v-model="joinCode"
                class="form-control text-uppercase"
                placeholder="e.g. K7Q2XM"
                maxlength="6"
                autocapitalize="characters"
                required
                aria-label="Event code"
                data-testid="join-code"
              />
              <button class="btn btn-primary" type="submit" data-testid="join-btn">Join</button>
            </div>
          </div>
        </form>
      </div>
      <div class="col-12 col-md-6">
        <div class="card h-100">
          <div class="card-body">
            <h2 class="h6">Create an event</h2>
            <p class="small text-muted mb-2">Details, people, groups and roles, step by step. You become the event's Root.</p>
            <RouterLink :to="{ name: 'event-new' }" class="btn btn-success" data-testid="create-event-btn">Create an event</RouterLink>

            <form class="mt-3" @submit.prevent="createSimulation">
              <label for="sim-name" class="form-label small mb-1">Or a simulation event (virtual groups for testing, clearly labelled)</label>
              <div class="input-group input-group-sm">
                <input
                  id="sim-name"
                  v-model="simName"
                  class="form-control"
                  placeholder="Simulation name"
                  maxlength="80"
                  required
                  data-testid="sim-event-name"
                />
                <button class="btn btn-outline-secondary" type="submit" data-testid="create-sim-btn">Create</button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>

    <p v-if="loading" class="text-muted">Loading...</p>
    <p v-else-if="events.length === 0" class="text-muted" data-testid="no-events">
      You're not in any events yet. Join one with a code or create one.
    </p>
    <div v-else class="list-group" data-testid="event-list">
      <RouterLink
        v-for="ev in events"
        :key="ev.id"
        :to="{ name: 'event', params: { id: ev.id } }"
        class="list-group-item list-group-item-action d-flex justify-content-between align-items-center"
      >
        <span>{{ ev.name }}</span>
        <span>
          <span v-if="ev.isSimulation" class="badge text-bg-warning ms-1">SIMULATION</span>
          <span class="badge text-bg-secondary ms-1">{{ eventRoleLabel(ev.roles) }}</span>
        </span>
      </RouterLink>
    </div>
  </main>
</template>
