<script setup>
// Event status card. Three states, each showing what will happen and only the actions that fit:
//
//   Not live   : Start event now · Schedule…   (Schedule = start time + optional end time, one form)
//   Scheduled  : Start now · Edit schedule · Cancel schedule
//   Live       : Remind ICs · Set / Change end time · Remove end time · End event now
//                ("ends 9:00 pm (in 2 h 58 min)" or "no end time")
//
// Root and planners get the buttons; everyone else only sees the status.
// ICs can only share while the event is live (the database checks this too).
// Slot "sharing": a second row for the IC's own Share / My GPS details buttons.
//
// Run sheet (merger Stage 4): retired in step 24 (060). A session runs a plan or nothing; the Start and Schedule
// panels offer the event's plans and nothing else, and the run-sheet engine cannot be started at all.
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { formatTime, formatDay, formatDayTime, formatDuration, toDateTimeLocal } from '../utils/time'
import { remindIcsNow } from '../composables/usePushNotifications'
import { askConfirm, toast } from '../composables/useNotify'
import { supabase } from '../lib/supabase'

const props = defineProps({
  sessions: { type: Object, required: true }, // from useEventSessions
  eventId: { type: String, required: true },
  canManage: { type: Boolean, default: false },
  icCount: { type: Number, default: 0 }, // ICs in the event
  sharingCount: { type: Number, default: 0 }, // ICs sharing right now (live only)
  plans: { type: Array, default: () => [] }, // plan_list rows: a session runs one of these
  plansReady: { type: Boolean, default: true }, // false while the list is still loading: Start waits for it
  plannedStart: { type: String, default: null }, // the event's planned times (Create-an-event wizard), ISO or null
  plannedEnd: { type: String, default: null },
})

// ---------- What runs: a published plan, or nothing ----------
const planList = computed(() => props.plans || [])
const hasPlans = computed(() => planList.value.length > 0)
const livePlans = computed(() => planList.value.filter((p) => p.status === 'live'))

const engineChoice = ref('') // '' = nothing; 'plan:<id>'
const startPlan = computed(() => (engineChoice.value.startsWith('plan:') ? engineChoice.value.slice(5) : null))
function planName(id) {
  const p = id && planList.value.find((x) => x.id === id)
  return p ? p.name : ''
}
const openPlanName = computed(() => planName(props.sessions.openSession.value && props.sessions.openSession.value.planId))
function planOption(p) {
  const frames = p.frame_count === 1 ? '1 frame' : (p.frame_count || 0) + ' frames'
  const status = p.status === 'live' ? 'published' : p.status === 'ready' ? 'checked, not published' : p.status === 'draft' ? 'draft: not published' : p.status
  return p.name + ' · ' + frames + ' · ' + status
}
// What to preselect: what the open session runs, else the published plan, else none
function preselectEngine() {
  const open = props.sessions.openSession.value
  if (open && open.planId && planList.value.some((p) => p.id === open.planId)) {
    engineChoice.value = 'plan:' + open.planId
    return
  }
  engineChoice.value = livePlans.value.length ? 'plan:' + livePlans.value[0].id : ''
}

// ---------- T+0: when the running plan's clock reads +0:00 ----------
// QA 31 Oct: nothing set it, so every plan ran at its default 18:00 -- a walk-through started at 01:04 showed every
// group "7 h late" from its first moment. "Now" starts the plan's clock with the event; a clock time is for a plan
// written against the real night ("+0:00 is Doors Open at 16:00"). It is written to the plan, in Singapore's date and
// time, just before the start, so start_event reads it the way it always has.
const t0Mode = ref('now') // 'now' | 'clock'
const t0Clock = ref('18:00')
function singapore(date) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date)
  const part = (type) => parts.find((x) => x.type === type).value
  return { date: `${part('year')}-${part('month')}-${part('day')}`, time: `${part('hour')}:${part('minute')}` }
}
const t0Text = computed(() => (t0Mode.value === 'now' ? 'now' : formatClock(t0Clock.value)))
function formatClock(hhmm) {
  return formatTime(`2000-01-01T${hhmm || '00:00'}:00+08:00`) // the clock is Singapore's, like formatTime
}
async function writeT0(planId) {
  const p = planList.value.find((x) => x.id === planId)
  if (!p) return
  const today = singapore(new Date())
  const time = t0Mode.value === 'now' ? today.time : t0Clock.value
  const { error } = await supabase.rpc('plan_save', {
    p_event: props.eventId,
    p_plan: { id: p.id, name: p.name, rev: p.rev, for_date: today.date, t0_time: time + ':00' },
  })
  if (error) throw error
}

