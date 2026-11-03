// Which ⋯ / ▾ menu of a component is open: one at a time, closed by a click outside any [data-menu] or by Escape.
import { onBeforeUnmount, onMounted, ref } from 'vue'

export function useOpenMenu() {
  const openMenu = ref(null)
  const toggleMenu = (key) => (openMenu.value = openMenu.value === key ? null : key)
  const closeMenu = () => (openMenu.value = null)
  function onPointer(event) {
    if (openMenu.value != null && !event.target.closest('[data-menu]')) closeMenu()
  }
  function onKey(event) {
    if (event.key === 'Escape') closeMenu()
  }
  onMounted(() => {
    document.addEventListener('pointerdown', onPointer)
    document.addEventListener('keydown', onKey)
  })
  onBeforeUnmount(() => {
    document.removeEventListener('pointerdown', onPointer)
    document.removeEventListener('keydown', onKey)
  })
  return { openMenu, toggleMenu, closeMenu }
}
