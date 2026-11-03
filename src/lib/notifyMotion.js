// notifyMotion - every banner, alert and inline message eases in and out instead of snapping the page about.
// Pages add and remove these with v-if in some fifty places; rather than wrap each one, this watches the document:
//   - one that appears unfolds (height and spacing from nothing, with a fade),
//   - one that goes is put back for a moment as an inert copy that folds away.
// Nothing here touches Vue's own nodes: the copy is removed again when its animation ends. With reduced motion set,
// everything snaps as before.
const SELECTOR = [
  '.alert',
  '.kp-banner',
  '.k2-banner',
  '.k2-ops-error',
  '.pv-ops-error',
  '.k2-err',
  '.pv-strip',
  '.pv-fix-result',
  '.kp-done-toast',
  '.bench-zoomhint',
  '.k2-notice-pile', // the message and SOS banner piles, when the whole pile comes or goes
  '.invalid-feedback', // a field's error line
  'p.text-danger', // a form's error line
  'div.text-danger',
].join(',')
// A notice that arrives with its page or panel (one opened in the last moment) is already there when the page shows:
// it is not slid in, so opening a page does not replay every notice on it.
const SETTLE_MS = 900
const bornAt = new WeakMap()
let quietUntil = 0

// Called on every page change: notices drawn while the new page builds do not animate
export function hushNotifyMotion(ms = 1200) {
  quietUntil = performance.now() + ms
}

function arrivedWithPage(el, now) {
  if (now < quietUntil || el.closest('.is-gathering')) return true
  for (let node = el.parentElement; node && node !== document.body; node = node.parentElement) {
    const t = bornAt.get(node)
    if (t !== undefined && now - t < SETTLE_MS) return true
  }
  return false
}
const MS = 260
const EASE = 'cubic-bezier(.4,0,.2,1)'

const SIDES = ['marginTop', 'marginBottom', 'paddingTop', 'paddingBottom', 'borderTopWidth', 'borderBottomWidth']

function frames(el, from, to) {
  const cs = getComputedStyle(el)
  const full = { height: el.getBoundingClientRect().height + 'px', opacity: 1 }
  for (const side of SIDES) full[side] = cs[side]
  const none = { height: '0px', opacity: 0 }
  for (const side of SIDES) none[side] = '0px'
  return from === 'none' ? [none, full] : [full, none]
}

function reduced() {
  return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function appear(el) {
  if (reduced() || !el.animate || !el.isConnected) return
  const prev = el.style.overflow
  el.style.overflow = 'hidden'
  const animation = el.animate(frames(el, 'none'), { duration: MS, easing: EASE })
  animation.onfinish = animation.oncancel = () => {
    el.style.overflow = prev
  }
}

function leave(el, parent, next) {
  if (reduced() || !el.animate || !parent || !parent.isConnected) return
  const ghost = el.cloneNode(true)
  ghost.setAttribute('aria-hidden', 'true')
  ghost.setAttribute('inert', '')
  ghost.removeAttribute('data-testid') // a browser check must not find the copy
  ghost.querySelectorAll('[data-testid]').forEach((node) => node.removeAttribute('data-testid'))
  ghost.style.pointerEvents = 'none'
  ghost.style.overflow = 'hidden'
  ghost.dataset.leaving = '1'
  parent.insertBefore(ghost, next && next.parentNode === parent ? next : null)
  const animation = ghost.animate(frames(ghost, 'out'), { duration: MS, easing: EASE, fill: 'forwards' })
  animation.onfinish = animation.oncancel = () => ghost.remove()
}

export function installNotifyMotion() {
  if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return
  new MutationObserver((records) => {
    for (const record of records) {
      const now = performance.now()
      for (const node of record.addedNodes) {
        if (node.nodeType !== 1) continue
        bornAt.set(node, now)
        if (node.matches(SELECTOR) && !node.dataset.leaving && !arrivedWithPage(node, now)) appear(node)
      }
      for (const node of record.removedNodes) {
        if (node.nodeType === 1 && node.matches(SELECTOR) && !node.dataset.leaving) leave(node, record.target, record.nextSibling)
      }
    }
  }).observe(document.body, { childList: true, subtree: true })
}
