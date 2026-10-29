<script setup>
// One event: status (live or not) and its pages (/events/:id/<page>): overview, timeline, map, people, groups, live,
// playback, simulator. Which pages and controls you get depends on your role (src/utils/permissions.js).
// The run-sheet half of this page -- the classic editor, the live show's bar and panel, the ops queue, the member's
// next-move card and the group message -- was deleted in step 25 with the engine that fed it.
import { ref, computed, watch, onMounted } from 'vue'
import { RouterLink, useRouter, useRoute } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useEventData } from '../composables/useEventData'
import { useEventSessions } from '../composables/useEventSessions'
import { useLiveLocations } from '../composables/useLiveLocations'
import { useLocationTracker } from '../composables/useLocationTracker'
import {
  syncStartReminders,
  clearStartReminder,
  exactRemindersAllowed,
  allowExactReminders,
} from '../composables/useStartReminders'
import { clearPushReminders } from '../composables/usePushNotifications'
import { askConfirm, toast } from '../composables/useNotify'
import { useZoneActivity } from '../composables/useZoneActivity'
import { usePhoneReadiness } from '../composables/usePhoneReadiness'
import { formatDayTime, formatTimeSeconds } from '../utils/time'
import { groupRoleLabel } from '../utils/people'
import { PAGES, PAGE_LABEL, ROLE_LABEL, topRole, isMarshal, viewRole, canView, pageMode } from '../utils/permissions'
import { leaveEvent as leaveEventCall, fetchMembership, rememberMembership, updateEventDetails, deleteEvent } from '../services/memberService'
import { isNativeApp } from '../lib/platform'
import PeoplePanel from '../components/PeoplePanel.vue'
import EventOverview from '../components/EventOverview.vue'
import EventPagePlaceholder from '../components/EventPagePlaceholder.vue'
import SharingWarnings from '../components/SharingWarnings.vue'
import EventStatus from '../components/EventStatus.vue'
import LiveMap from '../components/LiveMap.vue'
import MembersPanel from '../components/MembersPanel.vue'
import BenchAlert from '../components/BenchAlert.vue'
import PlaybackPanel from '../components/PlaybackPanel.vue'
import PolygonTestView from './PolygonTestView.vue'
import ZoneOverview from '../components/ZoneOverview.vue'
import SimulatorPanel from '../components/SimulatorPanel.vue'
import PlanBoard from '../components/plan/PlanBoard.vue'
import PlanSchedule from '../components/plan/PlanSchedule.vue'
import PlanOps from '../components/plan/PlanOps.vue'
import { usePlan } from '../composables/usePlan'
import { useBroadcasts } from '../composables/useBroadcasts'
import BroadcastBanner from '../components/BroadcastBanner.vue'
import BroadcastPanel from '../components/BroadcastPanel.vue'

const props = defineProps({ id: { type: String, required: true } })
const auth = useAuthStore()
const router = useRouter()
const route = useRoute()
const native = isNativeApp // phone app: "Message everyone" opens as a bottom sheet, not a card in the page

const { event, groups, members, loading, errorMsg, load, me, isRoot, canManage, seesWholeEvent, myGroup } =
  useEventData(props.id)

// Is the event live? (ICs can only share while it is)
const sessions = useEventSessions(props.id)
const { isLive, liveSession, scheduledStart } = sessions

// Plans (039): a session runs a plan or nothing (step 24). The Start dialog needs the list of plans.
const startPlans = usePlan(props.id)
const planSession = computed(() => !!(liveSession.value && liveSession.value.planId))
// What the schedule reads (step 16): the session that is running or about to run, or -- once the event is over -- the
// last one, so a member can still see how the night went. Null before anything has been started, which is the one
// case with no timetable to show.
const scheduleSession = computed(() => {
  const open = sessions.openSession.value
  if (open) return open
  const last = sessions.sessions.value[0]
  return last && last.planId ? last : null
})
// The page mounts before the event's data (and so before "am I staff?") has arrived, so the list is loaded when the
// answer becomes yes rather than at mount: at mount `seesWholeEvent` is still false and the Start dialog would open
// with nothing in it.
// `plansReady` exists so the Start button cannot be pressed while the list is still on its way: pressing it then
// opened the dialog with no plan in it and quietly meant "tracking only", which is the wrong thing to do by accident.
const plansReady = ref(false)
watch(
  seesWholeEvent,
  (yes) => {
    if (!yes || startPlans.plans.value.length) return
    startPlans
      .loadPlans()
      .catch(() => {})
      .finally(() => (plansReady.value = true))
  },
  { immediate: true },
)
// Zones during the live session (merger Stage 2): who is inside which zone, group positions, No-Go alerts.
// A No-Go entry is told to the event's root / planners / marshals (toast) and to the IC who entered it.
const zoneActivity = useZoneActivity(props.id, computed(() => (liveSession.value ? liveSession.value.id : null)), {
  onAlert(alert) {
    const mine = auth.user && alert.userId === auth.user.id
    if (!seesWholeEvent.value && !mine) return
    const zoneName = alert.zone ? alert.zone.name + ' (' + alert.zone.code + ')' : 'a No-Go area'
    if (mine) {
      toast('No-Go: You entered ' + zoneName + ' at ' + formatTimeSeconds(alert.at) + '.', 'danger', 12000)
      return
    }
    queueNoGoToast(alert, zoneName)
  },
})

