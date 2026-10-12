<script setup>
// Event status: Not started / Starts at ... / Live, with Start, End and a start-time picker
// for root and planners. Everyone else only sees the status.
// ICs can only share while the event is live (checked by the database too).
import { ref, computed } from 'vue'
import { formatTime, formatDayTime, toDateTimeLocal } from '../utils/time'
import { remindIcsNow } from '../composables/usePushNotifications'

const props = defineProps({
  sessions: { type: Object, required: true }, // from useEventSessions
  eventId: { type: String, required: true },
  canManage: { type: Boolean, default: false },
  icCount: { type: Number, default: 0 }, // ICs in the event
  sharingCount: { type: Number, default: 0 }, // ICs sharing right now (live only)
})

const live = computed(() => props.sessions.liveSession.value)
const scheduled = computed(() => props.sessions.scheduledStart.value)

const busy = ref(false)
const errorMsg = ref('')
const infoMsg = ref('')
const picking = ref(false) // start-time picker open
const pickedTime = ref('')

async function run(action, successText) {
  errorMsg.value = ''
  infoMsg.value = ''
  busy.value = true
  try {
    const result = await action()
    infoMsg.value = typeof successText === 'function' ? successText(result) : successText
    picking.value = false
  } catch (err) {
    errorMsg.value = err.message
  }
  busy.value = false
}

function startNow() {
  if (!confirm('Start the event now? ICs will be able to share their location.')) return
  run(props.sessions.startEvent, 'Event started. ICs can share now.')
}

function endNow() {
  if (!confirm("End the event? Everyone's location sharing stops.")) return
  run(props.sessions.endEvent, (stopped) =>
    'Event ended.' + (stopped ? ' Stopped sharing for ' + stopped + (stopped === 1 ? ' person.' : ' people.') : ''),
  )
}

function openPicker() {
  // Default: the current scheduled time, else the next full hour
  const next = new Date()
  next.setHours(next.getHours() + 1, 0, 0, 0)
  pickedTime.value = toDateTimeLocal(scheduled.value || next)
  picking.value = true
}

function saveSchedule() {
  if (!pickedTime.value) return
  run(() => props.sessions.scheduleStart(new Date(pickedTime.value)), 'Start time saved. The event goes live by itself then.')
}

// Push "a planner asked you to share" to every IC who isn't sharing yet (phone app, even closed)
function remind() {
  run(
    () => remindIcsNow(props.eventId),
    (result) =>
      result && result.sent
        ? 'Reminder sent to ' + result.sent + (result.sent === 1 ? ' phone.' : ' phones.')
        : 'No phone to remind: those ICs have no app with notifications on, or were reminded in the last minute.',
  )
}

function cancelSchedule() {
  if (!confirm('Cancel the scheduled start?')) return
  run(props.sessions.cancelSchedule, 'Scheduled start cancelled.')
}
</script>

<template>
  <div v-if="sessions.loaded.value" class="card mb-3" data-testid="event-status">
    <div class="card-body py-2">
      <div class="d-flex flex-wrap align-items-center gap-2">
        <!-- Status -->
        <span v-if="live" class="badge text-bg-danger" data-testid="status-live">● Live</span>
        <span v-else-if="scheduled" class="badge text-bg-warning" data-testid="status-scheduled">Scheduled</span>
        <span v-else class="badge text-bg-secondary" data-testid="status-not-started">Not live</span>

        <span class="small flex-grow-1" data-testid="status-text">
          <template v-if="live">
            Since {{ formatTime(live.startsAt) }}.
            <span v-if="canManage && icCount" class="text-muted">{{ sharingCount }} of {{ icCount }} ICs sharing.</span>
          </template>
          <template v-else-if="scheduled">Goes live by itself at <strong>{{ formatDayTime(scheduled) }}</strong>.</template>
          <template v-else>ICs can't share their location until {{ canManage ? 'you start' : 'a planner starts' }} the event.</template>
        </span>

        <!-- Root / planner controls -->
        <template v-if="canManage">
          <button
            v-if="live && sharingCount < icCount"
            class="btn btn-sm btn-outline-warning"
            :disabled="busy"
            data-testid="remind-ics-btn"
            @click="remind"
          >
            Remind ICs
          </button>
          <button v-if="live" class="btn btn-sm btn-danger" :disabled="busy" data-testid="end-event-btn" @click="endNow">
            End event
          </button>
          <template v-else>
            <button class="btn btn-sm btn-success" :disabled="busy" data-testid="start-event-btn" @click="startNow">
              Start event now
            </button>
            <button v-if="!picking" class="btn btn-sm btn-outline-primary" :disabled="busy" data-testid="schedule-btn" @click="openPicker">
              {{ scheduled ? 'Change start time' : 'Schedule start' }}
            </button>
            <button v-if="scheduled && !picking" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="cancel-schedule-btn" @click="cancelSchedule">
              Cancel schedule
            </button>
          </template>
        </template>
      </div>

      <!-- Start-time picker -->
      <form v-if="picking && !live" class="d-flex flex-wrap align-items-center gap-2 mt-2" @submit.prevent="saveSchedule">
        <label class="small" for="start-time">Start at</label>
        <input
          id="start-time"
          v-model="pickedTime"
          type="datetime-local"
          class="form-control form-control-sm w-auto"
          required
          data-testid="start-time-input"
        />
        <button class="btn btn-sm btn-primary" type="submit" :disabled="busy" data-testid="save-schedule-btn">Save</button>
        <button class="btn btn-sm btn-link" type="button" @click="picking = false">Cancel</button>
      </form>

      <div v-if="errorMsg" class="alert alert-danger py-1 px-2 small mt-2 mb-0" role="alert">{{ errorMsg }}</div>
      <div v-if="infoMsg" class="alert alert-success py-1 px-2 small mt-2 mb-0" role="status">{{ infoMsg }}</div>
    </div>
  </div>
</template>
