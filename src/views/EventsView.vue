<script setup>
// My events + create an event + join one with a code
import { ref, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'

const auth = useAuthStore()
const router = useRouter()

const events = ref([]) // [{ id, name, roles: ['root', ...] }]
const loading = ref(true)
const newName = ref('')
const joinCode = ref('')
const errorMsg = ref('')

async function loadEvents() {
  loading.value = true
  // My role rows, each with its event (RLS only returns events I belong to)
  const { data, error } = await supabase
    .from('event_roles')
    .select('role, events (id, name, created_at)')
    .eq('user_id', auth.user.id)
  loading.value = false
  if (error) {
    errorMsg.value = error.message
    return
  }

  // One entry per event, with all my roles in it
  const byId = {}
  for (const row of data) {
    const ev = row.events
    if (!byId[ev.id]) byId[ev.id] = { id: ev.id, name: ev.name, created_at: ev.created_at, roles: [] }
    byId[ev.id].roles.push(row.role)
  }
  events.value = Object.values(byId).sort((a, b) => b.created_at.localeCompare(a.created_at))
}

async function createEvent() {
  errorMsg.value = ''
  const { data: id, error } = await supabase.rpc('create_event', { p_name: newName.value })
  if (error) {
    errorMsg.value = error.message
    return
  }
  router.push({ name: 'event', params: { id } })
}

async function joinEvent() {
  errorMsg.value = ''
  const { data: id, error } = await supabase.rpc('join_event', { p_code: joinCode.value })
  if (error) {
    errorMsg.value = error.message
    return
  }
  router.push({ name: 'event', params: { id } })
}

onMounted(loadEvents)
</script>

<template>
  <main class="container py-3">
    <h1 class="h4 mb-3">My events</h1>

    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="events-error">{{ errorMsg }}</div>

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
        <form class="card h-100" @submit.prevent="createEvent">
          <div class="card-body">
            <h2 class="h6">Create an event</h2>
            <div class="input-group">
              <input
                v-model="newName"
                class="form-control"
                placeholder="e.g. NDP Rehearsal 1"
                maxlength="80"
                required
                aria-label="Event name"
                data-testid="new-event-name"
              />
              <button class="btn btn-success" type="submit" data-testid="create-event-btn">Create</button>
            </div>
            <div class="form-text">You become the event's Root.</div>
          </div>
        </form>
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
          <span v-for="r in ev.roles" :key="r" class="badge text-bg-secondary ms-1 text-capitalize">{{ r }}</span>
        </span>
      </RouterLink>
    </div>
  </main>
</template>
