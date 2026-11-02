<script setup>
// RehearsalRequests - the Requests tab of the Rehearsals page, for the root and planners: "not available" requests to
// approve or reject, then the ones already decided. The database reads and decides only for them (080).
import { computed } from 'vue'
import { formatRehearsal } from '../utils/rehearsalCalendar'

const props = defineProps({
  absences: { type: Array, default: () => [] },
  rehearsals: { type: Array, default: () => [] },
  members: { type: Array, default: () => [] },
  groups: { type: Array, default: () => [] },
  busy: { type: Boolean, default: false },
})
const emit = defineEmits(['decide'])

const nameOf = (userId) => {
  const member = props.members.find((m) => m.id === userId)
  return member ? member.display_name : 'Someone no longer in the event'
}
function groupOf(userId) {
  const member = props.members.find((m) => m.id === userId)
  const group = member && props.groups.find((g) => g.id === member.groupId)
  return group ? group.name : ''
}

/** Each request with its rehearsal, soonest rehearsal first. */
const requests = computed(() =>
  props.absences
    .map((absence) => ({ ...absence, rehearsal: props.rehearsals.find((r) => r.id === absence.rehearsalId) }))
    .filter((request) => request.rehearsal)
    .sort((a, b) => a.rehearsal.startsAt - b.rehearsal.startsAt),
)
const pending = computed(() => requests.value.filter((request) => request.status === 'pending'))
const decided = computed(() => requests.value.filter((request) => request.status !== 'pending'))
</script>

<template>
  <div class="kp-stack" data-testid="rehearsal-requests">
    <section class="kp-card" data-testid="requests-pending">
      <h2 class="kp-title mb-2">Waiting for a decision</h2>
      <ul v-if="pending.length" class="rq-list">
        <li v-for="request in pending" :key="request.id" data-testid="request-row">
          <div class="rq-main">
            <strong>{{ nameOf(request.userId) }}</strong><span v-if="groupOf(request.userId)" class="rq-soft"> · {{ groupOf(request.userId) }}</span>
            <div class="rq-soft">{{ formatRehearsal(request.rehearsal) }}</div>
            <p class="rq-reason" data-testid="request-reason">{{ request.reason }}</p>
          </div>
          <div class="rq-actions">
            <button type="button" class="btn btn-sm btn-primary" :disabled="busy" data-testid="request-approve" @click="emit('decide', { id: request.id, approve: true })">Approve</button>
            <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="request-reject" @click="emit('decide', { id: request.id, approve: false })">Reject</button>
          </div>
        </li>
      </ul>
      <p v-else class="rq-soft mb-0" data-testid="requests-none">No requests are waiting.</p>
    </section>

    <section v-if="decided.length" class="kp-card" data-testid="requests-decided">
      <h2 class="kp-title mb-2">Decided</h2>
      <ul class="rq-list">
        <li v-for="request in decided" :key="request.id" data-testid="request-decided-row">
          <div class="rq-main">
            <strong>{{ nameOf(request.userId) }}</strong><span v-if="groupOf(request.userId)" class="rq-soft"> · {{ groupOf(request.userId) }}</span>
            <span class="rq-status" :class="'is-' + request.status">{{ request.status === 'approved' ? 'Approved' : 'Rejected' }}</span>
            <div class="rq-soft">{{ formatRehearsal(request.rehearsal) }}</div>
            <p class="rq-reason">{{ request.reason }}</p>
            <div v-if="request.decidedBy" class="rq-soft">Decided by {{ nameOf(request.decidedBy) }}</div>
          </div>
          <div class="rq-actions">
            <button
              type="button"
              class="btn btn-sm btn-outline-secondary"
              :disabled="busy"
              data-testid="request-change"
              @click="emit('decide', { id: request.id, approve: request.status !== 'approved' })"
            >{{ request.status === 'approved' ? 'Reject instead' : 'Approve instead' }}</button>
          </div>
        </li>
      </ul>
    </section>
  </div>
</template>

<style scoped>
.rq-list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.rq-list li {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px 16px;
  padding: 12px 0;
  border-top: 1px solid var(--line);
  font-size: 14px;
}
.rq-list li:first-child {
  border-top: 0;
}
.rq-main {
  flex: 1 1 240px;
  min-width: 0;
}
.rq-soft {
  color: var(--muted);
  font-size: 13px;
}
.rq-reason {
  margin: 6px 0 0;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
}
.rq-status {
  margin-left: 8px;
  padding: 1px 8px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 600;
}
.rq-status.is-approved {
  background: var(--mint);
  color: var(--ink);
}
.rq-status.is-rejected {
  background: var(--soft);
  color: var(--ink);
}
.rq-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
</style>
