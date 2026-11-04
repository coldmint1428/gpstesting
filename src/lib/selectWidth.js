// Every dropdown keeps one width, whichever option is chosen. A styled dropdown (appearance: base-select) is as wide
// as the option it shows, so "Name A-Z" and "Smallest first" gave two box sizes and the row around it moved. Here a
// dropdown that sizes to its text gets the width of its longest option (never more than the room it is in). A
// dropdown whose width the page sets keeps that width; when its longest option does not fit, the text gets smaller
// (down to MIN_PX) rather than the box getting wider. Measured again when options change, the window resizes, the
// dropdown first shows (a phone-only filter, a sheet), or the fonts arrive.
const MIN_PX = 12

let ctx = null
function textWidth(text, font) {
  if (!ctx) ctx = document.createElement('canvas').getContext('2d')
  ctx.font = font
  return ctx.measureText(text).width
}
const fontOf = (cs, size) => cs.fontStyle + ' ' + cs.fontWeight + ' ' + size + 'px ' + cs.fontFamily
const single = (el) => el instanceof HTMLSelectElement && !el.multiple && !(el.size > 1)

// The width it may take at most: the content box of the nearest container wider than the dropdown itself (its own
// wrapper, or a flex item sized to it, would only give back the dropdown's width)
function roomAround(el) {
  const own = el.getBoundingClientRect().width
  for (let box = el.parentElement; box; box = box.parentElement) {
    const cs = getComputedStyle(box)
    if (cs.display === 'contents') continue
    const inner = box.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
    if (inner > own + 1) return inner
  }
  return Infinity
}

function fit(el) {
  if (!single(el) || !el.isConnected) return
  el.style.fontSize = ''
  const cs = getComputedStyle(el)
  if (cs.display === 'none' || !el.getBoundingClientRect().width) return
  const base = parseFloat(cs.fontSize)
  const font = fontOf(cs, base)
  const chrome = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight) + parseFloat(cs.borderLeftWidth) + parseFloat(cs.borderRightWidth)
  const widths = [...el.options].map((o) => textWidth(o.text.trim(), font))
  const widest = Math.max(0, ...widths)

  // Does its width follow the option it shows? Try its shortest and its longest option and see (no change event, so
  // nothing on the page notices). Asked once; a dropdown whose width the page sets is left at that width.
  if (!el.dataset.fitw && widths.length > 1) {
    const keep = el.selectedIndex
    const at = (i) => ((el.selectedIndex = i), el.getBoundingClientRect().width)
    const a = at(widths.indexOf(Math.min(...widths)))
    const b = at(widths.indexOf(widest))
    el.selectedIndex = keep
    el.dataset.fitw = Math.abs(a - b) > 1 ? 'content' : 'fixed'
  }
  // It does: one width for every option, its longest one's, as far as the room around it allows
  if (el.dataset.fitw === 'content') {
    el.style.minWidth = el.style.maxWidth = ''
    const cap = getComputedStyle(el).maxWidth // the page's own cap, in px ('none', or a share the room already covers)
    const pageMax = cap.endsWith('px') ? parseFloat(cap) : Infinity
    const w = Math.ceil(Math.min(widest + chrome + 1, roomAround(el), pageMax)) + 'px'
    el.style.minWidth = el.style.maxWidth = w
  }

  // The room it has for text; when the longest option is wider, every option is drawn smaller to fit it
  const room = el.getBoundingClientRect().width - chrome
  if (widest > room + 0.5 && room > 0) el.style.fontSize = Math.max(MIN_PX, Math.floor((base * room) / widest * 2) / 2) + 'px'
  el.dataset.fitAt = String(Math.round(el.getBoundingClientRect().width))
}

let queued = new Set()
let frame = 0
function schedule(el) {
  if (el) queued.add(el)
  else document.querySelectorAll('select').forEach((s) => queued.add(s))
  if (frame) return
  frame = requestAnimationFrame(() => {
    frame = 0
    const list = [...queued]
    queued = new Set()
    list.forEach(watchSize)
    list.forEach(fit)
  })
}

// A dropdown hidden at first (display: none) has no width to measure: fit it when it shows or its room changes
let sizes = null
const watched = new WeakSet()
function watchSize(el) {
  if (!sizes || watched.has(el)) return
  watched.add(el)
  sizes.observe(el)
}

export function installSelectWidth() {
  if (typeof window === 'undefined' || typeof MutationObserver === 'undefined') return
  if (typeof ResizeObserver !== 'undefined') {
    sizes = new ResizeObserver((entries) => {
      for (const e of entries) {
        const w = Math.round(e.target.getBoundingClientRect().width)
        if (String(w) !== e.target.dataset.fitAt) schedule(e.target)
      }
    })
  }
  new MutationObserver((records) => {
    for (const r of records) {
      const t = r.target.nodeType === 1 ? r.target : r.target.parentElement
      const owner = t && t.closest && t.closest('select')
      if (owner) schedule(owner)
      for (const n of r.addedNodes) {
        if (n.nodeType !== 1) continue
        if (n.tagName === 'SELECT') schedule(n)
        else if (n.querySelector) n.querySelectorAll('select').forEach((s) => schedule(s))
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true })
  window.addEventListener('resize', () => schedule())
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => schedule())
  schedule()
}
