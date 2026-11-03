<script setup>
// PlanOps — the ops board of a plan that is running: who is under way, when their next moment is, and where their ICs
// actually are.
//
// WHY A SCREEN OF ITS OWN. The Timeline page is the planner's instrument (a strip, a map, a frame inspector) or, for
// everyone else, their own timetable; the Live page is where people watch the ground. A plan session had nothing on
// the Live page: the run-sheet ops board reads movement_status and is deliberately not shown for a plan (027, step 20),
// so the one question an ops team asks during a plan -- "is everyone where the walk says they should be" -- had no
// answer on screen. This is that answer, and it is staff-only: the read is scoped by the database (040), and a member's
// own timetable is step 16's screen.
//
// ONE READ, ONE INSTANT. plan_ops(p_session) (056) answers a row per group per moment with pending / active / done,
// the time the strip gives that moment's walk, the position the walk has the group at now, and the accuracy-weighted
// midpoint of its ICs. The screen does not derive any of it: it groups the rows, picks the active one (or the first
// pending / last done when there is no active one), and renders. The words on the chips are the database's three
// states; the countdowns are arithmetic on the planned_at the read gave.
//
// WHEN IT ASKS AGAIN. A moment's status changes exactly when the clock reaches it, so the screen wakes at the soonest
// planned moment (up to two minutes out), polls every five seconds anyway -- the midpoint moves as ICs send readings,
// and a poll is the only thing that can show that -- and re-reads when the tab is looked at, when a publish moves the
// session's revision, and when the session is handed onto another plan. A read that fails keeps the last picture and
// says so: an ops board that blanks itself is worse than one that is a little behind.
//
// THE TWO THINGS A PERSON DOES HERE (step 21). A moment is closed by the database when its position is `auto` and an IC
// of the group is inside the zone its point stands in (057); a moment whose position is `manual`, or whose point is in
// no zone, waits for somebody to say it happened. So the board renders the mark the read gives it -- "Arrived 6:47 pm,
// the phone was there" for the tick's own close, "by hand" for a person's -- and offers the two buttons only on the
// moment the clock is on and only while it is unrecorded. `progress_mark` (050) is the door; this panel is its first
// client caller, and its rules (an off-site moment has nothing to record, a future one has not happened) are the
// database's, not repeated here. The hand-back is the other: the log says who has the board and since when, and taking
// it writes one row whose "from" the database reads off the previous one.
//
// WHO CLOSED IT, AND WHY AN ERROR STAYS (step 28). Since 064 the read answers `marked_auto` -- whether the tick closed
// the moment -- instead of this screen inferring "the phone was there" from a missing name, which is also what a
// deleted profile looks like. And a write's refusal is kept until the next write (or Dismiss): the board polls every
// five seconds and used to clear `errorMsg` on every successful poll, so a sentence saying why a mark was refused was
// wiped before anyone could read it. A refused mark also re-reads, so the row that kept its buttons is corrected
// rather than left stale.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { supabase } from '../../lib/supabase'
import { planErrorMessage } from '../../composables/usePlan'
import { formatDuration, formatTime } from '../../utils/time'
import { formatOffset } from '../../utils/planFrames'
import '../../assets/planova.css'
import SkeletonLoader from '../SkeletonLoader.vue'
import EmptyState from '../EmptyState.vue'
import { useLoadGate } from '../../composables/usePageReady'
import { GROUP_PALETTE } from '../../utils/groupColours'
import { useAuthStore } from '../../stores/auth'

const props = defineProps({
  // The live session on a plan: { id, planId, t0At, planRev } from useEventSessions. Null while there is none.
  session: { type: Object, default: null },
  // Seam for a check; in the app this is absent and the read goes to the database.
  api: { type: Object, default: null },
  // What to draw: 'all' (the phone's Ops tab, everything stacked), or one tab of the website's Live panel: 'ops' (the
  // run clock, the board and the groups) or 'log' (the plan log). The reads are the same in every case.
  view: { type: String, default: 'all' },
  // The event's groups, for each group's colour on the website's cards (the read has names, not colours)
  groups: { type: Array, default: () => [] },
})

// The website's Live panel shows the log's length on its tab
const emit = defineEmits(['counts'])
const auth = useAuthStore()

const POLL_MS = 5000 // the midpoint moves with the readings; the statuses move at the moments (wake)
const TICK_MS = 1000
const WAKE_MAX_MS = 120000 // a moment further out than this is left to the poll

const rows = ref([]) // the read, exactly as it answered
const handover = ref([]) // the hand-back chain, newest first (057)
const log = ref([]) // what was sent to the plan's groups, and what the plan changed (058)
const loaded = ref(false) // one answer has arrived (an empty read is still an answer)
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => !loaded.value)
const errorMsg = ref('')
const errorSticky = ref(false) // a write's error: a successful poll must not wipe it (step 28)
const readAt = ref(null)
const now = ref(Date.now())
const busy = ref('') // 'mark:<group>:<state>' / 'take' while a write is landing
const draft = ref('') // the composer's text
const toWhom = ref('all') // 'all' | 'ops' | 'group:<id>'
const sending = ref(false)
const acking = ref(0) // the log row whose ack is landing

