<script setup>
// One event: status (live or not), live map, members & groups, invite, and playback
// (root / planners). What you see depends on your role.
import { ref, computed, watch, nextTick } from 'vue'
import { RouterLink, useRouter, useRoute } from 'vue-router'
import { supabase } from '../lib/supabase'
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
import { eventRoleLabel, groupRoleLabel } from '../utils/people'
import SharingWarnings from '../components/SharingWarnings.vue'
import EventStatus from '../components/EventStatus.vue'
import LiveMap from '../components/LiveMap.vue'
import MembersPanel from '../components/MembersPanel.vue'
import InvitePanel from '../components/InvitePanel.vue'
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
import PhoneTabBar from '../components/PhoneTabBar.vue'
import BottomSheet from '../components/BottomSheet.vue'
import { isNativeApp } from '../lib/platform'
import { useMyMoves } from '../composables/useMyMoves'

const props = defineProps({ id: { type: String, required: true } })
const auth = useAuthStore()
const router = useRouter()
const route = useRoute()

const { event, groups, members, loading, errorMsg, load, me, myRoles, isRoot, canManage, seesWholeEvent, myGroup } =
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
  if (isNativeApp && tab.value !== 'map') {
    tab.value = 'map'
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

// The No-Go areas I am inside right now (shown to me as a warning until I leave).
const myNoGo = computed(() => {
  const mine = auth.user ? zoneActivity.staysByUser.value[auth.user.id] || [] : []
  return mine.filter((s) => s.zone.kind === 'no_go').map((s) => s.zone)
})

// Latest positions (one connection for the map and the "Not sharing yet" badges)
const live = useLiveLocations(props.id)

// The page shown: 'map' | 'runsheet' | 'zones' | 'members' | 'invite' | 'playback' | 'simulator'. Kept in the address
// (?tab=runsheet) so Back, a reload and a shared link open the same page.
const tab = ref(typeof route.query.tab === 'string' ? route.query.tab : 'map')
watch(tab, (t) => {
  if ((route.query.tab || 'map') === t) return
  const query = { ...route.query }
  if (t === 'map') delete query.tab
  else query.tab = t
  router.replace({ query })
})
watch(
  () => route.query.tab,
  (q) => {
    const t = typeof q === 'string' ? q : 'map'
    if (t !== tab.value) tab.value = t
  },
)

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
    tab.value = isNativeApp ? 'now' : 'map'
    router.replace({ query: {} })
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
      router.replace({ query: {} })
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
  tab.value = isNativeApp ? homeTab.value : 'map'
}

