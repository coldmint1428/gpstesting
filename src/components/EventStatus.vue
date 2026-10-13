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
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { formatTime, formatDay, formatDayTime, formatDuration, toDateTimeLocal } from '../utils/time'
import { remindIcsNow } from '../composables/usePushNotifications'
import { askConfirm, toast } from '../composables/useNotify'

const props = defineProps({
  sessions: { type: Object, required: true }, // from useEventSessions
  eventId: { type: String, required: true },
  canManage: { type: Boolean, default: false },
  icCount: { type: Number, default: 0 }, // ICs in the event
  sharingCount: { type: Number, default: 0 }, // ICs sharing right now (live only)
})

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
const startValue = ref('')
const endValue = ref('')
const formError = ref('')

const PRESETS = [
  { label: '+30 min', ms: 30 * 60000 },
  { label: '+1 h', ms: 3600000 },
  { label: '+2 h', ms: 2 * 3600000 },
  { label: '+3 h', ms: 3 * 3600000 },
]

function openSchedule() {
  const nextHour = new Date()
  nextHour.setHours(nextHour.getHours() + 1, 0, 0, 0)
  startValue.value = toDateTimeLocal(scheduledStart.value || nextHour)
  endValue.value = scheduledEnd.value ? toDateTimeLocal(scheduledEnd.value) : ''
  formError.value = ''
  form.value = 'schedule'
}

function openEnd() {
  endValue.value = toDateTimeLocal(scheduledEnd.value || new Date(Date.now() + 2 * 3600000))
  formError.value = ''
  form.value = 'end'
}

// Presets count from the start (scheduling) or from now (live)
function preset(ms) {
  const base = form.value === 'schedule' && startValue.value ? new Date(startValue.value).getTime() : Date.now()
  endValue.value = toDateTimeLocal(new Date(base + ms))
}

async function saveForm() {
  formError.value = ''
  const start = form.value === 'schedule' ? new Date(startValue.value) : live.value ? live.value.startsAt : null
  const end = endValue.value ? new Date(endValue.value) : null

  if (form.value === 'schedule' && !(start > new Date())) return (formError.value = 'Pick a start time in the future.')
  if (form.value === 'end' && !end) return (formError.value = 'Pick an end time.')
  if (end && end <= new Date()) return (formError.value = 'Pick an end time in the future.')
  if (end && start && end <= start) return (formError.value = 'The end time must be after the start time.')

  if (form.value === 'schedule') {
    await run(async () => {
      await props.sessions.scheduleStart(start)
      if (end) await props.sessions.scheduleEnd(end)
      else if (scheduledEnd.value) await props.sessions.cancelScheduledEnd()
    }, 'Schedule saved. The event goes live at ' + formatDayTime(start) + (end ? ' and ends at ' + endText(end, start) : '') + '.')
  } else {
    await run(() => props.sessions.scheduleEnd(end), "End time saved. Everyone's sharing stops at " + endText(end, start) + '.')
  }
}

