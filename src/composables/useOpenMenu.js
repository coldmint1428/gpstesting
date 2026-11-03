// Which ⋯ / ▾ menu of a component is open: one at a time across the whole page, closed by a click outside any
// [data-menu] or by Escape. Opening a menu in one component closes a menu left open by another.
import { onBeforeUnmount, onMounted, ref } from 'vue'

const instances = new Set() // the closeMenu of every mounted component that has menus

export function useOpenMenu() {
  const openMenu = ref(null)
  const closeMenu = () => (openMenu.value = null)
  const toggleMenu = (key) => {
    if (openMenu.value === key) return closeMenu()
    for (const close of instances) if (close !== closeMenu) close()
    openMenu.value = key
  }
  function onPointer(event) {
    if (openMenu.value != null && !event.target.closest('[data-menu]')) closeMenu()
  }
  function onKey(event) {
    if (event.key === 'Escape') closeMenu()
  }
  onMounted(() => {
    instances.add(closeMenu)
    document.addEventListener('pointerdown', onPointer)
    document.addEventListener('keydown', onKey)
  })
  onBeforeUnmount(() => {
    instances.delete(closeMenu)
    document.removeEventListener('pointerdown', onPointer)
    document.removeEventListener('keydown', onKey)
  })
  return { openMenu, toggleMenu, closeMenu }
}
