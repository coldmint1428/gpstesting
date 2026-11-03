// tooltips - hover hints in the site's own style instead of the browser's grey box.
//
// Any element with a `title` attribute would float the browser's own bubble, which looks like nothing else in the app
// (the "Trusted as drawn" hint on the timeline's Auto / Manual buttons, the icon buttons' names, and so on). This
// listens once for the whole page: while the pointer is over (or the keyboard is on) such an element, its title is
// held back so the browser shows nothing, and a small ink pill with the same words is drawn beside it instead.
// The title is put back when the pointer leaves, so assistive technology and the markup keep working as before.
//
// Nothing here decides what a hint says: that is still each element's `title`. Touch screens have no hover, so they
// get none, as before.

const SHOW_DELAY_MS = 350
const GAP = 8

let tip = null
let current = null // the element the pill is for
let held = '' // its title, kept while the pill shows
let timer = null

function pill() {
  if (tip) return tip
  tip = document.createElement('div')
  tip.className = 'k2-tip'
  tip.setAttribute('role', 'tooltip')
  tip.id = 'k2-tip'
  document.body.appendChild(tip)
  return tip
}

function place(el) {
  const t = pill()
  const r = el.getBoundingClientRect()
  const w = t.offsetWidth
  const h = t.offsetHeight
  const left = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), window.innerWidth - w - 8)
  const above = r.top - h - GAP >= 8
  t.style.left = left + 'px'
  t.style.top = (above ? r.top - h - GAP : r.bottom + GAP) + 'px'
  t.dataset.side = above ? 'top' : 'bottom'
}

function hide() {
  clearTimeout(timer)
  timer = null
  if (tip) tip.classList.remove('on')
  if (current) {
    if (held && !current.getAttribute('title')) current.setAttribute('title', held)
    current.removeAttribute('aria-describedby')
  }
  current = null
  held = ''
}

function show(el) {
  const text = el.getAttribute('title')
  if (!text || !text.trim()) return
  hide()
  current = el
  held = text
  el.removeAttribute('title') // the browser's own box must not appear too
  const t = pill()
  t.textContent = text
  el.setAttribute('aria-describedby', 'k2-tip')
  timer = setTimeout(() => {
    if (current !== el || !el.isConnected) return
    t.classList.add('on')
    place(el)
  }, SHOW_DELAY_MS)
}

function target(event) {
  const node = event.target
  return node instanceof Element ? node.closest('[title]') : null
}

export function installTooltips() {
  if (typeof window === 'undefined' || !window.matchMedia('(hover: hover)').matches) return
  document.addEventListener('mouseover', (e) => {
    const el = target(e)
    if (el && el !== current && el instanceof HTMLElement) show(el)
  })
  document.addEventListener('mouseout', (e) => {
    if (!current) return
    const to = e.relatedTarget
    if (!(to instanceof Node) || !current.contains(to)) hide()
  })
  document.addEventListener('focusin', (e) => {
    const el = target(e)
    if (el instanceof HTMLElement && el !== current) show(el)
  })
  document.addEventListener('focusout', hide)
  document.addEventListener('mousedown', hide, true)
  document.addEventListener('keydown', (e) => e.key === 'Escape' && hide(), true)
  window.addEventListener('scroll', hide, true)
  window.addEventListener('blur', hide)
}
