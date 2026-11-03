<script setup>
// PlanSchedule — the Schedule page: where a person's group should be and when, as a map and a list of the plan's moments.
//
// WHO THIS IS FOR. Everyone the board is not for: a member, an IC, a group admin. Each row says when and where
// and can zoom the map to its point. Once the event is live a row also says late or on schedule; before the start and
// after the end it does not. The map is PlanRoute, which draws the rows read here. (The board keeps root and planner.)
//
// STOPS, NOT MOMENTS. A person in one group reads the list as where to go and until when, so the moments at one point
// are one row, numbered as its pin is on the map (`stopsOf`). Ops staff still get a row per moment while the event is
// live: every group is in that list and each one changes stop at a different time, so no one row could say them all.
//
// TWO MODES. Live is an instrument: clock times, Now and Next, late or on schedule, the IC's press. Anything else is
// static, a view of the plan: each place and how long is spent there, for every group's stops, and no clock at all.
// Live means what the event header means by it (useEventSessions), so the two cannot disagree past a scheduled end.
//
// WHERE THE ROWS COME FROM. One read (051, widened in 052): session_timetable() answers a row per group per frame
// with the planned clock time, the five-state word, lateness, the frame's note, the plan's name and the revision the
// session follows. The scope is the database's (040): ops staff get every group, everyone else their own. So this
// screen does not filter by group — it renders what the read answered. A client-side filter would look identical in
// a browser and be a different rule; the database is where "only their group appears" has to be true, and step 16
// asserts it there as well as here.
//
// THE CLOCK IS LIVE, THE STATES ARE NOT THIS SCREEN'S. session_status() judges a moment at the instant it is asked
// (its p_at), so the five words are the database's answer, not a guess made from timestamps in the browser. What the
// screen decides is when to ask again: at each planned moment as the clock reaches it (so a moment that was pending
// turns late at that second, not at the next half minute), when the session's revision moves (a publish is the cue,
// and useEventSessions already listens to event_sessions), when the tab is looked at again, and every 30 s as a
// floor. Between reads the countdowns ("in 4 min", "3 min late") are arithmetic on the same planned_at the read
// gave: the number moves every second; the word changes when the database says so.
//
// ENDED, AND SCHEDULED. A session that has ended still has a timetable, and it is read at its end time
// (session_timetable's p_at) instead of now: a closed show should say how it closed, not keep turning late all night
// (the read deliberately does not consult ended_at — step 14's debt, decided in step 20 — so the screen names the
// moment instead of re-deciding the rule). A session that has not started reads too, all pending, with the start
// time in the header: "your schedule" is exactly what a person wants the day before.
//
// THE IC'S OWN PRESS (step 28). One role on this screen does something besides read: the group's IC can say "we are
// here" for the moment the clock is on, which is the manual half of what 063's tick does with a phone. `progress_mark`
// is the door and its rules are the database's -- the moment must have happened, the group must be on site, and a mark
// another person already made is refused rather than replaced (064) -- so this screen only decides which row offers
// the press (the last moment whose time has come and is still unrecorded) and shows the refusal in the database's own
// words. A write's error is kept until the next write: the read beside it polls every half minute, and an error that a
// poll can wipe is an error nobody reads.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { formatDay, formatDayTime, formatDuration, formatTime } from '../../utils/time'
import { scheduleOf } from '../../utils/scheduleRows'
import { textOn, NO_GROUP_COLOUR } from '../../utils/groupColours'
import { formatOffset } from '../../utils/planFrames'
import { isNativeApp } from '../../lib/platform'
import { stopsOf, walksOf } from '../../utils/planWalk'
import { planErrorMessage, usePlan } from '../../composables/usePlan'
import '../../assets/planova.css'
import SkeletonLoader from '../SkeletonLoader.vue'
import PlanRoute from './PlanRoute.vue'
import EmptyState from '../EmptyState.vue'
import { useLoadGate } from '../../composables/usePageReady'

