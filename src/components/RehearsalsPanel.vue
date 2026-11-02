<script setup>
// RehearsalsPanel - the Rehearsals page: a month calendar for everyone, and scheduling for the root and planners.
// The page emits what was asked and EventView does it, as the Attendance page does. The database decides who may (079).
import { computed, ref, watch } from 'vue'
import { formatDay, formatDayTime, formatTime } from '../utils/time'
import { dayKey, monthGrid, monthOf, monthTitle, shiftMonth } from '../utils/rehearsalCalendar'

const props = defineProps({
  rehearsals: { type: Array, default: () => [] }, // soonest first: { id, startsAt: Date }
  next: { type: Object, default: null },
  canEdit: { type: Boolean, default: false },
  eventStartsAt: { type: String, default: null },
  now: { type: Number, default: () => Date.now() },
  busy: { type: Boolean, default: false },
  errorMsg: { type: String, default: '' },
})
const emit = defineEmits(['add', 'remove'])

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

const shown = ref(monthOf(props.now))
const selected = ref(dayKey(props.now))
const moved = ref(false) // the person has chosen a month or a day: the list arriving must not take it away
const when = ref('') // the form's <input type="datetime-local"> value
const formError = ref('')

const todayKey = computed(() => dayKey(props.now))
const eventKey = computed(() => (props.eventStartsAt ? dayKey(props.eventStartsAt) : null))
const weeks = computed(() => monthGrid(shown.value))

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
    if (count > before) when.value = ''
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
  if (props.canEdit) when.value = day.key + 'T' + (when.value.slice(11) || '19:00')
}

function dayLabel(day) {
  const count = (byDay.value.get(day.key) || []).length
  let label = formatDay(day.key + 'T12:00:00+08:00')
  if (count) label += ', ' + count + (count === 1 ? ' rehearsal' : ' rehearsals')
  if (day.key === eventKey.value) label += ', event day'
  return label
}

function submit() {
  const date = new Date(when.value)
  if (!when.value || Number.isNaN(date.getTime())) {
    formError.value = 'Choose a date and time.'
    return
  }
  if (date.getTime() <= Date.now()) {
    formError.value = 'Choose a time in the future.'
    return
  }
  formError.value = ''
  moved.value = true
  shown.value = monthOf(date)
  selected.value = dayKey(date)
  emit('add', date)
}
</script>

<template>
  <div class="kp-stack" data-testid="rehearsals">
    <p v-if="errorMsg" class="alert alert-danger mb-0" role="alert" data-testid="rehearsal-error">{{ errorMsg }}</p>

    <section v-if="canEdit" class="kp-card" data-testid="rehearsal-form">
      <h2 class="kp-title mb-2">Schedule a rehearsal</h2>
      <form class="rh-form" novalidate @submit.prevent="submit">
        <div class="rh-when">
          <label for="rh-when" class="form-label">Date and time</label>
          <input
            id="rh-when"
            v-model="when"
            type="datetime-local"
            class="form-control"
            :class="{ 'is-invalid': formError }"
            data-testid="rehearsal-when"
          />
          <div v-if="formError" class="invalid-feedback">{{ formError }}</div>
        </div>
        <button class="btn btn-primary" type="submit" :disabled="busy" data-testid="rehearsal-add">Schedule</button>
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
          >{{ formatTime(rehearsal.startsAt) }}</span>
        </button>
      </div>
    </section>

    <section class="kp-card" data-testid="rehearsal-day-detail">
      <h2 class="kp-title mb-2">{{ selectedTitle }}</h2>
      <p v-if="selected === eventKey" class="rh-line mb-1">The event is on this day.</p>
      <ul v-if="selectedRehearsals.length" class="rh-list">
        <li v-for="rehearsal in selectedRehearsals" :key="rehearsal.id" data-testid="rehearsal-item">
          <span>Rehearsal at <strong>{{ formatTime(rehearsal.startsAt) }}</strong></span>
          <button
            v-if="canEdit"
            type="button"
            class="btn btn-sm btn-outline-secondary"
            :disabled="busy"
            :aria-label="'Remove the rehearsal on ' + formatDayTime(rehearsal.startsAt)"
            data-testid="rehearsal-remove"
            @click="emit('remove', rehearsal.id)"
          >Remove</button>
        </li>
      </ul>
      <p v-else class="rh-line mb-0" data-testid="rehearsal-none">No rehearsal on this day.</p>
    </section>
  </div>
</template>

<style scoped>
.rh-form {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 10px;
}
.rh-when {
  flex: 1 1 220px;
  max-width: 320px;
}
/* The button lines up with the field, under its label */
.rh-form > .btn {
  margin-top: 30px;
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
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 8px 0;
  border-top: 1px solid var(--line);
  font-size: 14px;
}
.rh-list li:first-child {
  border-top: 0;
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
