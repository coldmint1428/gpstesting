<script setup>
// My events + create an event + join one with a code
import { ref, computed, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { getMyEvents, createQuickEvent, joinEventByCode, getLiveEventIds } from '../services/eventService'
import BenchAlert from '../components/BenchAlert.vue'
import BottomSheet from '../components/BottomSheet.vue'
import { isNativeApp } from '../lib/platform'
import { useLocationTracker } from '../composables/useLocationTracker'
import { eventRoleLabel } from '../utils/people'
import { formatDayTime } from '../utils/time'

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
    if (native) liveIds.value = await getLiveEventIds(events.value.map((e) => e.id))
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

// ---------- Phone app (Figma screens 2 and 3): live events first, then the rest; Join is a sheet ----------
const native = isNativeApp
const tracker = useLocationTracker()
const liveIds = ref([])
const liveEvents = computed(() => events.value.filter((e) => liveIds.value.includes(e.id)))
// Soonest upcoming first, then past events (latest first), then the ones without a date
const otherEvents = computed(() => {
  const now = Date.now()
  const rank = (e) => (!e.startsAt ? 2 : new Date(e.startsAt).getTime() >= now - 12 * 3600 * 1000 ? 0 : 1)
  return events.value
    .filter((e) => !liveIds.value.includes(e.id))
    .sort((a, b) => {
      const ra = rank(a), rb = rank(b)
      if (ra !== rb) return ra - rb
      if (ra === 2) return 0
      const ta = new Date(a.startsAt).getTime(), tb = new Date(b.startsAt).getTime()
      return ra === 0 ? ta - tb : tb - ta
    })
})
const joinOpen = ref(false)
const firstName = computed(() => {
  const p = auth.profile
  return p ? String(p.display_name || p.username || '').split(/\s+/)[0] : ''
})
const initials = computed(() => {
  const p = auth.profile
  const n = p ? String(p.display_name || p.username || '') : ''
  return n.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('')
})
const greeting = computed(() => {
  const h = Number(new Date().toLocaleString('en-SG', { hour: 'numeric', hour12: false, timeZone: 'Asia/Singapore' }))
  return h < 12 ? 'Good morning,' : h < 18 ? 'Good afternoon,' : 'Good evening,'
})
// The date block on each row: day and month in Singapore time, or a dash for an event with no planned start
function dayOf(iso) {
  return iso ? new Date(iso).toLocaleDateString('en-SG', { day: 'numeric', timeZone: 'Asia/Singapore' }) : '–'
}
function monthOf(iso) {
  return iso ? new Date(iso).toLocaleDateString('en-SG', { month: 'short', timeZone: 'Asia/Singapore' }) : ''
}
function timeOf(iso) {
  return iso ? new Date(iso).toLocaleTimeString('en-SG', { hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Singapore' }) : ''
}
const ROLE_TONE = { Root: 'pv-role-root', Planner: 'pv-role-planner', Marshal: 'pv-role-marshal' }
function roleTone(label) {
  return ROLE_TONE[label] || 'pv-role-member'
}
</script>

<template>
  <!-- ===== Phone app: My events (Figma screen 2) ===== -->
  <main v-if="native" class="pv-events pv-has-tabs" data-testid="phone-events">
    <header class="pv-events-head">
      <div class="min-w-0">
        <p class="pv-hello">{{ greeting }}</p>
        <h1 class="pv-name">{{ firstName }}</h1>
      </div>
      <RouterLink :to="{ name: 'me' }" class="pv-avatar" aria-label="Me">{{ initials }}</RouterLink>
    </header>

    <BenchAlert v-if="errorMsg" data-testid="events-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <!-- Live now: straight into the live view -->
    <RouterLink
      v-for="ev in liveEvents"
      :key="'live-' + ev.id"
      :to="{ name: 'event', params: { id: ev.id } }"
      class="pv-live"
      :data-testid="'live-' + ev.id"
    >
      <span class="pv-chip pv-chip-live">● LIVE</span>
      <strong class="pv-live-name">{{ ev.name }}</strong>
      <span class="pv-live-meta">{{ ev.venue || 'Live now' }} · {{ eventRoleLabel(ev.roles) }}</span>
      <span v-if="tracker.isTracking.value && tracker.sharingEventId.value === ev.id" class="pv-live-share">
        <span class="pv-live-dot" aria-hidden="true"></span> Sharing your location · every 10 s
      </span>
      <span class="pv-live-open">Open live view</span>
    </RouterLink>

    <p v-if="loading" class="text-muted px-1">Loading…</p>
    <div v-else-if="events.length === 0" class="pv-empty" data-testid="no-events">
      <strong>No events yet</strong>
      <span>Join one with the code your planner sent, or create your own.</span>
    </div>
    <template v-else-if="otherEvents.length">
      <h2 class="pv-label px-1 mb-0">{{ liveEvents.length ? 'Your other events' : 'Your events' }}</h2>
      <RouterLink
        v-for="ev in otherEvents"
        :key="ev.id"
        :to="{ name: 'event', params: { id: ev.id } }"
        class="pv-row"
        data-testid="event-row"
      >
        <span class="pv-date" aria-hidden="true">
          <span class="pv-date-d">{{ dayOf(ev.startsAt) }}</span>
          <span class="pv-date-m">{{ monthOf(ev.startsAt) }}</span>
        </span>
        <span class="pv-row-text">
          <strong>{{ ev.name }}</strong>
          <span>
            <template v-if="ev.venue">{{ ev.venue }}</template><template v-if="ev.venue && ev.startsAt"> · </template><template v-if="ev.startsAt">{{ timeOf(ev.startsAt) }}</template>
            <template v-if="!ev.venue && !ev.startsAt">No date yet</template>
          </span>
        </span>
        <span class="pv-chip" :class="ev.isSimulation ? 'pv-role-sim' : roleTone(eventRoleLabel(ev.roles))">
          {{ ev.isSimulation ? 'Sim' : eventRoleLabel(ev.roles) }}
        </span>
      </RouterLink>
    </template>

    <button type="button" class="pv-fab" data-testid="join-fab" @click="joinOpen = true">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
      Join event
    </button>

    <!-- Join sheet (Figma screen 3) -->
    <BottomSheet :open="joinOpen" title="Join an event" @close="joinOpen = false">
      <form class="d-grid gap-3" @submit.prevent="joinEvent">
        <p class="text-muted mb-0">Type the 6-character code your planner sent you.</p>
        <input
          v-model="joinCode"
          class="form-control pv-code"
          placeholder="K7Q2XM"
          maxlength="6"
          autocapitalize="characters"
          autocomplete="off"
          spellcheck="false"
          required
          aria-label="Event code"
          data-testid="join-code"
        />
        <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>
        <button class="btn btn-primary btn-lg" type="submit" data-testid="join-btn">Join</button>
        <p class="small text-muted text-center mb-0">Invite links from WhatsApp or Telegram open the event straight away.</p>
        <div class="pv-or"><span>or</span></div>
        <RouterLink :to="{ name: 'event-new' }" class="btn btn-outline-secondary btn-lg" data-testid="create-event-btn">Create an event</RouterLink>
      </form>
    </BottomSheet>
  </main>

  <main v-else class="container py-3">
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
        <span>
          {{ ev.name }}
          <span v-if="ev.startsAt || ev.venue" class="d-block small text-muted" data-testid="event-list-when">
            <template v-if="ev.startsAt">{{ formatDayTime(ev.startsAt) }}</template><template v-if="ev.startsAt && ev.venue"> · </template>{{ ev.venue }}
          </span>
        </span>
        <span>
          <span v-if="ev.isSimulation" class="badge text-bg-warning ms-1">SIMULATION</span>
          <span class="badge text-bg-secondary ms-1">{{ eventRoleLabel(ev.roles) }}</span>
        </span>
      </RouterLink>
    </div>
  </main>
</template>
