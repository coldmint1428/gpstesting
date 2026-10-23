<script setup>
// BroadcastBanner - a planner's message to many people at once ("Lightning: take shelter now"), shown to each person it
// reached until they press Got it or a planner clears it (032). Urgent ones are red. Showing it on a visible page counts
// as "seen" for the planner's count; Got it counts as read and takes it away.
import { computed, onMounted, onUnmounted, watch } from 'vue'
import { formatTimeSeconds } from '../utils/time'

const props = defineProps({
  broadcasts: { type: Object, required: true }, // useBroadcasts()
})

const items = computed(() => props.broadcasts.mine.value)
const top = computed(() => items.value[0] || null)
const more = computed(() => items.value.slice(1))

// Seen = on screen while the page is visible
function markVisible() {
  if (document.visibilityState !== 'visible') return
  for (const b of items.value) if (!b.seen) props.broadcasts.markSeen(b.id)
}
watch(items, markVisible, { flush: 'post' })
onMounted(() => {
  markVisible()
  document.addEventListener('visibilitychange', markVisible)
})
onUnmounted(() => document.removeEventListener('visibilitychange', markVisible))
</script>

<template>
  <div
    v-if="top"
    class="alert py-2 mb-0 bc-banner"
    :class="top.urgent ? 'alert-danger' : 'alert-warning'"
    role="alert"
    aria-live="assertive"
    data-testid="broadcast-banner"
  >
    <div class="d-flex align-items-start gap-2">
      <span class="flex-grow-1 min-w-0">
        <strong>{{ top.urgent ? '⚠ Urgent message' : 'Message' }} from {{ top.from }}</strong>
        <span class="small opacity-75"> · {{ formatTimeSeconds(top.at) }}</span>
        <span class="d-block bc-body" data-testid="broadcast-body">{{ top.body }}</span>
      </span>
      <button
        type="button"
        class="btn btn-sm flex-shrink-0"
        :class="top.urgent ? 'btn-danger' : 'btn-dark'"
        data-testid="broadcast-ack"
        @click="broadcasts.ack(top.id)"
      >
        Got it
      </button>
    </div>
    <div v-for="b in more" :key="b.id" class="d-flex align-items-start gap-2 border-top mt-2 pt-2 small">
      <span class="flex-grow-1 min-w-0">
        <strong>{{ b.urgent ? '⚠ ' : '' }}{{ b.from }}</strong> · {{ formatTimeSeconds(b.at) }}<br />{{ b.body }}
      </span>
      <button type="button" class="btn btn-sm btn-outline-dark flex-shrink-0" @click="broadcasts.ack(b.id)">Got it</button>
    </div>
  </div>
</template>

<style scoped>
.bc-body {
  font-size: 1.05rem;
  margin-top: 2px;
  overflow-wrap: anywhere;
}
.min-w-0 {
  min-width: 0;
}
</style>