const props = defineProps({
  eventId: { type: String, required: true },
  // The session to read: the live one, the scheduled one, or the last one that has ended (EventView picks). Null
  // when the event has never been started, which is the one case with nothing to read.
  session: { type: Object, default: null },
  // True for ops staff (root, planner): they read every group's timetable. False for everyone else, whose
  // rows the database has already scoped to their group.
  whole: { type: Boolean, default: false },
  // The caller's group, for the header and for the no-group empty state. The rows are the authority for what is
  // shown; this only names it when the read has no rows to name.
  myGroup: { type: Object, default: null },
  // The event's groups, for the map's colours.
  groups: { type: Array, default: () => [] },
  // True for the group's own IC: the one role that may say "we are here" from this screen (step 28). It is passed in
  // rather than derived here because the membership row is the event's, not this read's.
  canPress: { type: Boolean, default: false },
  // What comes next for a static schedule: the next rehearsal (079), or else the event's own date.
  nextRehearsal: { type: Object, default: null },
  eventStartsAt: { type: String, default: null },
  // Seam for the development harness; in the app this is absent and the component reads through usePlan.
  api: { type: Object, default: null },
})

const api = props.api || usePlan(props.eventId)

const POLL_MS = 30000 // the floor, not the point: the wake at each moment is what keeps the screen honest
const TICK_MS = 1000

const rows = ref([]) // the read, exactly as it answered
const routeMap = ref(null)
const shownFrame = ref(null) // the row whose "Show on map" was last pressed
const shownGroup = ref(null) // and its group: a static list has every group's stops, and they share frames
const logRows = ref([]) // what the plan's log says to this person (058)
const loaded = ref(false) // one answer has arrived (an empty read is still an answer)
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => !loaded.value)
const errorMsg = ref('')
const readAt = ref(null)
const now = ref(Date.now())
const busyAck = ref(0) // the log row whose ack is landing
const busyHere = ref('') // the frame whose "we are here" is landing
const errorSticky = ref(false) // an error a write made: a successful read must not wipe it (step 28)
let running = false
let again = false // something changed while the read was in flight: the answer is stale, ask once more
let wakeTimer = null
let logReadAt = 0 // when the plan's log was last asked for
let pollTimer = null
let tickTimer = null

const sessionId = computed(() => (props.session ? props.session.id : null))
const planId = computed(() => (props.session && props.session.planId ? props.session.planId : null))
const endedAt = computed(() => (props.session && props.session.endedAt ? props.session.endedAt : null))
const phase = computed(() => {
  const s = props.session
  if (!s) return 'none'
  if (s.endedAt) return 'ended'
  if (s.startsAt && s.startsAt.getTime() > now.value) return 'scheduled'
  return 'live'
})
const isLive = computed(() => {
  const end = props.session && props.session.scheduledEnd
  return phase.value === 'live' && !(end && end.getTime() <= now.value)
})
const phaseWord = computed(() => {
  if (phase.value === 'live' && !isLive.value) return 'not live'
  return { none: 'not started', live: 'live', scheduled: 'scheduled', ended: 'ended' }[phase.value]
})

// The instant the screen is speaking about: the end of a closed show, otherwise the clock on the wall.
const clockAt = computed(() => (endedAt.value ? endedAt.value : new Date(now.value)))
const planName = computed(() => (rows.value.length ? rows.value[0].plan_name : ''))
const rev = computed(() => (rows.value.length ? rows.value[0].plan_rev : props.session ? props.session.planRev : null))
const groupName = computed(() => {
  if (props.whole) return ''
  return rows.value.length ? rows.value[0].group_name : props.myGroup ? props.myGroup.name : ''
})

/** The line a finished or not-yet-started schedule opens with: what is coming, not how the last run closed. */
const comingUp = computed(() => {
  if (isLive.value || phase.value === 'scheduled') return ''
  if (props.nextRehearsal) return 'Next rehearsal: ' + formatDayTime(props.nextRehearsal.startsAt)
  return props.eventStartsAt ? 'Event date: ' + formatDay(props.eventStartsAt) : ''
})

/** The messages addressed to this person that they have not read (058). */
const myMessages = computed(() => logRows.value.filter((row) => row.i_recipient && !row.i_acked))

/**
 * Read the timetable, and schedule the next ask. Guarded so a background poll cannot interrupt itself, and so a
 * failed read never clears what is on screen: an answer we do not have is not an answer that says "nothing".
 *
 * A read that answers about a session that has since changed, or about a clock that has since stopped (the event
 * ended while the poll was in flight), is not an answer for this screen: it is thrown away and asked again, because
 * the alternative is a closed event showing states judged at the wall clock until the next poll.
 */