// ---------- The event's pages (side navigation): every one in view, with what it is for ----------
const ICONS = {
  map: ['M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11z', 'M12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z'],
  runsheet: ['M9 6h12', 'M9 12h12', 'M9 18h12', 'M4 6h.01', 'M4 12h.01', 'M4 18h.01'],
  zones: ['M12 3l8 5v8l-8 5-8-5V8z'],
  members: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z', 'M22 21v-2a4 4 0 0 0-3-3.87', 'M16 3.13a4 4 0 0 1 0 7.75'],
  invite: ['M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71', 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71'],
  playback: ['M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z', 'M10 8l6 4-6 4z'],
  simulator: ['M9 3h6', 'M10 3v6l-5 9a2 2 0 0 0 1.7 3h10.6a2 2 0 0 0 1.7-3l-5-9V3'],
}
const pages = computed(() => {
  const ev = event.value
  return [
    {
      key: 'map',
      label: 'Live map',
      hint: show.board.value ? 'The show is running' : isLive.value ? 'Live now' : 'Where everyone is',
      badge: isLive.value ? 'LIVE' : '',
      badgeLive: true,
      about: viewText.value,
    },
    seesWholeEvent.value && {
      key: 'runsheet',
      label: 'Run sheet',
      hint: "The show's timeline",
      about: "The show's running order: cues with their times, and where each group must be by when. Make a version, " +
        'check it, mark it Ready, then pick it when you start the event.',
    },
    canManage.value && {
      key: 'zones',
      label: 'Zones',
      hint: 'Areas, doors, No-Go',
      about: 'The places groups must reach (formations, holding areas, doors) and No-Go areas. Each gets a code the run ' +
        'sheet uses, and everyone sees them on the live map.',
    },
    {
      key: 'members',
      label: 'Members',
      hint: 'People, groups, roles',
      badge: members.value.length,
      about: "Who is in the event, their roles and their groups. A group's IC shares its location.",
    },
    { key: 'invite', label: 'Invite', hint: 'Code and link', about: 'Share the join code or link: people who join become members.' },
    canManage.value && { key: 'playback', label: 'Playback', hint: 'Replay a session', about: 'Replay a past session of this event, or export it.' },
    ev && ev.is_simulation && isRoot.value && {
      key: 'simulator',
      label: 'Simulator',
      hint: 'Virtual groups',
      about: 'Virtual groups that the server moves, to test zones, alerts and the show at scale.',
    },
  ].filter(Boolean)
})
const currentPage = computed(() => pages.value.find((p) => p.key === tab.value) || pages.value[0])

// ---------- Phone app (Android first): bottom tabs that follow the role (Figma "Phone app — native prototype") ----------
// ICs and members: Now · Map · Group · Info. Root, planners and marshals: Ops · Map · Run sheet · People · More, with
// the rest (zones, invite, playback, simulator, event info) in the More sheet. Same pages and data as the website.
const native = isNativeApp
const homeTab = computed(() => (seesWholeEvent.value ? 'ops' : 'now'))
const nativeTabs = computed(() =>
  seesWholeEvent.value
    ? [
        { key: 'ops', label: 'Ops', icon: 'ops', dot: !!show.board.value },
        { key: 'map', label: 'Map', icon: 'map' },
        { key: 'runsheet', label: 'Run sheet', icon: 'runsheet' },
        { key: 'members', label: 'People', icon: 'group' },
        { key: 'more', label: 'More', icon: 'more' },
      ]
    : [
        { key: 'now', label: 'Now', icon: 'now', dot: isLive.value },
        { key: 'map', label: 'Map', icon: 'map' },
        { key: 'members', label: 'Group', icon: 'group' },
        { key: 'info', label: 'Info', icon: 'info' },
      ],
)
const morePages = computed(() =>
  seesWholeEvent.value
    ? [
        canManage.value && { key: 'zones', label: 'Zones', hint: 'Areas, doors and No-Go areas' },
        { key: 'invite', label: 'Invite', hint: 'Join code, link and QR' },
        canManage.value && { key: 'playback', label: 'Playback', hint: 'Replay a past session' },
        event.value && event.value.is_simulation && isRoot.value && { key: 'simulator', label: 'Simulator', hint: 'Virtual groups' },
        { key: 'info', label: 'Event info', hint: 'Details, and leave the event' },
      ].filter(Boolean)
    : [],
)
const moreOpen = ref(false)
const activeTab = computed(() => (morePages.value.some((p) => p.key === tab.value) ? 'more' : tab.value))
function selectTab(key) {
  if (key === 'more') {
    moreOpen.value = true
    return
  }
  tab.value = key
  window.scrollTo(0, 0)
}
function openMore(key) {
  moreOpen.value = false
  tab.value = key
  window.scrollTo(0, 0)
}
// The phone opens an event on its home tab (Now or Ops) unless the address asks for another page
watch(
  loading,
  (isLoading) => {
    if (native && !isLoading && event.value && !route.query.tab && tab.value === 'map') tab.value = homeTab.value
  },
  { immediate: true },
)
// On a phone the pages are one scrolling row: keep the open one in view (centred, without moving the page itself)
function showCurrentInNav() {
  nextTick(() => {
    const nav = document.querySelector('.ev-nav')
    const btn = nav && nav.querySelector('[aria-current="page"]')
    if (nav && btn && nav.scrollWidth > nav.clientWidth) nav.scrollLeft = btn.offsetLeft - (nav.clientWidth - btn.offsetWidth) / 2
  })
}
watch([tab, loading], showCurrentInNav)
// A page this person cannot open (an old link, a role taken away): the live map
watch([pages, loading], ([list, isLoading]) => {
  if (isLoading || !event.value) return
  const allowed = native ? [...nativeTabs.value, ...morePages.value].map((p) => p.key).filter((k) => k !== 'more') : list.map((p) => p.key)
  if (!allowed.includes(tab.value)) tab.value = native ? homeTab.value : 'map'
})

async function leaveEvent() {
  if (!(await askConfirm({ title: 'Leave this event?', confirmText: 'Leave', danger: true }))) return
  if (sharingHere.value) await tracker.stop() // stop sharing before leaving
  const { error } = await supabase.rpc('remove_member', { p_event_id: props.id, p_user_id: auth.user.id })
  if (error) errorMsg.value = error.message
  else router.push('/events')
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
          {{ eventRoleLabel(myRoles) }}<template v-if="myGroup"> · {{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}</template>
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
            <span class="ev-chip ev-chip-role" data-testid="event-role-badge">{{ eventRoleLabel(myRoles) }}</span>
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
            <button
              type="button"
              class="ev-nav-btn"
              :aria-current="tab === p.key ? 'page' : undefined"
              :data-testid="'tab-' + p.key"
              @click="tab = p.key"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path v-for="(d, i) in ICONS[p.key]" :key="i" :d="d" />
              </svg>
              <span class="ev-nav-text">
                <span>{{ p.label }}</span>
                <span class="ev-nav-hint">{{ p.hint }}</span>
              </span>
              <span v-if="p.badge" class="ev-nav-badge" :class="{ 'ev-nav-badge-live': p.badgeLive }">{{ p.badge }}</span>
            </button>
          </li>
        </ul>
        <div v-if="me && !isRoot" class="ev-nav-foot">
          <button type="button" class="btn btn-link btn-sm text-danger p-0" @click="leaveEvent">Leave event</button>
        </div>
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
        <div v-show="tab === 'map'">
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
          <OpsSummary v-if="!native && hasOps" class="mb-0" :ops="ops" />
          <OpsDecision v-if="!native && show.board.value" :show="show" :ops="ops" :groups="groups" :can-run="canManage" />
          <div :class="native ? 'ev-map-phone' : show.board.value ? 'ev-live' : 'ev-map-only'">
            <div style="min-width: 0">
              <LiveMap
                ref="liveMap"
                :active="tab === 'map'"
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

        <!-- Info: when and where, the invite code, leaving -->
        <template v-if="native && tab === 'info'">
          <section class="pv-card" data-testid="event-info">
            <h2 class="pv-label mb-2">Event</h2>
            <p class="fs-5 fw-semibold mb-1">{{ event.name }}</p>
            <p v-if="event.starts_at" class="mb-1">{{ formatDayTime(event.starts_at) }} – {{ formatDayTime(event.ends_at) }}</p>
            <p v-if="event.venue" class="mb-1">{{ event.venue }}</p>
            <p v-if="event.description" class="text-muted mb-0" style="white-space: pre-line">{{ event.description }}</p>
            <p class="text-muted small mb-0 mt-2">{{ viewText }}</p>
          </section>
          <InvitePanel v-if="!seesWholeEvent" :event-name="event.name" :join-code="event.join_code" />
          <button v-if="me && !isRoot" type="button" class="btn btn-outline-danger w-100" @click="leaveEvent">Leave event</button>
        </template>

        <MembersPanel
          v-if="tab === 'members'"
          :event-id="id"
          :members="members"
          :groups="groups"
          :me="me"
          :is-root="isRoot"
          :can-manage="canManage"
          :sharing-status="sharingStatus"
          @changed="load"
        />

        <InvitePanel v-if="tab === 'invite'" :event-name="event.name" :join-code="event.join_code" />

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

        <!-- v-if: the bench holds locks and a presence row only while it is open -->
        <template v-if="canManage && tab === 'zones'">
          <ZoneOverview :event-id="id" />
          <div class="ev-surface">
            <PolygonTestView :event-id="id" embedded />
          </div>
        </template>

        <RunSheetPanel
          v-if="seesWholeEvent && tab === 'runsheet'"
          :event-id="id"
          :can-edit="canManage"
          :list="runSheets"
          :groups="groups"
          :live-session="liveSession"
          :event-name="event.name"
          :planned-day="event.starts_at ? sgtIso(new Date(event.starts_at)).slice(0, 10) : ''"
          :members="members"
          @changed="load"
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
