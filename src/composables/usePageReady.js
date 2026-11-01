// usePageReady - one loading skeleton for a whole page, until every part of it has its data.
//
// A page is built from panels that each fetch their own data, so without this they appear one at a time: the header,
// then the status card, then the plan, then the zones. With it, the page is built out of sight behind its skeleton,
// every panel says when its first answer is in, and the page fades in once, complete.
//
//   Page:   const page = providePageReady()          page.ready is true once everything is in
//           page.watch(() => !sessionsLoaded.value)  the page's own data holds it too
//           page.arm()                               once the page's main data is in and its panels are mounted
//   Panel:  useLoadGate(() => !loaded.value)         holds the page while that is true
//
// Only the first load is held: once the page is shown, a panel that loads again (a tab opened later, a refresh)
// shows its own skeleton as before. If something never answers, the page is shown anyway after `maxWaitMs`, so a
// slow or failing panel can never leave the whole page grey.
import { ref, reactive, provide, inject, watch, nextTick, onBeforeUnmount, getCurrentInstance } from 'vue'

const KEY = Symbol('page-ready')

export function providePageReady({ maxWaitMs = 6000, quietMs = 80 } = {}) {
  const ready = ref(false)
  const pending = reactive(new Set())
  let armed = false
  let quietTimer = null
  let maxTimer = null

  function reveal() {
    if (ready.value) return
    ready.value = true
    clearTimeout(quietTimer)
    clearTimeout(maxTimer)
    pending.clear()
  }
  // A panel often starts its fetch only after another has answered (the schedule waits for the session), so the page
  // waits for a short quiet moment with nothing loading before it decides everything is in.
  function check() {
    clearTimeout(quietTimer)
    if (!armed || ready.value || pending.size) return
    quietTimer = setTimeout(() => {
      if (!pending.size) reveal()
    }, quietMs)
  }

  const api = {
    ready,
    hold(id) {
      if (ready.value) return
      pending.add(id)
      clearTimeout(quietTimer)
    },
    release(id) {
      pending.delete(id)
      check()
    },
    /** Hold the page while `isLoading()` is true (for data the page itself loads). */
    watch(isLoading) {
      gateOn(api, isLoading)
    },
    /** Called by the page once its own data is in and its panels have been mounted (out of sight). */
    arm() {
      if (armed) return
      armed = true
      maxTimer = setTimeout(reveal, maxWaitMs)
      nextTick(check)
    },
  }
  provide(KEY, api)
  onBeforeUnmount(() => {
    clearTimeout(quietTimer)
    clearTimeout(maxTimer)
  })
  return api
}

let ids = 0
function gateOn(gate, isLoading) {
  const id = ++ids
  // 'sync': a panel that starts loading as it mounts must hold the page before the page checks, not a tick later
  watch(isLoading, (loading) => (loading ? gate.hold(id) : gate.release(id)), { immediate: true, flush: 'sync' })
  onBeforeUnmount(() => gate.release(id))
}

/** Hold the page's skeleton while `isLoading()` is true. Does nothing on a page without providePageReady(). */
export function useLoadGate(isLoading) {
  const gate = inject(KEY, null)
  if (!gate || !getCurrentInstance()) return
  gateOn(gate, isLoading)
}
