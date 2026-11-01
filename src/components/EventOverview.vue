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
  <div data-testid="overview" :data-mode="mode">
    <div class="row g-3">
      <div class="col-12 col-lg-6">
        <!-- Root: edit the details -->
        <form v-if="editing" class="card h-100" data-testid="overview-edit" @submit.prevent="saveDetails">
          <div class="card-body">
            <h2 class="h6">Edit event details</h2>
            <div class="mb-2">
              <label for="ov-name" class="form-label small mb-1">Name <span class="text-danger">*</span></label>
              <input
                id="ov-name"
                v-model.trim="form.name"
                class="form-control"
                :class="{ 'is-invalid': formErrors.name }"
                maxlength="80"
                required
                data-testid="overview-name"
              />
              <div v-if="formErrors.name" class="invalid-feedback">{{ formErrors.name }}</div>
            </div>
            <div class="mb-2">
              <label for="ov-description" class="form-label small mb-1">Description</label>
              <textarea id="ov-description" v-model.trim="form.description" class="form-control" rows="3" maxlength="1000" data-testid="overview-description"></textarea>
            </div>
            <div class="mb-2">
              <label for="ov-venue" class="form-label small mb-1">Venue</label>
              <input id="ov-venue" v-model.trim="form.venue" class="form-control" maxlength="120" placeholder="e.g. Padang" data-testid="overview-venue" />
            </div>
            <div class="row g-2 mb-3">
              <div class="col-12 col-sm-6">
                <label for="ov-start" class="form-label small mb-1">Starts</label>
                <input
                  id="ov-start"
                  v-model="form.startsAt"
                  type="datetime-local"
                  class="form-control"
                  :class="{ 'is-invalid': formErrors.startsAt }"
                  data-testid="overview-start"
                />
                <div v-if="formErrors.startsAt" class="invalid-feedback">{{ formErrors.startsAt }}</div>
              </div>
              <div class="col-12 col-sm-6">
                <label for="ov-end" class="form-label small mb-1">Ends</label>
                <input
                  id="ov-end"
                  v-model="form.endsAt"
                  type="datetime-local"
                  class="form-control"
                  :class="{ 'is-invalid': formErrors.endsAt }"
                  data-testid="overview-end"
                />
                <div v-if="formErrors.endsAt" class="invalid-feedback">{{ formErrors.endsAt }}</div>
              </div>
            </div>
            <div class="d-flex gap-2">
              <button class="btn btn-primary" type="submit" :disabled="busy || !changed" data-testid="overview-save">Save</button>
              <button class="btn btn-outline-secondary" type="button" :disabled="busy" @click="editing = false">Cancel</button>
            </div>
          </div>
        </form>

        <div v-else class="card h-100">
          <div class="card-body">
            <div class="d-flex align-items-start gap-2 mb-2">
              <h2 class="h6 me-auto mb-0">Event</h2>
              <button v-if="mode === 'edit'" type="button" class="btn btn-sm btn-outline-primary" data-testid="overview-edit-btn" @click="startEditing">
                Edit details
              </button>
            </div>
            <p v-if="event.description" class="small mb-2 description" data-testid="overview-description-text">{{ event.description }}</p>
            <dl class="row small mb-0">
              <template v-if="event.starts_at">
                <dt class="col-5">When</dt>
                <dd class="col-7">{{ when }}</dd>
              </template>
              <template v-if="event.venue">
                <dt class="col-5">Venue</dt>
                <dd class="col-7">{{ event.venue }}</dd>
              </template>
              <dt class="col-5">Status</dt>
              <dd class="col-7" data-testid="overview-status">{{ status }}</dd>
              <dt class="col-5">Your role</dt>
              <dd class="col-7">{{ ROLE_LABEL[role] }}</dd>
              <!-- planners (and the root) run the whole event and are never in a group -->
              <template v-if="role !== 'root' && role !== 'planner'">
                <dt class="col-5">Your group</dt>
                <dd class="col-7">{{ myGroup ? myGroup.name : 'None yet' }}</dd>
              </template>
              <dt class="col-5">People</dt>
              <dd class="col-7">{{ members.length }} in {{ groupCount }}</dd>
            </dl>
          </div>
        </div>
      </div>

      <div v-if="can('invite', role)" class="col-12 col-lg-6">
        <InvitePanel :event-name="event.name" :join-code="event.join_code" />
      </div>
    </div>

    <div class="mt-4">
      <button v-if="mode === 'edit'" type="button" class="btn btn-outline-danger" :disabled="busy" data-testid="delete-event" @click="emit('delete')">
        Delete event
      </button>
      <button v-else type="button" class="btn btn-link text-danger px-0" data-testid="leave-event" @click="emit('leave')">Leave event</button>
    </div>
  </div>
</template>

<style scoped>
/* keep the line breaks typed into the description */
.description {
  white-space: pre-line;
}
</style>
