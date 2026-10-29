<script setup>
// PlanSchedule — the timetable a person follows: one moment per frame, on the plan's own clock.
//
// WHO THIS IS FOR. Everyone the board is not for: a member, an IC, a group admin, a marshal. The plan board is the
// planner's instrument — it draws a strip of frames and drags people around a map — and this is what the people who
// walk it need instead. It is deliberately not the board with its controls hidden: there is no strip, no map and no
// frames to select, because a follower's question is "when, and what is the clock saying about it", not "may I move
// anybody". (Step 16's job; the board keeps root and planner.)
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
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { formatDayTime, formatDuration, formatTime } from '../../utils/time'
import { formatOffset } from '../../utils/planFrames'
import { planErrorMessage, usePlan } from '../../composables/usePlan'
import '../../assets/planova.css'

const props = defineProps({
  eventId: { type: String, required: true },
  // The session to read: the live one, the scheduled one, or the last one that has ended (EventView picks). Null
  // when the event has never been started, which is the one case with nothing to read.
  session: { type: Object, default: null },
  // True for ops staff (root, planner, marshal): they read every group's timetable. False for everyone else, whose
  // rows the database has already scoped to their group.
  whole: { type: Boolean, default: false },
  // The caller's group, for the header and for the no-group empty state. The rows are the authority for what is
  // shown; this only names it when the read has no rows to name.
  myGroup: { type: Object, default: null },
  // Seam for the development harness; in the app this is absent and the component reads through usePlan.
  api: { type: Object, default: null },
})

const api = props.api || usePlan(props.eventId)

const POLL_MS = 30000 // the floor, not the point: the wake at each moment is what keeps the screen honest
const TICK_MS = 1000

const rows = ref([]) // the read, exactly as it answered
const logRows = ref([]) // what the plan's log says to this person (058)
const loaded = ref(false) // one answer has arrived (an empty read is still an answer)
const errorMsg = ref('')
const readAt = ref(null)
const now = ref(Date.now())
const busyAck = ref(0) // the log row whose ack is landing
let running = false
let again = false // something changed while the read was in flight: the answer is stale, ask once more
let wakeTimer = null
let pollTimer = null
let tickTimer = null

const sessionId = computed(() => (props.session ? props.session.id : null))
const planId = computed(() => (props.session && props.session.planId ? props.session.planId : null))
const t0 = computed(() => {
  const s = props.session
  return s ? s.t0At || s.startsAt || null : null
})
const endedAt = computed(() => (props.session && props.session.endedAt ? props.session.endedAt : null))
const phase = computed(() => {
  const s = props.session
  if (!s) return 'none'
  if (s.endedAt) return 'ended'
  if (s.startsAt && s.startsAt.getTime() > now.value) return 'scheduled'
  return 'live'
})
const phaseWord = computed(() => ({ none: 'not started', live: 'live', scheduled: 'scheduled', ended: 'ended' })[phase.value])

// The instant the screen is speaking about: the end of a closed show, otherwise the clock on the wall.
const clockAt = computed(() => (endedAt.value ? endedAt.value : new Date(now.value)))
const clockText = computed(() => formatTime(clockAt.value))
const t0Text = computed(() => (t0.value ? formatTime(t0.value) : ''))
const elapsedText = computed(() =>
  t0.value ? formatOffset((clockAt.value.getTime() - t0.value.getTime()) / 1000) : '',
)
const planName = computed(() => (rows.value.length ? rows.value[0].plan_name : ''))
const rev = computed(() => (rows.value.length ? rows.value[0].plan_rev : props.session ? props.session.planRev : null))
const groupName = computed(() => {
  if (props.whole) return ''
  return rows.value.length ? rows.value[0].group_name : props.myGroup ? props.myGroup.name : ''
})

/** The log rows addressed to this person: what a planner said, and the changes to their own times (058). */
const myMessages = computed(() => logRows.value.filter((row) => row.i_recipient))

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
  if (!id) return
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
    const logAsk = plan && api.readLog ? api.readLog(plan, 6).catch(() => null) : Promise.resolve([])
    const [answered, messages] = await Promise.all([api.readTimetable(id, at), logAsk])
    if (sessionId.value !== id || endedAt.value !== at) {
      again = true
      return
    }
    rows.value = answered
    if (messages) logRows.value = messages
    errorMsg.value = ''
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