// Alerts arrive one per IC, so a group walking in together, or a restart with many people already inside,
// used to stack one red toast per person (15 at once in the simulator run) over the planner's screen.
// Entries within 1.5 s are said together: per group, and as one line when several groups arrive at once.
// A single IC still reads exactly as before.
const noGoBurst = []
let noGoTimer = null
function queueNoGoToast(alert, zoneName) {
  noGoBurst.push({ alert, zoneName })
  if (!noGoTimer) noGoTimer = setTimeout(flushNoGoToasts, 1500)
}
function flushNoGoToasts() {
  noGoTimer = null
  const items = noGoBurst.splice(0)
  const byZone = new Map()
  for (const item of items) {
    const key = item.alert.zone ? item.alert.zone.id : item.zoneName
    if (!byZone.has(key)) byZone.set(key, { zoneName: item.zoneName, items: [] })
    byZone.get(key).items.push(item)
  }
  for (const { zoneName, items: entries } of byZone.values()) {
    const at = formatTimeSeconds(entries[0].alert.at)
    if (entries.length === 1) {
      const member = members.value.find((m) => m.id === entries[0].alert.userId)
      toast('No-Go: ' + (member ? member.display_name : 'Someone') + ' entered ' + zoneName + ' at ' + at + '.', 'danger', 12000)
      continue
    }
    const groupIds = [...new Set(entries.map((e) => e.alert.groupId))]
    const names = groupIds.map((id) => (groups.value.find((g) => g.id === id) || {}).name || 'a group')
    const ics = entries.length + ' ICs'
    const text =
      groupIds.length === 1
        ? names[0] + ' (' + ics + ') entered ' + zoneName
        : groupIds.length + ' groups (' + ics + ') entered ' + zoneName + ': ' + names.slice(0, 5).join(', ') + (names.length > 5 ? ', …' : '')
    toast('No-Go: ' + text + ' at ' + at + '.', 'danger', 12000)
  }
}

// The map, for "the group I picked is over there". The ops queue that used to call this is gone with the run sheet
// engine (step 25); the ref stays because the Live page owns the map.
const liveMap = ref(null)

// "Message everyone" (032): planners send one message to many groups at once; whoever it reaches sees a banner until
// they press Got it (and a toast as it arrives).
const broadcasts = useBroadcasts(computed(() => props.id), {
  myUserIdRef: computed(() => (auth.user ? auth.user.id : null)),
  staffRef: canManage,
  onNew(b) {
    toast((b.urgent ? 'URGENT · ' : '') + 'Message from ' + b.from + ': ' + b.body, b.urgent ? 'danger' : 'warning', 15000)
  },
})

// The No-Go areas I am inside right now (shown to me as a warning until I leave).
const myNoGo = computed(() => {
  const mine = auth.user ? zoneActivity.staysByUser.value[auth.user.id] || [] : []
  return mine.filter((s) => s.zone.kind === 'no_go').map((s) => s.zone)
})

// Latest positions (one connection for the map and the "Not sharing yet" badges)
const live = useLiveLocations(props.id)