let running = false
let again = false // something moved while the read was in flight: ask once more
let wakeTimer = null
let pollTimer = null
let tickTimer = null

const sessionId = computed(() => (props.session ? props.session.id : null))
const planId = computed(() => (props.session && props.session.planId ? props.session.planId : null))
const t0 = computed(() => (props.session && props.session.t0At ? props.session.t0At : null))
const rev = computed(() => (props.session ? props.session.planRev : null))
const clockText = computed(() => formatTime(new Date(now.value)))
const t0Text = computed(() => (t0.value ? formatTime(t0.value) : ''))
const elapsedText = computed(() => (t0.value ? formatOffset((now.value - t0.value.getTime()) / 1000) : ''))

async function ask(id) {
  if (props.api) return props.api.readOps(id)
  const { data, error } = await supabase.rpc('plan_ops', { p_session: id })
  if (error) throw error
  return data || []
}

async function askHandover(id) {
  if (props.api) return props.api.readHandover(id)
  const { data, error } = await supabase.rpc('handover_log_list', { p_session: id })
  if (error) throw error
  return data || []
}

/** The plan's log. Read by plan, not by session: the log outlives tonight's session (058). */
async function askLog(id) {
  if (!id) return []
  if (props.api && props.api.readLog) return props.api.readLog(id, 20)
  const { data, error } = await supabase.rpc('plan_log_list', { p_plan: id, p_limit: 20 })
  if (error) throw error
  return data || []
}

/**
 * Read the board, and schedule the next ask. Guarded so a background poll cannot interrupt itself and a failed read
 * never clears what is on screen; a read that answers about a session that has since changed is thrown away.
 */
async function read() {
  const id = sessionId.value
  if (!id) return
  if (running) {
    again = true
    return
  }
  running = true
  const plan = planId.value
  try {
    // All three answers in one wait: the board is not on screen until the hand-back line and the log are too, and a
    // session or plan whose chain cannot be read is the same kind of failure as one whose moments cannot be.
    const [answered, hands, messages] = await Promise.all([ask(id), askHandover(id), askLog(plan)])
    if (sessionId.value !== id) {
      again = true
      return
    }
    rows.value = answered
    handover.value = hands
    log.value = messages
    if (!errorSticky.value) errorMsg.value = ''
    readAt.value = new Date()
  } catch (error) {
    if (sessionId.value === id) errorMsg.value = planErrorMessage(error) || 'Could not read the ops board.'
  } finally {
    running = false
    loaded.value = true
    now.value = Date.now()
    if (again) {
      again = false
      read()
      return
    }
    planWake()
  }
}

/** Wake when the clock reaches the soonest moment still ahead: that is when a row changes status, not at the poll. */
function planWake() {
  clearTimeout(wakeTimer)
  wakeTimer = null
  if (!rows.value.length) return
  const at = Date.now()
  let soonest = null
  for (const row of rows.value) {
    if (!row.planned_at) continue
    const t = new Date(row.planned_at).getTime()
    if (t > at && (soonest == null || t < soonest)) soonest = t
  }
  if (soonest == null || soonest - at > WAKE_MAX_MS) return
  wakeTimer = setTimeout(() => {
    now.value = Date.now()
    read()
  }, soonest - at + 300)
}

// ---------- the read, arranged per group ----------
const STATE_WORD = { pending: 'Not started', active: 'Under way', done: 'Done' }

/**
 * One entry per group: its own three-word status (active if any of its moments is, else pending while one is still
 * ahead, else done), the moment it is on, and the one after it.
 */
const groups = computed(() => {
  const by = new Map()
  for (const row of rows.value) {
    let group = by.get(row.group_id)
    if (!group) {
      group = { id: row.group_id, name: row.group_name, rows: [] }
      by.set(row.group_id, group)
    }
    group.rows.push(row)
  }
  for (const group of by.values()) {
    group.rows.sort((a, b) => a.t_s - b.t_s)
    group.first = group.rows[0]
    group.last = group.rows[group.rows.length - 1]
    group.active = group.rows.find((r) => r.status === 'active') || null
    group.next = group.rows.find((r) => r.status === 'pending') || null
    group.status = group.active ? 'active' : group.next ? 'pending' : 'done'
    // The moment the clock is on -- the one a person can record something about. It is the last whose time has come,
    // which is the row that is active, or the last one of a group whose plan has ended.
    group.current = [...group.rows].reverse().find((r) => new Date(r.planned_at).getTime() <= now.value) || null
  }
  return [...by.values()].sort((a, b) => a.name.localeCompare(b.name))
})

const underWay = computed(() => groups.value.filter((g) => g.status === 'active').length)
const notStarted = computed(() => groups.value.filter((g) => g.status === 'pending').length)
const finished = computed(() => groups.value.filter((g) => g.status === 'done').length)

