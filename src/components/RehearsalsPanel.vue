<script setup>
// RehearsalsPanel - the Rehearsals page: a month calendar for everyone. Members, ICs and group admins can say they are not
// available for a rehearsal; the root and planners get scheduling and a Requests tab to decide those instead.
// The page emits what was asked and EventView does it, as the Attendance page does. The database decides who may (079, 080).
import { computed, ref, watch } from 'vue'
import { formatDay, formatDayTime, formatTime } from '../utils/time'
import { dayKey, formatRehearsal, monthGrid, monthOf, monthTitle, shiftMonth } from '../utils/rehearsalCalendar'
import RehearsalRequests from './RehearsalRequests.vue'

const props = defineProps({
  rehearsals: { type: Array, default: () => [] }, // soonest first: { id, startsAt: Date, endsAt: Date|null, note }
  absences: { type: Array, default: () => [] }, // the requests this person may read
  next: { type: Object, default: null },
  canEdit: { type: Boolean, default: false },
  myId: { type: String, default: null },
  members: { type: Array, default: () => [] },
  groups: { type: Array, default: () => [] },
  eventStartsAt: { type: String, default: null },
  now: { type: Number, default: () => Date.now() },
  busy: { type: Boolean, default: false },
  errorMsg: { type: String, default: '' },
})
const emit = defineEmits(['add', 'remove', 'request-absence', 'withdraw-absence', 'decide-absence'])

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

const view = ref('calendar') // 'calendar' | 'requests' (the root and planners)
const shown = ref(monthOf(props.now))
const selected = ref(dayKey(props.now))
const moved = ref(false) // the person has chosen a month or a day: the list arriving must not take it away
const form = ref({ startsAt: '', endsAt: '', note: '' }) // times as <input type="datetime-local"> values
const formErrors = ref({})
const askingFor = ref(null) // the rehearsal whose reason box is open
const reason = ref('')

const todayKey = computed(() => dayKey(props.now))
const eventKey = computed(() => (props.eventStartsAt ? dayKey(props.eventStartsAt) : null))
const weeks = computed(() => monthGrid(shown.value))
const pendingCount = computed(() => props.absences.filter((a) => a.status === 'pending').length)

const byDay = computed(() => {
  const out = new Map()
  for (const rehearsal of props.rehearsals) {
    const key = dayKey(rehearsal.startsAt)
    if (!out.has(key)) out.set(key, [])
    out.get(key).push(rehearsal)
  }
  return out
})
const selectedRehearsals = computed(() => byDay.value.get(selected.value) || [])
const selectedTitle = computed(() => formatDay(selected.value + 'T12:00:00+08:00'))

const myAbsence = (rehearsal) => props.absences.find((a) => a.rehearsalId === rehearsal.id && a.userId === props.myId) || null
const hasStarted = (rehearsal) => rehearsal.startsAt.getTime() <= props.now

// Open on the next rehearsal, once there is one to open on
watch(
  () => props.next,
  (next) => {
    if (next && !moved.value) {
      shown.value = monthOf(next.startsAt)
      selected.value = dayKey(next.startsAt)
    }
  },
  { immediate: true },
)
// A rehearsal was added: the form has done its job
watch(
  () => props.rehearsals.length,
  (count, before) => {
    if (count > before) form.value = { startsAt: '', endsAt: '', note: '' }
  },
)
// The request came back saved: the reason box has done its job. A refusal leaves it open with what was typed.
watch(
  () => props.absences.find((a) => a.rehearsalId === askingFor.value && a.userId === props.myId),
  (saved) => {
    if (saved && saved.status === 'pending' && saved.reason === reason.value.trim()) closeReason()
  },
)

function moveMonth(by) {
  moved.value = true
  shown.value = shiftMonth(shown.value, by)
}

function pick(day) {
  moved.value = true
  selected.value = day.key
  if (!day.inMonth) shown.value = monthOf(day.key + 'T12:00:00+08:00')
  // Scheduling starts from the day that was tapped, keeping a time already typed
  if (props.canEdit) {
    form.value.startsAt = day.key + 'T' + (form.value.startsAt.slice(11) || '19:00')
    if (form.value.endsAt) form.value.endsAt = day.key + 'T' + form.value.endsAt.slice(11)
  }
}

