<script setup>
// One event: status (live or not) and its pages (/events/:id/<page>): overview, timeline, map, people, groups, live,
// playback, simulator. Which pages and controls you get depends on your role (src/utils/permissions.js).
import { ref, computed, watch, nextTick } from 'vue'
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
import { useBroadcasts } from '../composables/useBroadcasts'
import BroadcastBanner from '../components/BroadcastBanner.vue'
import BroadcastPanel from '../components/BroadcastPanel.vue'
import NextMoveCard from '../components/NextMoveCard.vue'
import PhoneTabBar from '../components/PhoneTabBar.vue'
import BottomSheet from '../components/BottomSheet.vue'
import { isNativeApp } from '../lib/platform'
import { useMyMoves } from '../composables/useMyMoves'

const props = defineProps({ id: { type: String, required: true } })
const auth = useAuthStore()
const router = useRouter()
const route = useRoute()

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
  // Phone app: Ops and the map are separate tabs, so the map is opened first and given a moment to size itself
  if (isNativeApp && tab.value !== 'live') {
    openPage('live')
    setTimeout(() => liveMap.value && liveMap.value.focusGroup(groupId), 250)
    return
  }
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
const broadcasts = useBroadcasts(
  computed(() => props.id),
  {
    myUserIdRef: computed(() => (auth.user ? auth.user.id : null)),
    staffRef: canManage,
    onNew(b) {
      toast((b.urgent ? 'URGENT · ' : '') + 'Message from ' + b.from + ': ' + b.body, b.urgent ? 'danger' : 'warning', 15000)
    },
  },
)

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
// Phone app only: Now (an IC's or member's next move) and Ops (the live show) are tabs, not website pages
const PHONE_ONLY = ['now', 'ops']
const phoneTab = ref(null)
const tab = computed(() => phoneTab.value || page.value) // what is on screen
function openPage(key) {
  if (PHONE_ONLY.includes(key)) phoneTab.value = key
  else {
    phoneTab.value = null
    if (key !== page.value) goToPage(key)
  }
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
const nextMoveEl2 = ref(null) // where the card sits for a planner who is also in a group
watch(
  [() => route.query.next, () => myMoves.loaded.value],
  ([wanted, loaded]) => {
    if (wanted !== '1' || !loaded) return
    goToPage('live')
    if (isNativeApp) phoneTab.value = homeTab.value // Now, or Ops for a planner who is also in a group
    setTimeout(() => {
      const card = nextMoveEl.value || nextMoveEl2.value
      const el = card && (card.$el || card)
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
  if (isNativeApp) openPage(homeTab.value)
  else goToPage('live')
}

// ---------- The event's pages (side navigation): the ones my role may view, with what each is for ----------
const ICONS = {
  overview: ['M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z', 'M12 16v-4', 'M12 8h.01'],
  timeline: ['M9 6h12', 'M9 12h12', 'M9 18h12', 'M4 6h.01', 'M4 12h.01', 'M4 18h.01'],
  map: ['M12 3l8 5v8l-8 5-8-5V8z'],
  people: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z', 'M22 21v-2a4 4 0 0 0-3-3.87', 'M16 3.13a4 4 0 0 1 0 7.75'],
  groups: ['M3 3h7v7H3z', 'M14 3h7v7h-7z', 'M14 14h7v7h-7z', 'M3 14h7v7H3z'],
  live: ['M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11z', 'M12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z'],
  playback: ['M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z', 'M10 8l6 4-6 4z'],
  simulator: ['M9 3h6', 'M10 3v6l-5 9a2 2 0 0 0 1.7 3h10.6a2 2 0 0 0 1.7-3l-5-9V3'],
}
const PAGE_INFO = computed(() => ({
  overview: {
    hint: 'When, where, invite',
    about: 'What the event is, when and where it happens, and how people join.',
  },
  timeline: {
    hint: "The show's timeline",
    about: "The show's running order: cues with their times, and where each group must be by when. Make a version, " +
      'check it, mark it Ready, then pick it when you start the event.',
  },
  map: {
    hint: 'Areas, doors, No-Go',
    about: 'The places groups must reach (formations, holding areas, doors) and No-Go areas. Each gets a code the run ' +
      'sheet uses, and everyone sees them on the live map.',
  },
  people: {
    hint: 'Who is in it, roles',
    badge: members.value.length,
    about: 'Who is in the event and their roles.',
  },
  groups: {
    hint: 'Groups and their ICs',
    about: "The event's groups and who is in each. A group's IC shares its location.",
  },
  live: {
    hint: show.board.value ? 'The show is running' : isLive.value ? 'Live now' : 'Where everyone is',
    badge: isLive.value ? 'LIVE' : '',
    badgeLive: true,
    about: viewText.value,
  },
  playback: { hint: 'Replay a session', about: 'Replay a past session of this event, or export it.' },
  simulator: { hint: 'Virtual groups', about: 'Virtual groups that the server moves, to test zones, alerts and the show at scale.' },
}))
const pages = computed(() => visiblePages.value.map((key) => ({ key, label: PAGE_LABEL[key], ...PAGE_INFO.value[key] })))
const currentPage = computed(() => pages.value.find((p) => p.key === tab.value) || { label: event.value ? event.value.name : '' })

// ---------- Phone app (Android first): bottom tabs that follow the role (Figma "Phone app — native prototype") ----------
// ICs and members: Now · Map · Group · Info. Root, planners and marshals: Ops · Map · Timeline · People · More. Every
// other page my role may view is in the More sheet. Same pages and data as the website.
const native = isNativeApp
const homeTab = computed(() => (seesWholeEvent.value ? 'ops' : 'now'))
const nativeTabs = computed(() => {
  const tabs = seesWholeEvent.value
    ? [
        { key: 'ops', label: 'Ops', icon: 'ops', dot: !!show.board.value },
        { key: 'live', label: 'Map', icon: 'map' },
        { key: 'timeline', label: 'Timeline', icon: 'runsheet' },
        { key: 'people', label: 'People', icon: 'group' },
      ]
    : [
        { key: 'now', label: 'Now', icon: 'now', dot: isLive.value },
        { key: 'live', label: 'Map', icon: 'map' },
        { key: 'groups', label: 'Group', icon: 'group' },
        { key: 'overview', label: 'Info', icon: 'info' },
      ]
  return morePages.value.length ? [...tabs, { key: 'more', label: 'More', icon: 'more' }] : tabs
})
const MORE_HINT = {
  overview: 'Details, invite, and leave the event',
  timeline: "The show's timeline",
  map: 'Areas, doors and No-Go areas',
  people: 'Who is in it, roles',
  groups: 'Groups and their ICs',
  playback: 'Replay a past session',
  simulator: 'Virtual groups',
}
const morePages = computed(() => {
  const inBar = seesWholeEvent.value ? ['live', 'timeline', 'people'] : ['live', 'groups', 'overview']
  return visiblePages.value
    .filter((p) => !inBar.includes(p))
    .map((key) => ({ key, label: key === 'overview' ? 'Event info' : PAGE_LABEL[key], hint: MORE_HINT[key] }))
})
const moreOpen = ref(false)
const activeTab = computed(() => (morePages.value.some((p) => p.key === tab.value) ? 'more' : tab.value))
function selectTab(key) {
  if (key === 'more') {
    moreOpen.value = true
    return
  }
  openPage(key)
  window.scrollTo(0, 0)
}
function openMore(key) {
  moreOpen.value = false
  openPage(key)
  window.scrollTo(0, 0)
}
// The phone opens an event on its home tab (Now or Ops) unless the address asked for a page
const askedForPage = !!route.params.page && !route.redirectedFrom
watch(
  loading,
  (isLoading) => {
    if (native && !isLoading && event.value && !askedForPage && !phoneTab.value) phoneTab.value = homeTab.value
  },
  { immediate: true },
)
// A phone tab this person cannot open (a role taken away): their home tab
watch([homeTab, loading], ([home, isLoading]) => {
  if (!isLoading && phoneTab.value && phoneTab.value !== home) phoneTab.value = home
})
// On a phone the pages are one scrolling row: keep the open one in view (centred, without moving the page itself)
function showCurrentInNav() {
  nextTick(() => {
    const nav = document.querySelector('.ev-nav')
    const btn = nav && nav.querySelector('[aria-current="page"]')
    if (nav && btn && nav.scrollWidth > nav.clientWidth) nav.scrollLeft = btn.offsetLeft - (nav.clientWidth - btn.offsetWidth) / 2
  })
}
watch([tab, loading], showCurrentInNav)

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
  <p v-if="loading" class="container py-3 text-muted">Loading...</p>
  <div v-else-if="!event" class="container py-3">
    <div class="alert alert-danger" role="alert">
      {{ errorMsg || 'Event not found.' }}
      <div class="mt-2"><RouterLink to="/events">Back to my events</RouterLink></div>
    </div>
  </div>

  <div v-else class="ev" :class="{ 'ev-native': native }">
    <!-- Phone app: a compact header; the pages are in the bottom tabs -->
    <header v-if="native" class="pv-head" data-testid="phone-event-head">
      <RouterLink to="/events" class="pv-back" aria-label="Back to my events" data-testid="back-to-events">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6" /></svg>
      </RouterLink>
      <div class="pv-head-text">
        <h1 class="pv-title" data-testid="event-name">{{ event.name }}</h1>
        <p class="pv-sub" data-testid="event-role-badge">
          {{ ROLE_LABEL[topRole(me)] || 'Member' }}<template v-if="isMarshal(me)"> · Marshal</template><template v-if="myGroup"> · {{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}</template>
        </p>
      </div>
      <span v-if="isLive" class="pv-chip pv-chip-live" data-testid="head-live">● LIVE</span>
      <span v-else-if="event.is_simulation" class="pv-chip pv-chip-sim" data-testid="sim-badge">SIM</span>
    </header>

    <!-- Header: which event, when, its state, my role -->
    <header v-if="!native" class="ev-head">
      <div class="ev-head-inner">
        <div class="flex-grow-1" style="min-width: 0">
          <RouterLink to="/events" class="ev-back" data-testid="back-to-events">← My events</RouterLink>
          <h1 class="ev-title" data-testid="event-name">{{ event.name }}</h1>
          <div class="ev-meta mt-1">
            <span v-if="isLive" class="ev-chip ev-chip-live" data-testid="head-live">● LIVE</span>
            <span v-else-if="scheduledStart" class="ev-chip ev-chip-sched">Starts {{ formatDayTime(scheduledStart) }}</span>
            <span v-else class="ev-chip ev-chip-off">Not live</span>
            <span v-if="event.is_simulation" class="ev-chip ev-chip-sim" data-testid="sim-badge">SIMULATION</span>
            <span v-if="event.starts_at || event.venue" data-testid="event-when">
              <template v-if="event.starts_at">{{ formatDayTime(event.starts_at) }} – {{ formatDayTime(event.ends_at) }}</template>
              <template v-if="event.starts_at && event.venue"> · </template>
              <template v-if="event.venue">{{ event.venue }}</template>
            </span>
            <!-- One event badge (highest role) + one group badge ("Group A: Admin, IC") -->
            <span class="ev-chip ev-chip-role" data-testid="event-role-badge">{{ ROLE_LABEL[topRole(me)] || 'Member' }}</span>
            <span v-if="isMarshal(me)" class="ev-chip ev-chip-role" data-testid="event-marshal-badge">Marshal</span>
            <span v-if="myGroup" class="ev-chip ev-chip-role" data-testid="group-role-badge">
              {{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}
            </span>
          </div>
          <p v-if="event.description" class="ev-desc">{{ event.description }}</p>
        </div>
      </div>
    </header>

    <div class="ev-body">
      <!-- Every page of the event, always in view -->
      <nav v-if="!native" class="ev-nav" aria-label="Event pages">
        <ul>
          <li v-for="p in pages" :key="p.key">
            <RouterLink
              class="ev-nav-btn"
              :aria-current="tab === p.key ? 'page' : undefined"
              :to="{ name: 'event', params: { id, page: p.key } }"
              replace
              :data-testid="'tab-' + p.key"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path v-for="(d, i) in ICONS[p.key]" :key="i" :d="d" />
              </svg>
              <span class="ev-nav-text">
                <span>{{ p.label }}</span>
                <span class="ev-nav-hint">{{ p.hint }}</span>
              </span>
              <span v-if="p.badge" class="ev-nav-badge" :class="{ 'ev-nav-badge-live': p.badgeLive }">{{ p.badge }}</span>
            </RouterLink>
          </li>
        </ul>
      </nav>

      <section class="ev-main" :class="{ 'pv-has-tabs': native }" :aria-label="currentPage.label">
        <!-- The event's state and the Start / Schedule / End / Share controls: on every page (phone: on Ops, and on Now for ICs) -->
        <EventStatus v-if="!native || tab === 'ops' || (tab === 'now' && isIC)" :sessions="sessions" :event-id="id" :can-manage="canManage" :ic-count="icCount" :sharing-count="sharingCount"
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

        <div v-if="event.is_simulation && (!native || tab === 'ops')" class="alert alert-warning py-2 small mb-0" data-testid="sim-banner">
          <strong>Simulation event.</strong> Groups named SIM-… and their ICs are virtual: the server moves them every 10 s
          to test zones and alerts at scale. Nothing here is a real person.
        </div>

        <div v-if="isIC && scheduledStart && tracker.isNative && !exactAllowed" class="alert alert-light border py-2 small mb-0">
          We'll remind you to share at the start time. For an on-time reminder, allow alarms for this app.
          <button class="btn btn-sm btn-outline-primary ms-1" @click="allowExact">Allow alarms</button>
        </div>

        <!-- I (an IC) am inside a No-Go area right now -->
        <div v-if="myNoGo.length" class="alert alert-danger py-2 mb-0" role="alert" data-testid="my-no-go">
          <strong>You are inside a No-Go area:</strong> {{ myNoGo.map((z) => z.name).join(', ') }}. Please leave it now.
        </div>

        <!-- A message from the planners to many groups at once (032): stays until Got it -->
        <BroadcastBanner :broadcasts="broadcasts" />

        <!-- A message from the planners to my group (merger Stage 7) -->
        <div
          v-if="groupMessages.latest.value && closedMessage !== groupMessages.latest.value.id"
          class="alert alert-warning py-2 d-flex align-items-start gap-2 mb-0"
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

        <SharingWarnings v-if="sharingHere" />
        <BenchAlert v-if="shareError" data-testid="share-error" @dismiss="shareError = ''">{{ shareError }}</BenchAlert>
        <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

        <!-- The page's title and what it is for -->
        <div v-if="!native" class="ev-page-head">
          <h2>{{ currentPage.label }}</h2>
          <p data-testid="view-scope">{{ currentPage.about }}</p>
        </div>

        <!-- ===== Live map: v-show keeps the map (and its live connection) alive on the other pages ===== -->
        <div v-show="tab === 'live'">
          <div class="d-flex flex-column gap-3">
          <!-- Members of a group without the whole-show view: their next move comes first -->
          <NextMoveCard
            v-if="!native && liveSession && myGroup && !show.board.value"
            ref="nextMoveEl"
            class="mb-0"
            :moves="myMoves"
            :my-position="myPosition"
            :sharing="sharingHere"
            @stop-sharing="tracker.stop()"
            @share="startSharing"
          />
          <ShowBar v-if="!native && show.board.value" :show="show" :event-name="event.name" />
          <BroadcastPanel v-if="!native && canManage" :broadcasts="broadcasts" :groups="groups" :show="show" :can-run="canManage" />
          <OpsSummary v-if="!native && hasOps" class="mb-0" :ops="ops" />
          <OpsDecision v-if="!native && show.board.value" :show="show" :ops="ops" :groups="groups" :can-run="canManage" />
          <div :class="native ? 'ev-map-phone' : show.board.value ? 'ev-live' : 'ev-map-only'">
            <div style="min-width: 0">
              <LiveMap
                ref="liveMap"
                :active="tab === 'live'"
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
            <div v-if="!native && show.board.value" class="ev-live-side">
              <ShowPanel :show="show" :can-run="canManage" :ops="hasOps ? ops : null" />
              <OpsQueue v-if="hasOps" class="mb-0" :ops="ops" :now="show.now.value" @select="focusGroup" />
            </div>
          </div>
          <!-- A planner who is also in a group: the show first, their own next move under it -->
          <NextMoveCard
            v-if="!native && liveSession && myGroup && show.board.value"
            ref="nextMoveEl2"
            class="mb-0"
            :moves="myMoves"
            :my-position="myPosition"
            :sharing="sharingHere"
            @stop-sharing="tracker.stop()"
            @share="startSharing"
          />
          </div>
        </div>

        <!-- ===== Phone app pages (the website shows these on the Live map page) ===== -->
        <!-- Now: an IC's or member's next move, one big card -->
        <template v-if="native && tab === 'now'">
          <NextMoveCard
            v-if="liveSession && myGroup && (myMoves.next.value || myMoves.after.value.length)"
            ref="nextMoveEl"
            class="mb-0"
            ring
            :moves="myMoves"
            :my-position="myPosition"
            :sharing="sharingHere"
            @stop-sharing="tracker.stop()"
            @share="startSharing"
          />
          <div v-else class="pv-empty" data-testid="now-empty">
            <strong>{{ !liveSession ? (scheduledStart ? 'Starts ' + formatDayTime(scheduledStart) : 'Not started yet') : !myGroup ? 'You are not in a group yet' : 'Nothing to do right now' }}</strong>
            <span>{{ !liveSession ? 'When a planner starts the event, your next move shows here.' : !myGroup ? 'Ask the root, a planner or a group admin to add you to a group.' : 'When it is time to move you get a push, and the move shows here.' }}</span>
          </div>
        </template>

        <!-- Ops: the live show, the groups at a glance and what needs attention -->
        <template v-if="native && tab === 'ops'">
          <ShowBar v-if="show.board.value" :show="show" :event-name="event.name" />
          <BroadcastPanel v-if="canManage" native :broadcasts="broadcasts" :groups="groups" :show="show" :can-run="canManage" />
          <OpsDecision v-if="show.board.value" :show="show" :ops="ops" :groups="groups" :can-run="canManage" />
          <ShowPanel v-if="show.board.value" :show="show" :can-run="canManage" :ops="hasOps ? ops : null" />
          <OpsSummary v-if="hasOps" class="mb-0" :ops="ops" />
          <OpsQueue v-if="hasOps" class="mb-0" :ops="ops" :now="show.now.value" @select="focusGroup" />
          <div v-if="!show.board.value" class="pv-empty" data-testid="ops-empty">
            <strong>No show running</strong>
            <span>{{ isLive ? 'The event is live without a run sheet: the map shows where everyone is.' : 'Start the event with a Ready run sheet to run the show from here.' }}</span>
          </div>
          <NextMoveCard
            v-if="liveSession && myGroup && show.board.value"
            ref="nextMoveEl2"
            class="mb-0"
            :moves="myMoves"
            :my-position="myPosition"
            :sharing="sharingHere"
            @stop-sharing="tracker.stop()"
            @share="startSharing"
          />
        </template>

        <EventOverview
          v-if="tab === 'overview'"
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
          v-if="tab === 'groups'"
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
          v-if="tab === 'people'"
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
          v-show="tab === 'playback'"
          :active="tab === 'playback'"
          :event-id="id"
          :event-name="event.name"
          :members="members"
          @go-live="goLive"
        />

        <!-- Map: root / planners edit the zones (v-if: the bench holds locks and a presence row only while it is open) -->
        <template v-if="canManage && tab === 'map'">
          <ZoneOverview :event-id="id" />
          <div class="ev-surface">
            <PolygonTestView :event-id="id" embedded />
          </div>
        </template>

        <!-- Timeline: the run sheet (root / planners edit, marshals read) -->
        <RunSheetPanel
          v-if="seesWholeEvent && tab === 'timeline'"
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
          v-if="(tab === 'map' && !canManage) || (tab === 'timeline' && !seesWholeEvent)"
          :page="tab"
          :mode="modeOf(tab)"
          :role="role"
          :group="myGroup"
          :is-live="isLive"
          :scheduled-start="scheduledStart"
        />

        <SimulatorPanel v-if="event.is_simulation && isRoot && tab === 'simulator'" :event-id="id" @changed="load" />
      </section>
    </div>

    <!-- Phone app: bottom tabs that follow the role, and the More sheet for the rest -->
    <PhoneTabBar v-if="native" :items="nativeTabs" :active="activeTab" @select="selectTab" />
    <BottomSheet v-if="native" :open="moreOpen" title="More" @close="moreOpen = false">
      <div class="d-grid gap-2" data-testid="more-sheet">
        <button v-for="p in morePages" :key="p.key" type="button" class="pv-more-row" :data-testid="'more-' + p.key" @click="openMore(p.key)">
          <span class="flex-grow-1 text-start">
            <strong class="d-block">{{ p.label }}</strong>
            <span class="small text-muted">{{ p.hint }}</span>
          </span>
          <span aria-hidden="true" class="pv-chev">›</span>
        </button>
      </div>
    </BottomSheet>
  </div>
</template>
