<script setup>
// SosBanner - the event's active SOSs, on every page of the event (038_sos.sql).
//   My own SOS : that it was sent, whether my location is being sent, who is on the way, and "I'm safe".
//   Others'    : who needs help and where, "Show on map", "I'm on my way", and "Mark handled" for the people who may
//                end it (root, planners, marshals, and an IC or admin of the person's group).
// It only shows things and emits what was pressed; the event page (EventView.vue) calls the database.
import { computed } from 'vue'
import { timeAgo } from '../utils/people'

const props = defineProps({
  alerts: { type: Array, required: true }, // useSos().alerts
  mine: { type: Object, default: null }, // useSos().mine
  gps: { type: String, default: 'waiting' }, // useSos().gps
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  me: { type: Object, default: null },
  seesWholeEvent: { type: Boolean, default: false }, // root, planner or marshal
  now: { type: Number, required: true },
  busy: { type: Boolean, default: false },
})
defineEmits(['help', 'resolve', 'show'])

const nameOf = (userId) => (props.members.find((m) => m.id === userId) || { display_name: 'Someone' }).display_name
const groupOf = (groupId) => (props.groups.find((g) => g.id === groupId) || null)

// Who may end someone else's SOS (the database checks again)
function canResolve(a) {
  if (props.seesWholeEvent) return true
  return !!(props.me && a.groupId && props.me.groupId === a.groupId && (props.me.isIC || props.me.isAdmin))
}

const others = computed(() =>
  props.alerts
    .filter((a) => !props.mine || a.id !== props.mine.id)
    .map((a) => {
      const group = groupOf(a.groupId)
      return {
        a,
        name: nameOf(a.userId),
        group: group ? group.name : '',
        ago: timeAgo(a.raisedAt.getTime(), props.now),
        where: a.lat == null ? 'Location unknown' : 'Location ±' + Math.round(a.accuracy || 0) + ' m, ' + timeAgo(a.locatedAt.getTime(), props.now),
        iAmHelping: !!props.me && a.helpers.some((h) => h.userId === props.me.id),
        helpers: a.helpers.map((h) => h.name).join(', '),
        canResolve: canResolve(a),
      }
    }),
)

const myHelpers = computed(() => (props.mine ? props.mine.helpers.map((h) => h.name).join(', ') : ''))
const myGpsText = computed(() => {
  if (props.gps === 'on') return 'Your location is being sent.'
  if (props.gps === 'off') return 'Your location is off. Allow location for this app so people can find you.'
  return 'Getting your location…'
})
</script>

<template>
  <div v-if="mine || others.length" class="d-grid gap-2" data-testid="sos-banners">
    <!-- My SOS -->
    <div v-if="mine" class="alert alert-danger mb-0 py-2 sos-banner" role="alert" aria-live="assertive" data-testid="sos-mine">
      <div class="d-flex flex-wrap align-items-center gap-2">
        <span class="flex-grow-1">
          <strong>SOS sent.</strong> Everyone in this event can see it. {{ myGpsText }}
          <span class="d-block small">
            <template v-if="myHelpers"><strong>On the way:</strong> {{ myHelpers }}</template>
            <template v-else>No one has said they are on the way yet.</template>
          </span>
        </span>
        <button type="button" class="btn btn-sm btn-light" :disabled="busy" data-testid="sos-safe" @click="$emit('resolve', mine.id)">I'm safe</button>
      </div>
    </div>

    <!-- Other people's SOS -->
    <div
      v-for="o in others"
      :key="o.a.id"
      class="alert alert-danger mb-0 py-2 sos-banner"
      role="alert"
      aria-live="assertive"
      :data-testid="'sos-' + o.a.id"
    >
      <div class="d-flex flex-wrap align-items-center gap-2">
        <span class="flex-grow-1 min-w-0">
          <strong>SOS: {{ o.name }} needs help</strong><span v-if="o.group"> · {{ o.group }}</span>
          <span class="small"> · {{ o.ago }}</span>
          <span v-if="o.a.note" class="d-block">"{{ o.a.note }}"</span>
          <span class="d-block small">
            {{ o.where }}<template v-if="o.helpers"> · On the way: {{ o.helpers }}</template>
          </span>
        </span>
        <div class="d-flex flex-wrap gap-2">
          <button v-if="o.a.lat != null" type="button" class="btn btn-sm btn-light" data-testid="sos-show" @click="$emit('show', o.a.id)">Show on map</button>
          <button v-if="!o.iAmHelping" type="button" class="btn btn-sm btn-danger" :disabled="busy" data-testid="sos-help" @click="$emit('help', o.a.id)">
            I'm on my way
          </button>
          <span v-else class="badge text-bg-light align-self-center">You are on the way</span>
          <button v-if="o.canResolve" type="button" class="btn btn-sm btn-outline-dark" :disabled="busy" data-testid="sos-resolve" @click="$emit('resolve', o.a.id)">
            Mark handled
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.sos-banner {
  border-left: 0.35rem solid #b02a37;
}
.min-w-0 {
  min-width: 0;
}
</style>