const live = computed(() => props.sessions.liveSession.value)
const scheduledStart = computed(() => props.sessions.scheduledStart.value)
const scheduledEnd = computed(() => props.sessions.scheduledEnd.value)

// Ticking clock for "in 2 h 58 min"
const now = ref(Date.now())
let clock = null
onMounted(() => (clock = setInterval(() => (now.value = Date.now()), 30000)))
onUnmounted(() => clearInterval(clock))

const endsIn = computed(() => {
  if (!scheduledEnd.value) return ''
  const ms = scheduledEnd.value.getTime() - now.value
  return ms < 60000 ? 'in less than a minute' : 'in ' + formatDuration(ms)
})

// Same day as the start = just the time ("9:00 pm"), else day + time
function endText(end, start) {
  return start && formatDay(end) === formatDay(start) ? formatTime(end) : formatDayTime(end)
}

// ---------- Running an action: result as a toast ----------
const busy = ref(false)

async function run(action, successText) {
  busy.value = true
  try {
    const result = await action()
    const text = typeof successText === 'function' ? successText(result) : successText
    toast(text.text || text, text.type || 'success')
    form.value = ''
  } catch (err) {
    toast(err.message, 'danger', 8000)
  }
  busy.value = false
}

// ---------- Form: 'schedule' (start + optional end, before the start) or 'end' (while live) ----------
const form = ref('')
const startDate = ref('') // "2026-10-13"
const startTime = ref('') // "15:00"
const endDate = ref('')
const endTime = ref('')
const endMode = ref('none') // '30' | '60' | '120' | '180' (minutes) | 'custom' | 'none'
const formError = ref('')

const DURATIONS = [
  { mode: '30', label: '30 min' },
  { mode: '60', label: '1 h' },
  { mode: '120', label: '2 h' },
  { mode: '180', label: '3 h' },
]

const pad = (n) => String(n).padStart(2, '0')
const dateOf = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
const timeOf = (d) => pad(d.getHours()) + ':' + pad(d.getMinutes())
const combine = (date, time) => (date && time ? new Date(date + 'T' + time) : null)

const formStart = computed(() =>
  form.value === 'schedule' ? combine(startDate.value, startTime.value) : live.value ? live.value.startsAt : null,
)
// Durations count from the start (scheduling) or from now (live)
const durationBase = computed(() => (form.value === 'schedule' ? formStart.value : new Date(now.value)))
const formEnd = computed(() => {
  if (endMode.value === 'none') return null
  if (endMode.value === 'custom') return combine(endDate.value, endTime.value)
  return durationBase.value ? new Date(durationBase.value.getTime() + Number(endMode.value) * 60000) : null
})

// "Live Tue 13 Oct, 3:00 pm → 5:00 pm · 2 h"
const summary = computed(() => {
  const start = formStart.value
  const end = formEnd.value
  if (form.value === 'end') {
    if (!end) return ''
    const ms = end.getTime() - Date.now()
    return 'Sharing stops at ' + endText(end, new Date()) + (ms > 0 ? ' (in ' + formatDuration(ms) + ')' : '')
  }
  if (!start) return ''
  if (!end) return 'Live from ' + formatDayTime(start) + ' until someone ends it'
  return 'Live ' + formatDayTime(start) + ' → ' + endText(end, start) + (end > start ? ' · ' + formatDuration(end - start) : '')
})

