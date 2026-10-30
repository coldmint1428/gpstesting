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
import { formatDayTime } from '../utils/time'
import { ROLE_LABEL, topRole, isMarshal, viewRole } from '../utils/permissions'

const auth = useAuthStore()
const router = useRouter()

const events = ref([]) // [{ id, name, roles: ['root', ...], isAdmin, isIC }]
const loading = ref(true)
const simName = ref('') // merger Stage 3: a name-only test event for virtual groups
const joinCode = ref('')
const errorMsg = ref('')

async function loadEvents() {
  loading.value = true
  try {
    events.value = await getMyEvents(auth.user.id)
    liveIds.value = await getLiveEventIds(events.value.map((e) => e.id)).catch(() => [])
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

// "NDP Rehearsal · Planner": my role in each event (a member who is marshal or IC shows as that)
function roleLabel(ev) {
  return ROLE_LABEL[viewRole({ role: topRole(ev), is_ic: ev.isIC, is_marshal: isMarshal(ev) })]
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
// ---------- Website: Ongoing / Upcoming / Past, with a search ----------
const tab = ref('')
const search = ref('')
const isPast = (e) => !!e.startsAt && new Date(e.startsAt).getTime() < Date.now() - 12 * 3600 * 1000
const tabLists = computed(() => {
  const live = events.value.filter((e) => liveIds.value.includes(e.id))
  const rest = events.value.filter((e) => !liveIds.value.includes(e.id))
  const byStart = (a, b) => new Date(a.startsAt || 8.64e15).getTime() - new Date(b.startsAt || 8.64e15).getTime()
  return {
    ongoing: live,
    upcoming: rest.filter((e) => !isPast(e)).sort(byStart),
    past: rest.filter(isPast).sort((a, b) => new Date(b.startsAt).getTime() - new Date(a.startsAt).getTime()),
  }
})
// The live event already has its own card above, so the list opens on Upcoming (then Ongoing, then Past)
const activeTab = computed(() => tab.value || (tabLists.value.upcoming.length ? 'upcoming' : tabLists.value.ongoing.length ? 'ongoing' : 'past'))
const shownEvents = computed(() => {
  const q = search.value.trim().toLowerCase()
  return tabLists.value[activeTab.value].filter((e) => !q || (e.name + ' ' + (e.venue || '')).toLowerCase().includes(q))
})
const WEB_TABS = [
  { key: 'ongoing', label: 'Ongoing' },
  { key: 'upcoming', label: 'Upcoming' },
  { key: 'past', label: 'Past' },
]
function roleClass(ev) {
  const label = roleLabel(ev)
  return label === 'Root' ? 'pl-role--root' : label === 'Planner' ? 'pl-role--planner' : label === 'Marshal' ? 'pl-role--marshal' : label === 'IC' ? 'pl-role--ic' : ''
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
      <span class="pv-chip pv-chip-live">LIVE</span>
      <strong class="pv-live-name">{{ ev.name }}</strong>
      <span class="pv-live-meta">{{ ev.venue || 'Live now' }} · {{ roleLabel(ev) }}</span>
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
        <span class="pv-chip" :class="ev.isSimulation ? 'pv-role-sim' : roleTone(roleLabel(ev))">
          {{ ev.isSimulation ? 'Sim' : roleLabel(ev) }}
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

  <!-- ===== Website: My events (Planova) ===== -->
  <main v-else class="pl-page">
    <div class="pl-page__head">
      <div>
        <h1 class="pl-h-page">{{ greeting }} {{ firstName }}</h1>
        <p class="pl-meta mb-0">Your role is set per event, so what you can do changes from event to event.</p>
      </div>
      <div class="pl-actions">
        <form class="d-flex gap-2" @submit.prevent="joinEvent">
          <input
            v-model="joinCode"
            class="form-control text-uppercase"
            style="width: 8.5rem"
            placeholder="Event code"
            maxlength="6"
            autocapitalize="characters"
            required
            aria-label="Event code"
            data-testid="join-code"
          />
          <button class="btn btn-outline-primary" type="submit" data-testid="join-btn">Join</button>
        </form>
        <RouterLink :to="{ name: 'event-new' }" class="btn btn-primary" data-testid="create-event-btn">Create event</RouterLink>
      </div>
    </div>

    <BenchAlert v-if="errorMsg" data-testid="events-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <!-- Live now: straight into the event -->
    <RouterLink
      v-for="ev in tabLists.ongoing.slice(0, 1)"
      :key="'live-' + ev.id"
      :to="{ name: 'event', params: { id: ev.id } }"
      class="pl-live"
      :data-testid="'live-' + ev.id"
    >
      <span class="pl-badge pl-badge--success"><span class="pl-badge__dot"></span>Live now</span>
      <span class="pl-live__text">
        <span class="pl-live__name d-block">{{ ev.name }}</span>
        <span class="pl-meta d-block">
          <template v-if="ev.startsAt">{{ formatDayTime(ev.startsAt) }}</template><template v-if="ev.startsAt && ev.venue"> · </template>{{ ev.venue }}
          · You are <strong>{{ roleLabel(ev) }}</strong>
        </span>
      </span>
      <span class="pl-live__cta">Open event</span>
    </RouterLink>

    <div class="pl-page__head">
      <div class="pl-tabs" role="tablist" aria-label="Event list">
        <button
          v-for="t in WEB_TABS"
          :key="t.key"
          type="button"
          class="pl-tab"
          role="tab"
          :aria-selected="activeTab === t.key"
          :data-testid="'events-tab-' + t.key"
          @click="tab = t.key"
        >
          {{ t.label }}<span v-if="tabLists[t.key].length" class="pl-count">{{ tabLists[t.key].length }}</span>
        </button>
      </div>
      <div class="pl-search">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 1 1 16 0" /></svg>
        <input v-model="search" class="form-control" type="search" placeholder="Search events" aria-label="Search events" />
      </div>
    </div>

    <p v-if="loading" class="pl-meta">Loading...</p>
    <div v-else-if="events.length === 0" class="pl-empty" data-testid="no-events">
      <strong>No events yet</strong>
      <span class="pl-meta">Join one with a code, or create your own.</span>
      <RouterLink :to="{ name: 'event-new' }" class="btn btn-primary mt-2">Create event</RouterLink>
    </div>
    <div v-else-if="shownEvents.length === 0" class="pl-empty">
      <strong>{{ search ? 'No events match your search' : 'Nothing here yet' }}</strong>
      <span class="pl-meta">{{ search ? 'Try a different name or venue.' : 'Events in this tab will show up here.' }}</span>
    </div>
    <ul v-else class="pl-list" data-testid="event-list">
      <li v-for="ev in shownEvents" :key="ev.id">
        <RouterLink :to="{ name: 'event', params: { id: ev.id } }" class="pl-row">
          <span class="pl-row__lead">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16v16H4V5m3-3v6m10-6v6M4 10h16" /></svg>
          </span>
          <span class="pl-row__body">
            <span class="pl-row__title">{{ ev.name }}</span>
            <span class="pl-row__meta" data-testid="event-list-when">
              <template v-if="ev.startsAt">{{ formatDayTime(ev.startsAt) }}</template><template v-if="ev.startsAt && ev.venue"> · </template>{{ ev.venue }}
              <template v-if="!ev.startsAt && !ev.venue">No date yet</template>
            </span>
          </span>
          <span class="pl-row__trail">
            <span v-if="ev.isSimulation" class="pl-badge pl-badge--warning">Simulation</span>
            <span class="pl-role" :class="roleClass(ev)" data-testid="event-list-role">{{ roleLabel(ev) }}</span>
            <svg class="pl-row__chev" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg>
          </span>
        </RouterLink>
      </li>
    </ul>

    <!-- A name-only test event for virtual groups (Stage 3) -->
    <details class="pl-meta">
      <summary>Create a simulation event (virtual groups for testing)</summary>
      <form class="mt-2 d-flex gap-2" style="max-width: 28rem" @submit.prevent="createSimulation">
        <label for="sim-name" class="visually-hidden">Simulation name</label>
        <input id="sim-name" v-model="simName" class="form-control" placeholder="Simulation name" maxlength="80" required data-testid="sim-event-name" />
        <button class="btn btn-outline-secondary" type="submit" data-testid="create-sim-btn">Create</button>
      </form>
    </details>
  </main>
</template>