async function read() {
  const id = sessionId.value
  if (!id) {
    loaded.value = true // never started: nothing to wait for, so show the sentence and not a skeleton
    return
  }
  if (running) {
    again = true
    return
  }
  running = true
  const at = endedAt.value
  const plan = planId.value
  try {
    // The plan's log is read beside the timetable (step 22): a message a planner sent, and the "your times changed"
    // row a publish wrote. A log that cannot be read keeps the last one and does not blank the schedule.
    // At most every 25 s: the wake at each planned moment re-reads the timetable (from the copy, lib/timetableReader),
    // and the log does not change with the clock (2 Nov load fixes)
    const logDue = !logReadAt || Date.now() - logReadAt > 25000
    const logAsk = plan && api.readLog && logDue ? api.readLog(plan, 6).catch(() => null) : Promise.resolve(null)
    if (logDue) logReadAt = Date.now()
    const [answered, messages] = await Promise.all([api.readTimetable(id, at), logAsk])
    if (sessionId.value !== id || endedAt.value !== at) {
      again = true
      return
    }
    rows.value = answered
    if (messages) logRows.value = messages
    // A read that succeeds clears a read's error. It does not clear a write's: the sentence a refused press came back
    // with is the only place that refusal is said, and this poll runs every half minute (step 28).
    if (!errorSticky.value) errorMsg.value = ''
    readAt.value = new Date()
  } catch (error) {
    if (sessionId.value === id && endedAt.value === at) {
      errorMsg.value = planErrorMessage(error) || 'Could not read the schedule.'
    }
  } finally {
    running = false
    loaded.value = true
    if (again) {
      again = false
      read()
      return
    }
    planWake()
  }
}

/**
 * Wake up when the clock reaches the next planned moment. That is what makes "pending" become "late" at the right
 * second instead of at the next poll — and it is the only timer here whose moment the read itself gave us. A moment
 * further than two minutes out is left to the poll and to the next publish.
 */
function planWake() {
  clearTimeout(wakeTimer)
  wakeTimer = null
  if (endedAt.value || !rows.value.length) return
  const at = Date.now()
  let soonest = null
  for (const row of rows.value) {
    const t = new Date(row.planned_at).getTime()
    if (t > at && (soonest == null || t < soonest)) soonest = t
  }
  if (soonest == null || soonest - at > 120000) return
  wakeTimer = setTimeout(() => {
    now.value = Date.now()
    read()
  }, soonest - at + 300)
}

// ---------- what the read answered, arranged as moments ----------

/** One entry per frame: its clock time, its note, and a row per group (the rows arrive sorted by t_s, group name). */
const moments = computed(() => {
  const out = []
  const byFrame = new Map()
  for (const row of rows.value) {
    let moment = byFrame.get(row.frame_id)
    if (!moment) {
      moment = { frameId: row.frame_id, t_s: row.t_s, at: new Date(row.planned_at), note: row.note || '', rows: [] }
      byFrame.set(row.frame_id, moment)
      out.push(moment)
    }
    moment.rows.push(row)
  }
  return out
})

/** The first moment the clock has not reached yet — the one the eye should land on. */
const nextIndex = computed(() => moments.value.findIndex((m) => m.at.getTime() > clockAt.value.getTime()))

/** The status beside a row: only while the event is live, and only for a moment there is something to say about. */
function statusOf(row) {
  if (!isLive.value) return null
  if (row.state === 'arrived') {
    const late = secondsOfInterval(row.lateness)
    if (late != null && late >= 30) return { text: formatDuration(late * 1000) + ' late', tone: 'late' }
    return { text: 'On schedule', tone: 'ok' }
  }
  if (row.state === 'late') {
    return { text: formatDuration(clockAt.value.getTime() - new Date(row.planned_at).getTime()) + ' late', tone: 'late' }
  }
  if (row.state === 'missed') return { text: 'Missed', tone: 'missed' }
  return null
}

/**
 * PostgREST sends an interval as Postgres prints it: "00:03:00", "-00:00:45", "1 day 00:00:05". The client needs the
 * number of seconds, and it needs the sign: an arrival three minutes early is a negative lateness, not a positive
 * one spoken backwards.
 */
function secondsOfInterval(text) {
  if (!text) return null
  const found = String(text).match(/^\s*(-?\d+)\s+days?\s+(-?\d+):(\d+):(\d+(?:\.\d+)?)\s*$/)
    || String(text).match(/^\s*(-?\d+):(\d+):(\d+(?:\.\d+)?)\s*$/)
  if (!found) return null
  if (found.length === 5) {
    const days = Number(found[1])
    const rest = secondsOfInterval(found[2] + ':' + found[3] + ':' + found[4])
    if (rest == null) return null
    const sign = days < 0 || rest < 0 ? -1 : 1
    return sign * (Math.abs(days) * 86400 + Math.abs(rest))
  }
  const [h, m, s] = [Number(found[1]), Number(found[2]), Number(found[3])]
  const sign = h < 0 ? -1 : 1
  return sign * (Math.abs(h) * 3600 + m * 60 + s)
}

