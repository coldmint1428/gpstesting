<script setup>
// Wizard step 4: everything on one page before Confirm
import { computed } from 'vue'
import { useEventWizardStore, ROLE_OPTIONS } from '../../stores/eventWizard'
import { formatDayTime } from '../../utils/time'

const props = defineProps({
  everyone: { type: Array, required: true }, // [{ id, display_name, email, role }] incl. the creator
})
const wizard = useEventWizardStore()

const byId = computed(() => Object.fromEntries(props.everyone.map((p) => [p.id, p])))
const withRole = (role) => props.everyone.filter((p) => p.role === role)
const unassigned = computed(() => props.everyone.filter((p) => !wizard.groupOf[p.id]))
const roleLabel = (role) => (role === 'root' ? 'Root' : ROLE_OPTIONS.find((r) => r.value === role).label)
</script>

<template>
  <section>
    <h2 class="kp-title mb-3">Review</h2>

    <dl class="kp-dl mb-4" data-testid="wiz-preview-details">
      <dt>Name</dt>
      <dd>{{ wizard.details.name.trim() }}</dd>
      <template v-if="wizard.details.description.trim()">
        <dt>Description</dt>
        <dd class="kp-prewrap">{{ wizard.details.description.trim() }}</dd>
      </template>
      <template v-if="wizard.details.venue.trim()">
        <dt>Venue</dt>
        <dd>{{ wizard.details.venue.trim() }}</dd>
      </template>
      <dt>When</dt>
      <dd>{{ formatDayTime(wizard.details.startsAt) }} – {{ formatDayTime(wizard.details.endsAt) }}</dd>
      <dt>Root</dt>
      <dd>{{ withRole('root').map((p) => p.display_name).join(', ') }} (you)</dd>
      <dt>Planners</dt>
      <dd>{{ withRole('planner').map((p) => p.display_name).join(', ') || 'None' }}</dd>
      <dt>Marshals</dt>
      <dd>{{ withRole('marshal').map((p) => p.display_name).join(', ') || 'None' }}</dd>
      <dt>Members</dt>
      <dd>{{ withRole('participant').length }}</dd>
    </dl>

    <h3 class="kp-label">Groups · {{ wizard.groups.length }}</h3>
    <p v-if="wizard.groups.length === 0" class="kp-note">No groups.</p>
    <ul class="kp-list">
      <li v-for="g in wizard.groups" :key="g.key" class="kp-row">
        <span class="kp-dot" :style="{ background: g.colour }" aria-hidden="true"></span>
        <div class="kp-row-main">
          <strong>{{ g.name.trim() }}</strong>
          <span v-if="g.members.length === 0">No one yet.</span>
          <span v-else class="kp-chips mt-1">
            <span v-for="m in g.members" :key="m.userId" class="kp-chip" :class="{ 'kp-chip-peach': m.isIC }">
              {{ byId[m.userId].display_name }}<template v-if="m.isAdmin"> · Admin</template><template v-if="m.isIC"> · IC</template><template v-if="byId[m.userId].role !== 'participant'"> · {{ roleLabel(byId[m.userId].role) }}</template>
            </span>
          </span>
        </div>
      </li>
    </ul>

    <p v-if="unassigned.length" class="kp-note">Not in a group: {{ unassigned.map((p) => p.display_name).join(', ') }}</p>
  </section>
</template>