function setEndMode(mode) {
  endMode.value = mode
  if (mode === 'custom' && !endDate.value) {
    // Start the custom fields from what was shown (or 2 h after the start / now)
    const base = formEnd.value || new Date((durationBase.value || new Date()).getTime() + 2 * 3600000)
    endDate.value = dateOf(base)
    endTime.value = timeOf(base)
  }
}

// Which chip matches an existing end time
function modeFor(end, base) {
  if (!end) return 'none'
  const minutes = Math.round((end.getTime() - base.getTime()) / 60000)
  return DURATIONS.some((d) => Number(d.mode) === minutes) ? String(minutes) : 'custom'
}

function openSchedule() {
  const nextHour = new Date()
  nextHour.setHours(nextHour.getHours() + 1, 0, 0, 0)
  // Nothing scheduled yet: the event's planned times (from the Create-an-event wizard) if they are still ahead
  const plannedStart = props.plannedStart ? new Date(props.plannedStart) : null
  const plannedEnd = props.plannedEnd ? new Date(props.plannedEnd) : null
  const usePlanned = !scheduledStart.value && plannedStart && plannedStart > new Date()
  const start = scheduledStart.value || (usePlanned ? plannedStart : nextHour)
  const end = scheduledEnd.value || (usePlanned ? plannedEnd : null)
  startDate.value = dateOf(start)
  startTime.value = timeOf(start)
  endDate.value = end ? dateOf(end) : ''
  endTime.value = end ? timeOf(end) : ''
  endMode.value = modeFor(end, start)
  formError.value = ''
  preselectEngine()
  form.value = 'schedule'
}

function openEnd() {
  const end = scheduledEnd.value
  endDate.value = end ? dateOf(end) : ''
  endTime.value = end ? timeOf(end) : ''
  endMode.value = end ? 'custom' : '60'
  formError.value = ''
  form.value = 'end'
}

async function saveForm() {
  formError.value = ''
  const start = formStart.value
  const end = formEnd.value

  if (form.value === 'schedule' && !(start > new Date())) return (formError.value = 'Pick a start time in the future.')
  if (form.value === 'end' && !end) return (formError.value = 'Pick when the event should end.')
  if (endMode.value === 'custom' && !end) return (formError.value = 'Pick an end date and time.')
  if (end && end <= new Date()) return (formError.value = 'Pick an end time in the future.')
  if (end && start && end <= start) return (formError.value = 'The end time must be after the start time.')

  if (form.value === 'schedule') {
    await run(async () => {
      await props.sessions.scheduleStart(start, startPlan.value)
      if (end) await props.sessions.scheduleEnd(end)
      else if (scheduledEnd.value) await props.sessions.cancelScheduledEnd()
    }, 'Schedule saved. The event goes live at ' + formatDayTime(start) + (end ? ' and ends at ' + endText(end, start) : '') +
      whatRunsSuffix() + '.')
  } else {
    await run(() => props.sessions.scheduleEnd(end), "End time saved. Everyone's sharing stops at " + endText(end, start) + '.')
  }
}