/**
 * The moment the clock is on: the last one whose time has come. A press belongs to that one and not to a moment
 * ahead — "we are here" said at +0:00 about +5:00 is a claim nobody can make. The rows are ordered by frame, so the
 * last due one is the current statement.
 */
const currentFrameId = computed(() => {
  let id = null
  for (const moment of moments.value) {
    if (moment.at.getTime() <= clockAt.value.getTime()) id = moment.frameId
  }
  return id
})

/**
 * Whether this row offers the IC's press. `late` is 050's word for "its time has come and nobody has said anything":
 * `pending` has not happened, `arrived` and `missed` are already said, and `not_required` is an off-site moment with
 * nothing to arrive at. The database refuses each of those too; the screen simply does not offer them.
 */
function canHere(row) {
  return props.canPress && isLive.value && row.state === 'late' && row.frame_id === currentFrameId.value
}

/**
 * "We are here", for the moment the clock is on. One write, then a re-read: the row the database now reports is the
 * one shown, not a mark guessed here. A refusal keeps the database's sentence on screen (the poll does not wipe it)
 * -- another person's mark, a moment that has not happened, a group that is off site all come back that way.
 */
async function here(row) {
  if (!api.markProgress || busyHere.value) return
  busyHere.value = row.frame_id
  errorSticky.value = false
  errorMsg.value = ''
  try {
    await api.markProgress(sessionId.value, row.frame_id, row.group_id, 'arrived')
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
    // A refusal usually means somebody else got there first; re-read so the row stops offering a press that cannot
    // land. The sentence stays, because a write's error is sticky.
    await read()
  } finally {
    busyHere.value = ''
  }
}

// ---------- where each row is ----------

/** The list of stops, group by group. Ops staff read a row per moment instead while live (see the top of this file). */
const stops = computed(() => [...walksOf(rows.value).values()].flatMap((walk) => stopsOf(walk.rows)))

/** "6 stops", over the list. */
const stopCount = computed(() => {
  const count = stops.value.filter((stop) => stop.number).length
  return count === 1 ? '1 stop' : count + ' stops'
})

const currentStop = computed(() => stops.value.findIndex((stop) => stop.rows.some((row) => row.frame_id === currentFrameId.value)))

/** The first stop the clock has not reached yet: a carried moment ahead is not somewhere to go next. */
const nextStop = computed(() => stops.value.findIndex((stop) => new Date(stop.startsAt).getTime() > clockAt.value.getTime()))

/** The row a stop speaks for: the last of its moments the clock has reached, or its first if none has. */
function rowOfStop(stop) {
  const reached = stop.rows.filter((row) => new Date(row.planned_at).getTime() <= clockAt.value.getTime())
  return reached.length ? reached[reached.length - 1] : stop.rows[0]
}

function stopText(stop) {
  if (stop.kind === 'off') return 'Off site'
  if (stop.kind === 'none') return 'No place set'
  return stop.name || 'Stop ' + stop.number
}

/** "1:39 – 1:41 pm", "1:39 pm" when both ends read the same, "From 1:41 pm" for the last stop. */
function stopWhen(stop) {
  const start = formatTime(stop.startsAt)
  if (!stop.endsAt) return 'From ' + start
  const end = formatTime(stop.endsAt)
  if (start === end) return start
  return (start.slice(-2) === end.slice(-2) ? start.slice(0, -2).trim() : start) + ' – ' + end
}

/** How long a stop lasts: "5 min". The last stop runs to the event's scheduled end, or says nothing if it has none. */
function stopLength(stop) {
  const end = stop.endsAt ? new Date(stop.endsAt) : props.session && props.session.scheduledEnd
  const ms = end ? end.getTime() - new Date(stop.startsAt).getTime() : 0
  return ms > 0 ? formatDuration(ms) : ''
}

/** What a stop's moments say. Live, a later moment's note gets its time, as its row is gone from the list. */
function notesOf(stop) {
  return stop.rows
    .filter((row) => row.note)
    .map((row) => ({
      id: row.frame_id,
      text: isLive.value && row !== stop.rows[0] ? formatTime(row.planned_at) + ' · ' + row.note : row.note,
    }))
}

// ---------- the website's rows: a time range and a zone from the Map page ----------

