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
  const start = scheduledStart.value || nextHour
  startDate.value = dateOf(start)
  startTime.value = timeOf(start)
  endDate.value = scheduledEnd.value ? dateOf(scheduledEnd.value) : ''
  endTime.value = scheduledEnd.value ? timeOf(scheduledEnd.value) : ''
  endMode.value = modeFor(scheduledEnd.value, start)
  formError.value = ''
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
  if (!ok) return
  await run(props.sessions.startEvent, 'Event started. ICs can share now.')
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

      <!-- Schedule (start + optional end) / end-time panel -->
      <form v-if="form" class="time-panel mt-2" data-testid="time-form" @submit.prevent="saveForm">
        <div class="d-flex align-items-start justify-content-between mb-2">
          <div>
            <h3 class="h6 mb-0">{{ form === 'schedule' ? (scheduledStart ? 'Edit the schedule' : 'Schedule the event') : 'When should the event end?' }}</h3>
            <p class="small text-muted mb-0">
              {{
                form === 'schedule'
                  ? 'The event goes live by itself at the start and ends by itself at the end.'
                  : "At the end time everyone's sharing stops by itself."
              }}
            </p>
          </div>
          <button type="button" class="btn-close" aria-label="Close" @click="form = ''"></button>
        </div>

        <div class="row g-2">
          <!-- Start -->
          <div v-if="form === 'schedule'" class="col-12 col-md-5">
            <div class="time-card h-100">
              <div class="time-label"><span class="dot dot-start"></span>Start</div>
              <div class="d-flex gap-2">
                <input v-model="startDate" type="date" class="form-control date-input" aria-label="Start date" required data-testid="start-date-input" />
                <input v-model="startTime" type="time" class="form-control time-input" aria-label="Start time" required data-testid="start-time-input" />
              </div>
              <div class="small text-muted mt-1">{{ formStart ? formatDayTime(formStart) : '' }}</div>
            </div>
          </div>

          <!-- End -->
          <div class="col-12" :class="{ 'col-md-7': form === 'schedule' }">
            <div class="time-card h-100">
              <div class="time-label">
                <span class="dot dot-end"></span>{{ form === 'schedule' ? 'End' : 'End in' }}
                <span v-if="form === 'schedule'" class="text-muted fw-normal">· optional</span>
              </div>
              <div class="d-flex flex-wrap gap-1" role="group" aria-label="Event length">
                <button
                  v-for="d in DURATIONS"
                  :key="d.mode"
                  type="button"
                  class="chip"
                  :class="{ active: endMode === d.mode }"
                  :data-testid="'duration-' + d.mode"
                  @click="setEndMode(d.mode)"
                >
                  {{ form === 'end' ? '+' : '' }}{{ d.label }}
                </button>
                <button type="button" class="chip" :class="{ active: endMode === 'custom' }" data-testid="duration-custom" @click="setEndMode('custom')">
                  Pick a time
                </button>
                <button
                  v-if="form === 'schedule'"
                  type="button"
                  class="chip"
                  :class="{ active: endMode === 'none' }"
                  data-testid="duration-none"
                  @click="setEndMode('none')"
                >
                  No end
                </button>
              </div>
              <div v-if="endMode === 'custom'" class="d-flex gap-2 mt-2">
                <input v-model="endDate" type="date" class="form-control date-input" aria-label="End date" data-testid="end-date-input" />
                <input v-model="endTime" type="time" class="form-control time-input" aria-label="End time" data-testid="end-time-input" />
              </div>
            </div>
          </div>
        </div>

        <!-- Summary + save -->
        <div class="d-flex flex-wrap align-items-center gap-2 mt-2">
          <div class="summary flex-grow-1" data-testid="time-summary">
            <span v-if="formError" class="text-danger" role="alert">{{ formError }}</span>
            <template v-else>{{ summary }}</template>
          </div>
          <button class="btn btn-sm btn-outline-secondary" type="button" @click="form = ''">Cancel</button>
          <button class="btn btn-sm btn-primary px-3" type="submit" :disabled="busy" data-testid="save-schedule-btn">
            {{ form === 'schedule' ? 'Save schedule' : 'Save end time' }}
          </button>
        </div>
      </form>

      <div v-if="$slots.sharing" class="border-top mt-2 pt-2">
        <slot name="sharing" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.time-panel {
  background: var(--bs-tertiary-bg);
  border: 1px solid var(--bs-border-color);
  border-radius: 0.75rem;
  padding: 0.85rem;
}
.time-card {
  background: var(--bs-body-bg);
  border: 1px solid var(--bs-border-color);
  border-radius: 0.6rem;
  padding: 0.6rem 0.7rem;
}
.time-label {
  font-size: 0.75rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: 0.4rem;
}
/* Date + time side by side; both may shrink on a phone */
.date-input {
  flex: 1 1 9rem;
  min-width: 0;
  max-width: 11.5rem;
}
.time-input {
  flex: 0 1 8.5rem;
  min-width: 0;
}
.dot {
  display: inline-block;
  width: 0.55rem;
  height: 0.55rem;
  border-radius: 50%;
  margin-right: 0.35rem;
  vertical-align: 0.05rem;
}
.dot-start {
  background: var(--bs-success);
}
.dot-end {
  background: var(--bs-danger);
}
/* Duration chips: pill buttons, the chosen one filled */
.chip {
  border: 1px solid var(--bs-border-color);
  background: var(--bs-body-bg);
  color: var(--bs-body-color);
  border-radius: 999px;
  padding: 0.25rem 0.75rem;
  font-size: 0.875rem;
  line-height: 1.4;
}
.chip:hover {
  border-color: var(--bs-primary);
  color: var(--bs-primary);
}
.chip.active {
  background: var(--bs-primary);
  border-color: var(--bs-primary);
  color: #fff;
}
.summary {
  font-size: 0.875rem;
  font-weight: 500;
}
</style>
