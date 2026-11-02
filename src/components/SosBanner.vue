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
  <div v-if="mine || others.length" class="kp-stack" style="gap: 8px" data-testid="sos-banners">
    <!-- My SOS -->
    <div v-if="mine" class="kp-banner kp-banner-danger" role="alert" aria-live="assertive" data-testid="sos-mine">
      <div class="kp-banner-text">
        <strong>SOS sent.</strong> {{ myGpsText }}
        <small>
          <template v-if="myHelpers"><strong>On the way:</strong> {{ myHelpers }}</template>
          <template v-else>No one has said they are on the way yet.</template>
        </small>
      </div>
      <button type="button" class="btn btn-sm btn-danger" :disabled="busy" data-testid="sos-safe" @click="$emit('resolve', mine.id)">I'm safe</button>
    </div>

    <!-- Other people's SOS -->
    <div v-for="o in others" :key="o.a.id" class="kp-banner kp-banner-danger" role="alert" aria-live="assertive" :data-testid="'sos-' + o.a.id">
      <div class="kp-banner-text">
        <strong>SOS: {{ o.name }} needs help</strong><span v-if="o.group"> · {{ o.group }}</span>
        <span class="small"> · {{ o.ago }}</span>
        <div v-if="o.a.note">"{{ o.a.note }}"</div>
        <small>{{ o.where }}<template v-if="o.helpers"> · On the way: {{ o.helpers }}</template></small>
      </div>
      <div class="kp-actions">
        <button v-if="o.a.lat != null" type="button" class="btn btn-sm btn-outline-secondary" data-testid="sos-show" @click="$emit('show', o.a.id)">Show on map</button>
        <button v-if="!o.iAmHelping" type="button" class="btn btn-sm btn-danger" :disabled="busy" data-testid="sos-help" @click="$emit('help', o.a.id)">I'm on my way</button>
        <span v-else class="kp-chip">You are on the way</span>
        <button v-if="o.canResolve" type="button" class="btn btn-sm btn-ghost" :disabled="busy" data-testid="sos-resolve" @click="$emit('resolve', o.a.id)">Mark handled</button>
      </div>
    </div>
  </div>
</template>
