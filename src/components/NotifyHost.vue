<script setup>
// Draws the in-app confirm dialog and toast messages (see composables/useNotify.js).
// Bootstrap modal + toast styles, opened by Vue (no Bootstrap JavaScript needed).
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { confirmState, answerConfirm, toasts, closeToast } from '../composables/useNotify'

const confirmButton = ref(null)
const typeInput = ref(null)
const typed = ref('')
// A dialog that asks for a typed word only confirms once it matches (any case)
const typedOk = computed(
  () => !confirmState.value || !confirmState.value.requireText || typed.value.trim().toUpperCase() === confirmState.value.requireText.toUpperCase(),
)
function confirmIfAllowed() {
  if (typedOk.value) answerConfirm(true)
}

// Put the keyboard focus on the main button when the dialog opens (Enter confirms) -- or on the word to type
watch(confirmState, async (state) => {
  typed.value = ''
  if (state) {
    await nextTick()
    if (state.requireText && typeInput.value) typeInput.value.focus()
    else if (confirmButton.value) confirmButton.value.focus()
  }
})

function onKey(event) {
  if (event.key === 'Escape' && confirmState.value) answerConfirm(false)
}
onMounted(() => document.addEventListener('keydown', onKey))
onUnmounted(() => document.removeEventListener('keydown', onKey))
</script>

<template>
  <!-- Confirm dialog: fades in while the box rises and settles; the dimmed page behind fades separately (motion.css) -->
  <Transition name="dialog">
    <div
      v-if="confirmState"
      class="modal d-block"
      tabindex="-1"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-title"
      data-testid="confirm-dialog"
      @click.self="answerConfirm(false)"
    >
      <div class="modal-dialog modal-dialog-centered">
        <div class="modal-content shadow">
          <div class="modal-header border-0 pb-0">
            <h2 id="confirm-title" class="modal-title h5">{{ confirmState.title }}</h2>
            <button type="button" class="btn-close" aria-label="Close" @click="answerConfirm(false)"></button>
          </div>
          <div v-if="confirmState.message || (confirmState.lines && confirmState.lines.length)" class="modal-body pt-2">
            <p v-if="confirmState.message" class="mb-2">{{ confirmState.message }}</p>
            <ul v-if="confirmState.lines && confirmState.lines.length" class="mb-0 ps-3" data-testid="confirm-lines">
              <li v-for="(line, i) in confirmState.lines" :key="i">{{ line }}</li>
            </ul>
          </div>
          <div v-if="confirmState.requireText" class="modal-body pt-0">
            <label for="confirm-type" class="form-label small">Type <strong>{{ confirmState.requireText }}</strong> to confirm</label>
            <input
              id="confirm-type"
              ref="typeInput"
              v-model="typed"
              class="form-control"
              autocomplete="off"
              autocapitalize="characters"
              data-testid="confirm-type"
              @keydown.enter.prevent="confirmIfAllowed"
            />
          </div>
          <div class="modal-footer border-0 pt-0">
            <button
              v-if="confirmState.cancelText"
              type="button"
              class="btn btn-outline-secondary"
              data-testid="confirm-cancel"
              @click="answerConfirm(false)"
            >
              {{ confirmState.cancelText }}
            </button>
            <button
              ref="confirmButton"
              type="button"
              class="btn"
              :class="!typedOk ? 'btn-outline-secondary' : confirmState.danger ? 'btn-danger' : 'btn-primary'"
              :disabled="!typedOk"
              data-testid="confirm-ok"
              @click="confirmIfAllowed"
            >
              {{ typedOk ? confirmState.confirmText : 'Type ' + confirmState.requireText + ' to enable' }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </Transition>
  <Transition name="backdrop">
    <div v-if="confirmState" class="modal-backdrop show"></div>
  </Transition>

  <!-- Toasts: top right on a laptop, top of the screen on a phone -->
  <!-- Each toast slides in from the side and the others glide to make room -->
  <TransitionGroup tag="div" name="toast" class="toast-container position-fixed top-0 end-0 p-3" aria-live="polite" data-testid="toasts">
    <div
      v-for="t in toasts"
      :key="t.id"
      class="toast show align-items-center border-0"
      :class="'text-bg-' + t.type"
      role="status"
    >
      <div class="d-flex">
        <div class="toast-body">{{ t.text }}</div>
        <button
          type="button"
          class="btn-close me-2 m-auto"
          :class="{ 'btn-close-white': t.type !== 'warning' }"
          aria-label="Close"
          @click="closeToast(t.id)"
        ></button>
      </div>
    </div>
  </TransitionGroup>
</template>

<style scoped>
.toast-container {
  z-index: 2000; /* above Leaflet maps (400-1000) and the dialog backdrop */
}
</style>
