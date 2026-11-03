// segSlide - the lit pill of a segmented control (.seg / .k2-mini / .k2-opsfilter buttons, .kp-seg radios) and the
// underline of a tab row (.k2-tabs) slide to the chosen one instead of
// jumping. It adds nothing to the markup, so Vue's own rendering is untouched: the pill is the container's ::before, and
// this only tells it where the chosen item is (--seg-x/-y/-w/-h on the container). The CSS is at the end of kinetic-2.css.
const CONTAINERS = '.seg, .kp-seg, .k2-mini, .k2-opsfilter, .k2-tabs'
const CHOSEN = '[aria-pressed="true"], [aria-selected="true"], input:checked + label'

// A control that changes size (the side menu folding, a window resize, the row wrapping) moves its items without any
// attribute changing, so each one is watched and its pill placed again.
const watched = typeof ResizeObserver !== 'undefined' ? new ResizeObserver((entries) => entries.forEach((e) => place(e.target))) : null
const seen = new WeakSet()

function place(box) {
  if (watched && !seen.has(box)) {
    seen.add(box)
    watched.observe(box)
  }
  const item = box.querySelector(CHOSEN)
  if (!item || !item.offsetWidth) {
    box.removeAttribute('data-slide')
    return
  }
  box.style.setProperty('--seg-x', item.offsetLeft + 'px')
  box.style.setProperty('--seg-y', item.offsetTop + 'px')
  box.style.setProperty('--seg-w', item.offsetWidth + 'px')
  box.style.setProperty('--seg-h', item.offsetHeight + 'px')
  if (box.getAttribute('data-slide') === 'on') return
  // The first time, put the pill there without sliding in from nowhere; the slide starts from the next change
  box.setAttribute('data-slide', 'set')
  requestAnimationFrame(() => requestAnimationFrame(() => box.setAttribute('data-slide', 'on')))
}

export function installSegSlide() {
  if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return
  let queued = false
  const refresh = () => {
    if (queued) return
    queued = true
    requestAnimationFrame(() => {
      queued = false
      document.querySelectorAll(CONTAINERS).forEach(place)
    })
  }
  new MutationObserver(refresh).observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['aria-pressed', 'aria-selected', 'class'],
  })
  document.addEventListener('change', refresh, true) // a radio's checked state is not an attribute
  window.addEventListener('resize', refresh)
  document.addEventListener('transitionend', refresh, true) // the side menu folds over a transition
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(refresh)
  refresh()
}
