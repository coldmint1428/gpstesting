<script setup>
// RehearsalRequests - the Requests tab of the Rehearsals page, for the root and planners: "not available" requests to
// approve or reject, then the ones already decided. The database reads and decides only for them (080).
import { computed, ref } from 'vue'
import ExpandTransition from './ExpandTransition.vue'
import { dayKey, formatRehearsal } from '../utils/rehearsalCalendar'

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

/** Each request with its rehearsal, soonest rehearsal first. A member has one request a day: should the list hold two for
 *  the same day (an older one from before the database kept to that), only the newest is shown, so nothing sits there
 *  that cannot be answered. */
const requests = computed(() => {
  const newest = new Map()
  for (const absence of props.absences) {
    const rehearsal = props.rehearsals.find((r) => r.id === absence.rehearsalId)
    if (!rehearsal) continue
    const key = absence.userId + '|' + dayKey(rehearsal.startsAt)
    const seen = newest.get(key)
    if (!seen || (absence.createdAt || 0) > (seen.createdAt || 0)) newest.set(key, { ...absence, rehearsal })
  }
  return [...newest.values()].sort((a, b) => a.rehearsal.startsAt - b.rehearsal.startsAt)
})
const pending = computed(() => requests.value.filter((request) => request.status === 'pending'))
// A request is answered before its rehearsal starts; afterwards it is a record
const started = (request) => request.rehearsal.startsAt.getTime() <= Date.now()
const decided = computed(() => requests.value.filter((request) => request.status !== 'pending').reverse())
// The answered ones are history: folded away once there are a few, so the ones waiting stay in view
const decidedOpen = ref(false)
const FOLD_AT = 3
</script>

<template>
  <div class="kp-stack" data-testid="rehearsal-requests">
    <section class="kp-card" data-testid="requests-pending">
      <h2 class="kp-title mb-2">Waiting for a decision</h2>
      <ul v-if="pending.length" class="rq-list rq-scroll" data-testid="requests-pending-list">
        <li v-for="request in pending" :key="request.id" data-testid="request-row">
          <div class="rq-main">
            <strong>{{ nameOf(request.userId) }}</strong><span v-if="groupOf(request.userId)" class="rq-soft"> · {{ groupOf(request.userId) }}</span>
            <div class="rq-soft">{{ formatRehearsal(request.rehearsal) }}</div>
            <p class="rq-reason" data-testid="request-reason">{{ request.reason }}</p>
          </div>
          <div v-if="started(request)" class="rq-actions"><span class="rq-soft" data-testid="request-started">The rehearsal has started</span></div>
          <div v-else class="rq-actions">
            <button type="button" class="btn btn-sm btn-primary" :disabled="busy" data-testid="request-approve" @click="emit('decide', { id: request.id, approve: true })">Approve</button>
            <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" data-testid="request-reject" @click="emit('decide', { id: request.id, approve: false })">Reject</button>
          </div>
        </li>
      </ul>
      <p v-else class="rq-soft mb-0" data-testid="requests-none">No requests are waiting.</p>
    </section>

    <section v-if="decided.length" class="kp-card" data-testid="requests-decided">
      <div class="rq-head">
        <h2 class="kp-title mb-0">Decided <span class="rq-soft">· {{ decided.length }}</span></h2>
        <button v-if="decided.length > FOLD_AT" type="button" class="btn btn-sm btn-outline-secondary" :aria-expanded="decidedOpen ? 'true' : 'false'" data-testid="requests-decided-toggle" @click="decidedOpen = !decidedOpen">{{ decidedOpen ? 'Hide' : 'Show' }}</button>
      </div>
      <ExpandTransition><div v-if="decided.length <= FOLD_AT || decidedOpen">
      <ul class="rq-list rq-scroll">
        <li v-for="request in decided" :key="request.id" data-testid="request-decided-row">
          <div class="rq-main">
            <strong>{{ nameOf(request.userId) }}</strong><span v-if="groupOf(request.userId)" class="rq-soft"> · {{ groupOf(request.userId) }}</span>
            <span class="rq-status" :class="'is-' + request.status">{{ request.status === 'approved' ? 'Approved' : 'Rejected' }}</span>
            <div class="rq-soft">{{ formatRehearsal(request.rehearsal) }}</div>
            <p class="rq-reason">{{ request.reason }}</p>
            <div v-if="request.decidedBy" class="rq-soft">Decided by {{ nameOf(request.decidedBy) }}</div>
          </div>
          <div v-if="!started(request)" class="rq-actions">
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
      </div>
      </ExpandTransition>
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
/* Many requests scroll inside their card instead of growing the page */
.rq-scroll {
  max-height: min(50vh, 460px);
  overflow-y: auto;
  overscroll-behavior: contain;
  padding-right: 6px;
}
.rq-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 8px;
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