function dayLabel(day) {
  const count = (byDay.value.get(day.key) || []).length
  let label = formatDay(day.key + 'T12:00:00+08:00')
  if (count) label += ', ' + count + (count === 1 ? ' rehearsal' : ' rehearsals')
  if (day.key === eventKey.value) label += ', event day'
  return label
}

function chipText(rehearsal) {
  return rehearsal.endsAt && dayKey(rehearsal.endsAt) === dayKey(rehearsal.startsAt)
    ? formatTime(rehearsal.startsAt).replace(/\s?[ap]m$/i, '') + '–' + formatTime(rehearsal.endsAt)
    : formatTime(rehearsal.startsAt)
}

function submit() {
  const errors = {}
  const startsAt = new Date(form.value.startsAt)
  const endsAt = form.value.endsAt ? new Date(form.value.endsAt) : null
  if (!form.value.startsAt || Number.isNaN(startsAt.getTime())) errors.startsAt = 'Choose a date and time.'
  else if (startsAt.getTime() <= Date.now()) errors.startsAt = 'Choose a time in the future.'
  if (endsAt && !errors.startsAt && endsAt.getTime() <= startsAt.getTime()) errors.endsAt = 'Choose a time after the start.'
  formErrors.value = errors
  if (Object.keys(errors).length) return
  moved.value = true
  shown.value = monthOf(startsAt)
  selected.value = dayKey(startsAt)
  emit('add', { startsAt, endsAt, note: form.value.note.trim() })
}

function openReason(rehearsal) {
  askingFor.value = rehearsal.id
  reason.value = ''
}
function closeReason() {
  askingFor.value = null
  reason.value = ''
}
function sendReason(rehearsal) {
  if (reason.value.trim()) emit('request-absence', { rehearsalId: rehearsal.id, reason: reason.value.trim() })
}
</script>

