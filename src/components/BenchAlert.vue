<script setup>
// A dismissible alert.
//
// Every message in this app that the reader can act on -- a failed save, a refused upload,
// a claim somebody else holds -- is delivered in one of these, and every one of them carries
// a close button. A message with no way to close it is a message the reader has to work
// around: it sits there while they fix the problem, and it is still sitting there afterwards.
//
// `variant` is the Bootstrap colour (danger, warning, success, info, ...) and nothing else
// is derived from it, so a new kind of message needs no new component.
//
// Dismissing only clears what is displayed -- the state behind it is the parent's, because a
// close button that also reset `lostClaim` or threw away an unsaved edit would be a trap.
// Slot content is written per call site, so each message keeps its own wording and markup.
defineProps({
  variant: { type: String, default: 'danger' },
  testid: { type: String, default: '' },
})

const emit = defineEmits(['dismiss'])
</script>

<template>
  <!-- `data-testid` is on the alert itself so existing locators keep working; the close
       button gets `-close` for anything that wants to press it. -->
  <div
    class="alert py-2 alert-dismissible"
    :class="'alert-' + variant"
    role="alert"
    :data-testid="testid || undefined"
  >
    <slot />
    <button
      type="button"
      class="btn-close"
      :data-testid="testid ? testid + '-close' : undefined"
      aria-label="Close"
      @click="emit('dismiss')"
    ></button>
  </div>
</template>
