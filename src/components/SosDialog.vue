<script setup>
// SosDialog - asks "Send SOS?" before alerting everyone in the event (so a stray tap does not). An optional message says
// what happened. Emits `send` with the message, or `close`. The event page (EventView.vue) sends it.
import { ref, watch } from 'vue'

const props = defineProps({
  open: { type: Boolean, default: false },
  busy: { type: Boolean, default: false }, // sending (getting the location first)
})
const emit = defineEmits(['send', 'close'])

const note = ref('')
watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) note.value = ''
  },
)
</script>

<template>
  <Teleport to="body">
    <template v-if="open">
      <div class="modal d-block" tabindex="-1" role="dialog" aria-modal="true" aria-labelledby="sos-title" data-testid="sos-dialog" @click.self="emit('close')">
        <div class="modal-dialog modal-dialog-centered">
          <form class="modal-content" @submit.prevent="emit('send', note)">
            <div class="modal-header bg-danger text-white">
              <h2 id="sos-title" class="modal-title h5">Send SOS?</h2>
              <button type="button" class="btn-close btn-close-white" aria-label="Close" :disabled="busy" @click="emit('close')"></button>
            </div>
            <div class="modal-body">
              <p class="mb-2">Everyone in this event is alerted and sees your location until the SOS ends.</p>
              <label for="sos-note" class="form-label small mb-1">What happened? (optional)</label>
              <input
                id="sos-note"
                v-model.trim="note"
                class="form-control"
                maxlength="200"
                placeholder="e.g. Someone fainted"
                autocomplete="off"
                data-testid="sos-note"
              />
            </div>
            <div class="modal-footer">
              <button type="button" class="btn btn-outline-secondary" :disabled="busy" @click="emit('close')">Cancel</button>
              <button type="submit" class="btn btn-danger btn-lg px-4" :disabled="busy" data-testid="sos-send">
                {{ busy ? 'Getting your location…' : 'Send SOS' }}
              </button>
            </div>
          </form>
        </div>
      </div>
      <div class="modal-backdrop show"></div>
    </template>
  </Teleport>
</template>