<template>
  <div class="kp-stack" data-testid="rehearsals">
    <p v-if="errorMsg" class="alert alert-danger mb-0" role="alert" data-testid="rehearsal-error">{{ errorMsg }}</p>

    <div v-if="canEdit" class="kp-seg align-self-start" role="radiogroup" aria-label="Rehearsals view" data-testid="rehearsal-tabs">
      <input id="rh-view-calendar" v-model="view" type="radio" name="rh-view" value="calendar" />
      <label for="rh-view-calendar" data-testid="rehearsal-tab-calendar">Calendar</label>
      <input id="rh-view-requests" v-model="view" type="radio" name="rh-view" value="requests" />
      <label for="rh-view-requests" data-testid="rehearsal-tab-requests">Requests<span v-if="pendingCount" class="rh-count" data-testid="rehearsal-pending-count">{{ pendingCount }}</span></label>
    </div>

    <RehearsalRequests
      v-if="canEdit && view === 'requests'"
      :absences="absences"
      :rehearsals="rehearsals"
      :members="members"
      :groups="groups"
      :busy="busy"
      @decide="emit('decide-absence', $event)"
    />

    <template v-else>
      <section v-if="canEdit" class="kp-card" data-testid="rehearsal-form">
        <h2 class="kp-title mb-2">Schedule a rehearsal</h2>
        <form novalidate @submit.prevent="submit">
          <div class="kp-fields-2">
            <div>
              <label for="rh-when" class="form-label">Starts</label>
              <input id="rh-when" v-model="form.startsAt" type="datetime-local" class="form-control" :class="{ 'is-invalid': formErrors.startsAt }" data-testid="rehearsal-when" />
              <div v-if="formErrors.startsAt" class="invalid-feedback">{{ formErrors.startsAt }}</div>
            </div>
            <div>
              <label for="rh-until" class="form-label">Ends (optional)</label>
              <input id="rh-until" v-model="form.endsAt" type="datetime-local" class="form-control" :class="{ 'is-invalid': formErrors.endsAt }" :min="form.startsAt || undefined" data-testid="rehearsal-until" />
              <div v-if="formErrors.endsAt" class="invalid-feedback">{{ formErrors.endsAt }}</div>
            </div>
          </div>
          <div class="mt-2">
            <label for="rh-note" class="form-label">Notes (optional)</label>
            <textarea id="rh-note" v-model="form.note" class="form-control" rows="2" maxlength="500" placeholder="e.g. Meet at the main gate, bring water" data-testid="rehearsal-note"></textarea>
          </div>
          <div class="kp-actions">
            <button class="btn btn-primary" type="submit" :disabled="busy" data-testid="rehearsal-add">Schedule</button>
          </div>
        </form>
      </section>

      <section class="kp-card" data-testid="rehearsal-calendar">
        <div class="rh-head">
          <button type="button" class="btn btn-sm btn-outline-secondary" aria-label="Previous month" data-testid="rehearsal-prev" @click="moveMonth(-1)">‹</button>
          <h2 class="kp-title mb-0" aria-live="polite" data-testid="rehearsal-month">{{ monthTitle(shown) }}</h2>
          <button type="button" class="btn btn-sm btn-outline-secondary" aria-label="Next month" data-testid="rehearsal-next" @click="moveMonth(1)">›</button>
        </div>

        <div class="rh-grid rh-weekdays" aria-hidden="true">
          <span v-for="name in WEEKDAYS" :key="name">{{ name }}</span>
        </div>
        <div v-for="week in weeks" :key="week[0].key" class="rh-grid">
          <button
            v-for="day in week"
            :key="day.key"
            type="button"
            class="rh-day"
            :class="{
              'is-out': !day.inMonth,
              'is-today': day.key === todayKey,
              'is-selected': day.key === selected,
            }"
            :aria-label="dayLabel(day)"
            :aria-pressed="day.key === selected"
            :data-day="day.key"
            data-testid="rehearsal-day"
            @click="pick(day)"
          >
            <span class="rh-num">{{ day.day }}</span>
            <span v-if="day.key === eventKey" class="rh-chip is-event">Event</span>
            <span
              v-for="rehearsal in byDay.get(day.key) || []"
              :key="rehearsal.id"
              class="rh-chip"
              data-testid="rehearsal-chip"
            >{{ chipText(rehearsal) }}</span>
          </button>
        </div>
      </section>

      <section class="kp-card" data-testid="rehearsal-day-detail">
        <h2 class="kp-title mb-2">{{ selectedTitle }}</h2>
        <p v-if="selected === eventKey" class="rh-line mb-1">The event is on this day.</p>
        <ul v-if="selectedRehearsals.length" class="rh-list">
          <li v-for="rehearsal in selectedRehearsals" :key="rehearsal.id" data-testid="rehearsal-item">
            <div class="rh-item-head">
              <strong data-testid="rehearsal-time">{{ formatRehearsal(rehearsal) }}</strong>
              <button
                v-if="canEdit"
                type="button"
                class="btn btn-sm btn-outline-secondary"
                :disabled="busy"
                :aria-label="'Remove the rehearsal on ' + formatDayTime(rehearsal.startsAt)"
                data-testid="rehearsal-remove"
                @click="emit('remove', rehearsal.id)"
              >Remove</button>
            </div>
            <p v-if="rehearsal.note" class="rh-note" data-testid="rehearsal-item-note">{{ rehearsal.note }}</p>

            <!-- This person's own answer. The root and planners run the rehearsals, so they do not ask to miss one. -->
            <div v-if="!canEdit && myAbsence(rehearsal)" class="rh-mine" data-testid="absence-mine" :data-status="myAbsence(rehearsal).status">
              <span class="rh-status" :class="'is-' + myAbsence(rehearsal).status">
                {{ { pending: 'Not available: waiting for approval', approved: 'Not available: approved', rejected: 'Not approved: you are expected' }[myAbsence(rehearsal).status] }}
              </span>
              <p class="rh-note">{{ myAbsence(rehearsal).reason }}</p>
              <div v-if="!hasStarted(rehearsal) && askingFor !== rehearsal.id" class="rh-mine-actions">
                <button v-if="myAbsence(rehearsal).status === 'rejected'" type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="absence-again" @click="openReason(rehearsal)">Ask again</button>
                <button v-else type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="absence-withdraw" @click="emit('withdraw-absence', rehearsal.id)">{{ myAbsence(rehearsal).status === 'approved' ? 'I can make it after all' : 'Withdraw' }}</button>
              </div>
            </div>
            <button
              v-else-if="!canEdit && !hasStarted(rehearsal) && askingFor !== rehearsal.id"
              type="button"
              class="btn btn-sm btn-outline-secondary rh-unavailable"
              :disabled="busy"
              data-testid="absence-open"
              @click="openReason(rehearsal)"
            >Not available</button>

            <form v-if="askingFor === rehearsal.id && !hasStarted(rehearsal)" class="rh-reason" novalidate data-testid="absence-form" @submit.prevent="sendReason(rehearsal)">
              <label :for="'rh-reason-' + rehearsal.id" class="form-label">Why can’t you make it?</label>
              <textarea :id="'rh-reason-' + rehearsal.id" v-model="reason" class="form-control" rows="2" maxlength="300" data-testid="absence-reason"></textarea>
              <div class="form-text">The root or a planner needs to approve this.</div>
              <div class="rh-mine-actions">
                <button type="submit" class="btn btn-sm btn-primary" :disabled="busy || !reason.trim()" data-testid="absence-send">Send</button>
                <button type="button" class="btn btn-sm btn-ghost" :disabled="busy" data-testid="absence-cancel" @click="closeReason">Cancel</button>
              </div>
            </form>
          </li>
        </ul>
        <p v-else class="rh-line mb-0" data-testid="rehearsal-none">No rehearsal on this day.</p>
      </section>
    </template>
  </div>
