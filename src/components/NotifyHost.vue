<script setup>
// Draws the in-app confirm dialog and toast messages (see composables/useNotify.js).
// Bootstrap modal + toast styles, opened by Vue (no Bootstrap JavaScript needed).
import { ref, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { confirmState, answerConfirm, toasts, closeToast } from '../composables/useNotify'

const confirmButton = ref(null)

// Put the keyboard focus on the main button when the dialog opens (Enter confirms)
watch(confirmState, async (state) => {
  if (state) {
    await nextTick()
    if (confirmButton.value) confirmButton.value.focus()
  }
})

function onKey(event) {
  if (event.key === 'Escape' && confirmState.value) answerConfirm(false)
}
onMounted(() => document.addEventListener('keydown', onKey))
onUnmounted(() => document.removeEventListener('keydown', onKey))
</script>

<template>
  <!-- Confirm dialog -->
  <template v-if="confirmState">
    <div
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
              :class="confirmState.danger ? 'btn-danger' : 'btn-primary'"
              data-testid="confirm-ok"
              @click="answerConfirm(true)"
            >
              {{ confirmState.confirmText }}
            </button>
          </div>
        </div>
      </div>
    </div>
    <div class="modal-backdrop show"></div>
  </template>

  <!-- Toasts: top right on a laptop, top of the screen on a phone -->
  <div class="toast-container position-fixed top-0 end-0 p-3" aria-live="polite" data-testid="toasts">
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
  </div>
</template>

<style scoped>
.toast-container {
  z-index: 2000; /* above Leaflet maps (400-1000) and the dialog backdrop */
}
</style>