const zones = computed(() => (routeMap.value && routeMap.value.zones) || [])
const schedule = computed(() => scheduleOf(rows.value, zones.value))
// The number on a pin is the stop's number in the list under the map: every moment a stop covers carries it
const pinNumbers = computed(() => {
  if (isNativeApp) return null
  const out = new Map()
  for (const stop of stops.value) {
    if (!stop.number) continue
    for (const row of stop.rows) out.set(row.group_id + '|' + row.frame_id, stop.number)
  }
  return out
})
const KIND_WORD = { zone: 'Zone', stage: 'Stage', no_go: 'No-go', obstacle: 'Obstacle', entrance: 'Entrance' }

/** When this run starts on the clock: the session's own times, else the next rehearsal, else no clock (null). */
const scheduleBase = computed(() => {
  if (isLive.value || phase.value === 'scheduled') return 'session'
  return props.nextRehearsal ? new Date(props.nextRehearsal.startsAt).getTime() : null
})
function rowClock(at, t_s) {
  if (scheduleBase.value === 'session') return new Date(at)
  return new Date(scheduleBase.value + t_s * 1000)
}
/** "10:57:00 – 10:57:15 am", "From 10:58:00 am"; with no clock, offsets: "+0:15 – +0:30". */
function rowWhen(row) {
  if (scheduleBase.value == null) {
    return row.endS == null ? 'From ' + formatOffset(row.startS) : formatOffset(row.startS) + ' – ' + formatOffset(row.endS)
  }
  const start = formatTime(rowClock(row.startsAt, row.startS))
  if (row.endS == null) return 'From ' + start
  const end = formatTime(rowClock(row.endsAt, row.endS))
  return (start.slice(-2) === end.slice(-2) ? start.slice(0, -2).trim() : start) + ' – ' + end
}
const rowRowOf = (row) => rowOfStop({ rows: row.rows })
const rowNow = (row) => isLive.value && row.rows.some((r) => r.frame_id === currentFrameId.value)
const rowNext = computed(() => schedule.value.find((row) => new Date(row.startsAt).getTime() > clockAt.value.getTime()))
const rowShown = (row) => !!row.point && row.stops.some((stop) => stop.point && stop.point.frame_id === shownFrame.value && stop.point.group_id === shownGroup.value)
const rowNotes = (row) => row.stops.flatMap((stop) => notesOf(stop))
const scheduleDay = computed(() => {
  const at = scheduleBase.value === 'session' ? props.session.startsAt : scheduleBase.value
  return at ? formatDay(at) : ''
})
const placesText = computed(() => {
  const n = schedule.value.filter((row) => row.number).length
  return n + (n === 1 ? ' position' : ' positions')
})
const scheduleTitle = computed(() => (props.whole ? 'Groups’ schedule' : (groupName.value || 'Your group') + '’s schedule'))
const web = !isNativeApp

function colourOfGroup(groupId) {
  const group = props.groups.find((g) => g.id === groupId)
  return (group && group.colour) || NO_GROUP_COLOUR
}

/** For each row of the ops list: the point the group should be at then (a carried moment keeps the last one), and how to say it. */
const placeOfRow = computed(() => {
  const out = new Map()
  for (const walk of walksOf(rows.value).values()) {
    for (const stop of stopsOf(walk.rows)) {
      for (const row of stop.rows) {
        let text = stopText(stop)
        if (stop.kind === 'place' && !stop.name && row !== stop.point) text = 'Still at ' + text
        out.set(row, { point: stop.point, text })
      }
    }
  }
  return out
})

function nextText(at) {
  return 'Next · in ' + formatDuration(at.getTime() - clockAt.value.getTime())
}

function showOnMap(frameId, t_s, groupId) {
  if (!routeMap.value) return
  shownFrame.value = frameId
  shownGroup.value = groupId
  routeMap.value.showMoment(t_s, groupId)
  routeMap.value.$el.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
}

// ---------- the plan log (step 22) ----------

/**
 * One tap on a message: the database writes the wall-clock instant and the row is read back rather than guessed. A
 * second tap would change nothing (the first instant stands), so the button is simply gone once it is acked.
 */
async function ack(row) {
  if (!api.ackLog || busyAck.value) return
  busyAck.value = row.id
  errorSticky.value = false
  try {
    await api.ackLog(row.id)
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
  } finally {
    busyAck.value = 0
  }
}