</template>

<style scoped>
.rh-count {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 20px;
  height: 20px;
  margin-left: 6px;
  padding: 0 5px;
  border-radius: 999px;
  background: var(--lime);
  color: var(--ink);
  font-size: 12px;
}
.rh-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 12px;
}
.rh-grid {
  display: grid;
  grid-template-columns: repeat(7, minmax(0, 1fr));
  gap: 4px;
  margin-bottom: 4px;
}
.rh-weekdays {
  font-size: 12px;
  font-weight: 600;
  color: var(--muted);
  text-align: center;
}
.rh-day {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 3px;
  min-width: 0;
  min-height: 84px;
  padding: 6px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--surface);
  color: var(--ink);
  text-align: left;
  cursor: pointer;
}
.rh-day:hover {
  border-color: var(--ink);
}
.rh-day:focus-visible {
  outline: 2px solid var(--ink);
  outline-offset: 2px;
}
.rh-day.is-out {
  background: transparent;
  color: var(--muted);
  opacity: 0.6;
}
.rh-day.is-selected {
  border-color: var(--ink);
  box-shadow: inset 0 0 0 1px var(--ink);
}
.rh-num {
  font-size: 13px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.rh-day.is-today .rh-num {
  align-self: flex-start;
  padding: 0 6px;
  border-radius: 999px;
  background: var(--ink);
  color: var(--surface);
}
.rh-chip {
  overflow: hidden;
  padding: 1px 6px;
  border-radius: 6px;
  background: var(--mint);
  color: var(--ink);
  font-size: 11px;
  font-weight: 600;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.rh-chip.is-event {
  background: var(--lime);
}
.rh-line {
  color: var(--muted);
  font-size: 14px;
}
.rh-list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.rh-list li {
  padding: 12px 0;
  border-top: 1px solid var(--line);
  font-size: 14px;
}
.rh-list li:first-child {
  border-top: 0;
}
.rh-item-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.rh-note {
  margin: 6px 0 0;
  color: var(--muted);
  overflow-wrap: anywhere;
  white-space: pre-wrap;
}
.rh-unavailable,
.rh-reason,
.rh-mine {
  margin-top: 10px;
}
.rh-status {
  font-size: 13px;
  font-weight: 600;
}
.rh-status.is-approved {
  color: var(--ink);
}
.rh-mine-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}
/* A phone's day is too narrow for a time: a coloured mark says something is on, and the card below says what */
@media (max-width: 575.98px) {
  .rh-day {
    align-items: center;
    min-height: 52px;
    padding: 4px 2px;
  }
  .rh-chip {
    width: 8px;
    height: 8px;
    padding: 0;
    border-radius: 50%;
    font-size: 0;
    background: var(--ink);
  }
  .rh-chip.is-event {
    background: var(--lime-shadow);
  }
  .rh-day.is-today .rh-num {
    align-self: center;
  }
}
</style>
