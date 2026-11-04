<script setup>
// Draws the in-app confirm dialog and toast messages (see composables/useNotify.js).
// Bootstrap modal + toast styles, opened by Vue (no Bootstrap JavaScript needed).
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { confirmState, answerConfirm, toasts, closeToast } from '../composables/useNotify'
import ExpandTransition from './ExpandTransition.vue'

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

// A long list (a plan's 26 warnings) folds away under one button and scrolls inside the dialog when opened, so the
// question and its buttons stay on screen. A few lines are short enough to show as they are.
const FOLD_AFTER = 3
const linesOpen = ref(false)
const lineCount = computed(() => (confirmState.value && confirmState.value.lines ? confirmState.value.lines.length : 0))
const folds = computed(() => lineCount.value > FOLD_AFTER)
const foldLabel = computed(() => {
  const what = (confirmState.value && confirmState.value.linesLabel) || ''
  return (linesOpen.value ? 'Hide ' : 'Show ') + (what ? lineCount.value + ' ' + what : 'all ' + lineCount.value)
})
watch(confirmState, () => (linesOpen.value = false))

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
      <div class="modal-dialog modal-dialog-centered modal-dialog-scrollable">
        <div class="modal-content shadow">
          <div class="modal-header border-0 pb-0">
            <h2 id="confirm-title" class="modal-title h5">{{ confirmState.title }}</h2>
            <button type="button" class="btn-close" aria-label="Close" @click="answerConfirm(false)"></button>
          </div>
          <div v-if="confirmState.message || (confirmState.lines && confirmState.lines.length)" class="modal-body pt-2">
            <p v-if="confirmState.message" class="mb-2">{{ confirmState.message }}</p>
            <button
              v-if="folds"
              type="button"
              class="k2-foldbtn"
              :aria-expanded="linesOpen ? 'true' : 'false'"
              aria-controls="confirm-lines"
              data-testid="confirm-lines-toggle"
              @click="linesOpen = !linesOpen"
            >
              {{ foldLabel }}<svg viewBox="0 0 24 24" aria-hidden="true" :class="{ 'is-open': linesOpen }"><path d="m6 9 6 6 6-6"></path></svg>
            </button>
            <ul v-if="lineCount && !folds" id="confirm-lines" class="mb-0 ps-3" data-testid="confirm-lines">
              <li v-for="(line, i) in confirmState.lines" :key="i">{{ line }}</li>
            </ul>
            <ExpandTransition>
              <div v-if="folds && linesOpen">
                <div class="k2-foldpad">
                  <ul id="confirm-lines" class="mb-0 k2-foldlist" data-testid="confirm-lines">
                    <li v-for="(line, i) in confirmState.lines" :key="i">{{ line }}</li>
                  </ul>
                </div>
              </div>
            </ExpandTransition>
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
/* A question asked from inside a pop-up (Start event asks "Start the event now?") must sit above that pop-up's
   scrim (.k2-scrim, 1200), not at Bootstrap's 1055 behind it, where its buttons cannot be pressed */
.modal[data-testid='confirm-dialog'] {
  z-index: 1300;
}
</style>
