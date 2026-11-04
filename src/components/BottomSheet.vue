<script setup>
// BottomSheet - a sheet that rises from the bottom of the phone screen over a dimmed page (Figma "Join an event",
// "Problem actions"). Tapping the dimmed page or the close button closes it; the page underneath keeps its place.
import { watch, onBeforeUnmount } from 'vue'
import { useEscape } from '../composables/useEscape'

const props = defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: '' },
})
const emit = defineEmits(['close'])
useEscape(() => props.open, () => emit('close'))

// While a sheet is open the page under it stays still: a finger on the dimmed page must not scroll it. Counted, so
// two open sheets do not unlock each other.
let locked = false
function lock(on) {
  if (on === locked) return
  locked = on
  const root = document.documentElement
  const n = (+root.dataset.sheetLocks || 0) + (on ? 1 : -1)
  if (n > 0) root.dataset.sheetLocks = String(n)
  else delete root.dataset.sheetLocks
  root.classList.toggle('pv-scroll-locked', n > 0)
}
watch(() => props.open, lock, { immediate: true })
onBeforeUnmount(() => lock(false))
</script>

<template>
  <Teleport to="body">
    <!-- The page dims and the sheet rises in; both reverse when it closes (motion.css) -->
    <Transition name="backdrop">
      <div v-if="open" class="pv-scrim" aria-hidden="true" @click="emit('close')"></div>
    </Transition>
    <Transition name="sheet">
      <section v-if="open" class="pv-sheet" role="dialog" aria-modal="true" :aria-label="title" data-testid="bottom-sheet">
        <div class="pv-grabber" aria-hidden="true"></div>
        <div class="d-flex align-items-start gap-2 mb-2">
          <h2 v-if="title" class="h4 fw-semibold mb-0 flex-grow-1">{{ title }}</h2>
          <button type="button" class="btn-close mt-1" aria-label="Close" @click="emit('close')"></button>
        </div>
        <slot />
      </section>
    </Transition>
  </Teleport>
</template>
