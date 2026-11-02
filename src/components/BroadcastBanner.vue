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
  <div v-if="top" class="kp-stack" style="gap: 8px" role="alert" aria-live="assertive" data-testid="broadcast-banner">
    <div class="kp-banner" :class="{ 'kp-banner-danger': top.urgent }">
      <div class="kp-banner-text">
        <strong>{{ top.urgent ? '⚠ ' : '' }}{{ top.from }}</strong>
        <span class="small opacity-75"> · {{ formatTimeSeconds(top.at) }}</span>
        <div data-testid="broadcast-body">{{ top.body }}</div>
      </div>
      <button type="button" class="btn btn-sm" :class="top.urgent ? 'btn-danger' : 'btn-primary'" data-testid="broadcast-ack" @click="broadcasts.ack(top.id)">Got it</button>
    </div>
    <div v-for="b in more" :key="b.id" class="kp-banner" :class="{ 'kp-banner-danger': b.urgent }">
      <div class="kp-banner-text small">
        <strong>{{ b.urgent ? '⚠ ' : '' }}{{ b.from }}</strong> · {{ formatTimeSeconds(b.at) }}
        <div>{{ b.body }}</div>
      </div>
      <button type="button" class="btn btn-sm btn-outline-secondary" @click="broadcasts.ack(b.id)">Got it</button>
    </div>
  </div>
</template>