function countdown(iso) {
  const left = new Date(iso).getTime() - now.value
  return left > 0 ? 'in ' + formatDuration(left) : 'due'
}

/** The moment the group is on, or the one it is waiting for / finished on. */
function whenText(group) {
  if (group.active) {
    return 'Now ' + formatOffset(group.active.t_s) + (group.active.note ? ' · ' + group.active.note : '')
  }
  if (group.status === 'pending') {
    return 'First moment ' + formatOffset(group.first.t_s) + (group.first.note ? ' · ' + group.first.note : '')
  }
  return 'Last moment ' + formatOffset(group.last.t_s) + (group.last.note ? ' · ' + group.last.note : '')
}

function nextText(group) {
  const moment = group.active ? group.next : group.status === 'pending' ? group.first : null
  if (!moment) return 'No next moment'
  return (group.active ? 'Next ' : 'Starts ') + formatOffset(moment.t_s) + ' · ' + countdown(moment.planned_at)
}

/** The time the strip gives the leg the group is on -- its next moment minus this one, as the read answered it. */
function travelText(group) {
  const moment = group.active || (group.status === 'pending' ? group.first : null)
  if (!moment || moment.travel_s == null) return 'No leg ahead'
  return 'Travel ' + formatDuration(moment.travel_s * 1000)
}

/** Where the group really is, in the read's own numbers: the midpoint's distance from the walk, its ICs, its age. */
function placeText(group) {
  // The row the walk is speaking about: the one the group is on, or the first it is waiting for, or its last. The
  // position columns are the group's at the read's instant, so they are the same on all its rows.
  const moment = group.active || (group.status === 'pending' ? group.first : group.last)
  if (!moment) return ''
  const ics = moment.actual_ics || 0
  const icsText = ics + ' IC' + (ics === 1 ? '' : 's')
  if (moment.expected_lat == null) {
    // The group's walk has not started: there is no place to compare it with yet.
    return ics ? icsText + ' · not in the walk yet' : 'No signal'
  }
  if (moment.expected_state === 'off_site') return ics ? 'Off site · ' + icsText : 'Off site · no signal'
  if (ics === 0) return 'No signal'
  if (moment.actual_lat == null) return icsText + ' sharing, no fix'
  const age = moment.actual_at ? Math.max(0, Math.round((now.value - new Date(moment.actual_at).getTime()) / 1000)) : null
  const where = moment.off_m === 0 ? 'On the walk' : moment.off_m == null ? 'No position' : moment.off_m + ' m from the walk'
  return where + ' · ' + icsText + (age != null ? ' · ' + age + ' s ago' : '')
}

/**
 * Whether the current moment can be recorded from here: it has happened, its group is on site, and nobody (and no tick)
 * has said anything about it yet. The two refusals the database also makes -- a future moment, an off-site one -- are
 * therefore not offered as buttons in the first place.
 */
function canMark(group) {
  const moment = group.current
  return !!moment && moment.plan_state === 'on_site' && !moment.marked_state
}

/** What was recorded about the current moment, in the read's own words and with who said it. */
function markText(group) {
  const moment = group.current
  if (!moment || !moment.marked_state) return ''
  const when = moment.marked_at ? formatTime(moment.marked_at) : ''
  // `marked_auto` is the writer (064), not a missing name: a person's mark whose profile was deleted still says a
  // person did it, which is also why it is still protected from another person.
  const how = moment.marked_auto ? 'the phone was there' : 'by hand'
  return (moment.marked_state === 'missed' ? 'Missed ' : 'Arrived ') + when + ' · ' + how
}

/** Drop a sticky refusal. The next successful write clears it too; nothing else does. */
function dismissError() {
  errorMsg.value = ''
  errorSticky.value = false
}

/**
 * Record the current moment. One write, then a re-read: the screen never guesses what the row now says. A refusal --
 * another person already recorded it (064), a moment that is off site -- keeps its sentence on screen and re-reads,
 * so the buttons the stale row was still offering go away.
 */
async function mark(group, state) {
  const moment = group.current
  if (!moment || busy.value) return
  busy.value = 'mark:' + group.id + ':' + state
  errorSticky.value = false
  try {
    const { error } = await supabase.rpc('progress_mark', {
      p_session: sessionId.value,
      p_frame: moment.frame_id,
      p_group: group.id,
      p_state: state,
    })
    if (error) throw error
    errorMsg.value = ''
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
    await read()
  } finally {
    busy.value = ''
  }
}

/** The chain's newest row: who has the board, and since when. */
const latestHand = computed(() => handover.value[0] || null)
const handText = computed(() => {
  const row = latestHand.value
  if (!row) return 'No hand-back yet'
  const when = formatTime(row.handed_at)
  if (row.from_name) return 'Handed from ' + row.from_name + ' to ' + row.to_name + ' at ' + when
  return 'Board with ' + row.to_name + ' since ' + when
})

