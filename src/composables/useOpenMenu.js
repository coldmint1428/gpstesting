// Which ⋯ / ▾ menu of a component is open: one at a time across the whole page, closed by a click outside any
// [data-menu] or by Escape. Opening a menu in one component closes a menu left open by another.
//
// Every menu that opens is also placed so all of it can be reached (placeMenu below): a menu hangs under its button,
// but the last row of a scrolling list, a card that clips, the screen's edges and the phone's bottom bar could all cut
// it off. So it opens above the button when there is not room below, moves in from a side it would hang off, and,
// if it fits neither way, gets the height there is and scrolls.
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const instances = new Set() // the closeMenu of every mounted component that has menus
const GAP = 8 // the space a menu keeps from its button and from whatever would cut it off

/** The box a menu can show in: the screen, less the phone's bottom bar, cut down by every ancestor that clips. */
function roomFor(menu) {
  const room = { top: 0, left: 0, right: window.innerWidth, bottom: window.innerHeight }
  const bar = document.querySelector('.k2-bnav')
  if (bar && getComputedStyle(bar).display !== 'none' && !bar.contains(menu)) room.bottom = Math.min(room.bottom, bar.getBoundingClientRect().top)
  for (let box = menu.parentElement; box && box !== document.body; box = box.parentElement) {
    const style = getComputedStyle(box)
    if (style.overflowX === 'visible' && style.overflowY === 'visible') continue
    const r = box.getBoundingClientRect()
    room.top = Math.max(room.top, r.top)
    room.left = Math.max(room.left, r.left)
    room.right = Math.min(room.right, r.right)
    room.bottom = Math.min(room.bottom, r.bottom)
  }
  return room
}

/**
 * Where the menu's box is, without its opening animation: the pop scales and moves it for a moment, so a box read from
 * the screen mid-animation is a little small and in the wrong place. The layout offsets are what it settles at.
 */
function boxOf(menu) {
  const parent = menu.offsetParent || menu.parentElement
  const p = parent.getBoundingClientRect()
  const left = p.left + menu.offsetLeft - parent.scrollLeft
  const top = p.top + menu.offsetTop - parent.scrollTop
  return { left, top, right: left + menu.offsetWidth, bottom: top + menu.offsetHeight, height: menu.offsetHeight }
}

/** Put one open menu where all of it can be reached. Menus the stylesheet pins to the screen (fixed) are left alone. */
export function placeMenu(menu) {
  if (!menu || getComputedStyle(menu).position !== 'absolute') return
  menu.classList.remove('is-up')
  for (const prop of ['left', 'right', 'max-height', 'overflow-y']) menu.style.removeProperty(prop)
  const anchor = (menu.parentElement || menu).getBoundingClientRect()
  const room = roomFor(menu)
  let r = boxOf(menu)

  // Up or down: below unless it does not fit there and there is more room above
  const below = room.bottom - anchor.bottom - GAP
  const above = anchor.top - room.top - GAP
  if (r.bottom > room.bottom - 2 && above > below) menu.classList.add('is-up')
  const height = menu.classList.contains('is-up') ? above : below
  if (r.height > height && height > 80) {
    menu.style.maxHeight = Math.floor(height - GAP) + 'px'
    menu.style.overflowY = 'auto'
  }

  // Sideways: in from whichever edge it would hang off
  r = boxOf(menu)
  if (r.left < room.left + GAP) {
    menu.style.right = 'auto'
    menu.style.left = Math.round(room.left + GAP - anchor.left) + 'px'
  } else if (r.right > room.right - GAP) {
    menu.style.left = 'auto'
    menu.style.right = Math.round(anchor.right - (room.right - GAP)) + 'px'
  }
}

/** Place every menu that is open on the page. */
export function placeOpenMenus() {
  for (const menu of document.querySelectorAll('.menu, .k2-cal')) {
    if (menu.getBoundingClientRect().width) placeMenu(menu)
  }
}

/**
 * Keep a component's pop-up placed while it is open: when it opens, and again whenever the page or a list under it
 * scrolls or the window changes size (a list still scrolling when the menu opened would otherwise carry it past the
 * edge). For the menus here, and for pop-ups with their own open state (the date and time pickers, the account menu).
 */
export function usePlacedPopup(isOpen) {
  let frame = 0
  let following = false
  const replace = () => {
    cancelAnimationFrame(frame)
    frame = requestAnimationFrame(placeOpenMenus)
  }
  const follow = (on) => {
    if (on === following) return
    following = on
    const method = on ? 'addEventListener' : 'removeEventListener'
    document[method]('scroll', replace, { capture: true, passive: true })
    window[method]('resize', replace)
  }
  watch(isOpen, (open) => {
    follow(!!open)
    if (open) nextTick(replace)
  })
  onBeforeUnmount(() => {
    follow(false)
    cancelAnimationFrame(frame)
  })
}

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
  usePlacedPopup(() => openMenu.value != null)
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
