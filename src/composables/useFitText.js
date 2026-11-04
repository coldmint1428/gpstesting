// useFitText: a heading at the largest font size that fits the room it is given.
//
// It tries one line first, from `max` down to `oneLineMin`. A name that still does not fit may take a second line
// (`lines: 2`, the class `is-2l` turns wrapping on), from `oneLineMin` down to `min`. Only a name that does not fit even
// then is cut with "…". So a short name is shown big, a long one smaller or on two lines, and nothing is cut that could
// have been read. It measures again when the room changes (the window, the buttons beside it) and when the text does.
// The element may appear late (a page that renders its heading once its data arrives), so it attaches whenever the
// ref is set.
import { onBeforeUnmount, watch, nextTick } from 'vue'

const value = (v) => (typeof v === 'function' ? v() : v)

export function useFitText(elRef, { min = 12, oneLineMin = min, max = 18, lines = 1, step = 0.5, text = () => '' } = {}) {
  let observer = null
  let frame = 0

  function fit() {
    const el = elRef.value
    if (!el || !el.isConnected) return
    const top = value(max)
    const floor1 = value(oneLineMin)
    const floor = value(min)
    const set = (px) => (el.style.fontSize = px + 'px')
    const wide = () => el.scrollWidth > el.clientWidth + 0.5
    const tall = () => el.scrollHeight > el.clientHeight + 1

    el.classList.remove('is-2l')
    let size = top
    set(size)
    while (size > floor1 && wide()) set((size = Math.max(floor1, size - step)))
    if (!wide() || value(lines) < 2) {
      while (size > floor && wide()) set((size = Math.max(floor, size - step)))
      return
    }
    el.classList.add('is-2l')
    while (size > floor && tall()) set((size = Math.max(floor, size - step)))
  }

  function schedule() {
    cancelAnimationFrame(frame)
    frame = requestAnimationFrame(fit)
  }

  watch(
    elRef,
    (el) => {
      if (observer) observer.disconnect()
      observer = null
      if (!el) return
      if (typeof ResizeObserver !== 'undefined') {
        observer = new ResizeObserver(schedule)
        // The room is decided by the row the heading sits in, not by the heading itself
        let box = el.parentElement
        for (let i = 0; box && i < 3; i++, box = box.parentElement) observer.observe(box)
      }
      // A size measured in the fallback font is wrong once the real font arrives
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(schedule)
      schedule()
    },
    { flush: 'post', immediate: true },
  )
  watch(text, () => nextTick(schedule))
  if (typeof window !== 'undefined') window.addEventListener('resize', schedule)
  if (typeof document !== 'undefined' && document.fonts && document.fonts.addEventListener) document.fonts.addEventListener('loadingdone', schedule)
  onBeforeUnmount(() => {
    cancelAnimationFrame(frame)
    if (observer) observer.disconnect()
    if (typeof window !== 'undefined') window.removeEventListener('resize', schedule)
    if (typeof document !== 'undefined' && document.fonts && document.fonts.removeEventListener) document.fonts.removeEventListener('loadingdone', schedule)
  })
  return { fit: schedule }
}
