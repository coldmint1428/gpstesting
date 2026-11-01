// In-app confirm dialogs and toast messages (instead of the browser's confirm() / alert() boxes).
// One shared state for the whole app; <NotifyHost /> in App.vue draws it.
//
//   if (!(await askConfirm({ title: 'End the event?', message: '...', confirmText: 'End event', danger: true }))) return
//   toast('Event started. ICs can share now.')            // green, fades after 5 s
//   toast('Could not start the event: ...', 'danger')      // red
import { ref } from 'vue'

export const confirmState = ref(null) // { title, message, lines, confirmText, cancelText, danger, requireText, resolve } or null
export const toasts = ref([]) // [{ id, text, type }]

// Opens the dialog; resolves true (confirmed) or false (cancelled / closed).
//   lines       sentences under the message, drawn as a list: refusals name several things at once (step 23)
//   cancelText  null for a dialog with one button -- something to read, nothing to decide
//   requireText a word the person must type before the main button works (ending a live event: a slip-proof step)
export function askConfirm({ title, message = '', lines = [], confirmText = 'OK', cancelText = 'Cancel', danger = false, requireText = '' }) {
  if (confirmState.value) confirmState.value.resolve(false) // only one dialog at a time
  return new Promise((resolve) => {
    confirmState.value = { title, message, lines, confirmText, cancelText, danger, requireText, resolve }
  })
}

/** A dialog with one button: a refusal or a report, in the same frame as the questions. Resolves true when closed. */
export function askNotice({ title, message = '', lines = [], confirmText = 'OK' }) {
  return askConfirm({ title, message, lines, confirmText, cancelText: null })
}

export function answerConfirm(yes) {
  const state = confirmState.value
  confirmState.value = null
  if (state) state.resolve(yes)
}

let nextId = 1
// type: 'success' | 'danger' | 'warning' | 'info'
export function toast(text, type = 'success', ms = 5000) {
  // The same sentence already on screen is not said twice (QA 1 Nov: one toast per swipe stacked eight deep). It
  // stays up for the full time again instead, so a repeated action still gets its answer.
  const shown = toasts.value.find((t) => t.text === text && t.type === type)
  if (shown) {
    clearTimeout(shown.timer)
    shown.timer = setTimeout(() => closeToast(shown.id), ms)
    return
  }
  const id = nextId++
  const entry = { id, text, type, timer: null }
  toasts.value.push(entry)
  entry.timer = setTimeout(() => closeToast(id), ms)
}

export function closeToast(id) {
  toasts.value = toasts.value.filter((t) => t.id !== id)
}
