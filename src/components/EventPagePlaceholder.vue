<script setup>
// Stand-in for event screens not built yet for some roles (the view-only map, and the timeline for people who can't
// read the run sheet). It already gets what the real screen needs: replace this component, keep the props.
//   page : 'map' | 'timeline'      mode : 'edit' | 'view' (from canEdit in src/utils/permissions.js)
//   role : root | planner | marshal | admin | ic | member      group : my group (or null)
import { computed } from 'vue'
import { PAGE_LABEL } from '../utils/permissions'
import { formatDayTime } from '../utils/time'

const props = defineProps({
  page: { type: String, required: true },
  mode: { type: String, default: 'view' },
  role: { type: String, default: null },
  group: { type: Object, default: null },
  isLive: { type: Boolean, default: false },
  scheduledStart: { type: Date, default: null },
})

// What the finished screen will show this role
const plan = computed(() => {
  const mine = props.group ? props.group.name : 'your group'
  if (props.page === 'timeline') {
    if (props.role === 'member') return 'The timetable of ' + mine + ': where to be, and when.'
    if (props.role === 'ic') return 'The whole timeline, with ' + mine + '’s moves highlighted.'
    return 'The event’s timeline, view only.'
  }
  if (props.role === 'ic') return 'The event map with ' + mine + '’s zones. Use “Share my location” above to activate GPS.'
  return 'The event map: zones and areas, view only.'
})
</script>

<template>
  <div class="card" :data-testid="'placeholder-' + page" :data-mode="mode" :data-role="role">
    <div class="card-body">
      <h2 class="h6">{{ PAGE_LABEL[page] }} <span class="badge text-bg-light border">{{ mode === 'edit' ? 'Edit' : 'View' }}</span></h2>
      <p class="mb-2">{{ plan }}</p>
      <p v-if="!group && (role === 'ic' || role === 'member')" class="small text-muted mb-2">You are not in a group yet.</p>
      <p class="small text-muted mb-0">
        <template v-if="isLive">The event is live. The Live page shows where to go next.</template>
        <template v-else-if="scheduledStart">The event starts {{ formatDayTime(scheduledStart) }}.</template>
        <template v-else>This screen is still being built.</template>
      </p>
    </div>
  </div>
</template>
