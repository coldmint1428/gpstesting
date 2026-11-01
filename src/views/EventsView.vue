<script setup>
// My events + create an event + join one with a code
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { getMyEvents, createQuickEvent, joinEventByCode, getLiveEventIds } from '../services/eventService'
import BenchAlert from '../components/BenchAlert.vue'
import BottomSheet from '../components/BottomSheet.vue'
import { isNativeApp } from '../lib/platform'
import { useLocationTracker } from '../composables/useLocationTracker'
import { formatDayTime } from '../utils/time'
import { ROLE_LABEL, topRole, isMarshal, viewRole } from '../utils/permissions'
import SkeletonLoader from '../components/SkeletonLoader.vue'
import ExpandTransition from '../components/ExpandTransition.vue'
import KVenueMap from '../components/kinetic/KVenueMap.vue'
import { cachedMyEvents, saveMyEvents } from '../lib/myEventsCache'

const auth = useAuthStore()
const router = useRouter()

// Opens with the list from the last visit (myEventsCache) and reads a fresh one quietly; the skeleton is only for the
// first load.
const cached = cachedMyEvents(auth.user && auth.user.id)
const events = ref(cached ? cached.events : []) // [{ id, name, roles: ['root', ...], isAdmin, isIC }]
const loading = ref(!cached)
const simName = ref('') // merger Stage 3: a name-only test event for virtual groups
const joinCode = ref('')
// A pasted code keeps working with spaces or dashes in it ("9Z8-GGZ"): no maxlength, the six are counted after cleaning
function onJoinInput(event) {
  joinCode.value = (event.target.value || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6)
  event.target.value = joinCode.value
}
const errorMsg = ref('')