// ---------- Pages and my role ----------
// The page is in the address (the router guard already checked I may view it)
const page = computed(() => route.params.page || 'overview')
function goToPage(name, query = {}) {
  router.replace({ name: 'event', params: { id: props.id, page: name }, query })
}
// My membership as the permission map wants it, from the member list (kept up to date by Realtime)
const membership = computed(() =>
  me.value
    ? { role: topRole(me.value), group_id: me.value.groupId, is_admin: me.value.isAdmin, is_ic: me.value.isIC, is_marshal: isMarshal(me.value) }
    : null,
)
const role = computed(() => viewRole(membership.value)) // root | planner | admin | marshal | ic | member
const modeOf = (name) => pageMode(name, role.value)
const visiblePages = computed(() =>
  PAGES.filter((p) => canView(p, role.value) && (p !== 'simulator' || (event.value && event.value.is_simulation))),
)
// The Timeline tab is the planner's board; for everyone else it is their own timetable, and the tab says so
// (step 16). The address stays /timeline, so one page keeps one name in the URL.
function pageLabel(name) {
  return name === 'timeline' && modeOf('timeline') !== 'edit' ? 'Schedule' : PAGE_LABEL[name]
}
// Someone changed my role or removed me: keep the router guard's copy right, leave pages I may no longer view
watch(membership, async (now) => {
  if (loading.value || !event.value) return
  if (!now) {
    if (members.value.length) {
      toast('You are no longer a member of this event.', 'warning')
      router.push('/events')
    }
    return
  }
  const known = await fetchMembership(props.id).catch(() => null)
  rememberMembership(props.id, { ...(known || {}), ...now, is_simulation: !!event.value.is_simulation })
  if (!visiblePages.value.includes(page.value)) {
    toast('Your role in this event changed.', 'info')
    goToPage('overview')
  }
})

// A push ("get ready", "leave now", "you are late", a message) opens the page with ?next=1. It used to scroll to the
// member's "next move" card, which was read from `movements` and deleted with the run-sheet engine (step 25). The
// member's own moments live on the Schedule page now (step 16), so that is where the push lands.
watch(
  () => route.query.next,
  (wanted) => {
    if (wanted === '1') goToPage('timeline')
  },
  { immediate: true },
)

// ---------- One-tap sharing (same tracker as the Share page and navbar) ----------
const tracker = useLocationTracker()
const { isTracking, sharingEventId, errorMsg: shareError } = tracker
const sharingHere = computed(() => isTracking.value && sharingEventId.value === props.id)
const isIC = computed(() => !!(me.value && me.value.isIC && myGroup.value))

// Phone app: anything missing (location "all the time", battery, notifications...) opens "Set up sharing"
// first, one step at a time, which starts sharing by itself at the end. Nothing missing: straight on.
const readiness = usePhoneReadiness()
async function startSharing() {
  if (tracker.isNative) {
    const ready = await readiness.check()
    if (!ready.allOk) {
      router.push({ name: 'phone-check', query: { event: props.id, group: myGroup.value.id, share: '1' } })
      return
    }
  }
  await tracker.start(props.id, myGroup.value.id) // asks for location permission the first time
  if (tracker.isTracking.value) {
    clearStartReminder(props.id) // the "tap to share" reminders can go
    clearPushReminders()
  }
}

// Planner ended the event while I'm sharing: stop here too (the database already refuses
// my uploads and left a "Stopped sharing" marker, so don't save another one)
watch(isLive, (nowLive, wasLive) => {
  if (wasLive && !nowLive && sharingHere.value) {
    tracker.stop(false).then(() => {
      tracker.errorMsg.value = 'The event has ended, so sharing stopped.'
    })
  }
})

// Opened from the "Event started - tap to share" reminder: start sharing straight away
watch(
  [() => route.query.share, isLive, isIC],
  ([share, nowLive, ic]) => {
    if (share === '1' && nowLive && ic && !sharingHere.value) {
      goToPage('live')
      startSharing()
    }
  },
  { immediate: true },
)

// Phone app: keep the start reminders in step with this event's schedule
const exactAllowed = ref(true)
watch(
  [() => sessions.openSession.value && sessions.openSession.value.startsAt.getTime(), isIC],
  async () => {
    if (!auth.user) return
    await syncStartReminders(auth.user.id, sharingEventId.value)
    exactAllowed.value = await exactRemindersAllowed()
  },
)
async function allowExact() {
  exactAllowed.value = await allowExactReminders()
  syncStartReminders(auth.user.id, sharingEventId.value)
}

