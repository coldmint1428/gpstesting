<script setup>
// One event: status (live or not) and its pages (/events/:id/<page>): overview, live, timeline, map, groups, people,
// attendance, playback, simulator. Which pages and controls you get depends on your role (src/utils/permissions.js).
// The run-sheet half of this page -- the classic editor, the live show's bar and panel, the ops queue, the member's
// next-move card and the group message -- was deleted in step 25 with the engine that fed it.
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
import { formatDayTime, formatTimeSeconds } from '../utils/time'
import { groupRoleLabel } from '../utils/people'
import { PAGES, PAGE_LABEL, ROLE_LABEL, topRole, isMarshal, viewRole, canView, pageMode } from '../utils/permissions'
import { leaveEvent as leaveEventCall, fetchMembership, rememberMembership, updateEventDetails, deleteEvent } from '../services/memberService'
import { isNativeApp } from '../lib/platform'
import PeoplePanel from '../components/PeoplePanel.vue'
import EventOverview from '../components/EventOverview.vue'
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
import PlanRoute from '../components/plan/PlanRoute.vue'
import PlanOps from '../components/plan/PlanOps.vue'
import { usePlan } from '../composables/usePlan'
import { useBroadcasts } from '../composables/useBroadcasts'
import BroadcastBanner from '../components/BroadcastBanner.vue'
import BroadcastPanel from '../components/BroadcastPanel.vue'
import AttendancePanel from '../components/AttendancePanel.vue'
import { useAttendance } from '../composables/useAttendance'
import SosDialog from '../components/SosDialog.vue'
import SosBanner from '../components/SosBanner.vue'
import { useSos } from '../composables/useSos'
import PhoneTabBar from '../components/PhoneTabBar.vue'
import BottomSheet from '../components/BottomSheet.vue'
import SkeletonLoader from '../components/SkeletonLoader.vue'
import { providePageReady } from '../composables/usePageReady'

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
// One skeleton until the whole page has its data (usePageReady): the event, its sessions, the plans list and every
// panel on screen. The page is built out of sight meanwhile, then fades in once instead of panel by panel.
const pageGate = providePageReady()
const pageReady = pageGate.ready
pageGate.watch(() => !sessions.loaded.value)
pageGate.watch(() => seesWholeEvent.value && !plansReady.value)
watch(
  loading,
  (isLoading) => {
    if (!isLoading) nextTick(() => pageGate.arm())
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
// Attendance (071): roll calls taken by the IC by hand, or (QR mode, chosen by the organisers) by everyone scanning
// a QR on the IC's screen that changes every 5 s. A QR roll call opening for my group shows a banner (and a toast)
// until I have scanned. The Attendance page emits what was asked; it is done here.
const amGroupRunner = computed(() => !!(me.value && (me.value.isIC || me.value.isAdmin)))
const attendance = useAttendance(
  computed(() => props.id),
  {
    myUserIdRef: computed(() => (auth.user ? auth.user.id : null)),
    myGroupIdRef: computed(() => (myGroup.value ? myGroup.value.id : null)),
    onOpened(r) {
      if (amGroupRunner.value || r.mode !== 'qr') return // they run it / the IC marks by hand: nothing for me to do
      toast('Roll call open: ' + r.title + '. Scan the QR code on your IC’s screen.', 'info', 10000)
    },
  },
)
const attError = ref('')
const scanMessage = ref('')
// The banner: a QR roll call for my group I have not scanned yet (not for its ICs and admins), off the Attendance page
const showAttendanceBanner = computed(
  () =>
    !!attendance.myOpen.value &&
    attendance.myOpen.value.mode === 'qr' &&
    !attendance.myCheckin.value &&
    !amGroupRunner.value &&
    tab.value !== 'attendance',
)
async function onAttSetMode(mode) {
  attError.value = await attendance.setMode(mode)
  if (!attError.value) toast(mode === 'qr' ? 'New roll calls use a QR code.' : 'New roll calls are marked by hand.', 'success', 4000)
}
async function onAttOpen({ groupId, title, minutes }) {
  attError.value = await attendance.open(groupId, title, minutes)
  if (!attError.value) {
    toast(attendance.mode.value === 'qr' ? 'Roll call started. Show the QR code to your group.' : 'Roll call started. Tick who is there.', 'success', 4000)
  }
}
async function onAttClose(id) {
  const ok = await askConfirm({
    title: 'Close this roll call?',
    message: 'No one can check in after this. Anyone not marked is absent.',
    confirmText: 'Close roll call',
  })
  if (ok) attError.value = await attendance.close(id)
}
async function onAttMark({ id, userId, status }) {
  attError.value = await attendance.mark(id, userId, status)
}
async function onAttScan(text) {
  scanMessage.value = ''
  const result = await attendance.scan(text)
  if (result.ok) toast('You are marked present for ' + result.title + '.', 'success', 4000)
  else scanMessage.value = result.message
}

// SOS (072): anyone in the event can call for help. Everyone sees it as a banner on every page and on the map, with a
// toast (and a vibration on phones) when it arrives. The banner and dialog emit what was pressed; it is done here.
const sos = useSos(
  computed(() => props.id),
  {
    myUserIdRef: computed(() => (auth.user ? auth.user.id : null)),
    onNew(a) {
      const who = members.value.find((m) => m.id === a.userId)
      toast('SOS: ' + (who ? who.display_name : 'Someone') + ' needs help.' + (a.note ? ' "' + a.note + '"' : ''), 'danger', 15000)
      if (navigator.vibrate) navigator.vibrate([400, 150, 400])
    },
  },
)
const sosDialogOpen = ref(false)
async function onSosSend(note) {
  const message = await sos.raise(note)
  if (message) {
    toast('The SOS was not sent: ' + message, 'danger', 10000)
    return
  }
  sosDialogOpen.value = false
  toast('SOS sent. Everyone in this event has been alerted.', 'danger', 6000)
}
async function onSosHelp(id) {
  const message = await sos.help(id)
  if (message) toast(message, 'danger')
  else toast('They have been told you are on the way.', 'success', 4000)
}
async function onSosResolve(id) {
  const own = sos.mine.value && sos.mine.value.id === id
  const ok = await askConfirm(
    own
      ? { title: 'End your SOS?', message: 'Your location stops being sent. Everyone sees that you are safe.', confirmText: "I'm safe" }
      : { title: 'Mark this SOS handled?', message: 'The SOS ends for everyone.', confirmText: 'Mark handled' },
  )
  if (!ok) return
  const message = await sos.resolve(id)
  if (message) toast(message, 'danger')
}
// The SOSs the map draws (the ones with a location)
const sosOnMap = computed(() =>
  sos.alerts.value
    .filter((a) => a.lat != null)
    .map((a) => {
      const who = members.value.find((m) => m.id === a.userId)
      return { id: a.id, lat: a.lat, lng: a.lng, accuracy: a.accuracy, note: a.note, raisedAt: a.raisedAt, name: who ? who.display_name : 'Someone' }
    }),
)
// "Show on map": the live map, zoomed to the SOS
function showSos(id) {
  openPage('live')
  setTimeout(() => liveMap.value && liveMap.value.focusSos(id), 300)
}
// Opened from an SOS notification (?sos=<id>): show it once it has loaded
watch(
  [() => route.query.sos, () => sosOnMap.value.length],
  ([id]) => {
    if (id && sosOnMap.value.some((s) => String(s.id) === String(id))) {
      showSos(Number(id))
      router.replace({ query: { ...route.query, sos: undefined } })
    }
  },
)


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
// Phone app only: Now (an IC's or member's own schedule) and Ops (the plan's live walk) are tabs, not website pages
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
// member's own moments live on the Schedule page now (step 16), so that is where the push lands. On the phone that
// is the home tab (Now shows the same schedule; Ops for root / planners / marshals).
watch(
  () => route.query.next,
  (wanted) => {
    if (wanted !== '1') return
    if (isNativeApp) phoneTab.value = homeTab.value
    else goToPage('timeline')
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

// The status card (Start / Schedule / End, and an IC's Share): website, for the root and planners on the pages they
// run the event from, and for ICs on the overview and live pages; phone, on Ops (and on Now for ICs)
const showStatusCard = computed(() => {
  if (native) return tab.value === 'ops' || (tab.value === 'now' && isIC.value)
  if (canManage.value) return ['overview', 'live', 'timeline'].includes(tab.value)
  return isIC.value && ['overview', 'live'].includes(tab.value)
})

// Text under the title explaining what this person sees on the map
const viewText = computed(() => {
  if (seesWholeEvent.value) return 'You can see every group in this event.'
  if (myGroup.value) return 'You can see your group: ' + myGroup.value.name + '.'
  return 'You are not in a group. Ask a planner or a group admin to add you.'
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
  attendance: ['M9 11l3 3L22 4', 'M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11'],
}
const PAGE_INFO = computed(() => ({
  overview: {
    hint: 'When, where, invite',
    about: 'What the event is, when and where it happens, and how people join.',
  },
  timeline:
    modeOf('timeline') === 'edit'
      ? {
          hint: 'The plan board',
          about: "The plan: each group's moments on one clock and where it must be by when. Pick a plan when you " +
            'start the event.',
        }
      : {
          hint: 'Your timetable',
          about: seesWholeEvent.value ? "Every group's moments on the plan's clock." : "Your group's moments on the plan's clock.",
        },
  map: canManage.value
    ? {
        hint: 'Areas, doors, No-Go',
        about: 'The places groups must reach (formations, holding areas, doors) and No-Go areas. Each gets a code the ' +
          'plan uses, and everyone sees them on the live map.',
      }
    : { hint: 'Your route', about: "Where your group walks on the plan, and when it is due at each place." },
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
    hint: planSession.value ? 'The plan is running' : isLive.value ? 'Live now' : 'Where everyone is',
    badge: isLive.value ? 'LIVE' : '',
    badgeLive: true,
    about: viewText.value,
  },
  playback: { hint: 'Replay a session', about: 'Replay a past session of this event, or export it.' },
  simulator: { hint: 'Virtual groups', about: 'Virtual groups that the server moves, to test zones, alerts and the plan at scale.' },
  attendance: {
    hint: 'Roll calls',
    badge: showAttendanceBanner.value ? 'OPEN' : '',
    badgeLive: true,
    about: 'Take attendance by group. The IC ticks who is there, or everyone scans a QR code on the IC’s screen.',
  },
}))
const pages = computed(() => visiblePages.value.map((key) => ({ key, label: pageLabel(key), ...PAGE_INFO.value[key] })))
const currentPage = computed(() => pages.value.find((p) => p.key === tab.value) || { label: event.value ? event.value.name : '' })

// ---------- Phone app (Android first): bottom tabs that follow the role (Figma "Phone app — native prototype") ----------
// ICs and members: Now · Map · Group · Info. Root, planners and marshals: Ops · Map · Timeline · People · More. Every
// other page my role may view is in the More sheet. Same pages and data as the website.
const homeTab = computed(() => (seesWholeEvent.value ? 'ops' : 'now'))
const nativeTabs = computed(() => {
  const tabs = seesWholeEvent.value
    ? [
        { key: 'ops', label: 'Ops', icon: 'ops', dot: planSession.value },
        { key: 'live', label: 'Map', icon: 'map' },
        { key: 'timeline', label: pageLabel('timeline'), icon: 'timeline' },
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
const MORE_HINT = computed(() => ({
  overview: 'Details, invite, and leave the event',
  timeline: modeOf('timeline') === 'edit' ? 'The plan board' : 'Your timetable',
  map: canManage.value ? 'Areas, doors and No-Go areas' : 'Your route on the plan',
  people: 'Who is in it, roles',
  groups: 'Groups and their ICs',
  attendance: 'Roll calls',
  playback: 'Replay a past session',
  simulator: 'Virtual groups',
}))
const morePages = computed(() => {
  const inBar = seesWholeEvent.value ? ['live', 'timeline', 'people'] : ['live', 'groups', 'overview']
  return visiblePages.value
    .filter((p) => !inBar.includes(p))
    .map((key) => ({ key, label: key === 'overview' ? 'Event info' : pageLabel(key), hint: MORE_HINT.value[key] }))
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
// Changing page from the side menu (or a phone tab): the new page's content rises into place instead of
// appearing at once. The pages are siblings in one section, and the live map stays mounted (v-show), so rather than
// rebuilding the section this animates whatever is on screen from the page's heading down. The event's state bar
// above the heading is the same on every page and stays still.
const mainEl = ref(null)
const reduceMotion = typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
watch(
  tab,
  (now, before) => {
    if (!before || now === before || reduceMotion) return
    nextTick(() => {
      const main = mainEl.value
      if (!main || typeof main.animate !== 'function') return
      const kids = [...main.children]
      const head = main.querySelector(':scope > .ev-page-head')
      const from = head ? kids.indexOf(head) : 0
      kids.slice(from).forEach((el, i) => {
        if (!el.getClientRects().length) return // a page hidden by v-show
        el.animate(
          // The phone app fades only: its tab bar, sheets and button are fixed to the screen inside this section,
          // and moving their parent would carry them along for a moment.
          native ? [{ opacity: 0 }, { opacity: 1 }] : [
            { opacity: 0, transform: 'translateY(8px)' },
            { opacity: 1, transform: 'none' },
          ],
          { duration: 220, delay: Math.min(i, 3) * 30, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)', fill: 'backwards' },
        )
      })
    })
  },
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
  <SkeletonLoader v-if="loading || (event && !pageReady)" variant="event" label="Loading the event…" />
  <div v-if="!loading && !event" class="container py-3">
    <div class="alert alert-danger" role="alert">
      {{ errorMsg || 'Event not found.' }}
      <div class="mt-2"><RouterLink to="/events">Back to my events</RouterLink></div>
    </div>
  </div>

  <!-- Built while the skeleton shows (so every panel can fetch its data), shown in one go when all of it is in -->
  <div v-if="!loading && event" class="ev" :class="{ 'ev-native': native, 'is-gathering': !pageReady, 'data-in': pageReady }" :aria-hidden="pageReady ? null : 'true'">
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
      <span v-if="isLive" class="pv-chip pv-chip-live" data-testid="head-live">LIVE</span>
      <span v-else-if="event.is_simulation" class="pv-chip pv-chip-sim" data-testid="sim-badge">SIM</span>
      <button type="button" class="btn btn-danger btn-sm sos-btn flex-shrink-0" data-testid="sos-btn" @click="sosDialogOpen = true">SOS</button>
    </header>

    <!-- Which event and its state, in the site's top bar (one bar, as in the design) -->
    <Teleport v-if="!native" to="#k-nav-context">
      <div class="ks-ev">
        <RouterLink to="/events" class="ks-crumb" data-testid="back-to-events"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m15 18-6-6 6-6"></path></svg>Events</RouterLink>
        <h1 class="k-ev-name text-truncate" data-testid="event-name">{{ event.name }}</h1>
        <span v-if="isLive" class="chip chip-ink ks-hide-m" data-testid="head-live"><i class="dot pulse" style="background: var(--lime)"></i>Live</span>
        <span v-else-if="scheduledStart" class="chip chip-mint ks-hide-m">Starts {{ formatDayTime(scheduledStart) }}</span>
        <span v-else class="chip chip-soft ks-hide-m">Not live</span>
        <span v-if="event.is_simulation" class="chip rl-sim ks-hide-m" data-testid="sim-badge">Sim</span>
      </div>
    </Teleport>
    <Teleport v-if="!native" to="#k-nav-actions">
      <button type="button" class="kb kb-sm k-sos sos-btn" data-testid="sos-btn" @click="sosDialogOpen = true">SOS</button>
    </Teleport>

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
              <span class="ev-nav-text">{{ p.label }}</span>
              <span v-if="p.badge" class="ev-nav-badge" :class="{ 'ev-nav-badge-live': p.badgeLive }">{{ p.badge }}</span>
            </RouterLink>
          </li>
        </ul>
        <!-- One event badge (highest role) + one group badge ("Group A: Admin, IC") -->
        <div class="ks-me k-you">
          <span>You</span>
          <div class="k-you-pills">
            <span class="chip" :class="topRole(me) === 'root' ? 'rl-root' : topRole(me) === 'planner' ? 'rl-planner' : 'chip-soft'" data-testid="event-role-badge">{{ ROLE_LABEL[topRole(me)] || 'Member' }}</span>
            <span v-if="isMarshal(me)" class="chip chip-soft" data-testid="event-marshal-badge">Marshal</span>
            <span v-if="myGroup" class="chip" :class="me && me.isIC ? 'rl-ic' : 'chip-soft'" data-testid="group-role-badge">{{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}</span>
          </div>
        </div>
      </nav>

      <section ref="mainEl" class="ev-main" :class="{ 'pv-has-tabs': native }" :aria-label="currentPage.label">
        <!-- SOS (072): first, on every page -->
        <SosBanner
          :alerts="sos.alerts.value"
          :mine="sos.mine.value"
          :gps="sos.gps.value"
          :members="members"
          :groups="groups"
          :me="me"
          :sees-whole-event="seesWholeEvent"
          :now="live.now.value"
          :busy="sos.busy.value"
          @help="onSosHelp"
          @resolve="onSosResolve"
          @show="showSos"
        />

        <!-- The event's state and the Start / Schedule / End / Share controls: on every page (phone: on Ops, and on Now for ICs) -->
        <EventStatus v-if="showStatusCard" :sessions="sessions" :event-id="id" :can-manage="canManage" :ic-count="icCount" :sharing-count="sharingCount"
          :plans="seesWholeEvent ? startPlans.plans.value : []"
          :plans-ready="!seesWholeEvent || plansReady"
          :planned-start="event.starts_at" :planned-end="event.ends_at">
          <!-- Only the group's IC shares, and only while the event is live. One tap starts sharing. -->
          <template v-if="isIC" #sharing>
            <div class="d-flex flex-wrap align-items-center gap-2">
              <span class="kp-status-text">
                <span v-if="sharingHere" class="fw-bold" data-testid="sharing-banner">Sharing your location</span>
                <span v-else-if="isLive" class="text-muted">Location not shared yet</span>
                <span v-else class="text-muted" data-testid="share-locked-text">
                  <template v-if="scheduledStart">Sharing opens {{ formatDayTime(scheduledStart) }}</template>
                  <template v-else>Sharing opens when the event starts</template>
                </span>
              </span>
              <button v-if="sharingHere" class="btn btn-sm btn-outline-secondary" data-testid="stop-share-btn" @click="tracker.stop()">
                Stop sharing
              </button>
              <button v-else-if="isLive" class="btn btn-sm btn-success" data-testid="share-btn" @click="startSharing">
                Share my location
              </button>
              <button v-else class="btn btn-sm btn-success" disabled data-testid="share-btn-locked">Share my location</button>
              <RouterLink :to="{ name: 'share', params: { id } }" class="btn btn-sm btn-ghost" data-testid="share-details-link">
                My GPS
              </RouterLink>
            </div>
          </template>
        </EventStatus>

        <div v-if="event.is_simulation && (native ? tab === 'ops' : tab === 'overview' || tab === 'live')" class="kp-banner" data-testid="sim-banner">
          <span class="kp-banner-text"><strong>Simulation.</strong> SIM- groups are not real people.</span>
        </div>

        <div v-if="isIC && scheduledStart && tracker.isNative && !exactAllowed" class="kp-banner">
          <span class="kp-banner-text">Allow alarms to get your reminder on time.</span>
          <button class="btn btn-sm btn-outline-secondary" @click="allowExact">Allow alarms</button>
        </div>

        <!-- I (an IC) am inside a No-Go area right now -->
        <div v-if="myNoGo.length" class="kp-banner kp-banner-danger" role="alert" data-testid="my-no-go">
          <span class="kp-banner-text"><strong>You are in a No-Go area:</strong> {{ myNoGo.map((z) => z.name).join(', ') }}. Please leave now.</span>
        </div>

        <!-- A message from the planners to many groups at once (032): stays until Got it -->
        <BroadcastBanner :broadcasts="broadcasts" />

        <!-- A message from the planners to my group used to sit here. It was written by the ops board's
             `message_group`, which step 25 deleted with the run sheet engine and which nothing else wrote, so the
             banner that could never receive a message went with it. "Message everyone" (032) is the one left. -->
        <!-- A QR roll call is open for my group and I have not scanned in (071) -->
        <div v-if="showAttendanceBanner" class="kp-banner" role="alert" data-testid="attendance-banner">
          <span class="kp-banner-text"><strong>Roll call open: {{ attendance.myOpen.value.title }}</strong></span>
          <button type="button" class="btn btn-sm btn-primary" @click="openPage('attendance')">Scan</button>
        </div>


        <SharingWarnings v-if="sharingHere" />
        <BenchAlert v-if="shareError" data-testid="share-error" @dismiss="shareError = ''">{{ shareError }}</BenchAlert>
        <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

        <!-- The page's title. Only the Live page adds a line: who this person can see on the map. -->
        <div v-if="!native" class="ev-page-head">
          <h2>{{ currentPage.label }}</h2>
          <p v-if="tab === 'live'" data-testid="view-scope">{{ viewText }}</p>
        </div>

        <!-- ===== Live map: v-show keeps the map (and its live connection) alive on the other pages ===== -->
        <div v-show="tab === 'live'" class="kp-live" :class="{ 'has-side': !native && canManage }">
          <div class="kp-live-map" :class="native ? 'ev-map-phone' : 'ev-map-only'">
            <div style="min-width: 0">
              <LiveMap
                ref="liveMap"
                :active="tab === 'live'"
                :event-id="id"
                :positions="live.positions.value"
                :live-since="liveSession ? liveSession.startsAt.getTime() : null"
                :session="liveSession"
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
                :sos-alerts="sosOnMap"
              />
            </div>
          </div>
          <div v-if="!native" class="kp-live-side">
            <!-- "Message everyone" (032): planners send one message to many groups at once (phone: on the Ops tab) -->
            <BroadcastPanel v-if="canManage" :broadcasts="broadcasts" :groups="groups" />
            <!-- A plan session's staff picture of the walk: a row per group, its moment, its leg and where its ICs are
                 (step 20). Mounted only while the Live page is shown: the page itself is kept alive by v-show for the
                 map, and a panel that polls every five seconds must not run behind a planner who is drawing the plan. -->
            <PlanOps v-if="tab === 'live' && planSession && seesWholeEvent" :session="liveSession" />
          </div>
        </div>

        <!-- ===== Phone app pages (the website shows these on the Live map and Timeline pages) ===== -->
        <!-- Now: an IC's or member's own moments on the plan's clock (the same read as the Schedule page) -->
        <template v-if="native && tab === 'now'">
          <PlanSchedule
            v-if="scheduleSession"
            :event-id="id"
            :session="scheduleSession"
            :whole="seesWholeEvent"
            :my-group="myGroup"
            :can-press="isIC"
          />
          <div v-else class="pv-empty" data-testid="now-empty">
            <strong>{{ scheduledStart ? 'Starts ' + formatDayTime(scheduledStart) : 'Not started yet' }}</strong>
            <span>{{ !myGroup ? 'Ask the root, a planner or a group admin to add you to a group.' : 'When a planner starts the event, your schedule shows here.' }}</span>
          </div>
        </template>

        <!-- Ops: the plan's live walk, and "Message everyone" -->
        <template v-if="native && tab === 'ops'">
          <BroadcastPanel v-if="canManage" native :broadcasts="broadcasts" :groups="groups" />
          <PlanOps v-if="planSession && seesWholeEvent" :session="liveSession" />
          <div v-else class="pv-empty" data-testid="ops-empty">
            <strong>No plan running</strong>
            <span>{{ isLive ? 'The event is live without a plan: the map shows where everyone is.' : 'Start the event with a plan to follow the walk from here.' }}</span>
          </div>
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

        <AttendancePanel
          v-if="tab === 'attendance'"
          :groups="groups"
          :members="members"
          :me="me"
          :can-manage="canManage"
          :sees-whole-event="seesWholeEvent"
          :mode="attendance.mode.value"
          :rollcalls="attendance.rollcalls.value"
          :checkins="attendance.checkins.value"
          :qr="attendance.qr.value"
          :now="attendance.now.value"
          :busy="attendance.busy.value"
          :error-msg="attError"
          :scan-message="scanMessage"
          @set-mode="onAttSetMode"
          @open="onAttOpen"
          @close="onAttClose"
          @mark="onAttMark"
          @scan="onAttScan"
          @show-qr="attendance.showQr"
          @hide-qr="attendance.hideQr"
          @dismiss-error="attError = ''"
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

        <!-- Map: the follower's own walk for everyone the board is not for (step 29) -->
        <PlanRoute
          v-if="tab === 'map' && !canManage"
          :event-id="id"
          :session="scheduleSession"
          :whole="seesWholeEvent"
          :my-group="myGroup"
          :groups="groups"
          :focus-t="route.query.t"
        />

        <!-- Timeline: the plan board for the people who draw it, and the timetable for the people who follow it
             (step 16). Root and planner get the strip, the map and the inspector; a member, an IC, a group admin or a
             marshal gets their own moments on the plan's clock, from the one read that is already scoped to them (052). -->
        <template v-if="tab === 'timeline'">
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

        <SimulatorPanel v-if="event.is_simulation && isRoot && tab === 'simulator'" :event-id="id" @changed="load" />
      </section>
    </div>

    <SosDialog :open="sosDialogOpen" :busy="sos.busy.value" @send="onSosSend" @close="sosDialogOpen = false" />

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