const STATE_LABEL = {
  pending: 'due',
  late: 'late',
  arrived: 'arrived',
  missed: 'missed',
  not_required: 'not required',
}
function stateLabel(row) {
  return STATE_LABEL[row.state] || row.state
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

/** "2 min late" / "45 s early" / "on time" — the interval the database answered, in words. */
function latenessText(seconds) {
  if (seconds == null) return ''
  if (Math.abs(seconds) < 30) return 'on time'
  return formatDuration(Math.abs(seconds) * 1000) + (seconds > 0 ? ' late' : ' early')
}

/** The line under the word. States are the database's; countdowns are this screen's arithmetic on planned_at. */
function detail(row) {
  const planned = new Date(row.planned_at).getTime()
  if (row.state === 'pending') {
    const wait = planned - clockAt.value.getTime()
    return wait <= 0 ? 'due now' : 'in ' + formatDuration(wait)
  }
  if (row.state === 'late') {
    return formatDuration(clockAt.value.getTime() - planned) + ' late'
  }
  if (row.state === 'arrived') {
    const said = latenessText(secondsOfInterval(row.lateness))
    return [said, row.marked_at ? 'recorded ' + formatTime(row.marked_at) : ''].filter(Boolean).join(' · ')
  }
  if (row.state === 'missed') {
    const after = secondsOfInterval(row.lateness)
    const how = after != null && after > 30 ? 'decided ' + formatDuration(after * 1000) + ' after' : 'decided'
    return [how, row.marked_at ? 'recorded ' + formatTime(row.marked_at) : ''].filter(Boolean).join(' · ')
  }
  if (row.state === 'not_required') return 'off site at this moment'
  return ''
}

// ---------- the plan log (step 22) ----------

/**
 * One tap on a message: the database writes the wall-clock instant and the row is read back rather than guessed. A
 * second tap would change nothing (the first instant stands), so the button is simply gone once it is acked.
 */
async function ack(row) {
  if (!api.ackLog || busyAck.value) return
  busyAck.value = row.id
  try {
    await api.ackLog(row.id)
    await read()
  } catch (error) {
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
  } finally {
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
  read()
})

// The event ending changes the instant this screen is speaking about (the read is taken at the close), so the
// timetable is read again rather than left saying what the clock said a moment before the end.
watch(endedAt, () => read())

// The push: plan_publish moves the session's plan_rev, and useEventSessions already listens to event_sessions, so a
// publish elsewhere is this screen's cue to ask again. The cue is not the answer — the read is.
watch(
  () => (props.session ? props.session.planRev : null),
  () => read(),
)
</script>

<template>
  <div class="pv">
    <section class="pv-sched" data-testid="plan-schedule">
      <header class="pv-sched-head">
        <div class="pv-sched-id">
          <h2 class="pv-sched-title">{{ whole ? 'Timetable' : 'Your schedule' }}</h2>
          <p class="pv-sched-sub">
            <span class="pv-badge" :class="{ 'is-live': phase === 'live' }" data-testid="sched-phase">{{ phaseWord }}</span>
            <template v-if="planName">
              <span class="pv-sched-plan" data-testid="sched-plan">{{ planName }}</span>
              <span v-if="rev != null"> · version <strong data-testid="sched-rev">{{ rev }}</strong></span>
            </template>
            <span v-if="!whole && groupName" class="pv-sched-group-name" data-testid="sched-group">
              · your group <strong>{{ groupName }}</strong>
            </span>
          </p>
        </div>
        <div class="pv-sched-clock" data-testid="sched-clock" :data-t0="t0 ? t0.toISOString() : ''">
          <strong class="pv-sched-now" data-testid="sched-now">{{ clockText }}</strong>
          <span v-if="t0" class="pv-sched-t0">T+0 <span data-testid="sched-t0">{{ t0Text }}</span></span>
          <span v-if="elapsedText" class="pv-sched-elapsed">{{ elapsedText }}</span>
        </div>
      </header>

      <p v-if="phase === 'scheduled'" class="pv-sched-line" data-testid="sched-scheduled">
        The event starts {{ formatDayTime(session.startsAt) }}. These are the plan's times, all still to come.
      </p>
      <p v-if="phase === 'ended'" class="pv-sched-line" data-testid="sched-ended">
        The event ended {{ formatTime(endedAt) }}. This is the timetable as it stood when it closed.
      </p>

      <!-- A read that failed says so and keeps the last answer: a schedule that blanks itself is worse than an old one. -->
      <p v-if="errorMsg" class="pv-sched-line is-warn" data-testid="sched-error">
        {{ errorMsg }}<template v-if="readAt"> Showing the read from {{ formatTime(readAt) }}.</template>
      </p>

      <!-- What a planner said, and "your times changed" when a publish moved this group's walk (step 22). One tap to
           say it was read; an acked row stays as a quiet line rather than disappearing, because it is a record. -->
      <div v-if="myMessages.length" class="pv-sched-log" data-testid="sched-log">
        <article
          v-for="row in myMessages"
          :key="row.id"
          class="pv-sched-msg"
          :class="{ 'is-new': !row.i_acked, 'is-timeline': row.kind === 'timeline' }"
          data-testid="sched-msg"
          :data-kind="row.kind"
          :data-acked="row.i_acked ? 'true' : 'false'"
        >
          <div class="pv-sched-msg-line">
            <strong class="pv-sched-msg-title">{{ row.kind === 'timeline' ? 'Your times changed' : row.from_name }}</strong>
            <span class="pv-sched-msg-at">{{ formatTime(row.at) }}</span>
            <span v-if="row.i_acked" class="pv-sched-msg-done" data-testid="sched-acked">
              got it {{ formatTime(row.i_acked) }}
            </span>
            <button
              v-else
              type="button"
              class="pv-sched-ack"
              data-testid="sched-ack"
              :disabled="busyAck === row.id"
              @click="ack(row)"
            >
              Got it
            </button>
          </div>
          <p class="pv-sched-msg-body" data-testid="sched-msg-body">{{ row.body }}</p>
        </article>
      </div>

      <p v-if="!loaded" class="pv-sched-empty" data-testid="sched-loading">Reading the schedule…</p>

      <div v-else-if="!rows.length" class="pv-sched-empty" data-testid="sched-empty">
        <template v-if="phase === 'none'">
          No schedule yet. It appears here when a planner starts the event on a plan.
        </template>
        <template v-else-if="!session.planId">
          This event is running without a plan, so there is no timetable to follow.
        </template>
        <template v-else-if="!whole && !groupName">
          You are not in a group yet. Ask the root, a planner or a group admin to add you, and your moments appear here.
        </template>
        <template v-else-if="whole">This plan has no moments in it yet.</template>
        <template v-else>This plan has no moments for {{ groupName }} yet.</template>
      </div>

      <ol v-else class="pv-sched-list">
        <li
          v-for="(moment, i) in moments"
          :key="moment.frameId"
          class="pv-sched-moment"
          :class="{ 'is-next': i === nextIndex, 'is-past': moment.at.getTime() <= clockAt.getTime() }"
          data-testid="sched-moment"
          :data-frame="moment.frameId"
          :data-t="moment.t_s"
        >
          <div class="pv-sched-when">
            <strong class="pv-sched-at" :data-testid="'sched-at-' + moment.t_s">{{ formatTime(moment.at) }}</strong>
            <span class="pv-sched-offset">{{ formatOffset(moment.t_s) }}</span>
            <span v-if="moment.note" class="pv-sched-note" data-testid="sched-note">{{ moment.note }}</span>
          </div>
          <div class="pv-sched-rows">
            <div
              v-for="row in moment.rows"
              :key="row.group_id"
              class="pv-sched-row"
              :class="'is-' + row.state.replace('_', '-')"
              data-testid="sched-row"
              :data-group="row.group_id"
              :data-state="row.state"
            >
              <span v-if="whole" class="pv-sched-group">{{ row.group_name }}</span>
              <span class="pv-sched-state" data-testid="sched-state">{{ stateLabel(row) }}</span>
              <span class="pv-sched-detail">{{ detail(row) }}</span>
              <span v-if="i === nextIndex" class="pv-sched-flag">next</span>
            </div>
          </div>
        </li>
      </ol>

      <p v-if="rows.length" class="pv-sched-foot">
        Times are the plan's own clock, T+0 at {{ t0Text }}. A moment marked <em>not required</em> means
        {{ whole ? 'the group is' : 'your group is' }} off site then, so there is nothing to arrive at.
      </p>
    </section>
  </div>
</template>
