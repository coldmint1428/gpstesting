// Escape closes a pop-up wherever the keyboard focus is (a listener on the pop-up itself only hears it while
// something inside has focus). A confirm dialog asked on top of the pop-up takes the Escape for itself.
import { onBeforeUnmount, onMounted } from 'vue'
import { confirmState } from './useNotify'

export function useEscape(isOpen, close) {
  function onKey(event) {
    if (event.key !== 'Escape' || confirmState.value || !isOpen()) return
    close()
  }
  onMounted(() => document.addEventListener('keydown', onKey))
  onBeforeUnmount(() => document.removeEventListener('keydown', onKey))
}