async function loadEvents() {
  if (!cached) loading.value = true
  try {
    // Both answers first, then the page: the events alone would draw the list while the skeleton is still up, and the
    // list would then jump when the skeleton went away a moment later.
    const mine = await getMyEvents(auth.user.id)
    const live = await getLiveEventIds(mine.map((e) => e.id)).catch(() => [])
    events.value = mine
    liveIds.value = live
    saveMyEvents(auth.user.id, mine, live)
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
const liveIds = ref(cached ? cached.liveIds : [])
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
// Switching tabs: the list slides out the way the tabs moved (Past is to the right of Upcoming, so its list comes in
// from the right).
const tabDir = ref('right')
function pickTab(key) {
  const order = WEB_TABS.map((t) => t.key)
  tabDir.value = order.indexOf(key) >= order.indexOf(activeTab.value) ? 'right' : 'left'
  tab.value = key
}
// The next-up band: the live event, otherwise the soonest one with a date
const nextEvent = computed(() => tabLists.value.ongoing[0] || tabLists.value.upcoming.find((ev) => ev.startsAt) || null)
const nextIsLive = computed(() => !!tabLists.value.ongoing[0])
// Counts down in whole minutes, so once every 30 seconds is plenty; the digits just change
const nowTick = ref(Date.now())
const tickTimer = setInterval(() => (nowTick.value = Date.now()), 30000)
onBeforeUnmount(() => clearInterval(tickTimer))
const countdown = computed(() => {
  const left = nextEvent.value && nextEvent.value.startsAt ? Math.max(0, Math.floor((new Date(nextEvent.value.startsAt).getTime() - nowTick.value) / 60000)) : 0
  const two = (n) => String(n).padStart(2, '0')
  return { d: two(Math.floor(left / 1440)), h: two(Math.floor((left % 1440) / 60)), m: two(left % 60) }
})
const today = computed(() => {
  const at = new Date(nowTick.value)
  const SG = { timeZone: 'Asia/Singapore' }
  const date = at.toLocaleDateString('en-SG', { weekday: 'short', day: 'numeric', month: 'short', ...SG }).replace(',', '')
  const time = at.toLocaleTimeString('en-SG', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', ...SG })
  return date + ' · ' + time
})
// "Join with code": a popover that closes when you click away
const joinPop = ref(false)
const joinWrap = ref(null)
function closeJoinPop(event) {
  if (joinPop.value && joinWrap.value && !joinWrap.value.contains(event.target)) joinPop.value = false
}
onMounted(() => document.addEventListener('pointerdown', closeJoinPop))
onBeforeUnmount(() => document.removeEventListener('pointerdown', closeJoinPop))

// "Create a simulation event": opens and closes with the shared unfold (ExpandTransition)
const simOpen = ref(false)

// The role pills: Root ink, Planner mint, In-Charge peach, anyone else soft
function roleChip(ev) {
  const label = roleLabel(ev)
  return label === 'Root' ? 'rl-root' : label === 'Planner' ? 'rl-planner' : label === 'IC' || label === 'In-Charge' ? 'rl-ic' : 'chip-soft'
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
      v-for="ev in liveEvents.slice(0, 1)"
      :key="'live-' + ev.id"
      :to="{ name: 'event', params: { id: ev.id } }"
      class="pv-live data-in"
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

    <!-- More than one live at once: the first keeps the big card, the rest are compact rows (one loud thing per screen) -->
    <section v-if="liveEvents.length > 1" class="pv-also-live data-in" aria-label="Also live" data-testid="also-live">
      <h2 class="pv-also-title">Also live · {{ liveEvents.length - 1 }}</h2>
      <RouterLink
        v-for="ev in liveEvents.slice(1)"
        :key="'also-' + ev.id"
        :to="{ name: 'event', params: { id: ev.id } }"
        class="pv-also-row"
        :data-testid="'live-' + ev.id"
      >
        <span class="pv-chip pv-chip-live">LIVE</span>
        <span class="pv-also-text">
          <strong>{{ ev.name }}</strong>
          <span>{{ ev.venue || 'Live now' }} · {{ roleLabel(ev) }}</span>
        </span>
        <span aria-hidden="true" class="pv-also-chev">›</span>
      </RouterLink>
    </section>

    <SkeletonLoader v-if="loading" :rows="4" label="Loading your events…" class="px-1" />
    <div v-else-if="events.length === 0" class="pv-empty data-in" data-testid="no-events">
      <strong>No events yet</strong>
      <span>Join one with the code your planner sent, or create your own.</span>
    </div>
    <template v-else-if="otherEvents.length">
      <h2 class="pv-label px-1 mb-0 data-in">{{ liveEvents.length ? 'Your other events' : 'Your events' }}</h2>
      <RouterLink
        v-for="ev in otherEvents"
        :key="ev.id"
        :to="{ name: 'event', params: { id: ev.id } }"
        class="pv-row data-in"
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
          :value="joinCode"
          @input="onJoinInput"
          class="form-control pv-code"
          placeholder="K7Q2XM"
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

  <!-- ===== Website: Your events (Planova Kinetic) ===== -->
  <div v-else class="k kq">
    <!-- "Join with code" sits in the site's top bar (App.vue), which is always on the page first -->
    <Teleport to="#k-nav-actions">
      <div ref="joinWrap" class="wrapm">
        <button type="button" class="kb kb-line kb-sm" :aria-expanded="joinPop ? 'true' : 'false'" data-testid="join-open" @click="joinPop = !joinPop">Join with code</button>
        <form v-if="joinPop" class="ke-pop" @submit.prevent="joinEvent">
          <label class="lab" for="k-code" style="margin-top: 0">Event code</label>
          <div class="row">
            <input
              id="k-code"
              :value="joinCode"
              class="kin"
              placeholder="e.g. 3MF5Y5"
              autocapitalize="characters"
              autocomplete="off"
              required
              style="font: 700 16px Unbounded; letter-spacing: 0.14em; text-transform: uppercase"
              data-testid="join-code"
              @input="onJoinInput"
            />
            <button class="kb kb-lime" type="submit" :disabled="joinCode.length < 6" data-testid="join-btn">Join</button>
          </div>
        </form>
      </div>
    </Teleport>

    <main class="ke2-main ek-main">
      <div class="ke2-greet">
        <div>
          <span class="ey">{{ today }}</span>
          <h1>{{ greeting.replace(',', '') }}<template v-if="firstName">, {{ firstName }}</template></h1>
        </div>
        <span class="sp"></span>
        <RouterLink :to="{ name: 'event-new' }" class="kb kb-ink" data-testid="create-event-btn">
          <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>Create event
        </RouterLink>
      </div>

      <BenchAlert v-if="errorMsg" data-testid="events-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <!-- The next-up band: whichever event is live, otherwise the soonest upcoming. The whole band is one link. -->
      <RouterLink
        v-if="nextEvent"
        :to="{ name: 'event', params: { id: nextEvent.id } }"
        class="ke2-next data-in"
        :aria-label="'Open ' + nextEvent.name"
        :data-testid="nextIsLive ? 'live-' + nextEvent.id : 'next-' + nextEvent.id"
      >
        <div class="txt">
          <span v-if="nextIsLive" class="chip chip-lime"><i class="dot pulse" style="background: var(--ink)"></i>Live now</span>
          <span class="ey" :style="{ color: 'var(--lime)', display: 'block', marginTop: nextIsLive ? '14px' : 0 }">{{ nextIsLive ? 'Live now' : 'Next up' }} · you’re {{ roleLabel(nextEvent) }}</span>
          <h2>{{ nextEvent.name }}</h2>
          <div style="color: var(--on-forest-body); font-size: 15px">
            <template v-if="nextEvent.startsAt">{{ formatDayTime(nextEvent.startsAt) }}</template><template v-if="nextEvent.startsAt && nextEvent.venue"> · </template>{{ nextEvent.venue }}
          </div>
          <div v-if="!nextIsLive" class="ke2-cd" :aria-label="'Starts in ' + countdown.d + ' days ' + countdown.h + ' hours ' + countdown.m + ' minutes'">
            <div><b>{{ countdown.d }}</b><span>DAYS</span></div>
            <div><b>{{ countdown.h }}</b><span>HRS</span></div>
            <div><b>{{ countdown.m }}</b><span>MIN</span></div>
          </div>
        </div>
        <div class="kl-stage kl-spin" aria-hidden="true"><KVenueMap /></div>
      </RouterLink>

      <section class="ke2-list" aria-label="Events">
        <div class="ke2-lh">
          <h2>Your events</h2>
          <div class="seg" role="tablist" aria-label="Event list">
            <button
              v-for="t in WEB_TABS"
              :key="t.key"
              type="button"
              role="tab"
              :aria-pressed="activeTab === t.key ? 'true' : 'false'"
              :aria-selected="activeTab === t.key ? 'true' : 'false'"
              :data-testid="'events-tab-' + t.key"
              @click="pickTab(t.key)"
            >
              {{ t.label }} <span v-if="tabLists[t.key].length" style="opacity: 0.6">{{ tabLists[t.key].length }}</span>
            </button>
          </div>
          <span class="sp"></span>
          <div class="ek-search">
            <input v-model="search" class="kin" type="search" placeholder="Search" aria-label="Search events" />
            <span><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4"></path></svg></span>
          </div>
        </div>

        <SkeletonLoader v-if="loading" :rows="5" label="Loading your events…" />
        <div v-else-if="events.length === 0" class="ek-empty data-in" data-testid="no-events">
          <div class="U ek-empty-title">No events yet</div>
          <p class="mut">Join one with a code, or create your own.</p>
        </div>
        <!-- Each tab's list slides in from the side the tab is on; typing in the search does not re-run it. The direction
             is a CSS variable on the wrapper, so the list that is leaving reads the new direction too. -->
        <div v-else class="pl-tabswap data-in" :style="{ '--tab-shift': tabDir === 'right' ? '16px' : '-16px' }">
          <Transition name="tabswap">
            <div :key="activeTab" role="tabpanel">
              <div v-if="shownEvents.length === 0" class="ek-empty">
                <div class="U ek-empty-title">{{ search ? 'No events match' : 'Nothing here yet' }}</div>
                <p class="mut">{{ search ? 'Try another name.' : 'Create an event or join one with a code.' }}</p>
              </div>
              <div v-else data-testid="event-list">
                <RouterLink v-for="ev in shownEvents" :key="ev.id" :to="{ name: 'event', params: { id: ev.id } }" class="ke2-row ek-row">
                  <span class="ke2-dt" :class="{ tbc: !ev.startsAt }"><b>{{ ev.startsAt ? dayOf(ev.startsAt).padStart(2, '0') : 'TBC' }}</b><span>{{ ev.startsAt ? monthOf(ev.startsAt).toUpperCase() : 'DATE' }}</span></span>
                  <span style="min-width: 0">
                    <span class="nm text-truncate">{{ ev.name }}</span>
                    <span class="mt" data-testid="event-list-when">
                      <template v-if="ev.startsAt">{{ formatDayTime(ev.startsAt) }}</template><template v-if="ev.startsAt && ev.venue"> · </template>{{ ev.venue }}
                      <template v-if="!ev.startsAt && !ev.venue">No date yet</template>
                    </span>
                  </span>
                  <span class="ke2-tags">
                    <span v-if="ev.isSimulation" class="chip rl-sim">Sim</span>
                    <span class="chip" :class="roleChip(ev)" data-testid="event-list-role">{{ roleLabel(ev) }}</span>
                  </span>
                  <span><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg></span>
                </RouterLink>
              </div>
            </div>
          </Transition>
        </div>
      </section>

      <!-- A name-only test event for virtual groups (Stage 3) -->
      <div class="ek-sim">
        <button type="button" class="link" :aria-expanded="simOpen ? 'true' : 'false'" aria-controls="sim-form" @click="simOpen = !simOpen">
          Create a simulation event (virtual groups for testing)
        </button>
        <ExpandTransition>
          <div v-if="simOpen" id="sim-form">
            <form class="row ek-sim-form" @submit.prevent="createSimulation">
              <label for="sim-name" class="visually-hidden">Simulation name</label>
              <input id="sim-name" v-model="simName" class="kin" placeholder="Simulation name" maxlength="80" required data-testid="sim-event-name" />
              <button class="kb kb-line" type="submit" data-testid="create-sim-btn">Create</button>
            </form>
          </div>
        </ExpandTransition>
      </div>
    </main>
  </div>
</template>

<style scoped>
.ek-main { overflow: visible; max-width: 1440px; margin: 0 auto; padding-top: 22px; }
.ek-row { grid-template-columns: 72px minmax(0, 1fr) 200px 28px; }
.ek-search { position: relative; width: 230px; max-width: 100%; }
.ek-search input { padding-left: 40px; height: 42px; border-radius: 999px; background: var(--canvas); border-color: transparent; }
.ek-search span { position: absolute; left: 14px; top: 11px; color: var(--muted); }
.ek-empty { padding: 50px 0; text-align: center; }
.ek-empty-title { font-size: 20px; font-weight: 700; }
.ek-empty p { margin: 8px 0 0; }
.ek-sim { margin-top: 20px; font-size: 14px; }
.ek-sim-form { padding-top: 10px; max-width: 28rem; }
@container k (max-width: 767.98px) {
  .ek-row { grid-template-columns: 56px minmax(0, 1fr) 20px; gap: 12px; }
  .ek-row .ke2-tags { display: none; }
  .ek-search { width: 100%; }
  .k .ke2-lh .seg { max-width: 100%; overflow-x: auto; }
}
</style>