/** Take the board: the database works out who had it, dates the row itself, and copies the plan revision on. */
async function takeBoard() {
  if (busy.value) return
  busy.value = 'take'
  errorSticky.value = false
  try {
    const { error } = await supabase.rpc('handover_take', { p_session: sessionId.value })
    if (error) throw error
    errorMsg.value = ''
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not take the board.'
  } finally {
    busy.value = ''
  }
}

// ---------- the plan log (step 22) ----------

const canSend = computed(() => !!draft.value.trim() && draft.value.trim().length <= 300 && !sending.value)

/** The picker's value as the function's two arguments. */
function audienceOf() {
  if (toWhom.value === 'ops') return { audience: 'ops', group: null }
  if (toWhom.value.startsWith('group:')) return { audience: 'group', group: toWhom.value.slice(6) }
  return { audience: 'all', group: null }
}

/**
 * Send one message. The composer is cleared only when the database has taken it: a refused message (a group with no
 * part in the plan, a body of nothing) leaves what was typed where it is and says why.
 */
async function send() {
  if (!canSend.value || !planId.value) return
  const { audience, group } = audienceOf()
  sending.value = true
  errorSticky.value = false
  try {
    const { error } = await supabase.rpc('plan_broadcast', {
      p_plan: planId.value,
      p_body: draft.value.trim(),
      p_audience: audience,
      p_group: group,
    })
    if (error) throw error
    draft.value = ''
    errorMsg.value = ''
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not send that message.'
  } finally {
    sending.value = false
  }
}

/** One tap: a message the ops team was sent, or the timeline change addressed to them. */
async function ack(row) {
  if (acking.value) return
  acking.value = row.id
  errorSticky.value = false
  try {
    const { error } = await supabase.rpc('plan_log_ack', { p_log: row.id })
    if (error) throw error
    await read()
  } catch (error) {
    errorSticky.value = true
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
  } finally {
    acking.value = 0
  }
}

/** "3 of 5 got it · waiting on Sound" for the sender; the row's own state for anybody else. */
function tally(row) {
  if (row.recipients == null) {
    if (row.i_acked) return 'got it ' + formatTime(row.i_acked)
    return row.i_recipient ? 'not got it yet' : ''
  }
  const head = (row.acked || 0) + ' of ' + row.recipients + ' got it'
  if (row.waiting && row.waiting.length) return head + ' · waiting on ' + row.waiting.join(', ')
  return head
}

/** Who the row was sent to, in the board's words. */
function audienceWord(row) {
  if (row.kind === 'timeline') return 'the groups whose times moved'
  if (row.audience === 'ops') return 'the ops team'
  if (row.audience === 'group') {
    const group = groups.value.find((g) => g.id === row.audience_group)
    return group ? group.name : 'a group'
  }
  return 'every group'
}

// ---------- the website's Live panel: arrangement only, from the same read ----------

const DUE_SOON_MS = 30000 // a group under way whose next move is this close is "due soon"
const QUIET_MS = 120000 // a sharing group whose last reading is older than this has "no update"
const filter = ref('all') // 'all' | 'soon' | 'quiet'

const colourById = computed(() => {
  const out = new Map()
  props.groups.forEach((g, i) => out.set(g.id, g.colour || GROUP_PALETTE[i % GROUP_PALETTE.length]))
  return out
})
const colourOf = (id) => colourById.value.get(id) || GROUP_PALETTE[0]
function colourOfName(name) {
  const g = props.groups.find((x) => x.name === name)
  return g ? colourOf(g.id) : 'var(--muted)'
}

/** The moment a group is counting down to: its next while under way, its first while not started. */
function targetOf(group) {
  return group.active ? group.next : group.status === 'pending' ? group.first : null
}
function leftMs(group) {
  const moment = targetOf(group)
  return moment ? new Date(moment.planned_at).getTime() - now.value : null
}
const isDueSoon = (group) => group.status === 'active' && !!group.next && leftMs(group) <= DUE_SOON_MS

/** "Live", "No update 3 min" or "No signal", from the same columns as the place line. */
function signalOf(group) {
  const moment = group.active || (group.status === 'pending' ? group.first : group.last)
  if (!moment || !moment.actual_ics) return { kind: 'none', text: 'No signal' }
  const age = moment.actual_at ? now.value - new Date(moment.actual_at).getTime() : null
  if (age != null && age > QUIET_MS) return { kind: 'quiet', text: 'No update ' + Math.floor(age / 60000) + ' min' }
  return { kind: 'live', text: 'Live' }
}

/** "in 37 s", "in 1 min 22 s", "Due now"; nothing for a finished walk. */
function pillText(group) {
  const left = leftMs(group)
  if (left == null) return ''
  if (left <= 0) return 'Due now'
  const secs = Math.ceil(left / 1000)
  if (secs < 60) return 'in ' + secs + ' s'
  if (secs < 3600) return 'in ' + Math.floor(secs / 60) + ' min' + (secs % 60 ? ' ' + (secs % 60) + ' s' : '')
  return 'in ' + formatDuration(left)
}

