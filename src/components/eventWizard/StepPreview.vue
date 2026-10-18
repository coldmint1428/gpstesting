<script setup>
// Wizard step 4: everything on one page before Confirm
import { computed } from 'vue'
import { useEventWizardStore, ROLE_OPTIONS } from '../../stores/eventWizard'
import { formatDayTime } from '../../utils/time'

const props = defineProps({
  everyone: { type: Array, required: true }, // [{ id, username, display_name, role }] incl. the creator
})
const wizard = useEventWizardStore()

const byId = computed(() => Object.fromEntries(props.everyone.map((p) => [p.id, p])))
const withRole = (role) => props.everyone.filter((p) => p.role === role)
const unassigned = computed(() => props.everyone.filter((p) => !wizard.groupOf[p.id]))
const roleLabel = (role) => (role === 'root' ? 'Root' : ROLE_OPTIONS.find((r) => r.value === role).label)
</script>

<template>
  <section>
    <h2 class="h5 mb-3">Preview</h2>

    <dl class="row mb-4" data-testid="wiz-preview-details">
      <dt class="col-sm-3">Name</dt>
      <dd class="col-sm-9">{{ wizard.details.name.trim() }}</dd>
      <template v-if="wizard.details.description.trim()">
        <dt class="col-sm-3">Description</dt>
        <dd class="col-sm-9 description">{{ wizard.details.description.trim() }}</dd>
      </template>
      <template v-if="wizard.details.venue.trim()">
        <dt class="col-sm-3">Venue</dt>
        <dd class="col-sm-9">{{ wizard.details.venue.trim() }}</dd>
      </template>
      <dt class="col-sm-3">When</dt>
      <dd class="col-sm-9">{{ formatDayTime(wizard.details.startsAt) }} – {{ formatDayTime(wizard.details.endsAt) }}</dd>
    </dl>

    <h3 class="h6">People</h3>
    <ul class="list-unstyled small mb-4">
      <li><strong>Root:</strong> {{ withRole('root').map((p) => p.display_name).join(', ') }} (you)</li>
      <li><strong>Planners:</strong> {{ withRole('planner').map((p) => p.display_name).join(', ') || 'none' }}</li>
      <li><strong>Marshals:</strong> {{ withRole('marshal').map((p) => p.display_name).join(', ') || 'none' }}</li>
      <li><strong>Members:</strong> {{ withRole('participant').length }}</li>
    </ul>

    <h3 class="h6">Groups ({{ wizard.groups.length }})</h3>
    <p v-if="wizard.groups.length === 0" class="text-muted small">No groups.</p>
    <div class="row g-2 mb-3">
      <div v-for="g in wizard.groups" :key="g.key" class="col-12 col-md-6">
        <div class="card h-100">
          <div class="card-body p-2 p-sm-3">
            <h4 class="h6 d-flex align-items-center gap-2">
              <span class="group-dot flex-shrink-0" :style="{ background: g.colour }" aria-hidden="true"></span>
              <span class="text-truncate">{{ g.name.trim() }}</span>
              <span class="text-muted small fw-normal ms-auto flex-shrink-0">{{ g.members.length }}</span>
            </h4>
            <p v-if="g.members.length === 0" class="text-muted small mb-0">No one yet.</p>
            <ul v-else class="list-unstyled small mb-0">
              <li v-for="m in g.members" :key="m.userId">
                {{ byId[m.userId].display_name }}
                <span v-if="m.isAdmin" class="badge text-bg-primary">Admin</span>
                <span v-if="m.isIC" class="badge text-bg-success ms-1">IC</span>
                <span v-if="byId[m.userId].role !== 'participant'" class="badge text-bg-secondary ms-1">
                  {{ roleLabel(byId[m.userId].role) }}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>

    <p v-if="unassigned.length" class="small text-muted">
      <strong>Not in a group:</strong> {{ unassigned.map((p) => p.display_name).join(', ') }}
    </p>
  </section>
</template>

<style scoped>
.group-dot {
  width: 0.9rem;
  height: 0.9rem;
  border-radius: 50%;
}
.description {
  white-space: pre-line;
}
</style>