// ---------- Buttons ----------
// With something to run, "Start" first opens a panel to pick what; with nothing, it asks straight away.
function openStart() {
  if (!hasPlans.value) return startNow()
  preselectEngine()
  const p = startPlan.value && planList.value.find((x) => x.id === startPlan.value)
  t0Mode.value = 'now'
  t0Clock.value = p && p.t0_time ? String(p.t0_time).slice(0, 5) : '18:00'
  formError.value = ''
  form.value = 'start'
}
// "…, running the plan "X"" for the toasts.
function whatRunsSuffix() {
  if (startPlan.value) return ', running the plan "' + planName(startPlan.value) + '"'
  return hasPlans.value ? ', with no plan (tracking only)' : ''
}
async function startNow() {
  const plan = startPlan.value
  const what = plan
    ? 'Plan: "' + planName(plan) + '", its T+0 ' + (t0Mode.value === 'now' ? 'now' : 'at ' + t0Text.value) + '. '
    : hasPlans.value
      ? 'No plan: tracking only (no schedule). '
      : ''
  const ok = await askConfirm({
    title: 'Start the event now?',
    message:
      what +
      'ICs can share their location from now, and ICs who are not sharing get a reminder on their phone.' +
      (scheduledEnd.value ? ' It still ends at ' + formatDayTime(scheduledEnd.value) + '.' : ''),
    confirmText: 'Start event',
  })
  if (!ok) return
  await run(
    async () => {
      if (plan) await writeT0(plan)
      return props.sessions.startEvent(plan)
    },
    'Event started' + (plan ? ' on "' + planName(plan) + '"' : '') + '. ICs can share now.',
  )
  // The "Event started" push now, rather than at the next minute's server check (that check still
  // covers anyone this misses, and scheduled starts). A failure here changes nothing for the planner.
  if (props.sessions.isLive.value) remindIcsNow(props.eventId, true).catch(() => {})
}

async function endNow() {
  const ok = await askConfirm({
    title: 'End the event now?',
    message:
      (scheduledEnd.value ? 'It ends now instead of at ' + formatTime(scheduledEnd.value) + '. ' : '') +
      "Everyone's location sharing stops. To continue later, press Start event again (a new recording). " +
      'This recording stays in Playback for 7 days.',
    confirmText: 'End event now',
    danger: true,
    requireText: 'END', // ending stops everyone's sharing: a typed word, so a stray click can't do it
  })
  if (ok) run(props.sessions.endEvent, (stopped) =>
    'Event ended.' + (stopped ? ' Stopped sharing for ' + stopped + (stopped === 1 ? ' person.' : ' people.') : ''),
  )
}

async function removeEnd() {
  const ok = await askConfirm({
    title: 'Remove the end time?',
    message: 'The event then stays live until someone presses End event now.',
    confirmText: 'Remove end time',
    danger: true,
  })
  if (ok) run(props.sessions.cancelScheduledEnd, 'End time removed. The event stays live until you end it.')
}

async function cancelSchedule() {
  const ok = await askConfirm({
    title: 'Cancel the schedule?',
    message: "The event won't start by itself. You can still press Start event now.",
    confirmText: 'Cancel schedule',
    danger: true,
  })
  if (ok) run(props.sessions.cancelSchedule, 'Schedule cancelled.')
}

// Push "a planner asked you to share" to every IC who isn't sharing yet (phone app, even closed)
function remind() {
  run(
    () => remindIcsNow(props.eventId),
    (result) =>
      result && result.sent
        ? 'Reminder sent to ' + result.sent + (result.sent === 1 ? ' phone.' : ' phones.')
        : {
            text: 'No phone to remind: the ICs not sharing have no app with notifications on, or were reminded in the last minute.',
            type: 'warning',
          },
  )
}
</script>