/** How far along the leg the group is on: 0 before its walk starts, 100 once it is done. */
function progressOf(group) {
  if (group.status === 'done') return 100
  if (!group.active || !group.next) return 0
  const from = new Date(group.active.planned_at).getTime()
  const to = new Date(group.next.planned_at).getTime()
  if (to <= from) return 100
  return Math.min(100, Math.max(0, ((now.value - from) / (to - from)) * 100))
}

/** The card's headline: "Now +5:25 → Next +7:25", "Starts +0:45", "Finished +1:45". */
function moveOf(group) {
  if (group.active) {
    return { a: 'Now', at: formatOffset(group.active.t_s), b: group.next ? 'Next' : '', bt: group.next ? formatOffset(group.next.t_s) : '' }
  }
  if (group.status === 'pending') return { a: 'Starts', at: formatOffset(group.first.t_s), b: '', bt: '' }
  return { a: 'Finished', at: formatOffset(group.last.t_s), b: '', bt: '' }
}

/** What the moment says, if anything: the note the planner wrote on it. */
function noteOf(group) {
  const moment = group.active || (group.status === 'pending' ? group.first : group.last)
  return moment && moment.note ? moment.note : ''
}

// Soonest next move first; finished walks last
const sortedGroups = computed(() =>
  [...groups.value].sort((a, b) => {
    const la = leftMs(a)
    const lb = leftMs(b)
    if ((la == null) !== (lb == null)) return la == null ? 1 : -1
    if (la != null && la !== lb) return la - lb
    return a.name.localeCompare(b.name)
  }),
)
const dueSoonCount = computed(() => groups.value.filter(isDueSoon).length)
const quietCount = computed(() => groups.value.filter((g) => signalOf(g).kind !== 'live').length)
const shownGroups = computed(() => {
  if (filter.value === 'soon') return sortedGroups.value.filter(isDueSoon)
  if (filter.value === 'quiet') return sortedGroups.value.filter((g) => signalOf(g).kind !== 'live')
  return sortedGroups.value
})
const FILTER_EMPTY = { soon: 'No group is due to move in the next 30 seconds.', quiet: 'Every group is sending its position.' }

// The run clock's bar: under way, not started and done, as shares of the groups
const share = (n) => (groups.value.length ? (n / groups.value.length) * 100 : 0)

