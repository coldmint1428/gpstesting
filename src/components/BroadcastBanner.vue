<script setup>
// BroadcastBanner - a planner's message to many people at once ("Lightning: take shelter now"), shown to each person it
// reached until they press Got it or a planner clears it (032). Urgent ones are red. Showing it on a visible page counts
// as "seen" for the planner's count; Got it counts as read and takes it away.
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import ExpandTransition from './ExpandTransition.vue'
import { formatTimeSeconds } from '../utils/time'

const props = defineProps({
  broadcasts: { type: Object, required: true }, // useBroadcasts()
})

const items = computed(() => props.broadcasts.mine.value)
const top = computed(() => items.value[0] || null)
const more = computed(() => items.value.slice(1))
// When messages pile up (nobody pressed Got it) the newest stays on screen and the rest fold behind one line, in a
// box that scrolls, with one button to clear them all.
const moreOpen = ref(false)
watch(more, (list) => {
  if (!list.length) moreOpen.value = false
})
function ackAll() {
  for (const b of [...items.value]) props.broadcasts.ack(b.id)
}

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
  <div v-if="top" class="kp-stack k2-notice-pile" style="gap: 8px; margin-bottom: 14px" role="alert" aria-live="assertive" data-testid="broadcast-banner">
    <div class="kp-banner" :class="{ 'kp-banner-danger': top.urgent }">
      <div class="kp-banner-text">
        <strong>{{ top.urgent ? '⚠ ' : '' }}{{ top.from }}</strong>
        <span class="small opacity-75"> · {{ formatTimeSeconds(top.at) }}</span>
        <div data-testid="broadcast-body">{{ top.body }}</div>
      </div>
      <button type="button" class="btn btn-sm" :class="top.urgent ? 'btn-danger' : 'btn-primary'" data-testid="broadcast-ack" @click="broadcasts.ack(top.id)">Got it</button>
    </div>
    <div v-if="more.length" class="bb-pile-head">
      <button type="button" class="btn btn-sm btn-outline-secondary" :aria-expanded="moreOpen ? 'true' : 'false'" data-testid="broadcast-more" @click="moreOpen = !moreOpen">
        {{ moreOpen ? 'Hide' : 'Show' }} {{ more.length }} earlier {{ more.length === 1 ? 'message' : 'messages' }}
      </button>
      <button type="button" class="btn btn-sm btn-ghost" data-testid="broadcast-ack-all" @click="ackAll">Got it for all {{ items.length }}</button>
    </div>
    <ExpandTransition>
      <div v-if="moreOpen && more.length" data-testid="broadcast-earlier">
        <div class="kp-stack bb-pile" style="gap: 8px">
          <div v-for="b in more" :key="b.id" class="kp-banner" :class="{ 'kp-banner-danger': b.urgent }">
            <div class="kp-banner-text small">
              <strong>{{ b.urgent ? '⚠ ' : '' }}{{ b.from }}</strong> · {{ formatTimeSeconds(b.at) }}
              <div>{{ b.body }}</div>
            </div>
            <button type="button" class="btn btn-sm btn-outline-secondary" @click="broadcasts.ack(b.id)">Got it</button>
          </div>
        </div>
      </div>
    </ExpandTransition>
  </div>
</template>

<style scoped>
.bb-pile-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.bb-pile {
  max-height: min(40vh, 320px);
  overflow-y: auto;
  overscroll-behavior: contain;
  padding-right: 6px;
}
</style>
