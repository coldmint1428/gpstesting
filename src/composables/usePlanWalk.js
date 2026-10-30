// usePlanWalk — the read behind any screen that draws the plan's walk: `session_timetable` (065), polled, woken at the
// next planned moment, and guarded so a poll can never interrupt itself or outlive the session it asked about.
//
// WHY A COMPOSABLE AND NOT TWO COPIES. Two screens draw the same rows (the follower's map, step 29, and the live map
// under the people, step 30) and one of them is `v-show`n rather than mounted (EventView keeps the Live page alive for
// its map). The guards in here are exactly the kind that go subtly wrong when copied: an overlapping ask is deferred
// rather than dropped, a failed read keeps what is on screen, an answer about a session (or an end time) the screen has
// moved past is thrown away and asked again, and a page nobody is looking at does not ask at all. A second copy is a
// second set of those rules to drift apart, so the read lives here and both screens ask it.
//
// `enabled` is how a screen that is mounted but not on show keeps quiet: the Live page is `v-show`n, so a panel on it
// runs on every page, and a read from it would otherwise poll behind whatever the person is actually looking at
// (finding 72's trap). Turning it on reads straight away; turning it off stops the polling without throwing away the
// rows it already has, so coming back is a line that is still there until the fresh answer lands.
//
// WHO SEES WHOSE ROWS. The engine: 040's scope inside `session_status` (052). Nothing here filters, and nothing here
// should start.
//
// WHICH SESSION A SCREEN HANDS IT is the screen's decision, not this file's: the follower's map hands it the session it
// is drawing (live, or the last one that ended); the live map hands it the live session only, because a walk on the
// Live page is a walk somebody is on now.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { planErrorMessage } from './usePlan'

const POLL_MS = 30000 // the floor, not the point: the wake at each moment is what keeps a screen honest
const WAKE_MAX_MS = 120000 // a moment further out than this is left to the poll

export function usePlanWalk({ session, enabled = () => true, pollMs = POLL_MS, wakeMaxMs = WAKE_MAX_MS }) {
  const readSession = typeof session === 'function' ? session : () => (session ? session.value : null)

  const rows = ref([]) // the read, exactly as it answered
  const loaded = ref(false) // one answer has arrived (an empty read is still an answer)
  const errorMsg = ref('')
  const readAt = ref(null)

  let running = false
  let again = false // something moved while the read was in flight: ask once more
  let wakeTimer = null
  let pollTimer = null

  const sessionId = computed(() => {
    const s = readSession()
    return s ? s.id : null
  })
  // The instant the read speaks about: a closed session is read at its own end, so its picture is the one it closed on.
  const endedAt = computed(() => {
    const s = readSession()
    return s && s.endedAt ? s.endedAt : null
  })
  const planId = computed(() => {
    const s = readSession()
    return s && s.planId ? s.planId : null
  })
  const planRev = computed(() => {
    const s = readSession()
    return s ? s.planRev : null
  })
  const isEnabled = computed(() => !!enabled())

  /**
   * Read the timetable, then schedule the next ask. Deferred while a read is in flight (never overlapping), kept whole
   * on a failure, and thrown away if it belongs to a session this screen has already moved past.
   */
  async function read() {
    if (!isEnabled.value) return
    const id = sessionId.value
    if (!id) {
      // Nothing to ask. `loaded` is what tells a screen that waiting is over, so an event that was never started gets
      // its sentence rather than a spinner that never resolves.
      loaded.value = true
      return
    }
    // A session that runs no plan has no timetable to ask for: asking anyway earns the engine's "not running a plan"
    // as a console error on a page that had already decided there was nothing to show.
    if (!planId.value) {
      rows.value = []
      errorMsg.value = ''
      loaded.value = true
      return
    }
    if (running) {
      again = true
      return
    }
    running = true
    const at = endedAt.value
    try {
      const args = { p_session: id }
      if (at) args.p_at = at.toISOString()
      const { data, error } = await supabase.rpc('session_timetable', args)
      if (error) throw error
      if (sessionId.value !== id || endedAt.value !== at) {
        again = true
        return
      }
      rows.value = data || []
      errorMsg.value = ''
      readAt.value = new Date()
    } catch (error) {
      if (sessionId.value === id && endedAt.value === at) {
        errorMsg.value = planErrorMessage(error) || 'Could not read the walk.'
      }
    } finally {
      running = false
      loaded.value = true
      if (again) {
        again = false
        read()
        return
      }
      planWake()
    }
  }

  /** Wake at the soonest planned moment still ahead, so a screen's "next" becomes "now" at the second it does. */
  function planWake() {
    clearTimeout(wakeTimer)
    wakeTimer = null
    if (endedAt.value || !rows.value.length) return
    const at = Date.now()
    let soonest = null
    for (const row of rows.value) {
      if (!row.planned_at) continue
      const t = new Date(row.planned_at).getTime()
      if (t > at && (soonest == null || t < soonest)) soonest = t
    }
    if (soonest == null || soonest - at > wakeMaxMs) return
    wakeTimer = setTimeout(() => read(), soonest - at + 300)
  }

  function onLook() {
    if (document.hidden) return
    read()
  }

  onMounted(() => {
    read()
    pollTimer = setInterval(() => {
      if (!document.hidden) read()
    }, pollMs)
    document.addEventListener('visibilitychange', onLook)
    window.addEventListener('focus', onLook)
  })

  onBeforeUnmount(() => {
    clearTimeout(wakeTimer)
    clearInterval(pollTimer)
    document.removeEventListener('visibilitychange', onLook)
    window.removeEventListener('focus', onLook)
  })

  // Everything the answer is ABOUT in one string: the session, the plan it runs, the revision it follows, and the end
  // time it speaks about. One watcher, not four, because a new session arrives with a new plan and a new revision at
  // the same moment -- four watchers would ask four times for the same rows.
  const walkKey = computed(() =>
    [sessionId.value || '', planId.value || '', planRev.value == null ? '' : planRev.value,
      endedAt.value ? endedAt.value.getTime() : ''].join('|'),
  )

  // A different session is a different walk: start again rather than read the new one over the old rows.
  watch(walkKey, (nowKey, wasKey) => {
    const sameSession = wasKey !== undefined && nowKey.split('|')[0] === wasKey.split('|')[0]
    if (!sameSession) {
      rows.value = []
      loaded.value = false
      errorMsg.value = ''
    }
    read()
  })
  // Coming back onto a page: read at once rather than wait for the poll that was not running.
  watch(isEnabled, (on) => {
    if (on) read()
  })

  return { rows, loaded, errorMsg, readAt, read }
}