const boardName = computed(() => (latestHand.value ? latestHand.value.to_name : ''))
const iHaveBoard = computed(() => !!(latestHand.value && auth.user && latestHand.value.to_user === auth.user.id))
function initials(name) {
  const parts = String(name || '').trim().split(/\s+/).filter(Boolean)
  return ((parts[0] || '?')[0] + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase()
}

const LOG_TAG = { timeline: 'Times changed', zones: 'Zones changed' }
const ackShare = (row) => (row.recipients ? ((row.acked || 0) / row.recipients) * 100 : 0)
const ackHead = (row) => (row.acked || 0) + ' of ' + row.recipients + ' got it'

watch(
  () => log.value.length,
  (n) => emit('counts', { log: n }),
  { immediate: true },
)

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

// A different session, or the session handed onto another plan (a publish can do that, step 17), is a different
// board: start again rather than read the new one over the old rows.
watch(sessionId, () => {
  rows.value = []
  loaded.value = false
  errorMsg.value = ''
  errorSticky.value = false
  read()
})
watch(
  () => (props.session ? props.session.planId : null),
  () => read(),
)
watch(
  () => (props.session ? props.session.planRev : null),
  () => read(),
)
</script>

<template>
  <div class="pv" :class="{ 'k2-ops': view !== 'all' }" :aria-busy="busy || sending ? 'true' : null">
    <!-- The phone's Ops tab: everything in one column -->
    <section v-if="view === 'all'" class="pv-ops" data-testid="plan-ops">
      <header class="pv-ops-head">
        <div class="pv-ops-id">
          <h2 class="pv-ops-title">Operations</h2>
          <p class="pv-ops-sub">
            <span class="pv-badge is-live" data-testid="ops-live">live</span>
            <span v-if="rev != null">plan version <strong data-testid="ops-rev">{{ rev }}</strong></span>
            <span data-testid="ops-counts">
              {{ groups.length }} {{ groups.length === 1 ? 'group' : 'groups' }} ·
              {{ underWay }} under way · {{ notStarted }} not started · {{ finished }} done
            </span>
          </p>
        </div>
        <div class="pv-ops-clock">
          <strong class="pv-ops-now" data-testid="ops-clock">{{ clockText }}</strong>
          <span v-if="t0" class="pv-ops-t0">T+0 <span data-testid="ops-t0">{{ t0Text }}</span></span>
          <span v-if="elapsedText" class="pv-ops-elapsed">{{ elapsedText }}</span>
        </div>
      </header>

      <p v-if="errorMsg" class="pv-ops-error" data-testid="ops-error">
        {{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template>
        <button type="button" class="pv-ops-error-x" data-testid="ops-error-dismiss" aria-label="Dismiss" @click="dismissError">×</button>
      </p>

      <SkeletonLoader v-if="!loaded" variant="board" :rows="4" label="Reading the ops board…" data-testid="ops-loading" />
      <EmptyState v-else-if="!groups.length" compact icon="plan" title="Nothing planned" text="This plan has no moments yet." data-testid="ops-empty" />

      <ul v-else class="pv-ops-list">
        <li
          v-for="group in groups"
          :key="group.id"
          class="pv-ops-row"
          :class="'is-' + group.status"
          data-testid="ops-row"
          :data-group="group.id"
          :data-status="group.status"
        >
          <div class="pv-ops-line">
            <span class="pv-ops-name" data-testid="ops-group">{{ group.name }}</span>
            <span class="pv-ops-state" data-testid="ops-state">{{ STATE_WORD[group.status] }}</span>
            <span class="pv-ops-when" data-testid="ops-when">{{ whenText(group) }}</span>
          </div>
          <div class="pv-ops-line is-detail">
            <span class="pv-ops-next" data-testid="ops-next">{{ nextText(group) }}</span>
            <span class="pv-ops-travel" data-testid="ops-travel">{{ travelText(group) }}</span>
            <span class="pv-ops-place" data-testid="ops-place">{{ placeText(group) }}</span>
          </div>
          <div v-if="markText(group) || canMark(group)" class="pv-ops-line is-mark">
            <span
              v-if="markText(group)"
              class="pv-ops-mark"
              :class="group.current.marked_state === 'missed' ? 'is-miss' : 'is-arrived'"
              data-testid="ops-mark"
            >{{ markText(group) }}</span>
            <template v-else>
              <button
                type="button"
                class="pv-ops-act"
                data-testid="ops-mark-arrived"
                :disabled="busy === 'mark:' + group.id + ':arrived'"
                @click="mark(group, 'arrived')"
              >Arrived</button>
              <button
                type="button"
                class="pv-ops-act is-miss"
                data-testid="ops-mark-missed"
                :disabled="busy === 'mark:' + group.id + ':missed'"
                @click="mark(group, 'missed')"
              >Missed</button>
            </template>
          </div>
        </li>
      </ul>

      <div v-if="groups.length" class="pv-ops-hand">
        <span class="pv-ops-with" data-testid="ops-handback">{{ handText }}</span>
      </div>

      <!-- The plan's own log (step 22). Messages a planner sends, and the changes the plan itself made, with the one
           tally that matters during a show: who has it and who to radio. -->
      <section v-if="planId" class="pv-log" data-testid="plan-log">
        <header class="pv-log-head">
          <h3 class="pv-log-title">Plan log</h3>
        </header>

        <form class="pv-log-form" @submit.prevent="send">
          <select v-model="toWhom" class="pv-log-select" data-testid="log-audience" aria-label="Who gets this message">
            <option value="all">every group</option>
            <option value="ops">the ops team</option>
            <option v-for="group in groups" :key="group.id" :value="'group:' + group.id">{{ group.name }}</option>
          </select>
          <input
            v-model="draft"
            class="pv-input"
            data-testid="log-draft"
            maxlength="300"
            placeholder="Message"
            aria-label="Message"
            @keyup.enter="send"
          />
          <button type="submit" class="pv-btn is-primary" data-testid="log-send" :disabled="!canSend">
            {{ sending ? 'Sending…' : 'Send' }}
          </button>
        </form>

        <p v-if="!log.length" class="pv-log-empty" data-testid="log-empty">Nothing sent yet.</p>
        <ul v-else class="pv-log-list k2-longlist">
          <li
            v-for="row in log"
            :key="row.id"
            class="pv-log-row"
            :class="{ 'is-timeline': row.kind === 'timeline' }"
            data-testid="log-row"
            :data-kind="row.kind"
            :data-log="row.id"
          >
            <div class="pv-log-line">
              <span class="pv-log-kind">{{ row.kind === 'timeline' ? 'Times changed' : 'Message' }}</span>
              <span class="pv-log-from" data-testid="log-from">
                {{ row.from_name }} · {{ formatTime(row.at) }} · {{ audienceWord(row) }}
              </span>
              <span class="pv-log-tally" data-testid="log-tally">{{ tally(row) }}</span>
            </div>
            <p class="pv-log-body" data-testid="log-body">{{ row.body }}</p>
            <button
              v-if="row.i_recipient && !row.i_acked"
              type="button"
              class="pv-ops-act"
              data-testid="log-ack"
              :disabled="acking === row.id"
              @click="ack(row)"
            >
              Got it
            </button>
          </li>
        </ul>
      </section>
    </section>

    <!-- The website's Live panel, Operations tab: the run clock, who has the board, and a card per group -->
    <section v-else-if="view === 'ops'" class="k2-opsview" data-testid="plan-ops">
      <div class="k2-runclock">
        <div class="k2-rc-top">
          <span class="k2-rc-live" data-testid="ops-live"><i aria-hidden="true"></i>Live</span>
          <span v-if="rev != null" class="k2-rc-rev">Plan version <span data-testid="ops-rev">{{ rev }}</span></span>
        </div>
        <div class="k2-rc-mid">
          <strong v-if="elapsedText" class="k2-rc-elapsed" aria-label="Time since T+0">{{ elapsedText }}</strong>
          <div class="k2-rc-times">
            <span><span data-testid="ops-clock">{{ clockText }}</span> now</span>
            <span v-if="t0">T+0 at <span data-testid="ops-t0">{{ t0Text }}</span></span>
          </div>
        </div>
        <div class="k2-rc-bar" aria-hidden="true">
          <i class="is-active" :style="{ width: share(underWay) + '%' }"></i>
          <i class="is-pending" :style="{ width: share(notStarted) + '%' }"></i>
          <i class="is-done" :style="{ width: share(finished) + '%' }"></i>
        </div>
        <div class="k2-rc-legend" data-testid="ops-counts">
          <span><i class="is-active"></i>{{ underWay }} under way</span>
          <span><i class="is-pending"></i>{{ notStarted }} not started</span>
          <span><i class="is-done"></i>{{ finished }} done</span>
          <b class="k2-rc-n">{{ groups.length }} {{ groups.length === 1 ? 'group' : 'groups' }}</b>
        </div>
      </div>

      <p v-if="errorMsg" class="k2-ops-error" role="alert" data-testid="ops-error">
        <span>{{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template></span>
        <button type="button" class="k2-ops-x" data-testid="ops-error-dismiss" aria-label="Dismiss" @click="dismissError">×</button>
      </p>

      <div v-if="loaded && groups.length" class="k2-board">
        <span class="k2-board-av" aria-hidden="true">{{ boardName ? initials(boardName) : '–' }}</span>
        <div class="k2-board-txt">
          <b>{{ boardName ? (iHaveBoard ? 'You have the board' : boardName + ' has the board') : 'Nobody has the board yet' }}</b>
          <span data-testid="ops-handback">{{ handText }}</span>
        </div>
        <button
          type="button"
          class="k2-opsbtn"
          data-testid="ops-take"
          :disabled="busy === 'take' || iHaveBoard"
          @click="takeBoard"
        >{{ iHaveBoard ? 'You have it' : busy === 'take' ? 'Taking…' : 'Take board' }}</button>
      </div>

      <SkeletonLoader v-if="!loaded" variant="board" :rows="4" label="Reading the ops board…" data-testid="ops-loading" />
      <EmptyState v-else-if="!groups.length" compact icon="plan" title="Nothing planned" text="This plan has no moments yet." data-testid="ops-empty" />

      <template v-else>
        <div class="k2-opsfilter" role="group" aria-label="Show groups">
          <button type="button" :aria-pressed="filter === 'all' ? 'true' : 'false'" data-testid="ops-filter-all" @click="filter = 'all'">All <span>{{ groups.length }}</span></button>
          <button type="button" :aria-pressed="filter === 'soon' ? 'true' : 'false'" data-testid="ops-filter-soon" @click="filter = 'soon'">Due soon <span>{{ dueSoonCount }}</span></button>
          <button type="button" :aria-pressed="filter === 'quiet' ? 'true' : 'false'" data-testid="ops-filter-quiet" @click="filter = 'quiet'">No signal <span>{{ quietCount }}</span></button>
        </div>

        <p v-if="!shownGroups.length" class="k2-ops-none">{{ FILTER_EMPTY[filter] }}</p>
        <ul v-else class="k2-gcards">
          <li
            v-for="group in shownGroups"
            :key="group.id"
            class="k2-gcard"
            :class="['is-' + group.status, { 'is-soon': isDueSoon(group) }]"
            data-testid="ops-row"
            :data-group="group.id"
            :data-status="group.status"
          >
            <div class="k2-gc-top">
              <i class="k2-gc-dot" :style="{ background: colourOf(group.id) }" aria-hidden="true"></i>
              <b class="k2-gc-name" data-testid="ops-group" :title="group.name">{{ group.name }}</b>
              <span class="k2-gc-state" :class="'is-' + group.status" data-testid="ops-state">{{ STATE_WORD[group.status] }}</span>
              <span class="k2-gc-sig" :class="'is-' + signalOf(group).kind" :title="placeText(group)">
                <svg viewBox="0 0 16 16" aria-hidden="true"><rect x="1" y="10" width="2.6" height="4" rx=".6" /><rect x="5.2" y="7" width="2.6" height="7" rx=".6" /><rect x="9.4" y="4" width="2.6" height="10" rx=".6" /><rect x="13.6" y="1" width="1.4" height="13" rx=".6" /></svg>{{ signalOf(group).text }}
              </span>
            </div>
            <div class="k2-gc-move">
              <span class="k2-gc-moves" aria-hidden="true">
                <small>{{ moveOf(group).a }}</small> {{ moveOf(group).at }}
                <template v-if="moveOf(group).b"><span class="k2-gc-arrow">→</span><small>{{ moveOf(group).b }}</small> {{ moveOf(group).bt }}</template>
              </span>
              <span class="k2-sr" data-testid="ops-when">{{ whenText(group) }}</span>
              <span class="k2-sr" data-testid="ops-next">{{ nextText(group) }}</span>
              <span v-if="pillText(group)" class="k2-gc-pill" :class="{ 'is-due': leftMs(group) <= 0 || isDueSoon(group) }" aria-hidden="true">{{ pillText(group) }}</span>
            </div>
            <div class="k2-gc-bar" aria-hidden="true"><i :style="{ width: progressOf(group) + '%' }"></i></div>
            <div class="k2-gc-foot">
              <span class="k2-gc-meta">
                <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="13" cy="4" r="2" /><path d="m9 20 3-6 3 3v4M7 12l3-4 4 1 2 3h3" /></svg>
                <span data-testid="ops-travel">{{ travelText(group) }}</span>
                <template v-if="noteOf(group)"> · {{ noteOf(group) }}</template>
                <span class="k2-sr" data-testid="ops-place">{{ placeText(group) }}</span>
              </span>
              <span v-if="markText(group)" class="k2-gc-marked" :class="group.current.marked_state === 'missed' ? 'is-miss' : 'is-arrived'" data-testid="ops-mark">{{ markText(group) }}</span>
              <span v-else-if="canMark(group)" class="k2-gc-acts">
                <button
                  type="button"
                  class="k2-gc-act"
                  aria-pressed="false"
                  data-testid="ops-mark-arrived"
                  :disabled="busy === 'mark:' + group.id + ':arrived'"
                  @click="mark(group, 'arrived')"
                ><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5L20 7" /></svg>Arrived</button>
                <button
                  type="button"
                  class="k2-gc-act is-miss"
                  aria-pressed="false"
                  data-testid="ops-mark-missed"
                  :disabled="busy === 'mark:' + group.id + ':missed'"
                  @click="mark(group, 'missed')"
                >Missed</button>
              </span>
            </div>
          </li>
        </ul>
      </template>
    </section>

    <!-- The website's Live panel, Plan log tab: send to the plan's groups, and who has read what -->
    <section v-else-if="view === 'log'" class="k2-logview" data-testid="plan-ops">
      <p v-if="errorMsg" class="k2-ops-error" role="alert" data-testid="ops-error">
        <span>{{ errorMsg }}</span>
        <button type="button" class="k2-ops-x" data-testid="ops-error-dismiss" aria-label="Dismiss" @click="dismissError">×</button>
      </p>
      <div v-if="planId" class="k2-logwrap" data-testid="plan-log">
        <form class="k2-logform" @submit.prevent="send">
          <select v-model="toWhom" class="pv-log-select" data-testid="log-audience" aria-label="Who gets this message">
            <option value="all">Every group</option>
            <option value="ops">The ops team</option>
            <option v-for="group in groups" :key="group.id" :value="'group:' + group.id">{{ group.name }}</option>
          </select>
          <div class="k2-logrow">
            <input
              v-model="draft"
              class="kin"
              data-testid="log-draft"
              maxlength="300"
              placeholder="Message to the groups"
              aria-label="Message to the groups"
            />
            <button type="submit" class="k2-opsbtn is-ink" data-testid="log-send" :disabled="!canSend">{{ sending ? 'Sending…' : 'Send' }}</button>
          </div>
        </form>

        <SkeletonLoader v-if="!loaded" variant="board" :rows="3" label="Reading the plan log…" />
        <p v-else-if="!log.length" class="k2-ops-none" data-testid="log-empty">Nothing sent yet.</p>
        <ul v-else class="k2-logs">
          <li
            v-for="row in log"
            :key="row.id"
            class="k2-logentry"
            data-testid="log-row"
            :data-kind="row.kind"
            :data-log="row.id"
          >
            <span class="k2-logtag" :class="'is-' + row.kind">{{ LOG_TAG[row.kind] || 'Message' }}</span>
            <div class="k2-logmeta" data-testid="log-from">{{ formatTime(row.at) }} · {{ row.from_name }} → {{ audienceWord(row) }}</div>
            <p class="k2-logbody" data-testid="log-body">{{ row.body }}</p>
            <span class="k2-sr" data-testid="log-tally">{{ tally(row) }}</span>
            <div v-if="row.recipients != null" class="k2-logack" aria-hidden="true">
              <span class="k2-logbar"><i :style="{ width: ackShare(row) + '%' }"></i></span>{{ ackHead(row) }}
            </div>
            <div v-else-if="tally(row)" class="k2-logack" aria-hidden="true">{{ tally(row) }}</div>
            <div v-if="row.waiting && row.waiting.length" class="k2-logwait" aria-hidden="true">
              <span class="k2-logwait-h">Waiting on</span>
              <span v-for="name in row.waiting" :key="name" class="k2-waitchip"><i :style="{ background: colourOfName(name) }"></i>{{ name }}</span>
            </div>
            <button
              v-if="row.i_recipient && !row.i_acked"
              type="button"
              class="k2-opsbtn"
              data-testid="log-ack"
              :disabled="acking === row.id"
              @click="ack(row)"
            >Got it</button>
          </li>
        </ul>
      </div>
    </section>
  </div>
</template>
