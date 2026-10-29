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
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { supabase } from '../../lib/supabase'
import { planErrorMessage } from '../../composables/usePlan'
import { formatDuration, formatTime } from '../../utils/time'
import { formatOffset } from '../../utils/planFrames'
import '../../assets/planova.css'

const props = defineProps({
  // The live session on a plan: { id, planId, t0At, planRev } from useEventSessions. Null while there is none.
  session: { type: Object, default: null },
  // Seam for a check; in the app this is absent and the read goes to the database.
  api: { type: Object, default: null },
})

const POLL_MS = 5000 // the midpoint moves with the readings; the statuses move at the moments (wake)
const TICK_MS = 1000
const WAKE_MAX_MS = 120000 // a moment further out than this is left to the poll

const rows = ref([]) // the read, exactly as it answered
const handover = ref([]) // the hand-back chain, newest first (057)
const log = ref([]) // what was sent to the plan's groups, and what the plan changed (058)
const loaded = ref(false) // one answer has arrived (an empty read is still an answer)
const errorMsg = ref('')
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
    errorMsg.value = ''
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
  const how = moment.marked_by ? 'by hand' : 'the phone was there'
  return (moment.marked_state === 'missed' ? 'Missed ' : 'Arrived ') + when + ' · ' + how
}

/** Record the current moment. One write, then a re-read: the screen never guesses what the row now says. */
async function mark(group, state) {
  const moment = group.current
  if (!moment || busy.value) return
  busy.value = 'mark:' + group.id + ':' + state
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
    errorMsg.value = planErrorMessage(error) || 'Could not record that.'
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
  try {
    const { error } = await supabase.rpc('handover_take', { p_session: sessionId.value })
    if (error) throw error
    errorMsg.value = ''
    await read()
  } catch (error) {
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
    errorMsg.value = planErrorMessage(error) || 'Could not send that message.'
  } finally {
    sending.value = false
  }
}

/** One tap: a message the ops team was sent, or the timeline change addressed to them. */
async function ack(row) {
  if (acking.value) return
  acking.value = row.id
  try {
    const { error } = await supabase.rpc('plan_log_ack', { p_log: row.id })
    if (error) throw error
    await read()
  } catch (error) {
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
  <div class="pv">
    <section class="pv-ops" data-testid="plan-ops">
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
      </p>

      <p v-if="!loaded" class="pv-ops-empty" data-testid="ops-loading">Reading the ops board…</p>
      <p v-else-if="!groups.length" class="pv-ops-empty" data-testid="ops-empty">
        This plan has no moments in it yet, so there is nothing for anyone to be doing.
      </p>

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
        <button type="button" class="pv-ops-act" data-testid="ops-take" :disabled="busy === 'take'" @click="takeBoard">
          Take the board
        </button>
      </div>

      <p v-if="groups.length" class="pv-ops-foot">
        Times are the plan's own clock, T+0 at {{ t0Text }}. <em>Travel</em> is the time the strip gives a group
        between one moment and its next; the distance is how far its ICs are from where the walk has it now, from
        the midpoint of their newest readings. A moment marked <em>auto</em> closes itself when an IC is inside the
        zone its point stands in; take the board when you take over so the next person knows who to ask.
      </p>

      <!-- The plan's own log (step 22). Messages a planner sends, and the changes the plan itself made, with the one
           tally that matters during a show: who has it and who to radio. -->
      <section v-if="planId" class="pv-log" data-testid="plan-log">
        <header class="pv-log-head">
          <h3 class="pv-log-title">Plan log</h3>
          <span class="pv-log-note" data-testid="log-note">
            What the plan's groups were told. People ack a message on their own schedule, with one tap.
          </span>
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
            placeholder="Say something to the plan — 300 characters"
            aria-label="Message"
            @keyup.enter="send"
          />
          <button type="submit" class="pv-btn is-primary" data-testid="log-send" :disabled="!canSend">
            {{ sending ? 'Sending…' : 'Send' }}
          </button>
        </form>

        <p v-if="!log.length" class="pv-log-empty" data-testid="log-empty">Nothing has been sent on this plan yet.</p>
        <ul v-else class="pv-log-list">
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
  </div>
</template>
