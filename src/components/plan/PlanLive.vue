<script setup>
// PlanLive — the strip that says which revision of the running plan this page is showing, and gets loud when a
// planner publishes a newer one somewhere else (step 15).
//
// WHY A REVISION IS NOT JUST A NUMBER ON A ROW. The plan board loads a plan once and then draws it; nothing about a
// frame edit tells another tab that the timetable everybody is following has changed. Publishing does, because
// plan_publish moves plans.rev and writes the same number onto the open session (051). This strip holds the revision
// the page is showing — the board's, since step 18 — and asks the session's timetable again whenever the session says
// its revision moved (realtime), every half minute, and when the tab is looked at again. When a fresh read answers a
// different revision, the page is out of date and says so — in words, with the two numbers, and a button that reloads.
//
// The read is the authority, not the push: `session.planRev` only tells this component to look again. A poll that
// fails says nothing (a flaky network must never claim a plan changed); a read that answers with no rows — a member
// whose group has no moments — falls back to the revision the session carries, so nobody is left without the
// warning. The screen that renders the rows themselves is step 16.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { formatTime } from '../../utils/time'

const props = defineProps({
  // The live session from useEventSessions: { id, planId, t0At, planRev } while it runs, else null.
  session: { type: Object, default: null },
  // The plan this page is showing.
  planId: { type: String, default: null },
  // That plan's revision as the board loaded it. When the board reloads, this moves and the strip follows it.
  planRev: { type: Number, default: null },
  // The board's usePlan instance, whose readTimetable() is the one read (051).
  api: { type: Object, required: true },
})

const emit = defineEmits(['reload'])

const POLL_MS = 30000

// Only while the page is showing the plan that is actually running: a planning tab looking at tomorrow's draft has
// nothing to be stale about.
const active = computed(
  () => !!(props.session && props.session.planId && props.planId && props.session.planId === props.planId),
)

const heldRev = ref(null) // the revision this page is showing
const freshRev = ref(null) // the revision the last read answered
const stale = ref(null) // { from, to } once a fresh read disagrees
const checking = ref(false)
let running = false // one read at a time: the poll and the push can arrive together
let timer = null

// The revision this page is showing -- the held one, not the fresh one: when the strip is warning, the chip and the
// sentence must agree about which version is on screen, and the warning is the place the newer number appears.
const shownRev = computed(() => heldRev.value ?? props.planRev ?? freshRev.value ?? null)
const t0Text = computed(() => (props.session && props.session.t0At ? formatTime(props.session.t0At) : ''))

function reset() {
  heldRev.value = null
  freshRev.value = null
  stale.value = null
}

/**
 * Ask the session's timetable which revision it is on. Everything is guarded so that a background poll cannot
 * interrupt itself, and a failed read cannot leave a "stale" claim on screen: an answer we do not have is not an
 * answer that says "changed".
 */
async function check() {
  if (!active.value || running) return
  running = true
  checking.value = true
  try {
    const rows = await props.api.readTimetable(props.session.id)
    const fromRead = rows && rows.length ? rows[0].plan_rev : null
    // No rows is not "no revision": a member sees only their own group, and a group with no moments in the plan is
    // a legitimate empty read. The session's own number is the same fact 051 writes, so it fills the gap.
    const rev = fromRead ?? (props.session ? props.session.planRev : null)
    if (rev == null) return
    freshRev.value = rev
    // What the page is showing is the board's revision, not the first number this strip happened to read. Since step
    // 17 a publish can hand the running session onto a copy, so a strip that adopted the session's revision as its
    // own would call a page that is still drawing revision 1 "version 2" and never warn about it.
    const held = heldRev.value ?? props.planRev
    if (held == null) {
      heldRev.value = rev
      return
    }
    heldRev.value = held
    stale.value = rev === held ? null : { from: held, to: rev }
  } catch {
    // A read that did not happen says nothing about the plan. The next poll, or the next publish, will ask again.
  } finally {
    running = false
    checking.value = false
  }
}

/** Reload the plan in place: the board re-reads the plan and its frames, and this strip adopts the new revision. */
function useFresh() {
  if (!stale.value) return
  // `planRev` is what the board's own reload writes; adopting it here means the strip clears as soon as the board
  // has the new plan, and stays warning if the reload failed.
  emit('reload')
}

// The board reloaded (it moved `plan.rev`): whatever is on screen is the revision the page now shows.
watch(
  () => props.planRev,
  (rev) => {
    if (rev == null) return
    heldRev.value = rev
    freshRev.value = rev
    stale.value = null
  },
)

// A different plan, or a session that started or ended: start over rather than compare two plans' numbers.
watch(active, (on) => {
  reset()
  if (on) check()
})

// The push: plan_publish moves the session's plan_rev in the same transaction, and useEventSessions already listens
// to event_sessions -- so another tab's publish is this tab's cue to re-read. This is a cue, not the answer.
watch(
  () => (props.session ? props.session.planRev : null),
  () => check(),
)

function onVisible() {
  if (!document.hidden) check()
}

onMounted(() => {
  document.addEventListener('visibilitychange', onVisible)
  window.addEventListener('focus', onVisible)
  if (active.value) check()
  timer = setInterval(() => {
    if (!document.hidden) check()
  }, POLL_MS)
})

onBeforeUnmount(() => {
  clearInterval(timer)
  document.removeEventListener('visibilitychange', onVisible)
  window.removeEventListener('focus', onVisible)
})
</script>

<template>
  <div v-if="active" class="pv-run" :class="{ 'is-stale': !!stale }" data-testid="plan-live">
    <div class="pv-run-line">
      <span class="pv-run-dot" aria-hidden="true"></span>
      <span>Live · plan version <strong data-testid="plan-live-rev">{{ shownRev ?? '…' }}</strong></span>
      <span
        v-if="t0Text"
        class="pv-run-clock"
        data-testid="plan-live-t0"
        :data-t0="session && session.t0At ? session.t0At.toISOString() : ''"
      >T+0 {{ t0Text }}</span>
    </div>

    <!-- The warning is the point of the strip: a version on screen with no consequence is a bumped column the
         client ignores. This names both numbers and what the page is showing, and offers the reload. -->
    <div v-if="stale" class="pv-run-warn">
      <span data-testid="plan-stale">
        This plan was published again while this page was open (version {{ stale.from }} → {{ stale.to }}).
        What is on screen is version {{ stale.from }}.
      </span>
      <button class="pv-btn is-primary" data-testid="plan-reload" :disabled="checking" @click="useFresh">
        Show version {{ stale.to }}
      </button>
    </div>
  </div>
</template>