// ---------- Buttons ----------
async function startNow() {
  const ok = await askConfirm({
    title: 'Start the event now?',
    message:
      'ICs can share their location from now, and ICs who are not sharing get a reminder on their phone.' +
      (scheduledEnd.value ? ' It still ends at ' + formatDayTime(scheduledEnd.value) + '.' : ''),
    confirmText: 'Start event',
  })
  if (ok) run(props.sessions.startEvent, 'Event started. ICs can share now.')
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
  <div v-if="sessions.loaded.value" class="card mb-3" data-testid="event-status">
    <div class="card-body py-2">
      <div class="d-flex flex-wrap align-items-center gap-2">
        <!-- Status -->
        <span v-if="live" class="badge text-bg-danger" data-testid="status-live">● Live</span>
        <span v-else-if="scheduledStart" class="badge text-bg-warning" data-testid="status-scheduled">Scheduled</span>
        <span v-else class="badge text-bg-secondary" data-testid="status-not-started">Not live</span>

        <span class="small flex-grow-1" data-testid="status-text">
          <template v-if="live">
            Since {{ formatTime(live.startsAt) }} ·
            <template v-if="scheduledEnd">
              ends <strong>{{ endText(scheduledEnd, live.startsAt) }}</strong> <span class="text-muted">({{ endsIn }})</span>
            </template>
            <span v-else class="text-muted">no end time</span>
            <span v-if="canManage && icCount" class="text-muted"> · {{ sharingCount }} of {{ icCount }} ICs sharing</span>
          </template>
          <template v-else-if="scheduledStart">
            Starts <strong>{{ formatDayTime(scheduledStart) }}</strong> ·
            <template v-if="scheduledEnd">ends <strong>{{ endText(scheduledEnd, scheduledStart) }}</strong></template>
            <span v-else class="text-muted">no end time</span>
          </template>
          <template v-else>ICs can't share their location until {{ canManage ? 'you start' : 'a planner starts' }} the event.</template>
        </span>

        <!-- Root / planner buttons (hidden while a form is open) -->
        <template v-if="canManage && !form">
          <template v-if="live">
            <button v-if="sharingCount < icCount" class="btn btn-sm btn-outline-warning" :disabled="busy" data-testid="remind-ics-btn" @click="remind">
              Remind ICs
            </button>
            <button class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="schedule-end-btn" @click="openEnd">
              {{ scheduledEnd ? 'Change end time' : 'Set end time' }}
            </button>
            <button v-if="scheduledEnd" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="remove-end-btn" @click="removeEnd">
              Remove end time
            </button>
            <button class="btn btn-sm btn-danger" :disabled="busy" data-testid="end-event-btn" @click="endNow">End event now</button>
          </template>
          <template v-else-if="scheduledStart">
            <button class="btn btn-sm btn-success" :disabled="busy" data-testid="start-event-btn" @click="startNow">Start now</button>
            <button class="btn btn-sm btn-outline-primary" :disabled="busy" data-testid="schedule-btn" @click="openSchedule">Edit schedule</button>
            <button class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="cancel-schedule-btn" @click="cancelSchedule">
              Cancel schedule
            </button>
          </template>
          <template v-else>
            <button class="btn btn-sm btn-success" :disabled="busy" data-testid="start-event-btn" @click="startNow">Start event now</button>
            <button class="btn btn-sm btn-outline-primary" :disabled="busy" data-testid="schedule-btn" @click="openSchedule">Schedule…</button>
          </template>
        </template>
      </div>

      <!-- Schedule (start + optional end) / end-time form -->
      <form v-if="form" class="border rounded p-2 mt-2" data-testid="time-form" @submit.prevent="saveForm">
        <div class="row g-2 align-items-end">
          <div v-if="form === 'schedule'" class="col-12 col-sm-auto">
            <label class="form-label small mb-1" for="start-time">Start</label>
            <input id="start-time" v-model="startValue" type="datetime-local" class="form-control form-control-sm" required data-testid="start-time-input" />
          </div>
          <div class="col-12 col-sm-auto">
            <label class="form-label small mb-1" for="end-time">
              End <span v-if="form === 'schedule'" class="text-muted">(optional)</span>
            </label>
            <input id="end-time" v-model="endValue" type="datetime-local" class="form-control form-control-sm" data-testid="end-time-input" />
          </div>
          <div class="col-12 col-sm-auto d-flex flex-wrap gap-1">
            <button v-for="p in PRESETS" :key="p.label" type="button" class="btn btn-sm btn-light border" @click="preset(p.ms)">{{ p.label }}</button>
            <button v-if="form === 'schedule' && endValue" type="button" class="btn btn-sm btn-link" @click="endValue = ''">No end time</button>
          </div>
        </div>
        <div class="small text-muted mt-1">
          <template v-if="form === 'end'">Quick buttons count from now.</template>
          <template v-else>Quick buttons count from the start. Without an end time, the event stays live until someone ends it.</template>
        </div>
        <div v-if="formError" class="small text-danger mt-1" role="alert">{{ formError }}</div>
        <div class="d-flex gap-2 mt-2">
          <button class="btn btn-sm btn-primary" type="submit" :disabled="busy" data-testid="save-schedule-btn">Save</button>
          <button class="btn btn-sm btn-outline-secondary" type="button" @click="form = ''">Cancel</button>
        </div>
      </form>

      <div v-if="$slots.sharing" class="border-top mt-2 pt-2">
        <slot name="sharing" />
      </div>
    </div>
  </div>
</template>