/**
 * "Mark all as read": the same one-tap ack for every unread message, then one re-read. A refusal part-way keeps what
 * landed (each ack is its own write) and says why, like a single tap would.
 */
async function ackAll() {
  if (!api.ackLog || busyAck.value || !myMessages.value.length) return
  busyAck.value = -1
  errorSticky.value = false
  try {
    for (const row of [...myMessages.value]) await api.ackLog(row.id)
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
  } finally {
    await read()
    busyAck.value = 0
  }
}

// ---------- lifecycle ----------

function onLook() {
  if (document.hidden) return
  now.value = Date.now()
  read()
}

function onTick() {
  now.value = Date.now()
}

onMounted(() => {
  read()
  tickTimer = setInterval(onTick, TICK_MS)
  pollTimer = setInterval(() => {
    if (!document.hidden) read()
  }, POLL_MS)
  document.addEventListener('visibilitychange', onLook)
  window.addEventListener('focus', onLook)
})

onBeforeUnmount(() => {
  clearTimeout(wakeTimer)
  clearInterval(pollTimer)
  clearInterval(tickTimer)
  document.removeEventListener('visibilitychange', onLook)
  window.removeEventListener('focus', onLook)
})

// A different session is a different timetable: start again rather than read the new one over the old rows.
watch(sessionId, () => {
  rows.value = []
  loaded.value = false
  errorMsg.value = ''
  errorSticky.value = false
  read()
})

// The event ending changes the instant this screen is speaking about (the read is taken at the close), so the
// timetable is read again rather than left saying what the clock said a moment before the end.
watch(endedAt, () => read())

// The push: plan_publish moves the session's plan_rev, and useEventSessions already listens to event_sessions, so a
// publish elsewhere is this screen's cue to ask again. The cue is not the answer — the read is.
watch(
  () => (props.session ? props.session.planRev : null),
  () => {
    logReadAt = 0 // a publish writes "your times changed" into the log: read it now, not at the next 25 s
    read()
  },
)
</script>