// ---------- Who is sharing (for planners while live) ----------
// An IC counts as sharing if their newest reading is GPS from this session
const sharingStatus = computed(() => {
  const status = {}
  if (!liveSession.value) return status
  const since = liveSession.value.startsAt.getTime()
  for (const m of members.value) {
    if (!m.isIC) continue
    const p = live.positions.value[m.id]
    status[m.id] = !!(p && p.source === 'gps' && p.time.getTime() >= since)
  }
  return status
})
const icCount = computed(() => Object.keys(sharingStatus.value).length)
const sharingCount = computed(() => Object.values(sharingStatus.value).filter(Boolean).length)

// Text under the title explaining what this person sees on the map
const viewText = computed(() => {
  if (seesWholeEvent.value) return 'You can see every group in this event.'
  if (myGroup.value) return 'You can see your group: ' + myGroup.value.name + '.'
  return 'You are not in a group yet. Ask the root, a planner or a group admin to add you.'
})

function goLive() {
  goToPage('live')
}

async function leaveEvent() {
  if (!(await askConfirm({ title: 'Leave this event?', confirmText: 'Leave', danger: true }))) return
  if (sharingHere.value) await tracker.stop() // stop sharing before leaving
  const message = await leaveEventCall(props.id, auth.user.id)
  if (message) errorMsg.value = message
  else router.push('/events')
}

// ---------- The root edits or deletes the event (EventOverview emits; the view saves) ----------
const overviewBusy = ref(false)
const detailsSavedCount = ref(0) // tells EventOverview to close its form

async function saveEventDetails(details) {
  errorMsg.value = ''
  overviewBusy.value = true
  const message = await updateEventDetails(props.id, details)
  overviewBusy.value = false
  if (message) errorMsg.value = message
  else {
    toast('Event details saved.', 'success', 3000)
    detailsSavedCount.value++
    load() // re-fetch, so the page shows what the database stored
  }
}

async function removeEvent() {
  const ok = await askConfirm({
    title: 'Delete "' + event.value.name + '"?',
    message: 'Everything in it goes: groups, people, zones, plans, recordings. This cannot be undone.',
    confirmText: 'Delete event',
    danger: true,
  })
  if (!ok) return
  errorMsg.value = ''
  overviewBusy.value = true
  const message = await deleteEvent(props.id)
  overviewBusy.value = false
  if (message) {
    errorMsg.value = message
    return
  }
  if (sharingHere.value) await tracker.stop(false)
  toast('Event deleted.')
  router.push('/events')
}
</script>