<template>
  <section v-if="sessions.loaded.value" class="kp-status" data-testid="event-status" :aria-busy="busy ? 'true' : null">
    <div class="kp-status-bar">
      <span v-if="live" class="kp-chip kp-chip-ink" data-testid="status-live"><span class="kp-dot kp-pulse"></span>Live</span>
      <span v-else-if="scheduledStart" class="kp-chip kp-chip-mint" data-testid="status-scheduled">Scheduled</span>
      <span v-else class="kp-chip" data-testid="status-not-started">Not live</span>

      <span class="kp-status-text" data-testid="status-text">
        <template v-if="live">
          Since {{ formatTime(live.startsAt) }} ·
          <template v-if="scheduledEnd">
            ends <strong>{{ endText(scheduledEnd, live.startsAt) }}</strong> <span class="text-muted">({{ endsIn }})</span>
          </template>
          <span v-else class="text-muted">no end time</span>
          <span v-if="canManage && icCount" class="text-muted"> · {{ sharingCount }}/{{ icCount }} ICs sharing</span>
          <span v-if="openPlanName" data-testid="status-plan"> · <strong>{{ openPlanName }}</strong></span>
          <span v-else-if="hasPlans" class="text-muted" data-testid="status-tracking-only"> · tracking only</span>
        </template>
        <template v-else-if="scheduledStart">
          Starts <strong>{{ formatDayTime(scheduledStart) }}</strong> ·
          <template v-if="scheduledEnd">ends <strong>{{ endText(scheduledEnd, scheduledStart) }}</strong></template>
          <span v-else class="text-muted">no end time</span>
          <span v-if="openPlanName" data-testid="status-plan"> · <strong>{{ openPlanName }}</strong></span>
        </template>
        <template v-else>ICs can share once {{ canManage ? 'you start' : 'a planner starts' }} the event.</template>
      </span>

      <!-- Root / planner buttons (hidden while a form is open) -->
      <template v-if="canManage && !form">
        <template v-if="live">
          <button v-if="sharingCount < icCount" class="btn btn-sm btn-ghost" :disabled="busy" data-testid="remind-ics-btn" @click="remind">Remind ICs</button>
          <button class="btn btn-sm btn-ghost" :disabled="busy" data-testid="schedule-end-btn" @click="openEnd">{{ scheduledEnd ? 'Change end' : 'Set end' }}</button>
          <button v-if="scheduledEnd" class="btn btn-sm btn-ghost" :disabled="busy" data-testid="remove-end-btn" @click="removeEnd">Clear end</button>
          <button class="btn btn-sm btn-danger" :disabled="busy" data-testid="end-event-btn" @click="endNow">End event</button>
        </template>
        <template v-else-if="scheduledStart">
          <button class="btn btn-sm btn-ghost" :disabled="busy" data-testid="cancel-schedule-btn" @click="cancelSchedule">Cancel schedule</button>
          <button class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="schedule-btn" @click="openSchedule">Edit schedule</button>
          <button class="btn btn-sm btn-success" :disabled="busy || !plansReady" data-testid="start-event-btn" @click="openStart">Start now</button>
        </template>
        <template v-else>
          <button class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="schedule-btn" @click="openSchedule">Schedule</button>
          <button class="btn btn-sm btn-success" :disabled="busy || !plansReady" data-testid="start-event-btn" @click="openStart">Start now</button>
        </template>
      </template>
    </div>

    <!-- Start now: which published plan runs -->
    <form v-if="form === 'start'" class="kp-status-panel kp-fields" data-testid="start-form" @submit.prevent="startNow">
      <div>
        <label class="form-label" for="start-engine">What runs</label>
        <select id="start-engine" v-model="engineChoice" class="form-select" data-testid="start-engine">
          <option value="">Nothing: tracking only</option>
          <optgroup label="Plan">
            <option v-for="p in planList" :key="p.id" :value="'plan:' + p.id" :disabled="p.status !== 'live'">{{ planOption(p) }}</option>
          </optgroup>
        </select>
        <div class="form-text">Only published plans can run.</div>
      </div>
      <fieldset v-if="startPlan" data-testid="start-t0">
        <legend class="form-label" style="font-size: 13px">When is T+0?</legend>
        <div class="kp-actions" style="gap: 8px 16px">
          <label class="form-check mb-0">
            <input v-model="t0Mode" class="form-check-input" type="radio" value="now" data-testid="start-t0-now" />
            <span class="form-check-label">Now</span>
          </label>
          <label class="form-check mb-0 kp-inline">
            <input v-model="t0Mode" class="form-check-input" type="radio" value="clock" data-testid="start-t0-clock" />
            <span class="form-check-label text-nowrap">Today at</span>
            <input v-model="t0Clock" type="time" class="form-control form-control-sm" style="width: 8rem" :disabled="t0Mode !== 'clock'" aria-label="T+0 time" data-testid="start-t0-time" />
          </label>
        </div>
        <div class="form-text">Lateness is measured from T+0.</div>
      </fieldset>
      <div class="kp-actions" style="justify-content: flex-end">
        <button class="btn btn-sm btn-ghost" type="button" @click="form = ''">Cancel</button>
        <button class="btn btn-sm btn-success" type="submit" :disabled="busy" data-testid="start-confirm-btn">Start event</button>
      </div>
    </form>

    <!-- Schedule (start + optional end) / end-time panel -->
    <form v-if="form === 'schedule' || form === 'end'" class="kp-status-panel kp-fields" data-testid="time-form" @submit.prevent="saveForm">
      <h3 class="kp-title" style="font-size: 16px">{{ form === 'schedule' ? (scheduledStart ? 'Edit schedule' : 'Schedule event') : 'Set end time' }}</h3>

      <div v-if="form === 'schedule'">
        <span class="form-label d-block">Start</span>
        <div class="kp-inline">
          <input v-model="startDate" type="date" class="form-control" aria-label="Start date" required data-testid="start-date-input" />
          <input v-model="startTime" type="time" class="form-control" aria-label="Start time" required data-testid="start-time-input" />
        </div>
      </div>

      <div>
        <span class="form-label d-block">{{ form === 'schedule' ? 'End (optional)' : 'End in' }}</span>
        <div class="kp-actions" style="gap: 6px" role="group" aria-label="Event length">
          <button v-for="d in DURATIONS" :key="d.mode" type="button" class="kp-opt" :class="{ 'is-on': endMode === d.mode }" :data-testid="'duration-' + d.mode" @click="setEndMode(d.mode)">
            {{ form === 'end' ? '+' : '' }}{{ d.label }}
          </button>
          <button type="button" class="kp-opt" :class="{ 'is-on': endMode === 'custom' }" data-testid="duration-custom" @click="setEndMode('custom')">Pick a time</button>
          <button v-if="form === 'schedule'" type="button" class="kp-opt" :class="{ 'is-on': endMode === 'none' }" data-testid="duration-none" @click="setEndMode('none')">No end</button>
        </div>
        <div v-if="endMode === 'custom'" class="kp-inline mt-2">
          <input v-model="endDate" type="date" class="form-control" aria-label="End date" data-testid="end-date-input" />
          <input v-model="endTime" type="time" class="form-control" aria-label="End time" data-testid="end-time-input" />
        </div>
      </div>

      <!-- Which plan the scheduled start runs -->
      <div v-if="form === 'schedule' && hasPlans">
        <label class="form-label" for="schedule-engine">What runs</label>
        <select id="schedule-engine" v-model="engineChoice" class="form-select" data-testid="schedule-engine">
          <option value="">Nothing: tracking only</option>
          <optgroup label="Plan">
            <option v-for="p in planList" :key="p.id" :value="'plan:' + p.id" :disabled="p.status !== 'live'">{{ planOption(p) }}</option>
          </optgroup>
        </select>
      </div>

      <div class="kp-actions">
        <div class="kp-status-text small fw-bold" data-testid="time-summary">
          <span v-if="formError" class="text-danger" role="alert">{{ formError }}</span>
          <template v-else>{{ summary }}</template>
        </div>
        <button class="btn btn-sm btn-ghost" type="button" @click="form = ''">Cancel</button>
        <button class="btn btn-sm btn-primary" type="submit" :disabled="busy" data-testid="save-schedule-btn">Save</button>
      </div>
    </form>

    <div v-if="$slots.sharing" class="kp-status-extra">
      <slot name="sharing" />
    </div>
  </section>
</template>
