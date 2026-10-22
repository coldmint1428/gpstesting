<script setup>
// One event: status (live or not) and its pages (/events/:id/<page>): overview, timeline, map, people, groups, live,
// playback, simulator. Which pages and controls you get depends on your role (src/utils/permissions.js).
import { ref, computed, watch } from 'vue'
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
import { formatDayTime, formatTimeSeconds, sgtIso } from '../utils/time'
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
import RunSheetPanel from '../components/RunSheetPanel.vue'
import ShowBar from '../components/ShowBar.vue'
import ShowPanel from '../components/ShowPanel.vue'
import { useShow } from '../composables/useShow'
import { useRunSheetList } from '../composables/useRunSheets'
import OpsSummary from '../components/OpsSummary.vue'
import OpsQueue from '../components/OpsQueue.vue'
import OpsDecision from '../components/OpsDecision.vue'
import { useOps } from '../composables/useOps'
import { useGroupMessages } from '../composables/useGroupMessages'
import NextMoveCard from '../components/NextMoveCard.vue'
import { useMyMoves } from '../composables/useMyMoves'
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

// Run sheet versions (merger Stage 4): root / planners edit, marshals read; ICs and members don't see them.
// One list for the Run sheet tab, the Start / Schedule picker and Playback.
const runSheets = useRunSheetList(props.id, seesWholeEvent)
// The live show (merger Stage 6): while the live session runs a run sheet, root / planners / marshals see it
// beside the map (planners press GO / Hold / +30 s). What happens arrives here once, as a toast, whatever tab is open.
const showSession = computed(() =>
  seesWholeEvent.value && liveSession.value && liveSession.value.runSheetId ? liveSession.value.id : null,
)
const SHOW_TOAST = {
  waiting_go: ['warning', 10000],
  waiting_groups: ['warning', 12000],
  anchor_risk: ['danger', 12000],
  anchor_cut: ['danger', 12000],
  finished: ['info', 6000],
  go: ['info', 5000],
  hold: ['warning', 6000],
  resume: ['info', 5000],
  skip: ['info', 5000],
  end_now: ['info', 5000],
  add_time: ['info', 5000],
  switch: ['info', 6000],
  keep_holding: ['warning', 6000],
  delay_report: ['warning', 12000],
  // 'message' (to a group) is not toasted: the sender is told, and a message to 20 waiting groups would be 20 toasts
}
const show = useShow(showSession, {
  onLog(entry) {
    const how = SHOW_TOAST[entry.kind]
    if (how) toast(entry.message, how[0], how[1])
  },
})