<template>
  <main class="container py-3">
    <p v-if="loading" class="text-muted">Loading...</p>
    <div v-else-if="!event" class="alert alert-danger" role="alert">
      {{ errorMsg || 'Event not found.' }}
      <div class="mt-2"><RouterLink to="/events">Back to my events</RouterLink></div>
    </div>

    <template v-else>
      <div class="mb-3">
        <h1 class="h4 mb-1" data-testid="event-name">{{ event.name }}</h1>
        <!-- Details from the Create-an-event wizard (older events have none) -->
        <p v-if="event.starts_at || event.venue" class="small text-muted mb-1" data-testid="event-when">
          <template v-if="event.starts_at">{{ formatDayTime(event.starts_at) }} – {{ formatDayTime(event.ends_at) }}</template>
          <template v-if="event.starts_at && event.venue"> · </template>
          <template v-if="event.venue">{{ event.venue }}</template>
        </p>
        <p v-if="event.description" class="small mb-1" style="white-space: pre-line">{{ event.description }}</p>
        <!-- One event badge (highest role) + one group badge ("Group A: Admin, IC") -->
        <span v-if="event.is_simulation" class="badge text-bg-warning me-1" data-testid="sim-badge">SIMULATION</span>
        <span class="badge text-bg-secondary me-1" data-testid="event-role-badge">{{ ROLE_LABEL[topRole(me)] || 'Member' }}</span>
        <span v-if="isMarshal(me)" class="badge text-bg-dark me-1" data-testid="event-marshal-badge">Marshal</span>
        <span v-if="myGroup" class="badge text-bg-info me-1" data-testid="group-role-badge">
          {{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}
        </span>
      </div>

      <div v-if="event.is_simulation" class="alert alert-warning py-2 small" data-testid="sim-banner">
        <strong>Simulation event.</strong> Groups named SIM-… and their ICs are virtual: the server moves them every 10 s
        to test zones and alerts at scale. Nothing here is a real person.
      </div>

      <EventStatus :sessions="sessions" :event-id="id" :can-manage="canManage" :ic-count="icCount" :sharing-count="sharingCount"
        :plans="seesWholeEvent ? startPlans.plans.value : []"
        :plans-ready="!seesWholeEvent || plansReady"
        :planned-start="event.starts_at" :planned-end="event.ends_at">
        <!-- Only the group's IC shares, and only while the event is live. One tap starts sharing. -->
        <template v-if="isIC" #sharing>
          <div class="d-flex flex-wrap align-items-center gap-2">
            <span class="small flex-grow-1">
              <strong>Your location:</strong>
              <span v-if="sharingHere" class="text-success" data-testid="sharing-banner">
                ● Sharing with this event's planners and your group.
              </span>
              <span v-else-if="isLive" class="text-muted"> not shared yet.</span>
              <span v-else class="text-muted" data-testid="share-locked-text">
                <template v-if="scheduledStart"> sharing opens at {{ formatDayTime(scheduledStart) }}.</template>
                <template v-else> sharing opens when a planner starts the event.</template>
              </span>
            </span>
            <button v-if="sharingHere" class="btn btn-sm btn-danger" data-testid="stop-share-btn" @click="tracker.stop()">
              Stop sharing
            </button>
            <button v-else-if="isLive" class="btn btn-sm btn-success" data-testid="share-btn" @click="startSharing">
              Share my location
            </button>
            <button v-else class="btn btn-sm btn-success" disabled data-testid="share-btn-locked">Share my location</button>
            <RouterLink :to="{ name: 'share', params: { id } }" class="btn btn-sm btn-outline-secondary" data-testid="share-details-link">
              My GPS details
            </RouterLink>
          </div>
        </template>
      </EventStatus>

      <div v-if="isIC && scheduledStart && tracker.isNative && !exactAllowed" class="alert alert-light border py-2 small">
        We'll remind you to share at the start time. For an on-time reminder, allow alarms for this app.
        <button class="btn btn-sm btn-outline-primary ms-1" @click="allowExact">Allow alarms</button>
      </div>

      <!-- I (an IC) am inside a No-Go area right now -->
      <div v-if="myNoGo.length" class="alert alert-danger py-2" role="alert" data-testid="my-no-go">
        <strong>You are inside a No-Go area:</strong> {{ myNoGo.map((z) => z.name).join(', ') }}. Please leave it now.
      </div>

      <!-- A message from the planners to my group used to sit here. It was written by the ops board's
           `message_group`, which step 25 deleted with the run sheet engine and which nothing else wrote, so the
           banner that could never receive a message went with it. "Message everyone" (032) is right below. -->

      <SharingWarnings v-if="sharingHere" />
      <BenchAlert v-if="shareError" data-testid="share-error" @dismiss="shareError = ''">{{ shareError }}</BenchAlert>
      <p class="small text-muted mb-3" data-testid="view-scope">{{ viewText }}</p>

      <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <!-- A message from the planners to many groups at once (032): stays until Got it -->
      <BroadcastBanner :broadcasts="broadcasts" />

      <!-- The pages my role may view: tabs, or a menu on a phone -->
      <nav aria-label="Event pages" class="mb-3">
        <ul class="nav nav-tabs d-none d-sm-flex" data-testid="event-nav">
          <li v-for="p in visiblePages" :key="p" class="nav-item">
            <RouterLink
              class="nav-link"
              :class="{ active: page === p }"
              :aria-current="page === p ? 'page' : undefined"
              :to="{ name: 'event', params: { id, page: p } }"
              replace
              :data-testid="'tab-' + p"
            >
              {{ pageLabel(p) }}
              <span v-if="p === 'people'" class="badge text-bg-light">{{ members.length }}</span>
            </RouterLink>
          </li>
        </ul>
        <div class="d-sm-none">
          <label for="event-page-select" class="visually-hidden">Page</label>
          <select id="event-page-select" class="form-select" :value="page" data-testid="event-nav-select" @change="goToPage($event.target.value)">
            <option v-for="p in visiblePages" :key="p" :value="p">{{ PAGE_LABEL[p] }}</option>
          </select>
        </div>
      </nav>

      <!-- Live: v-show keeps the map alive (and its live connection) on the other pages. -->
      <div v-show="page === 'live'">
      <!-- A plan session's staff picture of the walk: a row per group, its moment, its leg and where its ICs are
           (step 20). It is mounted only while the Live page is shown: the page itself is kept alive by v-show for the
           map, and a panel that polls every five seconds must not run behind a planner who is drawing the plan. -->
      <PlanOps v-if="page === 'live' && planSession && seesWholeEvent" :session="liveSession" />
      <div class="row g-3">
      <div class="col-12">
      <LiveMap
        ref="liveMap"
        :active="page === 'live'"
        :event-id="id"
        :positions="live.positions.value"
        :live-since="liveSession ? liveSession.startsAt.getTime() : null"
        :on-reading="live.onReading"
        :now="live.now.value"
        :live-error="live.errorMsg.value"
        :reconnecting="live.reconnecting.value"
        :members="members"
        :groups="groups"
        :my-user-id="auth.user ? auth.user.id : null"
        :zone-stays="zoneActivity.staysByUser.value"
        :zone-counts="zoneActivity.countsByZone.value"
        :no-go-occupied="zoneActivity.noGoOccupied.value"
        :group-positions="zoneActivity.groupPositions.value"
      />
      </div>
      </div>

      <!-- "Message everyone" (032): planners send one message to many groups at once -->
      <BroadcastPanel v-if="canManage" :broadcasts="broadcasts" :groups="groups" :native="native" />
      </div>

      <EventOverview
        v-if="page === 'overview'"
        :event="event"
        :role="role"
        :mode="modeOf('overview')"
        :members="members"
        :groups="groups"
        :my-group="myGroup"
        :is-live="isLive"
        :scheduled-start="scheduledStart"
        :busy="overviewBusy"
        :saved-count="detailsSavedCount"
        @save-details="saveEventDetails"
        @leave="leaveEvent"
        @delete="removeEvent"
      />

      <!-- Groups: root / planners edit every group, a group admin their own; ICs and members see their own group -->
      <MembersPanel
        v-if="page === 'groups'"
        :event-id="id"
        :members="members"
        :groups="groups"
        :me="me"
        :is-root="isRoot"
        :can-manage="canManage"
        :only-group-id="role === 'ic' || role === 'member' ? (myGroup ? myGroup.id : 'none') : null"
        :sharing-status="sharingStatus"
        @changed="load"
      />

      <PeoplePanel
        v-if="page === 'people'"
        :event-id="id"
        :members="members"
        :groups="groups"
        :me="me"
        :mode="modeOf('people')"
        @changed="load"
      />

      <!-- v-show keeps an open replay when peeking at another page -->
      <PlaybackPanel
        v-if="canManage"
        v-show="page === 'playback'"
        :active="page === 'playback'"
        :event-id="id"
        :event-name="event.name"
        :members="members"
        @go-live="goLive"
      />

      <!-- Map: root / planners edit the zones (v-if: the bench holds locks and a presence row only while it is open) -->
      <template v-if="canManage && page === 'map'">
        <ZoneOverview class="mb-3" :event-id="id" />
        <PolygonTestView :event-id="id" embedded />
      </template>

      <!-- Timeline: the plan board for the people who draw it, and the timetable for the people who follow it
           (step 16). Root and planner get the strip, the map and the inspector; a member, an IC, a group admin or a
           marshal gets their own moments on the plan's clock, from the one read that is already scoped to them (052).
           The root's "open the classic run sheet" button was here until step 25 deleted the run sheet. -->
      <template v-if="page === 'timeline'">
        <PlanBoard
          v-if="modeOf('timeline') === 'edit'"
          :event-id="id"
          :can-edit="modeOf('timeline') === 'edit'"
          :only-group-id="seesWholeEvent ? null : myGroup ? myGroup.id : 'none'"
          :live-session="liveSession"
        />
        <PlanSchedule
          v-else
          :event-id="id"
          :session="scheduleSession"
          :whole="seesWholeEvent"
          :my-group="myGroup"
          :can-press="isIC"
        />
      </template>

      <!-- Not built yet for these roles: the view-only map -->
      <EventPagePlaceholder
        v-if="page === 'map' && !canManage"
        :page="page"
        :mode="modeOf(page)"
        :role="role"
        :group="myGroup"
        :is-live="isLive"
        :scheduled-start="scheduledStart"
      />

      <SimulatorPanel v-if="event.is_simulation && isRoot && page === 'simulator'" :event-id="id" @changed="load" />
    </template>
  </main>
</template>
