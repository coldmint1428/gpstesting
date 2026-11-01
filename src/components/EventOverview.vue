<script setup>
// The event's Overview page: details, status, my role and group, counts; the invite code for root / planners;
// editing the event's details and deleting the event for the root (mode 'edit'); "Leave event" for everyone else.
// Saving and deleting are done by the parent view (EventView): this component only emits 'save-details' / 'delete'.
import { ref, computed, watch } from 'vue'
import { ROLE_LABEL, can } from '../utils/permissions'
import { formatDayTime, toDateTimeLocal } from '../utils/time'
import InvitePanel from './InvitePanel.vue'

const props = defineProps({
  event: { type: Object, required: true },
  role: { type: String, default: null }, // view role: root | planner | marshal | admin | ic | member
  mode: { type: String, default: 'view' }, // 'edit' (root) | 'view'
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  myGroup: { type: Object, default: null },
  isLive: { type: Boolean, default: false },
  scheduledStart: { type: Date, default: null },
  busy: { type: Boolean, default: false }, // the parent is saving or deleting
  savedCount: { type: Number, default: 0 }, // goes up each time the parent saves the details
})
const emit = defineEmits(['save-details', 'delete', 'leave'])

const status = computed(() => {
  if (props.isLive) return 'Live now'
  if (props.scheduledStart) return 'Starts ' + formatDayTime(props.scheduledStart)
  return 'Not live'
})
const when = computed(() =>
  props.event.starts_at ? formatDayTime(props.event.starts_at) + ' – ' + formatDayTime(props.event.ends_at) : '',
)
const groupCount = computed(() => props.groups.length + (props.groups.length === 1 ? ' group' : ' groups'))

// ---------- Editing the details (root) ----------
// The form is a copy of the event's details, filled when it opens (times as <input type="datetime-local"> values)
const editing = ref(false)
const form = ref(null)
const formErrors = ref({})
function detailsOf(e) {
  return {
    name: e.name || '',
    description: e.description || '',
    venue: e.venue || '',
    startsAt: e.starts_at ? toDateTimeLocal(e.starts_at) : '',
    endsAt: e.ends_at ? toDateTimeLocal(e.ends_at) : '',
  }
}
function startEditing() {
  form.value = detailsOf(props.event)
  formErrors.value = {}
  editing.value = true
}
const changed = computed(() => !!form.value && JSON.stringify(form.value) !== JSON.stringify(detailsOf(props.event)))

// The parent saved the details: close the form
watch(
  () => props.savedCount,
  () => (editing.value = false),
)

// The wizard's rules (the database checks them again)
function validate(d) {
  const errors = {}
  if (!d.name) errors.name = 'Give the event a name'
  if (d.startsAt && !d.endsAt) errors.endsAt = 'Pick an end date and time'
  if (d.endsAt && !d.startsAt) errors.startsAt = 'Pick a start date and time'
  if (d.startsAt && d.endsAt && new Date(d.endsAt) <= new Date(d.startsAt)) errors.endsAt = 'The end must be after the start'
  return errors
}

function saveDetails() {
  const d = form.value
  formErrors.value = validate(d)
  if (Object.keys(formErrors.value).length) return
  emit('save-details', {
    name: d.name,
    description: d.description,
    venue: d.venue,
    startsAt: d.startsAt ? new Date(d.startsAt).toISOString() : null, // datetime-local is local time -> UTC
    endsAt: d.endsAt ? new Date(d.endsAt).toISOString() : null,
  })
}
</script>

<template>
  <div class="kp-stack" data-testid="overview" :data-mode="mode">
    <div class="kp-overview">
      <!-- Root: edit the details -->
      <form v-if="editing" class="kp-card kp-fields" data-testid="overview-edit" @submit.prevent="saveDetails">
        <h2 class="kp-title">Edit details</h2>
        <div>
          <label for="ov-name" class="form-label">Name <span class="text-danger">*</span></label>
          <input id="ov-name" v-model.trim="form.name" class="form-control" :class="{ 'is-invalid': formErrors.name }" maxlength="80" required data-testid="overview-name" />
          <div v-if="formErrors.name" class="invalid-feedback">{{ formErrors.name }}</div>
        </div>
        <div>
          <label for="ov-description" class="form-label">Description</label>
          <textarea id="ov-description" v-model.trim="form.description" class="form-control" rows="3" maxlength="1000" data-testid="overview-description"></textarea>
        </div>
        <div>
          <label for="ov-venue" class="form-label">Venue</label>
          <input id="ov-venue" v-model.trim="form.venue" class="form-control" maxlength="120" placeholder="e.g. Padang" data-testid="overview-venue" />
        </div>
        <div class="kp-fields-2">
          <div>
            <label for="ov-start" class="form-label">Starts</label>
            <input id="ov-start" v-model="form.startsAt" type="datetime-local" class="form-control" :class="{ 'is-invalid': formErrors.startsAt }" data-testid="overview-start" />
            <div v-if="formErrors.startsAt" class="invalid-feedback">{{ formErrors.startsAt }}</div>
          </div>
          <div>
            <label for="ov-end" class="form-label">Ends</label>
            <input id="ov-end" v-model="form.endsAt" type="datetime-local" class="form-control" :class="{ 'is-invalid': formErrors.endsAt }" data-testid="overview-end" />
            <div v-if="formErrors.endsAt" class="invalid-feedback">{{ formErrors.endsAt }}</div>
          </div>
        </div>
        <div class="kp-actions">
          <button class="btn btn-primary" type="submit" :disabled="busy || !changed" data-testid="overview-save">Save</button>
          <button class="btn btn-ghost" type="button" :disabled="busy" @click="editing = false">Cancel</button>
        </div>
      </form>

      <div v-else class="kp-card">
        <div class="kp-card-head">
          <h2 class="kp-title">Details</h2>
          <button v-if="mode === 'edit'" type="button" class="btn btn-sm btn-outline-secondary" data-testid="overview-edit-btn" @click="startEditing">Edit</button>
        </div>
        <p v-if="event.description" class="kp-prewrap mb-2" data-testid="overview-description-text">{{ event.description }}</p>
        <dl class="kp-dl">
          <template v-if="event.starts_at">
            <dt>When</dt>
            <dd>{{ when }}</dd>
          </template>
          <template v-if="event.venue">
            <dt>Venue</dt>
            <dd>{{ event.venue }}</dd>
          </template>
          <dt>Status</dt>
          <dd data-testid="overview-status">{{ status }}</dd>
          <dt>Your role</dt>
          <dd>{{ ROLE_LABEL[role] }}</dd>
          <!-- planners (and the root) run the whole event and are never in a group -->
          <template v-if="role !== 'root' && role !== 'planner'">
            <dt>Your group</dt>
            <dd>{{ myGroup ? myGroup.name : 'None yet' }}</dd>
          </template>
          <dt>People</dt>
          <dd>{{ members.length }} in {{ groupCount }}</dd>
        </dl>
      </div>

      <InvitePanel v-if="can('invite', role)" :event-name="event.name" :join-code="event.join_code" />
    </div>

    <div>
      <button v-if="mode === 'edit'" type="button" class="btn btn-sm btn-ghost-danger" :disabled="busy" data-testid="delete-event" @click="emit('delete')">
        Delete event
      </button>
      <button v-else type="button" class="btn btn-sm btn-ghost-danger" data-testid="leave-event" @click="emit('leave')">Leave event</button>
    </div>
  </div>
</template>
