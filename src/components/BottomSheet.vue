<script setup>
// BottomSheet - a sheet that rises from the bottom of the phone screen over a dimmed page (Figma "Join an event",
// "Problem actions"). Tapping the dimmed page or the close button closes it; the page underneath keeps its place.
defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: '' },
})
const emit = defineEmits(['close'])
</script>

<template>
  <Teleport to="body">
    <template v-if="open">
      <div class="pv-scrim" aria-hidden="true" @click="emit('close')"></div>
      <section class="pv-sheet" role="dialog" aria-modal="true" :aria-label="title" data-testid="bottom-sheet">
        <div class="pv-grabber" aria-hidden="true"></div>
        <div class="d-flex align-items-start gap-2 mb-2">
          <h2 v-if="title" class="h4 fw-semibold mb-0 flex-grow-1">{{ title }}</h2>
          <button type="button" class="btn-close mt-1" aria-label="Close" @click="emit('close')"></button>
        </div>
        <slot />
      </section>
    </template>
  </Teleport>
</template>