// Start / schedule / cancel / end / switch change which version is Used, scheduled or live. Realtime doesn't
// announce a cancelled schedule (a deleted row), so reload whenever the session state changes.
watch(
  () => sessions.sessions.value.map((x) => x.id + (x.endedAt ? 'e' : '') + (x.runSheetId || '') + x.startsAt.getTime()).join(),
  () => {
    if (seesWholeEvent.value) runSheets.load()
  },
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

// The groups' movements during the show (merger Stage 7): statuses, the problem queue and the map's clusters. Read
// by root / planners / marshals only (the same people who see the show).
const ops = useOps(showSession, { groups, zones: zoneActivity.zones, myUserId: computed(() => (auth.user ? auth.user.id : null)) })
const hasOps = computed(() => !!show.board.value && ops.rows.value.length > 0)
const liveMap = ref(null)
function focusGroup(groupId) {
  if (liveMap.value) liveMap.value.focusGroup(groupId)
}

// A message from the ops view to my group ("Please head to FORMATION_1 now"): a toast when it arrives, and the newest
// one stays on the page while the event is live (until closed).
const groupMessages = useGroupMessages(
  computed(() => (myGroup.value ? myGroup.value.id : null)),
  computed(() => (liveSession.value ? liveSession.value.id : null)),
  {
    onMessage(m) {
      toast('Message from ' + m.from + ': ' + m.body, 'warning', 15000)
    },
  },
)
const closedMessage = ref(null)

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

// My group's next move (merger Stage 8): any member of a group sees where to be, by when, and when to leave. A push
// ("Get ready", "Leave now", "Running late", a message) opens the page with ?next=1: the card is scrolled into view.
const myMoves = useMyMoves(
  computed(() => (liveSession.value ? liveSession.value.id : null)),
  computed(() => !!myGroup.value),
)
const myPosition = computed(() => {
  const p = auth.user ? live.positions.value[auth.user.id] : null
  return p && p.source !== 'stop' ? { lat: p.lat, lng: p.lng } : null
})
const nextMoveEl = ref(null)
watch(
  [() => route.query.next, () => myMoves.loaded.value],
  ([wanted, loaded]) => {
    if (wanted !== '1' || !loaded) return
    goToPage('live')
    setTimeout(() => {
      const el = nextMoveEl.value && (nextMoveEl.value.$el || nextMoveEl.value)
      if (el && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }, 100)
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
    message: 'Everything in it goes: groups, people, zones, run sheets, recordings. This cannot be undone.',
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
        :run-sheets="seesWholeEvent ? runSheets : null" :planned-start="event.starts_at" :planned-end="event.ends_at">
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

      <!-- A message from the planners to my group (merger Stage 7) -->
      <div
        v-if="groupMessages.latest.value && closedMessage !== groupMessages.latest.value.id"
        class="alert alert-warning py-2 d-flex align-items-start gap-2"
        role="alert"
        data-testid="group-message"
      >
        <span class="flex-grow-1">
          <strong>Message from {{ groupMessages.latest.value.from }}</strong>
          <span class="text-muted small"> · {{ formatTimeSeconds(groupMessages.latest.value.at) }}</span><br />
          {{ groupMessages.latest.value.body }}
        </span>
        <button type="button" class="btn-close" aria-label="Close" @click="closedMessage = groupMessages.latest.value.id"></button>
      </div>

      <NextMoveCard
        v-if="liveSession && myGroup"
        ref="nextMoveEl"
        :moves="myMoves"
        :my-position="myPosition"
        :sharing="sharingHere"
        @stop-sharing="tracker.stop()"
        @share="startSharing"
      />

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
              {{ PAGE_LABEL[p] }}
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

      <!-- Live: v-show keeps the map alive (and its live connection) on the other pages. With a live run sheet the
           show's bar sits on top and its panel beside the map (above it on a phone). -->
      <div v-show="page === 'live'">
      <ShowBar v-if="show.board.value" :show="show" />
      <OpsSummary v-if="hasOps" :ops="ops" />
      <OpsDecision v-if="show.board.value" :show="show" :ops="ops" :groups="groups" :can-run="canManage" />
      <div class="row g-3">
      <div :class="show.board.value ? 'col-lg-8' : 'col-12'">
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
        :ops-active="hasOps ? ops.active.value : {}"
        :ops-visible="hasOps ? ops.visibleGroupIds.value : null"
      />
      </div>
      <div v-if="show.board.value" class="col-lg-4 order-first order-lg-last">
        <ShowPanel :show="show" :can-run="canManage" :ops="hasOps ? ops : null" />
        <OpsQueue v-if="hasOps" class="mt-3" :ops="ops" :now="show.now.value" @select="focusGroup" />
      </div>
      </div>

      <!-- "Message everyone" (032): planners send one message to many groups at once -->
      <BroadcastPanel v-if="canManage" :broadcasts="broadcasts" :groups="groups" :show="show" :can-run="canManage" :native="native" />
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

      <!-- Timeline: the run sheet (root / planners edit, marshals read) -->
      <RunSheetPanel
        v-if="seesWholeEvent && page === 'timeline'"
        :event-id="id"
        :can-edit="modeOf('timeline') === 'edit'"
        :list="runSheets"
        :groups="groups"
        :live-session="liveSession"
        :event-name="event.name"
        :planned-day="event.starts_at ? sgtIso(new Date(event.starts_at)).slice(0, 10) : ''"
        :members="members"
        @changed="load"
      />

      <!-- Not built yet for these roles (a teammate's screens): the view-only map, and the timeline for people who
           can't read the run sheet -->
      <EventPagePlaceholder
        v-if="(page === 'map' && !canManage) || (page === 'timeline' && !seesWholeEvent)"
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