<template>
  <div class="pv">
    <section class="pv-sched" data-testid="plan-schedule">
      <!-- Website: the page's title; everything else is in the one card below, as on the phone -->
      <div v-if="web" class="k k2-h k2-schedhead">
        <h1>Schedule</h1>
      </div>

      <!-- New messages from a planner, and "your times changed" when a publish moved this group's walk (step 22). -->
      <section v-if="web && myMessages.length" class="k k2-card k2-updates" data-testid="sched-log">
        <div class="row" style="margin-bottom: 6px">
          <b class="U" style="font-size: 16px; letter-spacing: -0.04em">Updates</b>
          <span class="chip chip-ink" style="height: 22px">{{ myMessages.length }} new</span>
          <button type="button" class="k2-readall" data-testid="sched-ack-all" :disabled="busyAck !== 0" @click="ackAll">Mark all as read</button>
        </div>
        <article v-for="row in myMessages" :key="row.id" class="k2-upd" data-testid="sched-msg" :data-kind="row.kind">
          <span class="k2-uico" :class="row.kind === 'timeline' ? 'change' : 'msg'">
            <svg v-if="row.kind === 'timeline'" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2"></path></svg>
            <svg v-else class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 12a8 8 0 0 1-8 8H4l2.5-3A8 8 0 1 1 21 12z"></path></svg>
          </span>
          <div style="flex: 1; min-width: 0">
            <b style="font-size: 14px">{{ row.kind === 'timeline' ? 'Your times changed' : row.from_name }}</b><span class="mut" style="font-size: 12px"> · {{ formatTime(row.at) }}</span>
            <div class="k2-updtxt" data-testid="sched-msg-body">{{ row.body }}</div>
          </div>
          <button type="button" class="k2-pillbtn" data-testid="sched-ack" :disabled="busyAck === row.id || busyAck === -1" @click="ack(row)">Got it</button>
        </article>
      </section>

      <div v-else-if="myMessages.length" class="pv-sched-log" data-testid="sched-log">
        <button type="button" class="pv-sched-ack pv-sched-ackall" data-testid="sched-ack-all" :disabled="busyAck !== 0" @click="ackAll">Mark all as read</button>
        <article
          v-for="row in myMessages"
          :key="row.id"
          class="pv-sched-msg is-new"
          :class="{ 'is-timeline': row.kind === 'timeline' }"
          data-testid="sched-msg"
          :data-kind="row.kind"
        >
          <div class="pv-sched-msg-line">
            <strong class="pv-sched-msg-title">{{ row.kind === 'timeline' ? 'Your times changed' : row.from_name }}</strong>
            <span class="pv-sched-msg-at">{{ formatTime(row.at) }}</span>
            <button
              type="button"
              class="pv-sched-ack"
              data-testid="sched-ack"
              :disabled="busyAck === row.id || busyAck === -1"
              @click="ack(row)"
            >
              Got it
            </button>
          </div>
          <p class="pv-sched-msg-body" data-testid="sched-msg-body">{{ row.body }}</p>
        </article>
      </div>

      <div class="pv-sched-card">
      <header class="pv-sched-head">
        <h2 class="pv-sched-title" data-testid="sched-title">
          {{ whole ? 'Where groups should be' : 'Where ' + (groupName || 'your group') + ' should be' }}
        </h2>
        <p class="pv-sched-sub">
          <span v-if="phase !== 'ended'" class="pv-badge" :class="{ 'is-live': isLive }" data-testid="sched-phase">{{ phaseWord }}</span>
          <template v-if="planName">
            <span class="pv-sched-plan" data-testid="sched-plan">{{ planName }}</span>
            <span v-if="rev != null">· version <span data-testid="sched-rev">{{ rev }}</span></span>
          </template>
        </p>
      </header>

      <p v-if="phase === 'scheduled'" class="pv-sched-line" data-testid="sched-scheduled">
        Starts {{ formatDayTime(session.startsAt) }}.
      </p>
      <p v-if="comingUp" class="pv-sched-line" data-testid="sched-coming-up">{{ comingUp }}</p>

      <!-- A read that failed says so and keeps the last answer: a schedule that blanks itself is worse than an old one. -->
      <p v-if="errorMsg" class="pv-sched-line is-warn" data-testid="sched-error">
        {{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template>
      </p>

      <PlanRoute
        v-if="session"
        ref="routeMap"
        embedded
        :event-id="eventId"
        :session="session"
        :whole="whole"
        :my-group="myGroup"
        :groups="groups"
        :walk-rows="rows"
        :pin-numbers="pinNumbers"
      />

      <h3 v-if="loaded && rows.length" class="pv-sched-listhead" data-testid="sched-list-head">
        Full schedule
        <span v-if="!whole" class="pv-sched-listcount" data-testid="sched-list-count">{{ stopCount }}</span>
      </h3>

      <SkeletonLoader v-if="!loaded" :rows="4" class="pv-sched-skel" label="Reading the schedule…" data-testid="sched-loading" />

      <EmptyState
        v-else-if="!rows.length"
        compact
        icon="clock"
        :title="phase === 'none' ? 'No schedule yet' : !session.planId ? 'No plan running' : !whole && !groupName ? 'Not in a group' : 'Nothing planned'"
        :text="phase === 'none' ? 'The schedule appears once the event starts with a plan.' : !session.planId ? 'This event is running without a plan.' : !whole && !groupName ? 'Ask a planner to add you to a group.' : whole ? 'This plan has no moments yet.' : 'This plan has no moments for ' + groupName + ' yet.'"
        data-testid="sched-empty"
      />

      <ol v-else-if="!whole || !isLive" class="pv-sched-list">
        <li
          v-for="(stop, i) in stops"
          :key="stop.rows[0].group_id + stop.rows[0].frame_id"
          class="pv-sched-moment pv-sched-stop"
          :class="{
            'is-static': !isLive,
            'is-now': isLive && i === currentStop,
            'is-past': isLive && i < currentStop,
            'is-shown': stop.point && stop.point.frame_id === shownFrame && stop.point.group_id === shownGroup,
          }"
          data-testid="sched-moment"
          :data-frame="stop.rows[0].frame_id"
          :data-t="stop.rows[0].t_s"
        >
          <strong v-if="isLive" class="pv-sched-at" :data-testid="'sched-at-' + stop.rows[0].t_s">{{ stopWhen(stop) }}</strong>
          <div class="pv-sched-rows">
            <div
              class="pv-sched-row"
              data-testid="sched-row"
              :data-group="stop.rows[0].group_id"
              :data-state="rowOfStop(stop).state"
            >
              <div class="pv-sched-where pv-sched-where-stop">
                <span class="pv-sched-node">
                  <span
                    v-if="stop.number"
                    class="pv-sched-num"
                    :style="{ '--pv-dot': colourOfGroup(stop.rows[0].group_id), '--pv-dot-ink': textOn(colourOfGroup(stop.rows[0].group_id)) }"
                    data-testid="sched-num"
                  >{{ stop.number }}</span>
                </span>
                <span class="pv-sched-what">
                  <span v-if="whole" class="pv-sched-group">{{ stop.rows[0].group_name }}</span>
                  <span class="pv-sched-place" data-testid="sched-place">{{ stopText(stop) }}</span>
                  <ul v-if="notesOf(stop).length" class="pv-sched-notes">
                    <li v-for="note in notesOf(stop)" :key="note.id" class="pv-sched-note" data-testid="sched-note">{{ note.text }}</li>
                  </ul>
                </span>
              </div>
              <div class="pv-sched-marks">
                <span v-if="!isLive && stopLength(stop)" class="pv-sched-for" data-testid="sched-for">{{ stopLength(stop) }}</span>
                <span v-if="isLive && i === currentStop" class="pv-sched-flag">Now</span>
                <span v-else-if="isLive && i === nextStop" class="pv-sched-flag">{{ nextText(new Date(stop.startsAt)) }}</span>
                <span
                  v-if="statusOf(rowOfStop(stop))"
                  class="pv-sched-state"
                  :class="'is-' + statusOf(rowOfStop(stop)).tone"
                  data-testid="sched-state"
                >{{ statusOf(rowOfStop(stop)).text }}</span>
              </div>
              <div class="pv-sched-actions">
                <button
                  v-if="canHere(rowOfStop(stop))"
                  type="button"
                  class="pv-sched-here"
                  data-testid="sched-here"
                  :disabled="busyHere === rowOfStop(stop).frame_id"
                  @click="here(rowOfStop(stop))"
                >{{ busyHere === rowOfStop(stop).frame_id ? 'Saving…' : 'We’re here' }}</button>
                <button
                  v-if="stop.point"
                  type="button"
                  class="pv-sched-show"
                  data-testid="sched-place-link"
                  @click="showOnMap(stop.point.frame_id, stop.point.t_s, stop.point.group_id)"
                >Show on map</button>
              </div>
            </div>
          </div>
        </li>
      </ol>

      <ol v-else class="pv-sched-list">
        <li
          v-for="(moment, i) in moments"
          :key="moment.frameId"
          class="pv-sched-moment"
          :class="{
            'is-now': moment.frameId === currentFrameId,
            'is-past': moment.at.getTime() <= clockAt.getTime() && moment.frameId !== currentFrameId,
            'is-shown': moment.frameId === shownFrame,
          }"
          data-testid="sched-moment"
          :data-frame="moment.frameId"
          :data-t="moment.t_s"
        >
          <strong class="pv-sched-at" :data-testid="'sched-at-' + moment.t_s">{{ formatTime(moment.at) }}</strong>
          <div class="pv-sched-rows">
            <div
              v-for="row in moment.rows"
              :key="row.group_id"
              class="pv-sched-row"
              data-testid="sched-row"
              :data-group="row.group_id"
              :data-state="row.state"
            >
              <div class="pv-sched-where">
                <span v-if="whole" class="pv-sched-group">{{ row.group_name }}</span>
                <span v-if="placeOfRow.get(row).text" class="pv-sched-place" data-testid="sched-place">{{ placeOfRow.get(row).text }}</span>
                <span v-if="moment.note" class="pv-sched-note" data-testid="sched-note">{{ moment.note }}</span>
              </div>
              <div class="pv-sched-marks">
                <span v-if="moment.frameId === currentFrameId" class="pv-sched-flag">Now</span>
                <span v-else-if="i === nextIndex" class="pv-sched-flag">{{ nextText(moment.at) }}</span>
                <span
                  v-if="statusOf(row)"
                  class="pv-sched-state"
                  :class="'is-' + statusOf(row).tone"
                  data-testid="sched-state"
                >{{ statusOf(row).text }}</span>
              </div>
              <div class="pv-sched-actions">
                <button
                  v-if="canHere(row)"
                  type="button"
                  class="pv-sched-here"
                  data-testid="sched-here"
                  :disabled="busyHere === moment.frameId"
                  @click="here(row)"
                >{{ busyHere === moment.frameId ? 'Saving…' : 'We’re here' }}</button>
                <button
                  v-if="placeOfRow.get(row).point"
                  type="button"
                  class="pv-sched-show"
                  data-testid="sched-place-link"
                  @click="showOnMap(moment.frameId, moment.t_s, row.group_id)"
                >Show on map</button>
              </div>
            </div>
          </div>
        </li>
      </ol>
      </div>
    </section>
  </div>
</template>
