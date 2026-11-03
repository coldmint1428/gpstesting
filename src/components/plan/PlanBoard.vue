<script setup>
// PlanBoard — the planning stage, as an animation timeline over a locked map.
//
// The mental model, in one line: a plan is a strip of frames; at each frame you say where every group is;
// a straight line joins neighbouring frames, and no two neighbouring positions for one group may be more
// than 25 m apart. Nothing here draws a route, and nothing here edits a polygon.
//
// The map and the bar are two views of the same selection. Selecting a frame on the bar decides which moment
// the map is showing; dragging a marker on the map writes that moment's position for that group -- and for every
// ticked group standing there, which all travel together and are written once.
//
// THE SELECTION MODEL lives here rather than in either view, because later steps need the same two sets:
//   selection       the frames selected on the bar. It is always a contiguous stretch of time — click picks one,
//                   Shift+click extends from the open frame, dragging across the bar picks the run it touches —
//                   and that is what lets the whole stretch be named by two times when it is pushed (frame_shift,
//                   044) without the client and the server disagreeing about what "selected" means. A set of ids
//                   is still the shape, because a selection is a set of frames and not a pair of numbers.
//   selectedGroups  the groups ticked in the inspector. Any subset: a planner works on some groups at a time, and
//                   the rest step back on the map. Step 7's Hold writes exactly these groups (or everyone standing
//                   at the open frame when nothing is ticked); step 8 drags every ticked group that stands at the
//                   open frame together, in one save; step 10 verifies them.
// The open frame (selectedId) is still exactly one: the map shows one moment at a time, and that frame is what the
// inspector and Ctrl+C act on. It is always one of the selected frames.
//
// EVERY WRITE LEAVES A WAY BACK (step 13). Each edit the board makes is recorded as an inverse command the moment it
// lands -- see usePlanUndo, which owns the stack, the Ctrl+Z / Ctrl+Y keys' work, and the rule that an inverse is a
// fresh write under the same revision rules as any other. The board only has to say what it just did, in words a
// planner would recognise ("moved Gate Crew at +1:00"), because that sentence is what the undo toast repeats back.
//
// THE RUNNING PLAN'S REVISION (step 15) is not the board's business. PlanLive reads the session's timetable (051) and
// says which revision this page is showing; when a fresh read answers a newer one -- another tab published while
// this page was open -- it says so and offers the catch-up, which is `reloadPlan` below: re-read the plan and its
// frames, keep the open frame, and start the undo stack again, because the plan people are following is no longer
// the one this tab's inverses were built against.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import L from 'leaflet'
import { zoneCaption } from '../../utils/areaKinds'
import { useOpenMenu } from '../../composables/useOpenMenu'
import { venueBounds } from '../../utils/venueFrame'
import 'leaflet/dist/leaflet.css'
import { createOneMapLayer } from '../../utils/onemap'
import { isLockRefusal, planErrorMessage, usePlan } from '../../composables/usePlan'
import { usePlanUndo } from '../../composables/usePlanUndo'
import PlanLive from './PlanLive.vue'
import PlanProblems from './PlanProblems.vue'
import { calmCase, editAllowed, extraSeconds, problemWords, problemsOf, suggestedSpot, walkFixPlan, walkFixWords } from '../../utils/planProblems'
import { placeName } from '../../composables/useReverseGeocode'
import EmptyState from '../EmptyState.vue'
import { askConfirm, askNotice, toast } from '../../composables/useNotify'
import { saveFile } from '../../lib/saveFile'
import { escapeHtml } from '../../utils/people'
import { formatDuration } from '../../utils/time'
import {
  SNAP_S,
  annotate,
  formatOffset,
  formatOffsetShort,
  gapDetail,
  parseOffset,
  resolveTracks,
  restatedPositions,
  snap,
  snapshotAt,
} from '../../utils/planFrames'
import { readSheet, sheetFileName, sheetGaps, sheetText } from '../../utils/planSheet'
import '../../assets/planova.css'
import { GROUP_PALETTE } from '../../utils/groupColours'
import { useLoadGate } from '../../composables/usePageReady'

const props = defineProps({
  eventId: { type: String, required: true },
  canEdit: { type: Boolean, default: false },
  // Set for a member, an IC or a group admin: they see one group, never the event (040). 'none' means they are
  // in no group yet. Null for ops staff (root, planner), who see every group.
  onlyGroupId: { type: String, default: null },
  // The event's live session (useEventSessions), when there is one: the board says which revision of the running
  // plan it is showing, and warns when another tab publishes a newer one (step 15).
  liveSession: { type: Object, default: null },
  // Seam for the development harness (dev/preview.js), which renders the board against fixtures instead of a
  // session. In the app this is always absent and the board uses the real composable.
  api: { type: Object, default: null },
})

// A group's own colour (the one the live map uses), so the board and the map tell the same story; the palette only
// fills in for a group that has none
const GROUP_COLORS = GROUP_PALETTE

const api = props.api || usePlan(props.eventId)
const { plans, plan, frames, groups, zones, loading, busy, errorMsg, livePlan } = api
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
// (the groups, zones and plans read at mount, then the first plan opened: `boardReady` below)
const boardReady = ref(false)
useLoadGate(() => !boardReady.value)
const edits = usePlanUndo({
  plan,
  frames,
  api,
  // A refused undo is the strip's business, like a refused drag: nothing moved, and the sentence says who has the
  // badge. The stack is untouched, so the key works again once the badge is free.
  onRefused: (label, error) => sayRefusal(`${label}: ${trimStop(planErrorMessage(error))}.`),
})
const { canUndo, canRedo } = edits

const mapEl = ref(null)
const trackEl = ref(null)
const selectedId = ref(null)                  // the open frame: the one moment the map is showing
const selection = ref(new Set())              // the frames selected on the bar
const selectedGroups = ref(new Set())         // the groups ticked in the inspector
const pxPerSecond = ref(1.1)
const dragState = ref(null)                   // { delta, from_s, to_s } while a stretch is being dragged
const sweep = ref(null)                       // { x0, x1 } while a stretch is being swept out on the bar
const clipboard = ref(null)
const newPlanName = ref('')
const creating = ref(false)
// The hidden <input type=file> behind the sheet buttons (step 23). A ref rather than a query: the button and the
// picker are one control, and the ref is what lets the button open it.
const sheetFile = ref(null)

// ---------- the run (step 22) ----------
// A play of the plan on the strip: the clock from T+0 moving at a chosen rate while the map shows where each group is
// on its walk at that instant. It is a mode of this board rather than a second screen -- the strip, the map and the
// groups are already here, and the artefact's Playback tab is this same picture with the clock running.
const playhead = ref(null) // seconds from T+0 while a run is on the strip, or null
const playing = ref(false)
const speed = ref(60) // 1x, 10x or 60x: a thirty-minute plan at 60x is half a minute
const PLAY_SPEEDS = [1, 10, 60]
let playRaf = null
let playLast = 0
let playDrawnAt = 0
// The cursor is being dragged along the ruler by hand: the map follows the finger, and nothing plays (QA 1 Nov).
const scrubbing = ref(false)

// The group waiting for a tap on the map to say where it stands at the open frame (QA 1 Nov: a plan drawn by hand
// had no way to put a group on the map at all -- a badge could be dragged only once it had a position).
const placing = ref(null)
// Lock: no dragging frames along the time bar or badges on the map, so a slip of the finger cannot move anything.
// Buttons (Add frame, flags, placing a group) still work. Remembered on this device.
const LOCK_KEY = 'planova.planLock'
const moveLock = ref(readLock())
function readLock() {
  try {
    return localStorage.getItem(LOCK_KEY) === '1'
  } catch {
    return false
  }
}
function toggleLock() {
  moveLock.value = !moveLock.value
  try {
    localStorage.setItem(LOCK_KEY, moveLock.value ? '1' : '0')
  } catch {
    /* private mode: the lock still works until the page closes */
  }
  drawMarkers()
}
const canMove = computed(() => props.canEdit && !moveLock.value)

const selected = computed(() => frames.value.find((f) => f.id === selectedId.value) || null)
const tracks = computed(() => resolveTracks(frames.value))
const analysis = computed(() => annotate(frames.value))

/**
 * The offset a copy was taken at (053), or null for a plan that was drawn rather than copied from a running one.
 * It is the copy's first frame and the last instant nothing may be written at or before, so the board marks the
 * frame and says what it is: the walk before it is not on this plan at all.
 */
const cutS = computed(() => (plan.value && plan.value.fork_cut_s != null ? plan.value.fork_cut_s : null))
function isCutFrame(frame) {
  return cutS.value != null && !!frame && frame.t_s === cutS.value
}

/**
 * What the database will refuse the plan for that the board's own walk does not already say. `annotate` is the 25 m
 * rule, derived here so a drag goes red before anything is written; plan_check is the second opinion, and the only
 * one that looks at the locked polygons and at pace. Its rows are fetched after every frame read -- a write is
 * followed by a read -- so a walk that clips a no-go, or a hop that asks for a speed nobody can run, is marked on the
 * board instead of waiting for Publish to refuse it. A row naming the same pair as a local gap is that same problem
 * said twice, so it is left to the gap row, which already carries the Fill button that fixes it.
 */
const serverProblems = ref([])
const blocking = computed(() => {
  // The pair is the pair on both sides now (step 12): the board reports a walk from the frame that last said where a
  // group was, and so does plan_check. A row naming a pair the walk already reports is that same problem said twice,
  // so it is left to the gap row, which carries the Fill button that fixes it. (Before step 12 the board reported
  // from a carried frame and the database from the stated one -- finding 24 -- so this matched on the end alone.)
  const told = new Set(analysis.value.gaps.map((g) => `${g.groupId}|${g.from.frameId}|${g.to.frameId}`))
  return (serverProblems.value || []).filter(
    (row) =>
      row.severity === 'error' &&
      !String(row.message || '').includes('faster than running') &&
      !told.has(`${row.group_id}|${row.from_frame}|${row.to_frame}`),
  )
})

// ---------- the Problems panel, and the lock it explains ----------
// Errors lock the plan: only the frames and groups they name can change, until they are fixed. Warnings do not; they
// can be dismissed, on this browser, and come back if the walk changes (planProblems).
const problems = computed(() => problemsOf(analysis.value.gaps, serverProblems.value || []))
const errors = computed(() => problems.value.filter((p) => p.level === 'error'))
const dismissedIds = ref(new Set())
const shownProblemId = ref('')
const problemsPanel = ref(null)
const placeNames = ref({}) // "lat,lng" -> a place's name, as OneMap answers it
const walkFix = ref(null) // the fix on show, worked out and not yet written
const walkFixResult = ref(null) // what the last fix really did
let applyingFix = false

const dismissKey = () => 'planova.dismissed.' + (plan.value ? plan.value.id : '')
function readDismissed() {
  try {
    dismissedIds.value = new Set(JSON.parse(localStorage.getItem(dismissKey()) || '[]'))
  } catch {
    dismissedIds.value = new Set()
  }
}
function setDismissed(problem, on) {
  const next = new Set(dismissedIds.value)
  if (on) next.add(problem.id)
  else next.delete(problem.id)
  if (on && shownProblemId.value === problem.id) shownProblemId.value = ''
  dismissedIds.value = next
  try {
    localStorage.setItem(dismissKey(), JSON.stringify([...next]))
  } catch {
    // A browser that will not store it still dismisses it until the page is reloaded
  }
  drawLines()
}
const openWarnings = computed(() => problems.value.filter((p) => p.level === 'warning' && !dismissedIds.value.has(p.id)))

function problemPoint(groupId, frameId) {
  const track = tracks.value.get(groupId)
  return (track && track.find((p) => p.frameId === frameId)) || null
}
function pointText(point) {
  if (!point) return ''
  const name = point.place || placeNames.value[point.lat + ',' + point.lng]
  return name ? calmCase(name) : point.lat.toFixed(5) + ', ' + point.lng.toFixed(5)
}
// The names, for the problems on screen: placeName caches them, and the coordinates stand in until one answers
watch(problems, (list) => {
  for (const problem of list.slice(0, 40)) {
    for (const frameId of [problem.fromFrame, problem.toFrame]) {
      const point = problemPoint(problem.groupId, frameId)
      if (!point || point.place) continue
      const key = point.lat + ',' + point.lng
      if (key in placeNames.value) continue
      placeNames.value = { ...placeNames.value, [key]: '' }
      placeName(point.lat, point.lng).then((name) => {
        if (name) placeNames.value = { ...placeNames.value, [key]: name }
      })
    }
  }
})

function problemActions(problem) {
  const seconds = problem.toS - problem.fromS
  // Two rules, two fixes: frames for the 25 m limit, time for speed (planProblems)
  if (problem.kind === 'far') return [{ key: 'walk', label: 'Fill', testid: 'gap-fill' }]
  if (problem.kind === 'pace') return [{ key: 'walk', label: 'Add time', testid: 'problem-time' }]
  if (problem.kind === 'zone' && seconds >= 2) return [{ key: 'between', label: 'Add frame between', testid: 'problem-between' }]
  if (problem.kind === 'zone') return [{ key: 'time', seconds: 10, label: 'Add 10 s', testid: 'problem-time' }]
  return []
}
const frameNumber = (frameId) => frameOrder.value.findIndex((f) => f.id === frameId) + 1
const problemCards = computed(() =>
  problems.value.map((problem) => {
    const from = pointText(problemPoint(problem.groupId, problem.fromFrame))
    const to = pointText(problemPoint(problem.groupId, problem.toFrame))
    return {
      ...problem,
      ...problemWords(problem, groupName(problem.groupId)),
      dismissed: dismissedIds.value.has(problem.id),
      actions: problemActions(problem),
      when: `${formatOffset(problem.fromS)} → ${formatOffset(problem.toS)}`,
      // Which dots, when, and where: one place when both ends read the same
      meta: [
        `Frames ${frameNumber(problem.fromFrame)} → ${frameNumber(problem.toFrame)}`,
        `${formatOffset(problem.fromS)} → ${formatOffset(problem.toS)}`,
        from === to ? from : `${from} → ${to}`,
      ].filter(Boolean).join('  ·  '),
    }
  }),
)
const problemBadge = computed(() => {
  const parts = []
  const n = errors.value.length
  if (n) parts.push(n + (n === 1 ? ' error' : ' errors'))
  const w = openWarnings.value.length
  if (w) parts.push(w + (w === 1 ? ' warning' : ' warnings'))
  return parts.join(' · ')
})

/** Bring the panel into view, wherever the inspector has scrolled to. */
function revealProblems() {
  nextTick(() => {
    const panel = problemsPanel.value && problemsPanel.value.$el
    if (panel && panel.scrollIntoView) panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  })
}

/** True when the errors forbid this edit, having said so. No moment named: an edit that adds to the plan. */
function blockedByErrors(moments = null, groupIds = []) {
  if (!props.canEdit || !errors.value.length) return false
  if (moments && moments.every((t_s) => editAllowed(errors.value, t_s, groupIds))) return false
  const n = errors.value.length
  toast(`Fix the ${n === 1 ? 'error' : n + ' errors'} first. You can only change what ${n === 1 ? 'it names' : 'they name'} until then.`, 'warning', 5000)
  revealProblems()
  return true
}
function canEditCell(frame, groupId) {
  return !errors.value.length || editAllowed(errors.value, frame.t_s, [groupId])
}
const frameLocked = computed(() => !!selected.value && !editAllowed(errors.value, selected.value.t_s))

/** The problem somebody last asked to see, and where the suggestion says to send its group. */
const shownProblem = computed(() => problems.value.find((p) => p.id === shownProblemId.value) || null)
function spotOf(problem) {
  return suggestedSpot(problem, problemPoint(problem.groupId, problem.fromFrame), problemPoint(problem.groupId, problem.toFrame), zones.value)
}
/** Which end of the shown problem a dot on the bar is, in words: "From · Frame 116". */
function problemNodeTag(frame) {
  const problem = shownProblem.value
  if (!problem) return ''
  if (frame.id === problem.fromFrame) return 'From · Frame ' + frameNumber(frame.id)
  if (frame.id === problem.toFrame) return 'To · Frame ' + frameNumber(frame.id)
  return ''
}

/** Mark the problem, and open the frame it ends on: the one whose badge moves. */
function openProblem(problem) {
  const frame = frames.value.find((f) => f.id === problem.toFrame) || frames.value.find((f) => f.id === problem.fromFrame)
  if (!frame) return false
  selectOnly(frame.id)
  selectedId.value = frame.id
  shownProblemId.value = problem.id
  return true
}

/** "Show on map": frame the walk with the walk and the suggestion marked. */
function showProblemOnMap(problem) {
  if (!openProblem(problem)) return
  drawLines()
  const a = problemPoint(problem.groupId, problem.fromFrame)
  const b = problemPoint(problem.groupId, problem.toFrame)
  if (!map || !a || !b) return
  const bounds = L.latLngBounds([a.lat, a.lng], [b.lat, b.lng])
  const spot = spotOf(problem)
  if (spot) bounds.extend([spot.lat, spot.lng])
  map.fitBounds(bounds.pad(0.6), { maxZoom: 19 })
  // The panel sits under the bar, so the map may have scrolled away by the time a card is pressed
  if (mapEl.value) mapEl.value.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
}

// Close enough apart to tell the two ends of a walk from each other: a dot is 16 px across
const NODE_SPACING_PX = 34

/** "Show on timeline": zoom in until the walk's two dots stand apart, and bring them to the middle of the bar. */
async function showProblemOnTimeline(problem) {
  if (!openProblem(problem)) return
  drawLines()
  const seconds = Math.max(problem.toS - problem.fromS, 1)
  pxPerSecond.value = Math.min(MAX_PX_PER_SECOND, Math.max(pxPerSecond.value, NODE_SPACING_PX / seconds))
  await nextTick()
  const track = trackEl.value
  if (!track) return
  track.scrollLeft = xOf((problem.fromS + problem.toS) / 2) - track.clientWidth / 2
  track.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
}

/** Open a frame between the two ends, or make one, so the group can be dragged around what is in the way. */
async function addFrameBetween(problem) {
  const between = frameOrder.value.filter((f) => f.t_s > problem.fromS && f.t_s < problem.toS)
  const name = groupName(problem.groupId)
  if (between.length) {
    revealFrame(between[Math.floor(between.length / 2)].id)
    toast(`Drag ${name} around the area at this frame.`, 'success', 5000)
    return
  }
  const t = problem.fromS + Math.floor((problem.toS - problem.fromS) / 2)
  try {
    await api.saveFrame({ t_s: t, positions: effectiveAt(t) })
    await nextTick()
    const created = frames.value.find((f) => f.t_s === t)
    if (created) {
      revealFrame(created.id)
      edits.created(frameCopy(created), `added a frame at ${formatOffset(t)}`)
      toast(`Frame added. Drag ${name} around the area.`, 'success', 5000)
    }
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

/** Give a walk more time: its end and everything after it move later together. */
function addTimeTo(problem, seconds) {
  const last = Math.max(...frames.value.map((f) => f.t_s))
  return shiftStretch(problem.toS, seconds, last)
}

/**
 * Fill or Add time, step one: work out what it would do, say so, and draw it. Nothing is written until Apply.
 */
function startWalkFix(problem) {
  if (problem.level === 'warning' && blockedByErrors()) return
  const open = problems.value.filter((p) => !dismissedIds.value.has(p.id) || p.id === problem.id)
  const fix = walkFixPlan(problem, open, tracks.value.get(problem.groupId) || [], zones.value)
  walkFixResult.value = null
  walkFix.value = {
    ...fix,
    words: fix.blocked ? null : walkFixWords(fix, groupName(problem.groupId), frameNumber),
  }
  openProblem(problem)
  drawLines()
  if (map && fix.route.length > 1) map.fitBounds(L.latLngBounds(fix.route.map((p) => [p.lat, p.lng])).pad(0.4), { maxZoom: 19 })
}

function cancelWalkFix() {
  walkFix.value = null
  drawLines()
}

/**
 * Step two: write it, as one edit. Any time first, latest first, so a walk's times still mean what they said when its
 * turn comes, and so each fill has the seconds it needs. Afterwards the plan is read again, and the result says what is really
 * fixed and what is not, rather than what was meant.
 */
async function applyWalkFix() {
  const fix = walkFix.value
  if (!fix || fix.blocked) return
  const name = groupName(fix.groupId)
  const commands = []
  const span = new Set(fix.frameIds)
  let added = 0
  let timeAdded = 0
  let failure = ''
  applyingFix = true
  try {
    for (const time of [...fix.times].sort((a, b) => b.from_s - a.from_s)) {
      const to_s = Math.max(...frames.value.map((f) => f.t_s))
      const at = frames.value.filter((f) => f.t_s >= time.from_s).map((f) => ({ id: f.id, t_s: f.t_s }))
      await api.shiftFrom(time.from_s, time.seconds, to_s)
      commands.push({ kind: 'shift', from_s: time.from_s, to_s, delta: time.seconds, frames: at })
      timeAdded += time.seconds
    }
    for (const fill of fix.fills) {
      const from = frames.value.find((f) => f.id === fill.fromFrame)
      const to = frames.value.find((f) => f.id === fill.toFrame)
      // A frame already standing at a wanted time is reused, and gains a position: undo has to take that off it too
      const inside = frames.value.filter((f) => f.t_s > from.t_s && f.t_s < to.t_s)
      const known = new Set(frames.value.map((f) => f.id))
      const before = new Map(inside.map((f) => [f.id, restatedPositions(f)]))
      const result = await api.fillGap(fill.fromFrame, fill.toFrame, [fix.groupId])
      added += result?.frames_added ?? 0
      const written = frames.value.filter((f) => !known.has(f.id))
      for (const frame of written) span.add(frame.id)
      if (written.length) commands.push({ kind: 'fill', added: written.map(frameCopy) })
      for (const frame of inside) {
        const now = frames.value.find((f) => f.id === frame.id)
        if (!now) continue
        const after = restatedPositions(now)
        if (JSON.stringify(after) !== JSON.stringify(before.get(frame.id))) {
          span.add(frame.id)
          commands.push({ kind: 'positions', frameId: frame.id, before: before.get(frame.id), after })
        }
      }
    }
  } catch (error) {
    failure = planErrorMessage(error)
  }
  if (commands.length) edits.batch(commands, fix.kind === 'far' ? `filled ${name}'s walk` : `added time to ${name}'s walk`)
  walkFix.value = null
  await refreshProblems()
  applyingFix = false

  // Only what this fix was for counts against it: a filled walk that is still fast is the other fix's problem
  const here = problemCards.value.filter((p) => p.groupId === fix.groupId && span.has(p.fromFrame) && span.has(p.toFrame))
  const left = here.filter((p) => p.kind === fix.kind)
  const others = here.filter((p) => p.kind !== fix.kind)
  const lines = []
  if (added) lines.push(`Added ${added === 1 ? '1 new frame' : added + ' new frames'} for ${name}. Later frames are renumbered.`)
  if (timeAdded) lines.push(`Added ${formatDuration(timeAdded * 1000)}${fix.kind === 'far' ? ' to make room for them' : ''}. The plan runs that much longer.`)
  if (failure) lines.push(failure, commands.length ? 'The changes above are still in place.' : 'Nothing was changed.')
  for (const p of left) lines.push(`Still open: ${p.title}. ${p.detail}`.trim())
  const fast = others.filter((p) => p.kind === 'pace').length
  if (fast) lines.push(`${fast === 1 ? '1 too-fast warning' : fast + ' too-fast warnings'} on this walk ${fast === 1 ? 'is' : 'are'} separate: use Add time or Fix all timing.`)
  for (const p of others.filter((o) => o.kind !== 'pace')) lines.push(`Now showing: ${p.title}.`)
  walkFixResult.value = {
    title: failure ? 'The fix stopped partway' : left.length ? 'Partly fixed' : fix.kind === 'far' ? 'Filled: this walk is inside the 25 m limit' : 'Time added: this walk can be walked',
    tone: failure || left.length ? 'warn' : 'ok',
    lines,
    canUndo: commands.length > 0,
    frames: frames.value,
  }
  shownProblemId.value = ''
  drawLines()
  revealProblems()
}

async function undoWalkFix() {
  walkFixResult.value = null
  await runUndo()
}

/**
 * Fix all timing: give every open too-fast walk the time it needs, as one edit. Later walks go first, so a walk's times
 * still mean what they said when its turn comes: pushing an end only moves what comes after it.
 */
async function fixAllTiming() {
  if (blockedByErrors()) return
  const list = openWarnings.value.filter((p) => p.kind === 'pace').sort((a, b) => b.toS - a.toS)
  if (!list.length) return
  const needs = list.map((problem) => ({ problem, seconds: extraSeconds(problem.metres, problem.toS - problem.fromS) }))
  const total = needs.reduce((sum, row) => sum + row.seconds, 0)
  const ok = await askConfirm({
    title: `Add ${formatDuration(total * 1000)} to this plan?`,
    message: `${list.length === 1 ? 'This walk gets' : list.length + ' walks get'} enough time to be walked, and everything after each one moves later. The plan runs ${formatDuration(total * 1000)} longer. Undo puts it all back.`,
    confirmText: 'Add time',
  })
  if (!ok) return
  const done = []
  try {
    for (const { problem, seconds } of needs) {
      const to_s = Math.max(...frames.value.map((f) => f.t_s))
      const at = frames.value.filter((f) => f.t_s >= problem.toS).map((f) => ({ id: f.id, t_s: f.t_s }))
      await api.shiftFrom(problem.toS, seconds, to_s)
      done.push({ from_s: problem.toS, to_s, delta: seconds, frames: at })
    }
    toast(`Added ${formatDuration(total * 1000)}.`, 'success', 3000)
  } catch (error) {
    // A walk somebody is retiming refuses its push. The ones already moved stay, and Undo still reaches them.
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
  if (done.length) edits.batch(done.map((one) => ({ kind: 'shift', ...one })), `added ${formatDuration(total * 1000)} to ${list.length === 1 ? 'a walk' : list.length + ' walks'}`)
}

function dismissAllWarnings() {
  for (const problem of openWarnings.value) setDismissed(problem, true)
}

function actOnProblem(problem, key) {
  if (key === 'walk') return startWalkFix(problem)
  if (key === 'between') return addFrameBetween(problem)
  const action = problem.actions.find((a) => a.key === key)
  return addTimeTo(problem, action.seconds)
}

/** The group-frames the database names, merged into the lanes' and the map's red. The strip is left to the 25 m
 *  rule: a frame dot means "this moment is broken for somebody's walk", and a crossing is already named by the row,
 *  the badge and the segment -- marking two more dots would count a rule the strip does not measure. */
const flaggedCells = computed(
  () =>
    new Set([
      ...analysis.value.cells,
      ...blocking.value.flatMap((row) => [`${row.group_id}|${row.from_frame}`, `${row.group_id}|${row.to_frame}`]),
    ]),
)

/**
 * Where the open frame sits in the strip, and the stretches it is inside. A dot marked red on the bar says "this
 * moment is part of an impossible walk"; this says which walk, and over what span -- the answer to "why is that dot
 * red?" without hunting through the warning rows for a sentence that happens to mention this time.
 */
const frameOrder = computed(() => [...frames.value].sort((a, b) => a.t_s - b.t_s))
const stretchAtSelected = computed(() => {
  const frame = selected.value
  if (!frame) return []
  const index = frameOrder.value.findIndex((f) => f.id === frame.id)
  if (index < 0) return []
  return analysis.value.stretches.filter((s) => s.fromIndex <= index && index <= s.toIndex)
})

/**
 * Ask what the database makes of the plan, then repaint. The answer is deliberately not an error path: a failed
 * second opinion must leave the board's own red exactly as it was, never blank it.
 */
async function refreshProblems() {
  const askedFor = plan.value ? plan.value.id : null
  try {
    const rows = await api.check()
    // A slow answer about a plan the planner has already left must not land on the one now open.
    if ((plan.value ? plan.value.id : null) !== askedFor) return
    serverProblems.value = Array.isArray(rows) ? rows : []
  } catch {
    serverProblems.value = []
  }
  drawLines()
  drawMarkers()
}

/** The selected frames in time order, and the one pair of times that names them. */
const selectedFrames = computed(() => frames.value.filter((f) => selection.value.has(f.id)))
const selectionSpan = computed(() => {
  const list = selectedFrames.value
  if (!list.length) return null
  const times = list.map((f) => f.t_s)
  return { count: list.length, from_s: Math.min(...times), to_s: Math.max(...times) }
})

/**
 * Who a flag or a hold acts on: the groups ticked in the inspector, or — when nothing is ticked — every group that
 * stands at the open frame. Ticking narrows the hold to those groups, which is the spec's "hold one group"; the flag
 * controls use the same rule, so "who does this button act on?" has one answer on this screen.
 */
const standingTargets = computed(() => {
  if (!selected.value) return []
  if (selectedGroups.value.size) return shownGroups.value.filter((g) => selectedGroups.value.has(g.id))
  return shownGroups.value.filter((g) => framePosition(selected.value, g.id))
})

/** "A", "A and B", "A, B and C" — the same list the hold, the flags and the drag all have to name. */
function nameList(names) {
  if (!names.length) return ''
  if (names.length === 1) return names[0]
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
}

const standingLabel = computed(() => nameList(standingTargets.value.map((g) => g.name)))

/**
 * The frames the confirmation controls act on: the whole selected stretch, or the one open frame. A confirmation is
 * about a position, and a selection is how the planner names more than one; naming the frames is what lets the write
 * be one call (frame_set_verify, 047) instead of one save per frame.
 */
const flagFrames = computed(() => {
  if (selectedFrames.value.length) return selectedFrames.value
  return selected.value ? [selected.value] : []
})

/**
 * How many positions the confirmation buttons would touch: the cells among those frames and groups that the plan
 * actually STATES. A carried-forward position is the same statement as the frame that set it, so it is not a cell
 * here — the server patches rows and never invents one (047), and this is the honest count of the rows it can reach.
 */
const verifyRows = computed(() => {
  let n = 0
  for (const frame of flagFrames.value) {
    for (const group of standingTargets.value) {
      if (framePosition(frame, group.id)?.defined) n += 1
    }
  }
  return n
})

/**
 * What a drag moves: the ticked groups that stand at the open frame. Ticking is the only way to say "these move
 * together", and a group that stands nowhere here cannot be dragged from here -- there is no badge to grab, and
 * inventing a place for it would be a different edit (step 8). An off-site group has no badge either (step 10 draws
 * one marker fewer), so it is not in this list: the sentence beside the map would otherwise name a badge that is not
 * there.
 */
const dragTargets = computed(() => {
  const frame = selected.value
  if (!frame) return []
  return shownGroups.value.filter((g) => {
    if (!selectedGroups.value.has(g.id)) return false
    const at = framePosition(frame, g.id)
    return !!at && at.state !== 'off_site'
  })
})
const dragLabel = computed(() => nameList(dragTargets.value.map((g) => g.name)))

// One group for a member, every group for ops staff. The database already refuses the other groups' rows (040);
// this keeps the board from drawing them as "not yet placed", which would be a different lie.
const shownGroups = computed(() =>
  props.onlyGroupId ? groups.value.filter((g) => g.id === props.onlyGroupId) : groups.value,
)
// A member follows whatever is published. The draft someone is still drawing is not theirs to read on a board:
// the timetable they will actually use replaces this view in step 16.
const readablePlan = computed(() => {
  if (!props.onlyGroupId) return livePlan.value || plans.value[0] || null
  return livePlan.value
})
const colorOf = computed(() => {
  const map = new Map()
  groups.value.forEach((g, i) => map.set(g.id, g.colour || GROUP_COLORS[i % GROUP_COLORS.length]))
  return map
})

function groupName(id) {
  const g = groups.value.find((x) => x.id === id)
  return g ? g.name : 'a group'
}

function initials(name) {
  return String(name || '?')
    .split(/\s+/)
    .slice(0, 2)
    .map((word) => word[0])
    .join('')
    .toUpperCase()
}

// ---------- the selection ----------

function isFrameSelected(id) {
  return selection.value.has(id)
}

function selectOnly(id) {
  selection.value = new Set(id ? [id] : [])
}

/** Every frame between two moments, inclusive: what Shift+click and a sweep across the bar both produce. */
function framesBetween(a, b) {
  const lo = Math.min(a, b)
  const hi = Math.max(a, b)
  return frames.value.filter((f) => f.t_s >= lo && f.t_s <= hi).map((f) => f.id)
}

function isGroupSelected(id) {
  return selectedGroups.value.has(id)
}

function toggleGroup(id) {
  const next = new Set(selectedGroups.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  selectedGroups.value = next
}

const allGroupsTicked = computed(() => shownGroups.value.length > 0 && shownGroups.value.every((g) => selectedGroups.value.has(g.id)))

function toggleAllGroups() {
  selectedGroups.value = allGroupsTicked.value ? new Set() : new Set(shownGroups.value.map((g) => g.id))
}

// ---------- the map ----------

let map = null
let zoneLayer = null
let lineLayer = null
let markerLayer = null
// The badges drawn right now, by group, so a drag can carry its companions along. Rebuilt on every redraw.
const markers = new Map()
// The drag in flight: { leaderId, roster: [{ id, lat, lng }] } — where every badge it will move started.
let groupDrag = null
// Where a drop put the badges while its write is on the way: { frameId, at: Map(groupId -> { lat, lng }) }. Any
// redraw in that window (a check coming back, a background read) drew the badges at the old place, so they jumped
// back and then forward again (QA 1 Nov). Until the write has been read back, the drop is what the map shows.
let pendingMoves = null
// Fitting happens twice at most: once for the polygons as soon as they arrive, then once more when the plan's
// positions arrive, because the areas and the people are not always in the same corner of the map. After that the
// view is the planner's: re-fitting on every save would drag the map out from under a drag.
let fitted = false
let fittedWithFrames = false
let zoneBounds = null

const ZONE_STYLE = {
  zone: { color: '#0b3d2e', weight: 2.5, fillOpacity: 0.6, fillColor: '#9be7c4' },
  no_go: { color: '#c2410c', weight: 2.5, dashArray: '10 7', fillOpacity: 0.35, fillColor: '#ff8a65' },
  obstacle: { color: '#56685f', weight: 1.5, dashArray: '3 3', fillOpacity: 0.16, fillColor: '#56685f' },
  stage: { color: '#0a1f17', weight: 2.5, fillOpacity: 0.75, fillColor: '#c6f36b' },
  entrance: { color: '#14523e', weight: 1.5, fillOpacity: 0.08, fillColor: '#14523e' },
}

function drawZones() {
  if (!map || !zoneLayer) return
  zoneLayer.clearLayers()
  const bounds = L.latLngBounds([])
  for (const zone of zones.value) {
    if (!zone.geojson) continue
    const layer = L.geoJSON(zone.geojson, {
      style: ZONE_STYLE[zone.kind] || ZONE_STYLE.zone,
      interactive: false, // locked: the planner reads the areas, and never edits them here
    })
    layer.addTo(zoneLayer)
    const caption = zoneCaption(L, layer, zone.kind, zone.name)
    if (caption) caption.addTo(zoneLayer)
    try {
      bounds.extend(layer.getBounds())
    } catch {
      /* an empty or broken polygon should not stop the rest drawing */
    }
  }
  if (bounds.isValid()) {
    zoneBounds = bounds
  } else {
    zoneBounds = null
  }
}

/**
 * Frame the whole picture: the locked polygons and the plan itself. Fitting to the polygons alone opened a plan on
 * a map that did not contain a single marker whenever the groups stood outside the drawn areas.
 */
function fitMap() {
  if (!map) return
  // Once the plan is in the view, stop moving the map: a planner who has panned somewhere else keeps that view.
  if (fitted && (fittedWithFrames || !tracks.value.size)) return
  // Only the places somebody is: an off-site row has a coordinate but is not a position on the map (step 10), and
  // fitting to it would open the plan looking at somewhere nobody stands. They widen the zones' view only when they
  // are near the zones (utils/venueFrame).
  const points = []
  for (const [, track] of tracks.value) {
    for (const point of track) if (point.state !== 'off_site') points.push([point.lat, point.lng])
  }
  const bounds = venueBounds(L, zoneBounds, points)
  if (!bounds || !bounds.isValid()) return
  // Not animated, deliberately: a fit that has to glide is a fit that can lose the argument with the layout — the
  // inspector changes the map's height, and an animation started at the old size lands somewhere else. Instant
  // framing is also what a plan switch should feel like (finding 39).
  // Capped at 18: the first group placed on a new plan is a single point, and fitting to it went to zoom 20, where
  // OneMap has no tiles and the map turned to a hatched blank (QA 1 Nov).
  map.fitBounds(bounds.pad(0.2), { animate: false, maxZoom: 18 })
  fitted = true
  fittedWithFrames = tracks.value.size > 0
}

/** The effective position each group has at a time: the last thing said at or before it. */
function effectiveAt(t_s) {
  const out = {}
  for (const [groupId, points] of tracks.value) {
    let found = null
    for (const point of points) {
      if (point.t_s <= t_s) found = point
      else break
    }
    // The flags travel with the coordinates (046): a new frame placed after an off-site moment must not silently
    // put that group back on the map at an old position.
    if (found) out[groupId] = { lat: found.lat, lng: found.lng, state: found.state, verify: found.verify }
  }
  return out
}

/** Position of a group on a frame, inherited when that frame does not mention it. */
function framePosition(frame, groupId) {
  if (!frame) return null
  const points = tracks.value.get(groupId)
  if (!points) return null
  const hit = points.find((p) => p.frameId === frame.id)
  return hit || null
}

/**
 * Where every group is at an instant between its moments (step 22). A playback cursor is a time, not a frame, so a
 * badge is drawn along the straight line between the two statements the walk gives it -- the same line the strip draws
 * dashed. An off-site stretch is not a place on the map, so the badge is held where the group last stood on the ground
 * and then disappears until the next on-site statement: exactly the rule that breaks the track's line (046, step 10).
 */
function pointAt(t) {
  const out = new Map()
  for (const [groupId, points] of tracks.value) {
    let before = null
    let after = null
    for (const point of points) {
      if (point.t_s <= t) before = point
      else {
        after = point
        break
      }
    }
    if (!before || before.state === 'off_site') continue
    if (!after || after.state === 'off_site' || after.t_s <= before.t_s) {
      out.set(groupId, { lat: before.lat, lng: before.lng, state: 'on_site', moving: false, next: null, t_s: before.t_s })
      continue
    }
    const share = (t - before.t_s) / (after.t_s - before.t_s)
    out.set(groupId, {
      lat: before.lat + (after.lat - before.lat) * share,
      lng: before.lng + (after.lng - before.lng) * share,
      state: 'on_site',
      moving: true,
      next: after,
      t_s: before.t_s,
    })
  }
  return out
}

/**
 * The moment the run is between and the one it is walking towards. The caption says both, so "where are we" is
 * answered by the same sentence whether the cursor is mid-walk or exactly on a moment.
 */
const playPosition = computed(() => {
  if (playhead.value == null) return null
  const t = playhead.value
  let before = null
  let after = null
  for (const frame of frameOrder.value) {
    if (frame.t_s <= t) before = frame
    else {
      after = frame
      break
    }
  }
  return { before, after, at: t }
})

const playText = computed(() => {
  const at = playPosition.value
  if (!at) return ''
  const here = formatOffset(Math.floor(at.at))
  if (!at.after) return here + ' · the end of the walk'
  if (!at.before) return here + ' · before ' + formatOffset(at.after.t_s)
  return here + ' · next ' + formatOffset(at.after.t_s) + (at.after.note ? ' ' + at.after.note : '')
})

const playClock = computed(() => (playhead.value == null ? '' : formatOffset(Math.floor(playhead.value))))

/**
 * What the inspector says about one group on the open frame. An off-site group is still listed -- the row is the
 * plan's statement that it is not on the map -- which is why this is a word beside the name and not a missing row,
 * and why the map draws no badge for it rather than a badge somewhere it is not (step 10).
 */
function stateWord(point) {
  if (!point) return 'not yet placed'
  if (point.state === 'off_site') return 'off site'
  return point.defined ? 'set' : 'same'
}

/** The flag chips read the resolved position, so a carried-forward group shows the statement that is in force. */
function isOffSite(frame, groupId) {
  return framePosition(frame, groupId)?.state === 'off_site'
}

function isManual(frame, groupId) {
  return framePosition(frame, groupId)?.verify === 'manual'
}

/** True when this frame states the group itself, rather than carrying an earlier statement into it. */
function isStated(frame, groupId) {
  return framePosition(frame, groupId)?.defined === true
}

function drawLines() {
  if (!map || !lineLayer) return
  lineLayer.clearLayers()
  for (const [groupId, points] of tracks.value) {
    if (!points.length) continue
    // An off-site statement is not a place on the map, so the track stops there and starts again at the next on-site
    // frame: the line is drawn as the runs between on-site statements (046, step 10). Joining through an off-site
    // point would draw a walk to a place nobody is, which is the picture the 25 m rule already refuses to measure.
    const line = (run) => {
      if (run.length < 2) return
      L.polyline(run, {
        color: colorOf.value.get(groupId) || '#0b3d2e',
        weight: 2,
        // A group that is not ticked steps back so the ticked ones read as the subject.
        opacity: selectedGroups.value.size && !selectedGroups.value.has(groupId) ? 0.12 : 0.55,
        dashArray: '5 5',
        interactive: false,
      }).addTo(lineLayer)
    }
    let run = []
    for (const point of points) {
      if (point.state === 'off_site') {
        line(run)
        run = []
      } else {
        run.push([point.lat, point.lng])
      }
    }
    line(run)
  }
  // Every break in the chain, drawn in the same red the bar uses.
  for (const gap of analysis.value.gaps) {
    L.polyline(
      [
        [gap.from.lat, gap.from.lng],
        [gap.to.lat, gap.to.lng],
      ],
      { color: '#c2410c', weight: 3, opacity: 0.9, interactive: false },
    ).addTo(lineLayer)
  }
  // The stretches the database refuses that the walk above does not report: a line through a zone, or a hop too
  // quick to be a walk. Drawn on top of the track, so the segment the sentence names is the segment on screen. A
  // shorter dash tells it apart from a break: the people are there, the ground is not allowed.
  for (const row of blocking.value) {
    const track = tracks.value.get(row.group_id)
    const from = track && track.find((p) => p.frameId === row.from_frame)
    const to = track && track.find((p) => p.frameId === row.to_frame)
    if (!from || !to) continue
    L.polyline(
      [
        [from.lat, from.lng],
        [to.lat, to.lng],
      ],
      { color: '#c2410c', weight: 3, opacity: 0.9, dashArray: '2 4', interactive: false },
    ).addTo(lineLayer)
  }
  // A fix on show: the walk it covers, and the new frames it would add along it.
  if (walkFix.value && walkFix.value.route.length > 1) {
    L.polyline(walkFix.value.route.map((p) => [p.lat, p.lng]), { color: '#15803d', weight: 4, opacity: 0.9, interactive: false }).addTo(lineLayer)
    for (const spot of walkFix.value.fills.flatMap((fill) => fill.spots)) {
      L.circleMarker([spot.lat, spot.lng], { radius: 6, color: '#15803d', weight: 3, fillColor: '#fff', fillOpacity: 1, interactive: false }).addTo(lineLayer)
    }
  }
  // Warnings the planner has not dismissed, amber where an error is red; and the walk "Show on map" asked for, wide.
  for (const problem of problems.value) {
    const shown = problem.id === shownProblemId.value
    if (!shown && !openWarnings.value.includes(problem)) continue
    const from = problemPoint(problem.groupId, problem.fromFrame)
    const to = problemPoint(problem.groupId, problem.toFrame)
    if (!from || !to) continue
    const line = [[from.lat, from.lng], [to.lat, to.lng]]
    if (shown) L.polyline(line, { color: problem.level === 'error' ? '#c2410c' : '#d97706', weight: 9, opacity: 0.35, interactive: false }).addTo(lineLayer)
    if (problem.level === 'warning') L.polyline(line, { color: '#d97706', weight: 3, opacity: 0.95, dashArray: '2 4', interactive: false }).addTo(lineLayer)
    const spot = shown && !walkFix.value ? spotOf(problem) : null
    if (spot) {
      L.polyline([[from.lat, from.lng], [spot.lat, spot.lng]], { color: '#15803d', weight: 3, dashArray: '6 6', interactive: false }).addTo(lineLayer)
      L.marker([spot.lat, spot.lng], {
        interactive: false,
        keyboard: false,
        zIndexOffset: 500,
        icon: L.divIcon({
          className: 'pv-suggest-wrap',
          html: `<div class="pv-suggest" data-testid="problem-spot"><span class="pv-suggest-dot"></span><span class="pv-suggest-label">Suggested spot for ${escapeHtml(groupName(problem.groupId))}</span></div>`,
          iconSize: [22, 22],
          iconAnchor: [11, 11],
        }),
      }).addTo(lineLayer)
    }
  }
}

function drawMarkers() {
  if (!map || !markerLayer) return
  // A hand is on the board. Redrawing replaces the very marker Leaflet is dragging -- the drag ends with the marker
  // that was removed -- and snaps the dots back under a stretch being moved. The redraw the reload wanted happens as
  // soon as the gesture is over, because the drag's own write re-reads the plan.
  // A scrub is the one gesture that wants the badges redrawn under the hand: it is how the map follows the cursor.
  if (groupDrag || dragState.value || (pointerDown.value && !scrubbing.value)) return
  markerLayer.clearLayers()
  markers.clear()
  const frame = selected.value
  const run = playhead.value != null ? pointAt(playhead.value) : null
  if (!frame && !run) return

  const dropped = !run && pendingMoves && frame && pendingMoves.frameId === frame.id ? pendingMoves.at : null
  for (const group of shownGroups.value) {
    let point = run ? run.get(group.id) : framePosition(frame, group.id)
    if (point && dropped && dropped.has(group.id)) point = { ...point, ...dropped.get(group.id) }
    // Not placed yet, or not on the map at this moment: no badge. An off-site row is still the plan's statement —
    // the inspector lists it and calls it "off site" — but nobody is standing there, so a marker would be a person
    // the map is drawing who is not there. Step 10's Done-when is the words: "one fewer marker, still listed".
    if (!point || point.state === 'off_site') continue
    const color = colorOf.value.get(group.id) || '#0b3d2e'
    const dim = selectedGroups.value.size > 0 && !selectedGroups.value.has(group.id)
    // This badge is an end of a stretch the database refuses: same red ring the bar and the lane use.
    const bad = !run && flaggedCells.value.has(`${group.id}|${frame.id}`)
    // Who has this badge now (081). `other` is somebody else's hand on it: a ring, and a tooltip that names them, so a
    // planner can see why it will not move before they try it. `own` is a session of my own account -- my other
    // window, or the gesture this page is making -- which is a different fact and reads differently.
    const cell = cellId(frame ? frame.id : '', group.id)
    const other = run || !frame ? null : busyCells.value.get(cell) || null
    const own = run || !frame || other ? null : ownCells.value.get(cell) || null
    const icon = L.divIcon({
      className: 'pv-marker-wrap',
      html: `<div class="pv-marker${dim ? ' is-dim' : ''}${bad ? ' is-bad' : ''}${run ? ' is-walking' : ''}${other ? ' is-busy' : ''}${own ? ' is-held' : ''}" style="background:${color}">${initials(group.name)}</div>`,
      iconSize: [26, 26],
      iconAnchor: [13, 13],
    })
    const marker = L.marker([point.lat, point.lng], {
      icon,
      // Nobody drags a badge while the clock is running: the position on screen is a place between two moments, and
      // there is no row to write it to.
      draggable: canMove.value && !run && !!frame && canEditCell(frame, group.id),
      keyboard: false,
      autoPan: true,
      title: group.name,
    })
    if (canMove.value && !run && frame && canEditCell(frame, group.id)) {
      // Only the badge under the pointer raises dragstart/dragend; the companions are moved with setLatLng(), which
      // raises no drag event. So one gesture is one dragend, and one write is all that can happen.
      marker.on('dragstart', () => beginGroupDrag(group.id))
      marker.on('drag', () => onGroupDrag(group.id))
      marker.on('dragend', () => endGroupDrag(group.id))
    }
    marker.bindTooltip(
      (run
        ? `${group.name} · ${point.moving ? 'walking to ' + formatOffset(point.next.t_s) : 'held at ' + formatOffset(point.t_s)}`
        : `${group.name} · ${point.defined ? 'set at ' : 'unchanged since '}${formatOffset(point.t_s)}`) +
        (other ? ` · ${other.display_name || 'Somebody'} is editing` : ''),
      { direction: 'top', offset: [0, -14] },
    )
    markers.set(group.id, marker)
    marker.addTo(markerLayer)
    // The ids a browser check holds on to. A badge is drawn by Leaflet, so it has no Vue template to put them in; the
    // element Leaflet made for it is the one the hand grabs, which is exactly the one a check should grab too.
    const element = marker.getElement()
    if (element) {
      element.dataset.testid = 'plan-badge'
      element.dataset.group = group.id
      element.dataset.cell = cell
      element.dataset.hold = other ? 'other' : own ? 'mine' : ''
      element.dataset.heldBy = other ? other.display_name || 'Somebody' : ''
    }
  }
}

// ---------- holding a badge while the hand is on it (081, 082) ----------

/**
 * The product's rule: a badge nobody has moved for five seconds is let go, so a planner who walks away mid-drag does
 * not keep a colleague out of it. The next movement takes it back silently -- nothing failed, so nothing is said --
 * and if somebody else took it in the gap, the write is refused and the badge goes back with the sentence. That
 * snap-back is the price of the rule rather than a bug in it: a hold nobody is using is worse than a gesture that
 * has to be repeated.
 */
const HOLD_IDLE_MS = 5000
/** How often the board asks who is editing what. The read is cheap; a ring that names the wrong person is not. */
const HOLDERS_MS = 2500

/**
 * `?concurrent=0` turns the ownership picture off: the rings, the stack of who else is editing, and the hold across a
 * gesture. It deliberately cannot bring back the old write path -- 082 refuses a badge map for a frame that already
 * stands, because that map was the bug (a drag wrote every other badge back as this page had last read it). So the
 * flag is a way to look at the board without the new UI, never a way to edit the old way.
 */
const OWNERSHIP_UI = (() => {
  try {
    return new URLSearchParams(window.location.search).get('concurrent') !== '0'
  } catch {
    return true
  }
})()

/** "This badge is open in another of your windows ... Take it over to edit here." -- the one refusal with a way out. */
const TAKE_OVER = /another of your windows/i

// The board's one strip for refusals: a badge somebody else has, a move that never reached the database, a hold that
// was lost. It is not a toast because it has to outlive the pointer (a drag ends in the same instant a refusal may
// arrive) and because a snap-back is not a success notice. One line, the server's own words, at most one way out.
const refusal = ref(null)
let refusalTimer = null

function sayRefusal(text, action = null) {
  clearTimeout(refusalTimer)
  const clean = String(text || '').trim()
  if (!clean) return
  refusal.value = { text: clean, action }
  refusalTimer = setTimeout(() => {
    refusal.value = null
  }, action ? 15000 : 8000)
}

function clearRefusal() {
  clearTimeout(refusalTimer)
  refusal.value = null
}

function runRefusalAction() {
  const action = refusal.value ? refusal.value.action : null
  clearRefusal()
  if (action) action.run()
}

function trimStop(text) {
  const s = String(text || '').trim()
  return s.endsWith('.') ? s.slice(0, -1) : s
}

/** "Error updating location: Priya has this badge" -- the product's sentence for a move that did not land. */
function locationRefusal(error) {
  const reason = trimStop(planErrorMessage(error))
  return reason ? `Error updating location: ${reason}.` : 'Error updating location.'
}

/**
 * A write refused because a badge (or a moment) is somebody else's. The strip is where that is said, and the caller
 * keeps its toast for everything else: a validation rule, a plan that moved under it, a network failure with no
 * sentence of its own.
 */
function refusedBecauseHeld(error) {
  if (!isLockRefusal(error)) return false
  sayRefusal(planErrorMessage(error))
  return true
}

// Who is editing what, right now (081's plan_lock_holders): a ring on a badge somebody else has, and a small stack of
// who they are. Both are drawn from this one read and neither decides anything -- the database still decides.
const holders = ref([])
let holdersTimer = null

async function refreshHolders() {
  if (!OWNERSHIP_UI || !props.canEdit || !plan.value || !api.lockHolders) {
    holders.value = []
    return
  }
  holders.value = (await api.lockHolders()) || []
}

function cellId(frameId, groupId) {
  return `${frameId}|${groupId}`
}

/** Rows for badges somebody else holds, keyed the way the map draws a cell. */
const busyCells = computed(() => {
  const map = new Map()
  for (const row of holders.value) {
    if (row.kind !== 'badge' || row.mine) continue
    map.set(cellId(row.frame_id, row.group_id), row)
  }
  return map
})

/** The same, for a hold of my own account in another window: not "somebody else", but still worth a ring. */
const ownCells = computed(() => {
  const map = new Map()
  for (const row of holders.value) {
    if (row.kind !== 'badge' || !row.mine) continue
    map.set(cellId(row.frame_id, row.group_id), row)
  }
  return map
})

/** Is this row a badge the gesture in flight is carrying? A hold of my own hand is not news about myself. */
function inMyGesture(row) {
  return !!groupDrag && groupDrag.cells.some((c) => c.frame === row.frame_id && c.group === row.group_id)
}

/** Who else is editing, one chip each: the presence stack beside the clock. */
const editors = computed(() => {
  const byPerson = new Map()
  for (const row of holders.value) {
    if (row.kind !== 'badge') continue
    if (row.mine && inMyGesture(row)) continue
    const key = row.mine ? 'me-elsewhere' : row.user_id || row.display_name || 'somebody'
    const entry = byPerson.get(key) || {
      key,
      name: row.mine ? 'You, another window' : row.display_name || 'Somebody',
      // "You, another window" has no initials worth guessing, so the chip says "you" instead of inventing letters.
      initials: row.mine ? 'you' : initials(row.display_name || 'Somebody'),
      cells: [],
    }
    entry.cells.push(row)
    byPerson.set(key, entry)
  }
  return [...byPerson.values()]
})

function editorTitle(editor) {
  const named = editor.cells
    .slice(0, 4)
    .map((row) => `${row.group_name || groupName(row.group_id)} at ${formatOffset(row.t_s)}`)
  const more = editor.cells.length - named.length
  return `${editor.name} is editing ${named.join(', ')}${more > 0 ? ` and ${more} more` : ''}.`
}

// A badge this page holds and no longer has (the heartbeat found out: taken over, or it expired). Nothing is written
// at the end of this gesture -- the badge is somebody else's -- so the drag finishes as a refusal and goes back.
if (api.onHoldLost) {
  api.onHoldLost((gone) => {
    const state = groupDrag
    if (!state || state.phase === 'refused') return
    const hit = state.cells.some((cell) => gone.some((row) => row.frame === cell.frame && row.group === cell.group))
    if (!hit) return
    state.phase = 'refused'
    state.refusal = 'This badge stopped being yours to edit. Try again.'
    sayRefusal(state.refusal)
    refreshHolders()
  })
}

// ---------- where somebody else's drag is going (phase 4) ----------

/**
 * A colleague's badge does NOT move on this screen while they drag it: it is drawn from the plan, and the plan has not
 * changed yet. So their drag is drawn as a GHOST, on a layer of its own, at the place they are taking the badge --
 * beside the ring that already says it is theirs. That pair is the honest picture: this is where the plan has the
 * badge, and that is where somebody else is taking it.
 *
 * The ghost comes from a broadcast (usePlanStream) and is never a position: it cannot be written, and a forged one is
 * a lie about a preview rather than about the plan (utils/planDraft.js). It goes when the sender says they let go,
 * when they have not refreshed it for two and a half seconds, or when this page leaves the plan.
 */
const drafts = ref([]) // rows from the stream: { cell, frame, group, lat, lng, from }
let draftLayer = null
const ghosts = new Map() // cell -> the Leaflet marker drawing it

function draftIcon(groupId) {
  const group = groups.value.find((g) => g.id === groupId)
  const color = colorOf.value.get(groupId) || '#0b3d2e'
  return L.divIcon({
    className: 'pv-ghost-wrap',
    html: `<div class="pv-ghost" style="--pv-ghost-colour:${color}">${initials(group ? group.name : '?')}</div>`,
    iconSize: [26, 26],
    iconAnchor: [13, 13],
  })
}

/**
 * Draw the ghosts of other planners' drags: only the open moment has a map, only a group this page can see has a
 * badge, and only a badge that is being dragged has a ghost. Everything else about the plan is still drawn from the
 * plan, which is why a ghost can never be confused with a position.
 */
function drawGhosts() {
  if (!map || !draftLayer) return
  const frame = selected.value
  const keep = new Set()
  if (OWNERSHIP_UI && frame && playhead.value == null) {
    for (const row of drafts.value) {
      if (row.frame !== frame.id) continue
      if (!shownGroups.value.some((group) => group.id === row.group)) continue
      keep.add(row.cell)
      let ghost = ghosts.get(row.cell)
      if (!ghost) {
        // Under the badges: the plan's own position is the real one, and a ghost must never cover it.
        ghost = L.marker([row.lat, row.lng], {
          icon: draftIcon(row.group),
          interactive: false,
          keyboard: false,
          zIndexOffset: -100,
        }).addTo(draftLayer)
        ghosts.set(row.cell, ghost)
      } else {
        ghost.setLatLng([row.lat, row.lng])
      }
      // The ids a browser check holds on to, and who the ghost is: the NAME comes from the holders read, not from the
      // broadcast, because a name in a broadcast is a name anybody can type.
      const element = ghost.getElement()
      if (element) {
        const named = busyCells.value.get(row.cell) || null
        element.dataset.testid = 'plan-ghost'
        element.dataset.group = row.group
        element.dataset.cell = row.cell
        element.dataset.by = named ? named.display_name || 'Somebody' : ''
      }
    }
  }
  for (const [cell, ghost] of ghosts) {
    if (keep.has(cell)) continue
    draftLayer.removeLayer(ghost)
    ghosts.delete(cell)
  }
}

/** Forget every ghost: the plan they were about is not on screen any more. */
function clearGhosts() {
  drafts.value = []
  for (const ghost of ghosts.values()) if (draftLayer) draftLayer.removeLayer(ghost)
  ghosts.clear()
}

/**
 * Publish where this gesture's badges are going, per badge, for everybody else's screen. The throttle (one per badge
 * per 50 ms, with the last place always sent) lives in usePlanStream, so this can be called on every drag step.
 * Nothing is published for a gesture that has already been refused: it will never move anything, and a ghost heading
 * somewhere no badge will ever stand is a lie about a preview.
 */
function publishDrafts(state) {
  if (!OWNERSHIP_UI || !api.planDraft || !state) return
  for (const row of state.roster) {
    const marker = markers.get(row.id)
    if (!marker) continue
    const at = marker.getLatLng()
    api.planDraft({ frame: state.frameId, group: row.id }, { lat: at.lat, lng: at.lng })
    state.published = true
  }
}

/**
 * The gesture is over: the ghosts for its badges go now, whatever happened to the write. A gesture that never moved
 * published nothing, so it has nothing to take back -- a click on a badge must not send a message about it.
 */
function releaseDrafts(state) {
  if (!OWNERSHIP_UI || !api.clearDrafts || !state || !state.cells || !state.published) return
  api.clearDrafts(state.cells)
}

if (OWNERSHIP_UI && api.onDraft) api.onDraft((rows) => (drafts.value = rows))

/**
 * Drag a group on the map: that moment states a new position for it. When the group is ticked, every ticked group
 * standing at this frame comes with it — the gesture a planner makes for "the whole crew steps ten metres back".
 *
 * The hold is taken as the drag begins and kept for as long as the hand is on it, so the badge is locked to other
 * planners for the whole gesture rather than for the instant of the write. The write at the end is ONE call carrying
 * every badge that moved (082): a gesture is one statement, so three badges dragged are three written or none. It
 * carries only the badges that moved, and one cell's write touches one row — that is what lets a colleague drag a
 * different badge at the same moment without either of them losing the other's work.
 */
function beginGroupDrag(leaderId) {
  const frame = selected.value
  groupDrag = null
  if (!frame) return
  const ticked = dragTargets.value
  // While there are errors, a ticked group they do not name stays where it is (blockedByErrors)
  const ids = (ticked.some((g) => g.id === leaderId) ? ticked.map((g) => g.id) : [leaderId]).filter((id) => canEditCell(frame, id))
  const roster = []
  for (const id of ids) {
    const at = framePosition(frame, id)
    if (at) roster.push({ id, lat: at.lat, lng: at.lng })
  }
  if (!roster.length) return
  const state = {
    leaderId,
    // The moment the gesture is about: the hold and the write both name it, and so does the draft a colleague draws.
    frameId: frame.id,
    roster,
    // One gesture, one hold: every badge the drag will carry, all or none, so a colleague cannot grab a companion of
    // a group that is being moved (081's all-or-nothing).
    cells: roster.map((row) => ({ frame: frame.id, group: row.id })),
    // asking -> held -> (releasing -> idle -> held) while the hand is down. `refused` is final for this gesture, and
    // `plain` is ?concurrent=0: the write still takes its own hold, but the gesture does not.
    phase: OWNERSHIP_UI ? 'asking' : 'plain',
    grab: null,
    movedWhileReleasing: false,
    published: false, // has this gesture told anybody else where the badges are going?
    refusal: '',
  }
  groupDrag = state
  if (state.phase === 'asking') state.grab = grabGesture(state)
  // The rings and the stack should be about now rather than about the last poll -- a colleague may have taken this
  // badge a second ago, and the refusal is cheaper to bear when the ring already said so.
  refreshHolders()
}

/**
 * Take the badges for the gesture. The badge is being dragged locally while this is on its way (the product's answer:
 * move it first, find out second), so a refusal is said now and the badge goes back when the hand comes up.
 */
async function grabGesture(state) {
  try {
    await api.holdCells(state.cells)
    state.phase = 'held'
    if (groupDrag === state) armHoldIdle()
  } catch (error) {
    if (groupDrag !== state) return
    state.phase = 'refused'
    state.refusal = planErrorMessage(error)
    sayRefusal(state.refusal)
    refreshHolders()
  }
}

let holdIdle = null

function armHoldIdle() {
  clearTimeout(holdIdle)
  const state = groupDrag
  if (!state || state.phase !== 'held') return
  holdIdle = setTimeout(() => releaseIdle(state), HOLD_IDLE_MS)
}

/** Five seconds without a movement: put the badge down, and keep dragging locally. */
async function releaseIdle(state) {
  if (groupDrag !== state || state.phase !== 'held') return
  state.phase = 'releasing' // a hold being given up is not a hold: the next movement takes it back
  state.release = api.releaseCells(state.cells)
  await state.release
  if (groupDrag !== state) return
  state.phase = 'idle'
  refreshHolders()
  if (state.movedWhileReleasing) {
    state.movedWhileReleasing = false
    reacquire(state)
  }
}

/** Take the badge back after an idle release. Silent on success: nothing failed, so there is nothing to say. */
async function reacquire(state) {
  if (groupDrag !== state || state.phase !== 'idle') return
  state.phase = 'asking'
  try {
    await api.holdCells(state.cells)
    if (groupDrag !== state) {
      // The hand came up while the grab was on its way: let go at once rather than hold a badge nobody is moving.
      await api.releaseCells(state.cells)
      return
    }
    state.phase = 'held'
    armHoldIdle()
  } catch (error) {
    if (groupDrag !== state) return
    state.phase = 'refused'
    state.refusal = planErrorMessage(error)
    sayRefusal(locationRefusal(error))
    refreshHolders()
  }
}

/** A drag step: companions follow, and the hold's clock is reset -- or the badge is taken back after an idle release. */
function onGroupDrag(leaderId) {
  dragCompanions(leaderId)
  const state = groupDrag
  if (!state || state.leaderId !== leaderId) return
  // Everybody else sees the badge moving, not just the position it lands on (phase 4).
  if (state.phase !== 'refused') publishDrafts(state)
  if (state.phase === 'releasing') {
    state.movedWhileReleasing = true
    return
  }
  if (state.phase === 'idle') {
    reacquire(state)
    return
  }
  if (state.phase === 'held') armHoldIdle()
}

/** Carry the other ticked badges by the same amount the one under the finger has travelled so far. */
function dragCompanions(leaderId) {
  if (!groupDrag || groupDrag.leaderId !== leaderId) return
  const leader = markers.get(leaderId)
  const origin = groupDrag.roster.find((row) => row.id === leaderId)
  if (!leader || !origin) return
  const here = leader.getLatLng()
  const dLat = here.lat - origin.lat
  const dLng = here.lng - origin.lng
  for (const row of groupDrag.roster) {
    if (row.id === leaderId) continue
    const mate = markers.get(row.id)
    if (mate) mate.setLatLng([row.lat + dLat, row.lng + dLng])
  }
}

/** The distance the badges actually travelled, in metres, with the arithmetic the plan's own rule uses. */
function metresOf(dLat, dLng, lat) {
  const dx = dLng * 111320 * Math.cos((lat * Math.PI) / 180)
  const dy = dLat * 111320
  return Math.round(Math.hypot(dx, dy))
}

/** The gesture is over: the hand's reference goes, and the last reference takes the row with it (081). */
async function releaseHold(state) {
  clearTimeout(holdIdle)
  if (!state || !state.cells) return
  try {
    await api.releaseCells(state.cells)
  } catch {
    // A release that fails costs twelve seconds of a hold nobody is using, and nothing else.
  }
}

/** The strip's one way out of a refusal, offered only for a hold that is my own other window (081's p_take_over). */
function takeoverAction(frameId, changes, before, after, reason) {
  if (!TAKE_OVER.test(reason || '')) return null
  return { label: 'Edit it here anyway', run: () => takeOver(frameId, changes, before, after) }
}

/**
 * "Edit it here anyway": replay the move as the write it was going to be, with the take-over flag that reaches my own
 * other window and nothing else. That window learns about it the only way it can -- its next write is refused.
 */
async function takeOver(frameId, changes, before, after) {
  if (!frameId || !plan.value) return
  try {
    await api.placeCells(frameId, changes, { takeOver: true })
  } catch (error) {
    drawMarkers()
    sayRefusal(locationRefusal(error))
    refreshHolders()
    return
  }
  drawMarkers()
  refreshHolders()
  const frame = frames.value.find((f) => f.id === frameId)
  const where = frame ? ` at ${formatOffset(frame.t_s)}` : ''
  const movers = nameList(Object.keys(changes).map((id) => groupName(id)))
  edits.positions(frameId, before, after, `moved ${movers}${where}`)
  toast(`Moved ${movers}${where}. The other window will find out when it next writes.`, 'success', 5000)
}

async function endGroupDrag(leaderId) {
  const state = groupDrag
  try {
    await finishGroupDrag(leaderId, state)
  } finally {
    // Every way out of a gesture ends the ghost: a write that landed, a refusal, a click, a failure. The reload inside
    // the write has already put the real badge where the plan has it, so the ghost goes as the badge arrives.
    releaseDrafts(state)
  }
}

async function finishGroupDrag(leaderId, state) {
  const frame = selected.value
  const leader = markers.get(leaderId)
  const origin = state ? state.roster.find((row) => row.id === leaderId) : null
  clearTimeout(holdIdle)
  groupDrag = null
  if (!frame || !state || state.leaderId !== leaderId || !leader || !origin) {
    drawMarkers()
    return
  }
  // The grab may still be on its way when the hand comes up (a quick flick). Wait for the answer, because what
  // happens next depends on it: a badge somebody else holds is not written at all.
  if (state.grab) await state.grab
  // The idle release may still be on its way too, and its DELETE must not land after the write's INSERT: that would
  // take the hold away from a write in flight, which reads as "somebody else took it" for no reason at all.
  if (state.release) {
    try {
      await state.release
    } catch {
      // releaseCells() does not throw; a release that failed is the database's twelve seconds either way.
    }
  }
  const here = leader.getLatLng()
  const dLat = here.lat - origin.lat
  const dLng = here.lng - origin.lng
  // A badge that came back to where it started is a click, not an edit.
  if (Math.abs(dLat) < 1e-9 && Math.abs(dLng) < 1e-9) {
    await releaseHold(state)
    drawMarkers()
    return
  }
  // The payload is the badges that moved, and only those: 082 writes one cell per row, so a badge nobody touched
  // is not in the write and cannot be put back to how this page last read it. restatedPositions() still builds the
  // pair below, because the undo stack remembers a whole map and the inverse has to be able to restore one.
  const changes = {}
  for (const row of state.roster) {
    // The flags come with the coordinates (046). Dragging a badge says where the group now stands; it does not put an
    // off-site group back on the map, nor make a position somebody had to confirm trusted again. The resolved point
    // is the one to ask, because the frame may be inheriting it rather than stating it.
    const at = framePosition(frame, row.id)
    changes[row.id] = { lat: row.lat + dLat, lng: row.lng + dLng, state: at?.state, verify: at?.verify }
  }
  // Where the frame's statements stood before the drag, and where they stand after it: both whole maps, because that
  // is what the undo stack stores, and because the pair is what makes the gesture reversible (step 13).
  const before = restatedPositions(frame)
  const after = restatedPositions(frame, changes)
  // Refused while the hand was still down: the badge belongs to somebody else, so nothing is written. It goes back
  // where the plan has it, and the strip -- already saying who -- is the other half of the answer.
  if (state.phase === 'refused') {
    await releaseHold(state)
    drawMarkers()
    sayRefusal(state.refusal, takeoverAction(frame.id, changes, before, after, state.refusal))
    return
  }
  pendingMoves = {
    frameId: frame.id,
    at: new Map(state.roster.map((row) => [row.id, { lat: changes[row.id].lat, lng: changes[row.id].lng }])),
  }
  try {
    await api.placeCells(frame.id, changes)
  } catch (error) {
    pendingMoves = null
    await releaseHold(state)
    drawMarkers() // the database was not changed; put every badge back where it has it
    // The product decision: a move stands locally and is only undone when the write really failed -- and a planner
    // who has just watched a badge jump back is owed the reason, in one sentence, in the place refusals live.
    const reason = planErrorMessage(error)
    sayRefusal(locationRefusal(error), takeoverAction(frame.id, changes, before, after, reason))
    refreshHolders()
    return
  }
  pendingMoves = null
  await releaseHold(state)
  drawMarkers()
  refreshHolders()
  const movers = nameList(state.roster.map((row) => groupName(row.id)))
  edits.positions(frame.id, before, after, `moved ${movers} at ${formatOffset(frame.t_s)}`)
  if (state.roster.length > 1) {
    toast(
      `${movers} moved together at ${formatOffset(frame.t_s)} — ${metresOf(dLat, dLng, origin.lat)} m.`,
      'success',
      3000,
    )
  } else {
    toast(`${groupName(leaderId)} moved to ${formatOffset(frame.t_s)}.`, 'success', 2200)
  }
}

// ---------- placing a group (QA 1 Nov) ----------

/** The groups the open frame says nothing about: no badge to drag, so the only way onto the map is a tap. */
const unplacedGroups = computed(() =>
  selected.value ? shownGroups.value.filter((g) => !framePosition(selected.value, g.id)) : [],
)

/** Arm the map: the next tap on it is where this group stands at the open frame. Pressing again disarms it. */
function startPlacing(groupId) {
  if (!props.canEdit || !selected.value) return
  if (blockedByErrors([selected.value.t_s], [groupId])) return
  placing.value = placing.value === groupId ? null : groupId
}

/**
 * The tap that places the armed group. It is a statement at the open frame like a drag is, so it is the same one
 * write: that badge, at that place (082). After a placement the next group still unplaced is armed, so a new plan is
 * a tap per group rather than a button and a tap per group.
 */
async function onMapClick(event) {
  const groupId = placing.value
  const frame = selected.value
  if (!groupId || !frame || !props.canEdit || busy.value) return
  if (blockedByErrors([frame.t_s], [groupId])) {
    placing.value = null
    return
  }
  const changes = { [groupId]: { lat: event.latlng.lat, lng: event.latlng.lng, state: 'on_site', verify: 'auto' } }
  const before = restatedPositions(frame)
  const after = restatedPositions(frame, changes)
  try {
    await api.placeCells(frame.id, changes)
  } catch (error) {
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
    return
  }
  edits.positions(frame.id, before, after, `placed ${groupName(groupId)} at ${formatOffset(frame.t_s)}`)
  toast(`${groupName(groupId)} placed at ${formatOffset(frame.t_s)}.`, 'success', 2200)
  await nextTick()
  const next = unplacedGroups.value[0]
  placing.value = next ? next.id : null
}

// ---------- the time bar ----------

const spanEnd = computed(() => {
  const last = frames.value.length ? Math.max(...frames.value.map((f) => f.t_s)) : 0
  return Math.max(last + 120, 600)
})

function widthOf(t_s) {
  return t_s * pxPerSecond.value
}

/** Left inset so the frame at T+0 is fully visible instead of being cut in half by the edge. */
const PAD_LEFT = 18

function xOf(t_s) {
  return PAD_LEFT + widthOf(t_s)
}

const trackWidth = computed(() => Math.max(xOf(spanEnd.value) + 60, 340))

const ticks = computed(() => {
  const steps = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
  const step = steps.find((s) => s * pxPerSecond.value >= 72) || 3600
  const out = []
  // A half-minute tick labelled "+1m" (the short form rounds to the minute) put two "+1m"s next to each other once the
  // bar was zoomed in. Under a minute the label carries its seconds.
  for (let t = 0; t <= spanEnd.value; t += step) {
    out.push({ t, label: step < 60 ? formatOffset(t) : formatOffsetShort(t) })
  }
  return out
})

function frameLeft(frame) {
  // While a stretch is being dragged, every selected dot travels together and the others stay where they are.
  const delta = dragState.value && selection.value.has(frame.id) ? dragState.value.delta : 0
  return xOf(frame.t_s + delta)
}

const sweepStyle = computed(() => {
  if (!sweep.value) return null
  const lo = Math.min(sweep.value.x0, sweep.value.x1)
  const hi = Math.max(sweep.value.x0, sweep.value.x1)
  return { left: `${lo}px`, width: `${Math.max(hi - lo, 2)}px` }
})

// ---------- playing the run (step 22) ----------

/** Stop the clock and keep the cursor where it is. */
function haltPlay() {
  playing.value = false
  if (playRaf) {
    cancelAnimationFrame(playRaf)
    playRaf = null
  }
}

function playLoop(nowMs) {
  playRaf = null
  if (!playing.value || playhead.value == null) return
  const step = playLast ? (nowMs - playLast) / 1000 : 0
  playLast = nowMs
  const end = frameOrder.value.length ? frameOrder.value[frameOrder.value.length - 1].t_s : 0
  playhead.value = Math.min(playhead.value + step * speed.value, end)
  // Twenty redraws a second: fast enough to read as motion, and most frames cost nothing.
  if (nowMs - playDrawnAt > 50) {
    playDrawnAt = nowMs
    drawMarkers()
  }
  if (playhead.value >= end) {
    haltPlay()
    drawMarkers()
    return
  }
  playRaf = requestAnimationFrame(playLoop)
}

/**
 * Start or resume the run. The selection is let go first: the strip's selection is what an edit acts on, and watching
 * the plan is not editing it -- an open frame under a moving clock is a frame the next keystroke would move. Live
 * reads are held for the same reason: a background read replaces the frames and redraws the badges under the clock.
 */
function startPlay() {
  if (!frames.value.length) return
  const end = Math.max(...frames.value.map((f) => f.t_s), 0)
  const first = frameOrder.value[0].t_s
  if (playhead.value == null || playhead.value >= end) playhead.value = first
  selection.value = new Set()
  selectedId.value = null
  groupDrag = null
  playing.value = true
  playLast = 0
  playDrawnAt = 0
  if (api.pauseLive) api.pauseLive(true)
  playRaf = requestAnimationFrame(playLoop)
  drawMarkers()
}

function pausePlay() {
  haltPlay()
  if (api.pauseLive) api.pauseLive(false)
}

/** Leave the run and open the moment the cursor was on, so editing picks up where the eye was. */
function stopPlay() {
  const at = playhead.value
  haltPlay()
  playhead.value = null
  if (api.pauseLive) api.pauseLive(false)
  if (at != null && frameOrder.value.length) {
    const frame = [...frameOrder.value].reverse().find((f) => f.t_s <= at) || frameOrder.value[0]
    selectOnly(frame.id)
    selectedId.value = frame.id
  }
  drawMarkers()
}

// ---------- the toolbar's menus, the rename dialog and the inspector's tabs ----------
const { openMenu, toggleMenu, closeMenu } = useOpenMenu()
function fromMenu(action) {
  closeMenu()
  action()
}
const inspectorTab = ref('frame') // 'frame' | 'groups'
const renaming = ref(false)
const renameValue = ref('')
function openRename() {
  renameValue.value = plan.value ? plan.value.name : ''
  renaming.value = true
}
function saveRename() {
  renaming.value = false
  renameTo(renameValue.value)
}
function planMeta(p) {
  return p.status + ' · ' + countLabel(p.frame_count || 0) + (p.status === 'live' ? ' · published' : '')
}
function clearGroups() {
  selectedGroups.value = new Set()
}

/**
 * Drag a frame dot. If it is part of a selection, the whole selection travels — that is the "push a chunk" gesture,
 * and it is one write at the end, not one per frame. A chunk moves rigidly: pushing it past T+0 stops at T+0 rather
 * than squashing its first frames onto it, because a compressed chunk is not what the hand did.
 */
function startDrag(frame, event) {
  if (!canMove.value || event.button !== 0) return
  // Shift+click is a selection gesture, not a drag. The click handler runs after this one and extends the selection
  // from the open frame, so picking the frame here first would leave the anchor on the frame just pressed and the
  // extension would collapse to a single frame.
  if (event.shiftKey) return
  // The same ordering rule as selectFrame: a field being edited commits on blur, and it commits to the frame that is
  // open at that moment, so the pointer must not move the selection until the field has let go.
  blurActive()
  // Dragging a dot that is not selected picks it first, the way every timeline behaves.
  if (!selection.value.has(frame.id)) selectOnly(frame.id)
  selectedId.value = frame.id
  const span = selectionSpan.value
  if (!span) return
  // Selecting a locked frame is fine, and is all this press does: it cannot be dragged until the errors are fixed.
  if (!selectedFrames.value.every((f) => editAllowed(errors.value, f.t_s))) return
  const startX = event.clientX
  dragState.value = { delta: 0, from_s: span.from_s, to_s: span.to_s }
  const move = (e) => {
    const raw = Math.round((e.clientX - startX) / pxPerSecond.value)
    const delta = Math.max(snap(raw, SNAP_S), -span.from_s)
    dragState.value = { delta, from_s: span.from_s, to_s: span.to_s }
  }
  const up = async () => {
    window.removeEventListener('pointermove', move)
    window.removeEventListener('pointerup', up)
    window.removeEventListener('pointercancel', up)
    const state = dragState.value
    if (!state || !state.delta) {
      dragState.value = null
      // Nothing was written, so nothing re-reads the plan: put back any redraw the gesture suppressed.
      drawMarkers()
      return
    }
    // The dots stay where the hand left them until the moved frames are read back (the frames watcher lets go of
    // the offset in the same render that brings the new times); clearing it now put them back for the length of
    // the write, then forward again (QA 1 Nov).
    dragState.value = { ...state, settling: true }
    await shiftStretch(state.from_s, state.delta, state.to_s)
    dragState.value = null
    drawLines()
    drawMarkers()
  }
  window.addEventListener('pointermove', move)
  window.addEventListener('pointerup', up)
  // A touch the browser takes over (a scroll) ends in pointercancel, never pointerup: without this the drag never
  // ended and the badges were never redrawn again.
  window.addEventListener('pointercancel', up)
}

// ---------- scrubbing: the cursor dragged by hand (QA 1 Nov) ----------

/** The time under a pointer on the strip, clamped to the plan. */
function timeAtClientX(clientX) {
  const inner = trackEl.value ? trackEl.value.querySelector('.pv-track-inner') : null
  if (!inner) return 0
  const end = frameOrder.value.length ? frameOrder.value[frameOrder.value.length - 1].t_s : 0
  const t = (clientX - inner.getBoundingClientRect().left - PAD_LEFT) / pxPerSecond.value
  return Math.min(Math.max(t, 0), end)
}

/**
 * Press on the ruler (or grab the cursor) and drag: the cursor follows the hand and the map shows where everyone is
 * at that instant, so any moment can be looked at without playing from the start. Letting go leaves the cursor there,
 * paused; Resume plays on from it and Stop opens the frame it is on.
 */
function startScrub(event) {
  if (!frames.value.length || (event.pointerType === 'mouse' && event.button !== 0)) return
  blurActive()
  haltPlay()
  selection.value = new Set()
  selectedId.value = null
  placing.value = null
  groupDrag = null
  scrubbing.value = true
  if (api.pauseLive) api.pauseLive(true)
  const go = (e) => {
    playhead.value = timeAtClientX(e.clientX)
    drawMarkers()
  }
  go(event)
  const up = () => {
    window.removeEventListener('pointermove', go)
    window.removeEventListener('pointerup', up)
    window.removeEventListener('pointercancel', up)
    scrubbing.value = false
    if (api.pauseLive) api.pauseLive(false)
    drawMarkers()
  }
  window.addEventListener('pointermove', go)
  window.addEventListener('pointerup', up)
  window.addEventListener('pointercancel', up)
}

/**
 * Sweep across the bar to select the run it touches: the gesture people already know from a video editor. A sweep
 * that covers no ground is a click on empty bar, which clears the selection — that is how you put the plan down.
 */
function startSweep(event) {
  if (event.pointerType && event.pointerType !== 'mouse') {
    startStripTouch(event)
    return
  }
  if (!props.canEdit || event.button !== 0) return
  const left = event.currentTarget.getBoundingClientRect().left
  const x0 = event.clientX - left
  sweep.value = { x0, x1: x0 }
  const move = (e) => {
    if (sweep.value) sweep.value = { x0, x1: e.clientX - left }
  }
  const up = (e) => {
    window.removeEventListener('pointermove', move)
    window.removeEventListener('pointerup', up)
    window.removeEventListener('pointercancel', up)
    const walked = sweep.value
    sweep.value = null
    // A gesture the browser took over is not a sweep: nothing was chosen, so nothing is said.
    if (!walked || e.type === 'pointercancel') return
    const lo = Math.min(walked.x0, walked.x1)
    const hi = Math.max(walked.x0, walked.x1)
    if (hi - lo < 4) {
      selection.value = new Set()
      selectedId.value = null
      return
    }
    // A dot is 22 px wide and drawn centred on its time, so a sweep that comes within half a dot has touched it.
    const ids = frames.value.filter((f) => xOf(f.t_s) >= lo - 11 && xOf(f.t_s) <= hi + 11).map((f) => f.id)
    selection.value = new Set(ids)
    const first = frames.value.find((f) => f.id === ids[0])
    selectedId.value = first ? first.id : null
    if (!ids.length) toast('No frame in that stretch. Sweep closer to the dots.', 'warning', 2600)
  }
  window.addEventListener('pointermove', move)
  window.addEventListener('pointerup', up)
  window.addEventListener('pointercancel', up)
}

/**
 * A finger on the strip (QA 1 Nov, on an iPhone and an Android phone). A swipe there is the browser scrolling the
 * strip, never a sweep: treating it as one drew a grey band, then said "No frame in that stretch" for every swipe.
 * A tap (the finger came up where it went down) opens the frame nearest to it, within a finger's width -- a frame
 * dot is 12 px tall, and a tap a few pixels off it used to land on the empty strip and clear the selection instead.
 * A tap nowhere near a frame lets the selection go, as a click on empty bar does.
 */
const TAP_SLOP_PX = 10
const TAP_REACH_PX = 28
function startStripTouch(event) {
  const x0 = event.clientX
  const y0 = event.clientY
  const left = event.currentTarget.getBoundingClientRect().left
  const done = (e) => {
    window.removeEventListener('pointerup', done)
    window.removeEventListener('pointercancel', done)
    if (e.type === 'pointercancel') return // the browser scrolled the strip
    if (Math.hypot(e.clientX - x0, e.clientY - y0) > TAP_SLOP_PX) return
    const x = x0 - left
    let nearest = null
    for (const frame of frames.value) {
      const d = Math.abs(xOf(frame.t_s) - x)
      if (d <= TAP_REACH_PX && (!nearest || d < nearest.d)) nearest = { frame, d }
    }
    if (nearest) {
      selectFrame(nearest.frame.id)
      return
    }
    if (!props.canEdit) return
    selection.value = new Set()
    selectedId.value = null
  }
  window.addEventListener('pointerup', done)
  window.addEventListener('pointercancel', done)
}

function countLabel(n) {
  return `${n} frame${n === 1 ? '' : 's'}`
}

// Frames can be a second apart, and a dot is 16 px across: this is the zoom that tells them apart
const MAX_PX_PER_SECOND = 34

function zoom(factor) {
  pxPerSecond.value = Math.min(MAX_PX_PER_SECOND, Math.max(0.08, pxPerSecond.value * factor))
}

// ---------- writing frames ----------

/**
 * Open a frame, and decide what is selected with it. Shift extends from the open frame to the one clicked.
 *
 * There is deliberately no Ctrl+click to pick frames out of the middle. A stretch is named by its two times when it
 * is pushed (044), so a selection with a hole in it would move the frames in the hole too. "Select these three and
 * not the one between them" is therefore not a thing this board can honour, and offering the gesture anyway would
 * move something the planner had just unticked.
 */
function selectFrame(id, event) {
  const frame = frames.value.find((f) => f.id === id)
  if (!frame) return
  // A click on the strip while a run is on means "work on this moment": leave the run where the cursor is and open it.
  if (playhead.value != null) {
    haltPlay()
    playhead.value = null
    if (api.pauseLive) api.pauseLive(false)
  }
  // Give the keyboard back before the selection moves: a field that is being edited saves itself when it loses
  // focus, and its handler reads the open frame -- so the open frame has to still be the one the field showed.
  blurActive()
  const anchor = frames.value.find((f) => f.id === selectedId.value)
  if (event && event.shiftKey && anchor) {
    selection.value = new Set(framesBetween(anchor.t_s, frame.t_s))
  } else {
    selectOnly(id)
  }
  selectedId.value = id
}

/**
 * Take the keyboard away from whatever field has it. Clicking the bar means "work on this frame", and the dot's
 * pointerdown is prevented so a drag can start, which also means the browser never moves focus for us: without this
 * the keyboard still belongs to whichever input was used last, and the planner's next keystroke edits a field they
 * are no longer looking at. Blurring also commits that field, which is why it runs before the selection changes.
 */
function blurActive() {
  const active = document.activeElement
  if (active && active !== document.body && typeof active.blur === 'function') active.blur()
}

/**
 * A frame as the undo stack remembers it: its identity and its statements, never the object. A copy is what makes a
 * delete undoable -- the row is gone from the plan, so the only place its note and its positions still exist is here.
 * `positions` is the frame's OWN map (the same shape frame_save takes), flags included.
 */
function frameCopy(frame) {
  return { id: frame.id, t_s: frame.t_s, note: frame.note || null, positions: restatedPositions(frame) }
}

/**
 * The confidences an edit is about to change, as they stand now: `[{frameId, groupId, verify}]`, one per position the
 * frames actually state. A position that is merely carried into a frame has no row there to confirm, so it is not a
 * pair -- and the flag write would skip it anyway. Used by the undo stack to put the flags back one pair at a time.
 */
function verifyPairs(list, targets) {
  const pairs = []
  for (const frame of list) {
    for (const group of targets) {
      const at = framePosition(frame, group.id)
      if (at && at.defined) pairs.push({ frameId: frame.id, groupId: group.id, verify: at.verify })
    }
  }
  return pairs
}

async function addFrame() {
  if (!plan.value || blockedByErrors()) return
  const last = frames.value.length ? Math.max(...frames.value.map((f) => f.t_s)) : 0
  const t = frames.value.length ? snap(last + 60, SNAP_S) : 0
  try {
    await api.saveFrame({ t_s: t, positions: effectiveAt(t) })
    await nextTick()
    const created = frames.value.find((f) => f.t_s === t)
    if (created) {
      selectOnly(created.id)
      selectedId.value = created.id
      // A frame that was just made can be just unmade: the copy carries its identity, so the redo re-creates the
      // same frame rather than a lookalike (step 13).
      edits.created(frameCopy(created), `added a frame at ${formatOffset(t)}`)
    }
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Copy every group's position *as it stands at this frame*, not just the ones this frame happens to state.
 * Otherwise a group that was inheriting its position is silently left out of the copy, and pasting it
 * reproduces a subset of where everyone actually was. snapshotAt() does that resolution on the resolved
 * tracks, so the clipboard is a plain position map and the paste stays a single write.
 *
 * It copies the *open* frame, never the whole selection: pasting a stretch is a different feature, and quietly
 * copying only the first frame of a selection of five would be worse than copying one frame and saying which.
 */
function copyFrame() {
  const frame = selected.value
  if (!frame) return
  clipboard.value = { t_s: frame.t_s, note: frame.note, positions: snapshotAt(tracks.value, frame.id) }
  toast(`Copied ${formatOffset(frame.t_s)}. Paste it, then drag it to the time you want.`, 'success', 3000)
}

// Duplicate: the open frame again, straight away, and the clipboard left as it was
function duplicateFrame() {
  const frame = selected.value
  if (!frame) return
  saveFrameCopy({ note: frame.note, positions: snapshotAt(tracks.value, frame.id) }, 'duplicated')
}

function pasteFrame() {
  if (clipboard.value) saveFrameCopy(clipboard.value, 'pasted')
}

async function saveFrameCopy(from, word) {
  if (!plan.value || blockedByErrors()) return
  const last = frames.value.length ? Math.max(...frames.value.map((f) => f.t_s)) : 0
  const t = snap(last + 60, SNAP_S)
  try {
    // One write, not two: the earlier version created the frame and then overwrote it, so a failure on the
    // second call left a frame holding the wrong positions.
    await api.saveFrame({ t_s: t, positions: from.positions, note: from.note })
    const created = frames.value.find((f) => f.t_s === t)
    if (created) {
      selectOnly(created.id)
      selectedId.value = created.id
      edits.created(frameCopy(created), `${word} a frame at ${formatOffset(t)}`)
    }
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * "Hold one group": state the target groups again, where they already stand, at a later moment — one call (045), and
 * nothing else on that later frame changes, so a frame that already says somebody else keeps saying them. That is
 * the spec's "hold one group; rewrite that group's future spans so its next move happens later", in the only
 * vocabulary a plan has. The database refuses the two versions of it that would not mean what the word means: a
 * group that moves before the moment asked for, and a frame at that moment that already puts it somewhere else.
 */
async function hold(seconds) {
  const frame = selected.value
  if (!frame || !plan.value) return
  const targets = standingTargets.value
  if (!targets.length) {
    toast('Tick a group to hold it, or place one at this frame first.', 'warning', 3600)
    return
  }
  if (blockedByErrors([frame.t_s], targets.map((g) => g.id))) return
  const label = standingLabel.value
  const plural = targets.length > 1
  // The later frame as it stands now, if it stands at all: a hold either writes rows into it or invents it, and
  // either way the state before the call is what an undo has to put back (step 13).
  const target = frames.value.find((f) => f.t_s === frame.t_s + seconds) || null
  try {
    const result = await api.holdFrame(frame.id, seconds, targets.map((g) => g.id))
    const written = result?.positions_written ?? 0
    const at = formatOffset(result?.held_t_s ?? frame.t_s + seconds)
    if (!written) {
      toast(`${label} already ${plural ? 'stand' : 'stands'} there at ${at}.`, 'warning', 3600)
      return
    }
    const held = frames.value.find((f) => f.id === result?.held_frame_id) || null
    if (held) {
      edits.held(
        {
          frameId: held.id,
          added: (result?.frames_added ?? 0) > 0,
          before: target ? restatedPositions(target) : null,
          after: restatedPositions(held),
          frame: frameCopy(held),
        },
        `held ${label} at ${formatOffset(frame.t_s)}`,
      )
    }
    toast(`Held ${label} at ${formatOffset(frame.t_s)} until ${at}.`, 'success', 4000)
  } catch (error) {
    // A hold that would write over a badge in somebody's hand, or bump a moment they are retiming (083).
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 7000)
  }
}

// ---------- flags: off site, and how much the plan may trust a position ----------

/**
 * Take a group off the map at the open frame, or put it back on.
 *
 * Off site is a STATEMENT about this moment, so it is written at this moment: a frame that only inherits a position
 * has to gain a row here, or the earlier on-site sentence keeps standing. The write is that one badge (082), with
 * the place the row already holds — the plan does not know where the group went, and inventing a place is a
 * different edit (a drag, once there is a badge again).
 */
async function setGroupState(groupId, next) {
  const frame = selected.value
  if (!frame || !props.canEdit) return
  if (blockedByErrors([frame.t_s], [groupId])) return
  const at = framePosition(frame, groupId)
  if (!at) {
    toast('Place the group at this frame first — there is nothing to take off the map.', 'warning', 3600)
    return
  }
  if (at.state === next) return
  const changes = { [groupId]: { lat: at.lat, lng: at.lng, state: next, verify: at.verify } }
  const before = restatedPositions(frame)
  const after = restatedPositions(frame, changes)
  try {
    await api.placeCells(frame.id, changes)
    edits.positions(
      frame.id,
      before,
      after,
      next === 'off_site'
        ? `took ${groupName(groupId)} off site at ${formatOffset(frame.t_s)}`
        : `put ${groupName(groupId)} back on site at ${formatOffset(frame.t_s)}`,
    )
    toast(
      next === 'off_site'
        ? `${groupName(groupId)} is off site at ${formatOffset(frame.t_s)}.`
        : `${groupName(groupId)} is back on site at ${formatOffset(frame.t_s)}.`,
      'success',
      3000,
    )
  } catch (error) {
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Confirm one position by hand, or let the app trust it again — through the batch function (047) even for one row,
 * so the board has a single code path and a single answer: how many positions changed. Only a position this frame
 * states can be confirmed here; a frame that carries the position forward has no row of its own to flag, which is
 * what the disabled chip says.
 */
async function setGroupVerify(groupId, next) {
  const frame = selected.value
  if (!frame || !props.canEdit) return
  if (blockedByErrors([frame.t_s], [groupId])) return
  const at = framePosition(frame, groupId)
  if (!at) return
  if (at.verify === next) return
  const before = verifyPairs([frame], [{ id: groupId }])
  try {
    const result = await api.setVerify([frame.id], [groupId], next)
    const set = result?.positions_set ?? 0
    if (!set) {
      toast(
        `${groupName(groupId)} is carried into ${formatOffset(frame.t_s)}; open the frame that states it to confirm it.`,
        'warning',
        4000,
      )
      return
    }
    edits.verify(
      before,
      [{ frameId: frame.id, groupId, verify: next }],
      next === 'manual'
        ? `confirmed ${groupName(groupId)} by hand at ${formatOffset(frame.t_s)}`
        : `trusted ${groupName(groupId)} automatically at ${formatOffset(frame.t_s)}`,
    )
    toast(
      next === 'manual'
        ? `${groupName(groupId)} is confirmed by hand at ${formatOffset(frame.t_s)}.`
        : `${groupName(groupId)} is trusted automatically at ${formatOffset(frame.t_s)}.`,
      'success',
      3000,
    )
  } catch (error) {
    // A confirmation is a write on a cell somebody may be dragging, and it bumps the moment's revision (083).
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * The bulk state control: the same statement, for every group the flags act on, at the open frame. One call, because
 * a click is one statement: every badge it is about is written or none is (082).
 */
async function bulkState(next) {
  const frame = selected.value
  if (!frame || !props.canEdit) return
  const targets = standingTargets.value.filter((g) => framePosition(frame, g.id))
  if (!targets.length) {
    toast('Tick a group that stands here, or place one.', 'warning', 3600)
    return
  }
  if (blockedByErrors([frame.t_s], targets.map((g) => g.id))) return
  const changes = {}
  for (const group of targets) {
    const at = framePosition(frame, group.id)
    changes[group.id] = { lat: at.lat, lng: at.lng, state: next, verify: at.verify }
  }
  const before = restatedPositions(frame)
  const after = restatedPositions(frame, changes)
  try {
    await api.placeCells(frame.id, changes)
    const names = nameList(targets.map((g) => g.name))
    edits.positions(
      frame.id,
      before,
      after,
      next === 'off_site'
        ? `put ${names} off site at ${formatOffset(frame.t_s)}`
        : `brought ${names} back on site at ${formatOffset(frame.t_s)}`,
    )
    toast(
      `${nameList(targets.map((g) => g.name))} ${targets.length > 1 ? 'are' : 'is'} ${
        next === 'off_site' ? 'off site' : 'on site'
      } at ${formatOffset(frame.t_s)}.`,
      'success',
      3600,
    )
  } catch (error) {
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * The bulk confirmation: ticked groups (or everyone standing at the open frame) across the selected stretch, in one
 * call. The answer says what it could not reach — a frame that does not state a group has no position there to
 * confirm — so the toast can be honest instead of claiming more than was written.
 */
async function bulkVerify(next) {
  const frames = flagFrames.value
  const groups = standingTargets.value
  if (!frames.length || !groups.length) return
  if (blockedByErrors(frames.map((f) => f.t_s), groups.map((g) => g.id))) return
  const where = frames.length === 1 ? `at ${formatOffset(frames[0].t_s)}` : `across ${countLabel(frames.length)}`
  const word = next === 'manual' ? 'confirmed by hand' : 'trusted automatically'
  // What each of those positions was before the call: a stretch can hold both confidences, and an undo has to give
  // each row back the one it had (step 13).
  const before = verifyPairs(frames, groups)
  try {
    const result = await api.setVerify(frames.map((f) => f.id), groups.map((g) => g.id), next)
    const set = result?.positions_set ?? 0
    const skipped = result?.positions_skipped ?? 0
    if (set) {
      edits.verify(before, before.map((pair) => ({ ...pair, verify: next })), `${set} position${set === 1 ? '' : 's'} ${word} ${where}`)
      toast(
        `${set} position${set === 1 ? '' : 's'} ${word} ${where}${
          skipped ? ` — ${skipped} left alone, because those frames do not state them` : ''
        }.`,
        'success',
        4200,
      )
    } else if (skipped) {
      toast(
        `Nothing to confirm ${where}: those frames do not state ${groups.length > 1 ? 'those groups' : 'that group'}.`,
        'warning',
        4200,
      )
    } else {
      toast(`Already ${word} ${where}.`, 'warning', 3000)
    }
  } catch (error) {
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Move the open frame one frame along the strip, for the keyboard. With Shift it extends the selection instead, the
 * same way Shift+click does. This is also the only reliable way to reach a frame whose dot is underneath a
 * neighbour's at the current zoom (finding 25), which is why it lives with the selection model.
 */
function stepFrame(direction, extend) {
  if (!frames.value.length) return
  const index = frames.value.findIndex((f) => f.id === selectedId.value)
  const next = Math.min(frames.value.length - 1, Math.max(0, (index < 0 ? 0 : index) + direction))
  const frame = frames.value[next]
  if (frame) selectFrame(frame.id, { shiftKey: extend })
}

/**
 * The board's keys. Ctrl/Cmd + a letter are the toolbar's buttons for a planner who is working on the map rather than
 * reaching for it: C copy, V paste, Z undo, Y (or Shift+Z) redo. Three things are deliberately not shortcuts:
 *   * typing: Ctrl+C in the note or time field has to copy the words being typed, not the frame;
 *   * a question on screen: while the confirm dialog is up, the keys belong to it;
 *   * anyone who cannot edit: a member's board has no Copy, Paste, Delete or Undo to accelerate.
 * Delete (step 13) is the one destructive key, and it asks the same question the button asks -- next to the arrow
 * keys, a key that deleted without asking would be a trap. The arrow keys are unmodified and step the strip itself.
 *
 * A write already in flight keeps undo and redo out. Both of them read the frame's revision from what this tab has
 * read back, and during a write that read is one edit behind: the answer would be "someone else changed this", which
 * is the wrong sentence and a useless undo. The key is still claimed, so it never reaches the browser's own undo.
 */
function onKeydown(event) {
  if (!props.canEdit) return
  const target = event.target
  if (target && target.closest && target.closest('input, textarea, select, [contenteditable="true"]')) return
  if (document.querySelector('[data-testid=confirm-dialog]')) return

  const plain = !event.ctrlKey && !event.metaKey && !event.altKey
  if (plain && (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) {
    event.preventDefault()
    stepFrame(event.key === 'ArrowLeft' ? -1 : 1, event.shiftKey)
    return
  }
  if (plain && event.key === 'Delete') {
    event.preventDefault()
    deleteFromKeyboard()
    return
  }

  const accel = event.ctrlKey || event.metaKey
  if (!accel || event.altKey) return
  const key = String(event.key || '').toLowerCase()
  if (key === 'z') {
    event.preventDefault()
    if (busy.value) return
    if (event.shiftKey) runRedo()
    else runUndo()
    return
  }
  if (key === 'y' && !event.shiftKey) {
    event.preventDefault()
    if (busy.value) return
    runRedo()
    return
  }
  if (event.shiftKey) return
  if (key === 'c' && selected.value) {
    event.preventDefault()
    copyFrame()
  } else if (key === 'v' && clipboard.value) {
    event.preventDefault()
    pasteFrame()
  }
}

/**
 * Delete removes the open frame, after the question the button asks. A stretch is not one frame, so the key says so
 * instead of guessing which of the selected moments was meant.
 */
function deleteFromKeyboard() {
  const span = selectionSpan.value
  if (span && span.count > 1) {
    toast('That is a stretch of frames. Open the one you want to delete first.', 'warning', 3600)
    return
  }
  removeFrame()
}

/** Step back, then put the planner on the frame the change was about (an undone delete gives one back). */
async function runUndo() {
  const command = await edits.undo()
  if (command) revealFrame(edits.focusOf(command))
}

async function runRedo() {
  const command = await edits.redo()
  if (command) revealFrame(edits.focusOf(command))
}

/**
 * Open the frame an undo or a redo left the plan at, or let the selection go when that frame is now gone: an undone
 * paste takes away the frame that was open, and the inspector must not go on describing a frame that is not there.
 */
function revealFrame(frameId) {
  const frame = frameId ? frames.value.find((f) => f.id === frameId) : null
  if (frame) {
    selectOnly(frame.id)
    selectedId.value = frame.id
    return
  }
  if (selectedId.value && !frames.value.some((f) => f.id === selectedId.value)) {
    selection.value = new Set()
    selectedId.value = null
  }
}

async function removeFrame() {
  const frame = selected.value
  if (!frame) return
  if (blockedByErrors([frame.t_s])) return
  if (!(await askConfirm({ title: `Delete the frame at ${formatOffset(frame.t_s)}?`, confirmText: 'Delete', danger: true }))) return
  // What is about to be deleted, kept before the write: the row is gone afterwards, so this copy is the only place
  // the frame's note and its positions still exist (step 13, and 041 is why the id can be reused).
  const copy = frameCopy(frame)
  try {
    await api.deleteFrame(frame.id, frame.rev)
    selection.value = new Set()
    selectedId.value = null
    edits.deleted(copy, `deleted the frame at ${formatOffset(copy.t_s)}`)
  } catch (error) {
    // A delete refused because somebody's hand is in the moment (083): the strip, not a toast. The sentence names
    // them and says the moment cannot be deleted yet, which is the whole story.
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Save a frame's note, but only when it actually changed: leaving a field that still says what it said is not an
 * edit, and one write per tab-out would bump the revision for nothing.
 *
 * The field commits on blur rather than on change. `change` never fires for a value the browser does not consider
 * user-edited -- which is exactly what a typing harness produces, and what an autofilled or scripted value is --
 * so the note silently stayed on screen and never reached the plan. Blur is the moment the planner has finished
 * with the field, and Enter blurs it (below), so both paths commit.
 */
function commitNote(frameId, value) {
  const frame = frames.value.find((f) => f.id === frameId)
  if (!frame || !props.canEdit) return
  if (blockedByErrors([frame.t_s])) return
  const before = frame.note || ''
  if (before === (value || '')) return
  api
    .saveFrame({ id: frame.id, t_s: frame.t_s, rev: frame.rev, note: value })
    .then(() => edits.note(frame.id, before, value || '', `changed the note at ${formatOffset(frame.t_s)}`))
    .catch((error) => toast(planErrorMessage(error), 'danger', 5000))
}

async function setFrameTime(frameId, text, input = null) {
  const frame = frames.value.find((f) => f.id === frameId)
  if (!frame) return
  const t = parseOffset(text)
  if (t == null) {
    toast('Use +1:30 for a minute and a half, or 90s.', 'warning')
    return
  }
  if (t === frame.t_s) return
  if (blockedByErrors([frame.t_s])) {
    if (input) input.value = formatOffset(frame.t_s)
    return
  }
  const before_s = frame.t_s
  try {
    await api.moveFrame(frame.id, t, frame.rev)
    edits.time(frame.id, before_s, t, `moved the frame from ${formatOffset(before_s)} to ${formatOffset(t)}`)
  } catch (error) {
    // The field is bound to the frame's time, but a refused write leaves the frame where it was -- so the box would
    // otherwise keep saying the time the database just said no to. Put the truth back in it (finding 52).
    if (input) input.value = formatOffset(before_s)
    // A retime refused because somebody else is retiming the same moment (083) is the strip's; the box has already
    // been put back, so there is nothing to undo on screen.
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Push the selected stretch in time. The strip keeps its shape; only its timing moves, and the frames outside the
 * selection do not make room — a chunk pushed far enough passes over a frame that stays put (044 explains why that
 * is allowed). The count that comes back is what the database actually moved, so "0" can never be mistaken for
 * success: a stretch with no frame in it is refused, not counted.
 */
async function push(deltaSeconds) {
  const span = selectionSpan.value
  if (!span) return
  if (blockedByErrors(selectedFrames.value.map((f) => f.t_s))) return
  await shiftStretch(span.from_s, deltaSeconds, span.to_s)
}

/**
 * Move a stretch, and remember how to move it back. The frames it is about are read before the write, because after
 * it the strip has different times and the only thing that still names them is their ids (step 13).
 */
async function shiftStretch(from_s, delta, to_s) {
  const at = frames.value.filter((f) => f.t_s >= from_s && f.t_s <= to_s).map((f) => ({ id: f.id, t_s: f.t_s }))
  try {
    const moved = await api.shiftFrom(from_s, delta, to_s)
    edits.shift(
      { from_s, to_s, delta, frames: at },
      `${countLabel(moved)} moved by ${formatOffset(delta)}`,
    )
    toast(`${countLabel(moved)} moved by ${formatOffset(delta)}.`, 'success', 3000)
    return moved
  } catch (error) {
    // A stretch refused because somebody is retiming a moment in it (083): nothing moved, and the sentence says who.
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
    return 0
  }
}

// ---------- plans ----------

async function startCreate() {
  creating.value = true
  newPlanName.value = ''
  await nextTick()
}

async function confirmCreate() {
  const name = newPlanName.value.trim()
  if (!name) return
  try {
    await api.createPlan(name)
    creating.value = false
    await openFirstFrame()
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

async function choosePlan(id) {
  // Holds belong to the plan they were taken on: switching plans must not leave a badge held on a board nobody is
  // looking at (and the strip and the rings are about the plan that is now open).
  if (api.releaseAllHolds) await api.releaseAllHolds()
  await api.openPlan(id)
  // Where other planners' drags are going is about a plan too (phase 4): join that plan's channel, and leave whatever
  // channel was open before. `?concurrent=0` turns the stream off with the rest of the ownership picture.
  if (OWNERSHIP_UI && api.startDrafts) api.startDrafts(id)
  else if (api.stopDrafts) api.stopDrafts()
  clearGhosts()
  // The selection belongs to the plan that was open: ids from another plan mean nothing here.
  selectedGroups.value = new Set()
  await openFirstFrame()
  refreshHolders()
}

/**
 * Open the plan on its first frame, with just that frame selected.
 *
 * It waits a tick before framing, and that tick is load-bearing. Between the frames arriving and the selection
 * moving, the inspector is briefly looking at "nothing selected" — a much shorter panel, so the map is briefly much
 * shorter too. A fit taken then is a fit for half the height, and the board never refits afterwards, so the plan
 * opened zoomed several levels out (finding 39). Once the new selection has rendered, the panel is its real height.
 */
async function openFirstFrame() {
  const first = frames.value.length ? frames.value[0] : null
  selectOnly(first ? first.id : null)
  selectedId.value = first ? first.id : null
  await nextTick()
  if (map) map.invalidateSize({ pan: false })
  // A different plan is a different place. Fitting is skipped after the first time so a save cannot drag the map out
  // from under a drag, but a plan switch is not a save: without this the board opens the new plan still looking at
  // the previous one's corner, with none of its markers in view (finding 22's other half).
  fitted = false
  fittedWithFrames = false
  // The fit is never animated (see fitMap), because an animation started while the inspector is changing the map's
  // height finishes somewhere else: the same plan could open framed two different ways depending on the door it came
  // through (finding 39).
  fitMap()
}

async function fork() {
  if (!plan.value) return
  try {
    const copy = await api.forkPlan(plan.value.id)
    await openFirstFrame()
    // A copy of a running plan starts at the moment it was taken (053): say so, because "the original is
    // untouched" is not the whole story -- the walk before that moment is not on this copy at all.
    const cut = copy && copy.fork_cut_s != null ? copy.fork_cut_s : null
    toast(
      cut == null
        ? 'Duplicated. Edit this one; the original is untouched.'
        : `Copied from ${formatOffset(cut)}. Earlier moments stay on the original.`,
      'success',
      6000,
    )
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * Who is mid-edit on this plan, as the sentences the publish warning is made of: one line per person and the cell
 * they are on, so the planner can see what the version they are about to announce will not contain. The name and the
 * badge both come from `plan_lock_holders` -- the same read the rings are drawn from -- so the warning cannot name
 * somebody the board is not already showing as an editor.
 */
function midEditLines(rows) {
  return rows.map((row) => {
    const at = formatOffset(row.t_s)
    if (row.mine) {
      return row.kind === 'moment'
        ? `You are retiming ${at} in another window.`
        : `You have ${row.group_name || 'a badge'} at ${at} open in another window.`
    }
    const who = row.display_name || 'Somebody'
    return row.kind === 'moment'
      ? `${who} is retiming ${at}.`
      : `${who} is editing ${row.group_name || 'a badge'} at ${at}.`
  })
}

async function publish() {
  if (!plan.value) return
  // Publishing a plan that is already live is legitimate — it is how a change made ahead of the clock is announced
  // to everyone following it — so the button stays, and the question says which of the two things this is.
  const again = plan.value.status === 'live'
  if (blockedByErrors()) return
  // Warnings do not stop a publish, dismissed ones included, but the person publishing should see them once more
  const warned = problemCards.value.filter((p) => p.level === 'warning')
  const ok = await askConfirm({
    title: again ? `Publish "${plan.value.name}" again?` : `Publish "${plan.value.name}"?`,
    message:
      (again
        ? 'Everyone following it is told the timetable changed. Any other live plan stops.'
        : 'This becomes the timetable everyone follows. Any other live plan stops.') +
      (warned.length ? ` This plan has ${warned.length === 1 ? 'a warning' : warned.length + ' warnings'}:` : ''),
    lines: warned.map((p) => `${p.when}: ${p.title}. ${p.detail}`),
    confirmText: again ? 'Publish again' : 'Publish',
  })
  if (!ok) return

  // Decision 15: a publish is NOT blocked by somebody mid-edit -- they are drawing, not saving, and the plan as it
  // stands is still a thing worth announcing. It is a second question instead, naming them and their cells, because
  // the version being written is a snapshot: whatever they are still moving lands after it and needs another publish
  // to reach anybody. Read fresh rather than from the 2.5 s presence read: this is the one moment the answer matters.
  const editing = OWNERSHIP_UI && props.canEdit && api.lockHolders ? await api.lockHolders() : []
  if (editing.length) {
    const okBusy = await askConfirm({
      title: 'Somebody is editing this plan',
      message:
        'Publishing announces the plan as it stands now, so this version will not contain what they are still ' +
        'moving. Their change still lands, and needs another publish to reach everyone. Nobody is interrupted.',
      lines: midEditLines(editing),
      confirmText: 'Publish anyway',
    })
    if (!okBusy) return
  }

  try {
    // The revision this screen is showing goes with the request (step 18): the database refuses the publish if the
    // plan has moved on, rather than announcing a picture nobody is looking at any more.
    await api.publishPlan(plan.value.id, plan.value.rev)
    // A publish boundary ends the stack (step 13). A redo after this would put a pre-publish edit into a plan people
    // are already following, and an undo would rewrite a timetable that has been announced -- both are somebody's
    // decision to make again, not a keystroke's.
    edits.clear()
    toast(again ? 'Published again. Everyone following it will see the change.' : 'Published. This is now the plan people see.', 'success', 4000)
  } catch (error) {
    // A stale publish is not a dead end: re-read the plan so the next press publishes the plan as it now stands.
    // Nothing was announced by the refused call, and this tab's edits are already saved -- only the picture was old.
    if (error && error.code === 'PT409') await reloadPlan()
    toast(planErrorMessage(error), 'danger', 6000)
  }
}

/**
 * Catch up with the plan that was republished somewhere else (step 15). The live strip holds the revision this page
 * loaded; when a fresh read answers a newer one, this re-reads the plan and its frames and adopts the new revision.
 * The open frame is kept if it still exists -- a republished plan normally keeps its frame ids, and a planner who
 * was looking at +1:00 should still be -- and the undo stack starts again, because the plan people are following is
 * no longer the one this tab's inverses were built against.
 */
async function reloadPlan() {
  const id = plan.value ? plan.value.id : null
  if (!id) return
  try {
    await api.loadPlans()
    plan.value = plans.value.find((p) => p.id === id) || plan.value
    await api.loadFrames()
    await nextTick()
    if (selectedId.value && !frames.value.some((f) => f.id === selectedId.value)) {
      selection.value = new Set()
      selectedId.value = null
    }
    drawLines()
    drawMarkers()
    edits.clear()
  } catch (error) {
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

async function removePlan() {
  if (!plan.value) return
  const going = plan.value.id
  const ok = await askConfirm({
    title: `Delete "${plan.value.name}"?`,
    message: 'Its frames go with it. This cannot be undone.',
    confirmText: 'Delete plan',
    danger: true,
  })
  if (!ok) return
  try {
    await api.deletePlan(going)
    selectedId.value = null
    // The plan is gone, and so are the frames its commands name -- the stack has to go with it, stored copy included.
    // The id is passed explicitly because the plan is no longer readable from here.
    edits.clear(going)
    // The board was drawing the plan that is now gone. If this event has another plan, open it: without this the
    // toolbar sat with no plan under it -- an empty strip, the export and import buttons disabled, and a picker
    // showing a name nothing was reading (finding 88, hit by step 23's wipe-and-import).
    const next = readablePlan.value
    if (next) await choosePlan(next.id)
    else if (api.stopDrafts) api.stopDrafts() // nothing is open: the channel had one plan and that plan is gone
  } catch (error) {
    // Deleting a plan is refused while anybody is mid-edit anywhere in it (083): the same strip, the same sentence.
    if (!refusedBecauseHeld(error)) toast(planErrorMessage(error), 'danger', 5000)
  }
}

/**
 * The plan's name field. It is an edit like any other -- it changes the plan -- so it is on the stack too, and the
 * command holds the two names rather than a copy of the plan.
 */
async function renameTo(name) {
  if (!plan.value) return
  const before = plan.value.name
  if (name === before) return
  plan.value.name = name
  try {
    await api.renamePlan(plan.value.id, name)
    edits.planName(before, name, `renamed the plan to "${name}"`)
  } catch (error) {
    plan.value.name = before
    toast(planErrorMessage(error), 'danger', 5000)
  }
}

// ---------- the sheet: a plan in and out of a spreadsheet (step 23) ----------

/**
 * The plan as a CSV file: one row per group per moment, with the plan's own times and places.
 *
 * The file is made here and handed to `saveFile`, which is a download on a laptop and Android's Save screen in the
 * phone app. Nothing is read from the database to export it: the board already holds the plan, so exporting cannot
 * fail and cannot be stale.
 */
async function exportSheet() {
  if (!plan.value) return
  const name = sheetFileName(plan.value)
  try {
    const text = sheetText(plan.value, frames.value, groups.value)
    const saved = await saveFile(new TextEncoder().encode(text), name, 'text/csv;charset=utf-8')
    if (!saved) return // Android's Save screen was cancelled; nothing was saved and nothing should be claimed
    const count = frames.value.length
    toast(`Exported ${count} frame${count === 1 ? '' : 's'} as ${name}.`, 'success', 4000)
  } catch (error) {
    toast(`The sheet could not be saved: ${planErrorMessage(error)}`, 'danger', 6000)
  }
}

/** Open the file picker. Clearing the value first lets the same file be chosen twice in a row. */
function pickSheet() {
  if (!plan.value || !sheetFile.value || blockedByErrors()) return
  sheetFile.value.value = ''
  sheetFile.value.click()
}

/**
 * Read the chosen sheet, refuse it if it is not a plan, and import it if the planner says yes.
 *
 * THE ORDER IS THE POINT. A file is checked completely before anything is written: the reader's row-numbered
 * mistakes, then the 25 m rule in the board's own sentence, then a confirmation that names both counts and says the
 * plan's moments are replaced. Only then is the one call made -- and a refusal from the database (a plan whose actuals
 * have been marked, which the client cannot see) is shown in the same frame rather than as a toast that could be
 * missed. Nothing here touches a frame on the way to a refusal.
 */
async function onSheetPicked(event) {
  const input = event.target
  const file = input && input.files ? input.files[0] : null
  if (input) input.value = ''
  if (!file || !plan.value) return
  const target = plan.value

  let read
  try {
    read = readSheet(await file.text(), groups.value)
  } catch (error) {
    await askNotice({
      title: 'This sheet was not imported',
      message: `"${file.name}" could not be read. Nothing was changed.`,
      lines: [planErrorMessage(error)],
    })
    return
  }

  if (read.errors.length) {
    const more = read.errors.length > 6 ? [`…and ${read.errors.length - 6} more.`] : []
    await askNotice({
      title: 'This sheet was not imported',
      message: `"${file.name}" cannot be read as a plan. Nothing was changed.`,
      lines: [...read.errors.slice(0, 6).map((row) => `Row ${row.line}: ${row.message}`), ...more],
    })
    return
  }
  if (!read.frames.length) {
    await askNotice({
      title: 'This sheet was not imported',
      message: `"${file.name}" has no moments in it. Nothing was changed.`,
    })
    return
  }

  // The 25 m rule, in the same words the strip uses for the same pair of frames: a sheet whose walk cannot be walked
  // is refused before it is written, and the planner can see in the spreadsheet exactly which row to space out.
  const gaps = sheetGaps(read.frames)
  if (gaps.length) {
    await askNotice({
      title: 'This sheet was not imported',
      message:
        (gaps.length === 1 ? 'One walk in' : `${gaps.length} walks in`) +
        ` "${file.name}" ${gaps.length === 1 ? 'is' : 'are'} longer than the plan allows. Nothing was changed.`,
      lines: gaps.slice(0, 6).map((gap) => `${groupName(gap.groupId)}: ${gapDetail(gap)}`),
    })
    return
  }

  const positions = read.frames.reduce((sum, frame) => sum + Object.keys(frame.positions).length, 0)
  const had = frames.value.length
  const framesIn = read.frames.length
  const ok = await askConfirm({
    title: `Import "${file.name}" into "${target.name}"?`,
    message:
      had === 0
        ? 'Every moment in the file is added to the plan. This cannot be undone.'
        : `This replaces the plan's ${had} frame${had === 1 ? '' : 's'}. This cannot be undone.`,
    lines: [
      `${framesIn} frame${framesIn === 1 ? '' : 's'} and ${positions} position${positions === 1 ? '' : 's'} in the file.`,
      ...(target.status === 'live'
        ? ['This is the running timetable: nobody is told until you publish it again.']
        : []),
    ],
    confirmText: 'Import',
    danger: true,
  })
  if (!ok) return

  try {
    const summary = await api.importFrames(target.id, read.frames)
    // A sheet is the whole plan, so the frame-level inverses on the stack no longer describe it: replaying one would
    // write a single frame into the sheet's plan. A publish ends the stack for the same reason (step 13), and an
    // import is the larger boundary of the two.
    edits.clear()
    await openFirstFrame()
    // What the database wrote, not what the file said: `??` rather than `||`, because zero is a real answer.
    const gotFrames = summary.frames ?? framesIn
    const gotPositions = summary.positions ?? positions
    toast(
      `Imported ${gotFrames} frame${gotFrames === 1 ? '' : 's'} and ${gotPositions} position${gotPositions === 1 ? '' : 's'}.`,
      'success',
      6000,
    )
  } catch (error) {
    await askNotice({ title: 'This sheet was not imported', message: planErrorMessage(error) })
  }
}

// ---------- lifecycle ----------

/**
 * Build the map. Called from the ref watcher rather than onMounted, because in the app the board is rendered
 * only once the plans have loaded: at mount time the element does not exist yet, and Leaflet refuses a null
 * container. (The fixture harness had its data up front, so it never hit this.)
 */
function initMap() {
  if (map || !mapEl.value) return
  map = L.map(mapEl.value, { zoomControl: true, minZoom: 11, maxZoom: 20 }).setView([1.3521, 103.8198], 17)
  createOneMapLayer().addTo(map)
  zoneLayer = L.layerGroup().addTo(map)
  lineLayer = L.layerGroup().addTo(map)
  markerLayer = L.layerGroup().addTo(map)
  // The ghosts of other planners' drags live on a layer of their own, so drawing one can never disturb a badge (and
  // a badge being dragged is never below a marker layer that just got cleared).
  draftLayer = L.layerGroup().addTo(map)
  map.on('click', onMapClick)
  map.invalidateSize()
  drawZones()
  drawLines()
  drawMarkers()
  drawGhosts()
  fitMap()
}

onMounted(async () => {
  initMap()
  window.addEventListener('keydown', onKeydown)
  // Capture, so a gesture that stops its own propagation still pauses the background read.
  window.addEventListener('pointerdown', liveDown, true)
  window.addEventListener('pointerup', liveUp, true)
  window.addEventListener('pointercancel', liveUp, true)
  // Who else is editing, every few seconds while the board is open. It is the picture that makes a refusal
  // unsurprising -- and the read is cheap (one small list of live holds).
  if (OWNERSHIP_UI && props.canEdit) {
    refreshHolders()
    holdersTimer = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      refreshHolders()
    }, HOLDERS_MS)
  }
  await Promise.all([api.loadGroups(), api.loadZones(), api.loadPlans()])
  // Draw the locked areas BEFORE the first fit: the fit is what frames the plan, and the polygons are part of what
  // it frames (finding 22).
  drawZones()
  const first = readablePlan.value
  if (first) await choosePlan(first.id)
  boardReady.value = true
  // Redraw with the plan in place, then frame once more now that the board has its settled height: the inspector
  // only fills once a frame is open, and a camera framed for a mid-layout map opens the plan too far out. Since
  // `openFirstFrame` already waits a tick, this second fit is usually the same fit — it is the guarantee, not a
  // second opinion (findings 31 and 39). After it the view is the planner's.
  drawLines()
  drawMarkers()
  await nextTick()
  if (map) map.invalidateSize({ pan: false })
  fitted = false
  fitMap()
})

watch(mapEl, () => initMap())

// A pointer down on the board is the start of a gesture that owns the picture: a badge being dragged, a frame being
// moved, a stretch being swept. A change read from another tab in the middle of one redraws the markers and the
// gesture dies with them, so the background read waits for the hand to come up (usePlan.pauseLive) -- and the marker
// layer is not redrawn either, from the press itself: the drag that Leaflet starts is bound to the marker element that
// a redraw would replace, so suppressing a reload is not enough on its own.
const pointerDown = ref(false)
let pointerTimer = null

function liveDown() {
  pointerDown.value = true
  clearTimeout(pointerTimer)
  pointerTimer = setTimeout(() => (pointerDown.value = false), 5000) // a lost pointerup must not freeze the board
  if (api.pauseLive) api.pauseLive(true)
}
function liveUp() {
  pointerDown.value = false
  clearTimeout(pointerTimer)
  if (api.pauseLive) api.pauseLive(false)
}

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown)
  window.removeEventListener('pointerdown', liveDown, true)
  window.removeEventListener('pointerup', liveUp, true)
  window.removeEventListener('pointercancel', liveUp, true)
  clearTimeout(pointerTimer)
  clearTimeout(holdIdle)
  clearTimeout(refusalTimer)
  clearInterval(holdersTimer)
  // A page that is going away is not dragging anything: give up whatever this page still holds rather than leave a
  // colleague waiting out the twelve seconds.
  if (api.releaseAllHolds) api.releaseAllHolds()
  // And leave the draft channel: nothing this page is dragging should go on being drawn on anybody's screen.
  if (api.stopDrafts) api.stopDrafts()
  clearGhosts()
  haltPlay()
  if (map) {
    map.remove()
    map = null
  }
})

watch([frames, selectedId, () => zones.value.length], async () => {
  drawLines()
  drawMarkers()
  fitMap()
  await nextTick()
  // `pan: false`, deliberately. Bare invalidateSize() pans by half the difference between the size Leaflet last
  // saw and the container's size now, so the first save after the inspector changed height nudged the whole map by
  // seven pixels -- a jump the planner did not ask for, on the one surface whose camera is theirs. This call is
  // only here to notice a resize, not to move anything.
  if (map) map.invalidateSize({ pan: false })
})

watch(() => zones.value.length, () => { drawZones(); fitMap() })
watch(selectedId, () => {
  drawMarkers()
  drawGhosts() // what a colleague is dragging belongs to the moment that is open
})
// Who is on what changes the rings and the tooltips, never a position. drawMarkers() already refuses to run while a
// hand is down, so a poll cannot pull the badge out from under a drag -- it is drawn on the redraw the drop makes.
// The ghosts are redrawn too: a holder's name is the only honest source for "who is moving that".
watch(holders, () => {
  drawMarkers()
  drawGhosts()
})
// Other planners' drags arrive here: a broadcast, never a write (phase 4). drawGhosts() is the whole of what this page
// does with one.
watch(drafts, drawGhosts)
// A tap waiting to place a group belongs to the frame it was armed on; another frame, or a run, puts it down.
watch([selectedId, playhead], () => {
  if (placing.value && (playhead.value != null || !unplacedGroups.value.some((g) => g.id === placing.value))) {
    placing.value = null
  }
})
// The moved frames have been read back: let go of the drag's offset in the same render that draws their new times.
watch(
  frames,
  () => {
    if (dragState.value && dragState.value.settling) dragState.value = null
  },
  { flush: 'sync' },
)
// Every frame read is followed by the database's verdict on the whole plan, so an edit can never leave the board
// saying less than the gate would. `immediate` covers the preview harness, which starts with frames in hand.
watch(frames, refreshProblems, { immediate: true })
// A fix on show was worked out from the plan as it stood: if the plan moves under it, it is out of date
watch(frames, () => {
  if (walkFix.value && !applyingFix) cancelWalkFix()
})
watch(() => (plan.value ? plan.value.id : null), () => {
  shownProblemId.value = ''
  readDismissed()
}, { immediate: true })
// A tick in the inspector is a change to the picture, not a change to the plan: redraw, never reload.
watch(selectedGroups, () => {
  drawLines()
  drawMarkers()
})
// The group list arrives with the page; if the member's own group is known later than the frames, redraw once.
watch(shownGroups, () => {
  drawLines()
  drawMarkers()
  drawGhosts()
})

// Another tab's change is already in `frames` (usePlan read it back, step 19). This only lets go of what that read
// has taken away: an open frame somebody else deleted, and the selection that named it. Nothing is read here -- the
// frames watcher above does the drawing.
watch(
  () => (api.changeTick ? api.changeTick.value : 0),
  async () => {
    await nextTick()
    if (!selectedId.value || frames.value.some((f) => f.id === selectedId.value)) return
    selectedId.value = null
    selection.value = new Set()
  },
)
</script>

<template>
  <div class="pv">
    <div v-if="!loading && (!readablePlan || props.onlyGroupId === 'none')" class="pv-board is-empty" style="grid-template-columns: 1fr">
      <div class="pv-toolbar">
        <h2 class="pv-board-title">{{ props.onlyGroupId ? 'Your plan' : 'Planning' }}</h2>
      </div>
      <EmptyState v-if="props.onlyGroupId === 'none'" icon="people" title="You're not in a group yet" text="Ask a planner to add you to one." data-testid="plan-empty" />
      <EmptyState v-else-if="props.onlyGroupId" icon="plan" title="No plan yet" text="Your group's plan appears here once a planner publishes it." data-testid="plan-empty" />
      <EmptyState v-else icon="plan" title="No plans yet" data-testid="plan-empty">
        <template v-if="props.canEdit && !zones.length">
          <RouterLink :to="{ name: 'event', params: { id: props.eventId, page: 'map' } }">Draw your zones on the Map page</RouterLink>, then create a plan.
        </template>
        <template v-else-if="props.canEdit">Name a plan, then place each group frame by frame.</template>
        <template v-else>A planner hasn't made one yet.</template>
        <template v-if="props.canEdit" #actions>
          <form class="pv-empty-create" @submit.prevent="confirmCreate">
            <input v-model="newPlanName" class="pv-input" placeholder="Name the first plan" aria-label="Plan name" />
            <button type="submit" class="pv-btn is-primary" :disabled="busy || !newPlanName.trim()">Create plan</button>
          </form>
        </template>
      </EmptyState>
    </div>

    <div v-else class="pv-board" :aria-busy="busy || loading ? 'true' : null">
      <header class="pv-board-head">
      <div class="k k2-h k2-planbar">
        <div v-if="!props.onlyGroupId" class="wrapm" data-menu>
          <button type="button" class="k2-planbtn" :aria-expanded="openMenu === 'plans' ? 'true' : 'false'" data-testid="plan-picker" @click="toggleMenu('plans')">
            <span style="display: flex; flex-direction: column; line-height: 1.15; min-width: 0"><b class="text-truncate">{{ plan ? plan.name : 'Plan' }}</b><span v-if="plan" class="text-truncate">{{ plan.status }} · {{ countLabel(frames.length) }}{{ plan.status === 'live' ? ' · published' : '' }}</span></span>
            <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"></path></svg>
          </button>
          <div v-if="openMenu === 'plans'" class="menu l k2-plans" role="menu">
            <button v-for="p in plans" :key="p.id" type="button" role="menuitemradio" class="opt" :aria-checked="plan && p.id === plan.id ? 'true' : 'false'" :data-testid="'plan-option-' + p.id" @click="closeMenu(); choosePlan(p.id)">
              <span style="display: flex; flex-direction: column; align-items: flex-start">{{ p.name }}<small>{{ planMeta(p) }}</small></span>
              <svg v-if="plan && p.id === plan.id" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5 9-10"></path></svg>
            </button>
            <template v-if="props.canEdit">
              <hr />
              <button type="button" role="menuitem" :disabled="busy" data-testid="plan-new" @click="fromMenu(startCreate)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>New plan</button>
              <button type="button" role="menuitem" :disabled="busy" data-testid="plan-duplicate" @click="fromMenu(fork)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 9h11v11H9zM5 15H4V4h11v1"></path></svg>Duplicate plan</button>
            </template>
          </div>
        </div>
        <strong v-else-if="plan" data-testid="plan-name">{{ plan.name }}</strong>

        <span v-if="plan && plan.status === 'live'" class="chip chip-ink">LIVE</span>
        <span v-if="props.onlyGroupId" class="chip chip-soft" data-testid="plan-own-group">your group only</span>
        <button
          v-if="problemBadge"
          type="button"
          class="chip pv-probs-badge"
          :class="errors.length ? 'chip-warn' : 'chip-soft'"
          data-testid="plan-blocked"
          :title="errors.length ? 'This plan is locked until the errors are fixed. Press to see them.' : 'Press to see the warnings.'"
          @click="revealProblems"
        >
          {{ problemBadge }}
        </button>
        <span class="sp"></span>

        <template v-if="props.canEdit">
          <button type="button" class="ib k2-hm" data-testid="undo" aria-label="Undo (Ctrl+Z)" :disabled="busy || !canUndo" title="Undo (Ctrl+Z)" @click="runUndo"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14 4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3"></path></svg></button>
          <button type="button" class="ib k2-hm" data-testid="redo" aria-label="Redo (Ctrl+Y)" :disabled="busy || !canRedo" title="Redo (Ctrl+Y)" @click="runRedo"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m15 14 5-5-5-5M20 9H10a6 6 0 0 0 0 12h3"></path></svg></button>
          <div class="wrapm" data-menu>
            <button type="button" class="ib" aria-label="Plan options" :aria-expanded="openMenu === 'more' ? 'true' : 'false'" data-testid="plan-more" @click="toggleMenu('more')"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true" style="stroke-width: 3"><path d="M5 12h.01M12 12h.01M19 12h.01"></path></svg></button>
            <div v-if="openMenu === 'more'" class="menu r" role="menu">
              <button type="button" role="menuitem" :disabled="busy || !plan" data-testid="plan-rename" @click="fromMenu(openRename)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"></path></svg>Rename plan</button>
              <button type="button" role="menuitem" data-testid="sheet-export" :disabled="busy || !plan || !frames.length" title="Download this plan as a CSV sheet, to read or edit in a spreadsheet" @click="fromMenu(exportSheet)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v12M7 11l5 5 5-5M4 20h16"></path></svg>Export CSV</button>
              <button type="button" role="menuitem" data-testid="sheet-import" :disabled="busy || !plan" title="Replace every moment of this plan from a CSV sheet" @click="fromMenu(pickSheet)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 16V4M7 9l5-5 5 5M4 20h16"></path></svg>Import CSV</button>
              <hr />
              <button type="button" role="menuitem" class="danger" :disabled="busy" data-testid="plan-delete" @click="fromMenu(removePlan)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"></path></svg>Delete plan</button>
            </div>
          </div>
          <!-- The whole plan as a file (step 23): the picker is hidden and the menu item is the product's own. -->
          <input ref="sheetFile" type="file" accept=".csv,text/csv" class="pv-file" data-testid="sheet-file" @change="onSheetPicked" />
          <button
            class="pv-btn is-primary kb kb-ink kb-sm"
            data-testid="plan-publish"
            type="button"
            :disabled="busy"
            :title="plan && plan.status === 'live' ? 'Send the updated timetable to everyone' : 'Make this the timetable everyone follows'"
            @click="publish"
          >
            {{ plan && plan.status === 'live' ? 'Publish again' : 'Publish' }}
          </button>
        </template>
      </div>

      <form v-if="creating" class="k row k2-createplan" @submit.prevent="confirmCreate">
        <input v-model="newPlanName" class="kin" style="height: 40px; flex: 1; min-width: 160px" data-testid="plan-create-name" placeholder="Plan name" aria-label="Plan name" />
        <button type="submit" class="kb kb-lime kb-sm" :disabled="busy || !newPlanName.trim()">Create</button>
        <button type="button" class="kb kb-ghost kb-sm" @click="creating = false">Cancel</button>
      </form>
      </header>

      <!-- Rename plan: one input, the same save as always -->
      <Teleport to="body">
        <div v-if="renaming" class="k k2-scrim" @click.self="renaming = false" @keydown.esc="renaming = false">
          <form class="modal k2-dialog" role="dialog" aria-modal="true" aria-label="Rename plan" data-testid="rename-dialog" @submit.prevent="saveRename">
            <h3>Rename plan</h3>
            <label class="lab" for="plan-rename-input">Plan name</label>
            <input id="plan-rename-input" v-model="renameValue" class="kin" style="width: 100%" data-testid="plan-rename-input" />
            <div class="row" style="margin-top: 20px; justify-content: flex-end">
              <button type="button" class="kb kb-ghost" @click="renaming = false">Cancel</button>
              <button type="submit" class="kb kb-lime" :disabled="!renameValue.trim()" data-testid="plan-rename-save">Save</button>
            </div>
          </form>
        </div>
      </Teleport>

      <!-- The running plan's revision, and the warning that it moved while this page was open (step 15). -->
      <PlanLive
        v-if="plan"
        :session="liveSession"
        :plan-id="plan.id"
        :plan-rev="typeof plan.rev === 'number' ? plan.rev : null"
        :api="api"
        @reload="reloadPlan"
      />

      <div class="pv-body">
      <!-- The placing class is on the stage, never on the map element: Leaflet keeps its own classes on that element
           (leaflet-container clips the map), and a Vue class binding there replaced them, so the map spilled over the
           page as soon as Place was pressed. -->
      <div class="pv-stage" :class="{ 'is-placing': !!placing }">
        <div ref="mapEl" class="pv-map"></div>

        <!-- The one strip for refusals: who has the badge, or that the move did not land. It sits at the top of the
             map, above the badges, and it is the only place a refusal is said -- a toast would be about a success, and
             it would vanish while the hand is still on the badge it is talking about. -->
        <div v-if="refusal" class="pv-strip" role="alert" data-testid="plan-refusal">
          <span class="pv-strip-text">{{ refusal.text }}</span>
          <button
            v-if="refusal.action"
            type="button"
            class="pv-btn is-quiet pv-strip-action"
            data-testid="plan-refusal-action"
            @click="runRefusalAction"
          >
            {{ refusal.action.label }}
          </button>
          <button
            type="button"
            class="pv-strip-close"
            title="Dismiss"
            aria-label="Dismiss"
            data-testid="plan-refusal-dismiss"
            @click="clearRefusal"
          >
            ×
          </button>
        </div>

        <!-- Who else is editing, and what: the stack answers "why will that badge not move?" before the planner has to
             find out by trying. Nothing here decides anything -- the database does. -->
        <div
          v-if="editors.length"
          class="pv-presence"
          data-testid="plan-presence"
          :title="editors.map(editorTitle).join(' ')"
        >
          <span
            v-for="editor in editors.slice(0, 4)"
            :key="editor.key"
            class="pv-presence-chip"
            data-testid="plan-presence-chip"
            :data-editor="editor.name"
            :title="editorTitle(editor)"
          >
            <span class="pv-presence-initials">{{ editor.initials }}</span>
            <span class="pv-presence-name">{{ editor.name }}</span>
            <span class="pv-presence-count">{{ editor.cells.length }}</span>
          </span>
          <span v-if="editors.length > 4" class="pv-presence-chip" data-testid="plan-presence-more">
            +{{ editors.length - 4 }} more
          </span>
        </div>

        <div class="pv-hint" :class="{ 'is-placing': !!placing }" data-testid="board-hint">
          <template v-if="placing && selected">
            Tap the map where <strong>{{ groupName(placing) }}</strong> stands at {{ formatOffset(selected.t_s) }}.
            <button type="button" class="pv-btn is-quiet" data-testid="place-cancel" @click="placing = null">Cancel</button>
          </template>
          <template v-else-if="playhead != null">
            {{ playText }}<template v-if="playing"> · playing at {{ speed }}×</template>
          </template>
          <template v-else-if="selectionSpan && selectionSpan.count > 1">
            {{ countLabel(selectionSpan.count) }}, {{ formatOffset(selectionSpan.from_s) }} → {{ formatOffset(selectionSpan.to_s) }}<template v-if="canMove"> — drag one to move them all.</template>
          </template>
          <template v-else-if="selected">Frame {{ formatOffset(selected.t_s) }} · <template v-if="moveLock && props.canEdit">locked, unlock to drag.</template><template v-else-if="props.canEdit"><template v-if="dragTargets.length > 1">drag any of the {{ dragTargets.length }} ticked groups to move them together.</template><template v-else>drag a badge to move a group.</template></template><template v-else>where your group is at this moment.</template></template>
          <!-- A plan with no moments has nothing on the bar to pick (QA 1 Nov): say what comes first instead. -->
          <template v-else-if="!frames.length">
            This plan has no moments yet.<template v-if="props.canEdit"> Press Add frame, then place each group on the map.</template>
          </template>
          <template v-else>Pick a dot on the time bar to open that moment.</template>
        </div>
      </div>

      <div class="pv-bar">
        <div class="pv-bar-head k k2-transport-top">
          <button
            v-if="frames.length"
            type="button"
            class="rp-play"
            style="width: 40px; height: 40px"
            data-testid="play"
            :aria-pressed="playing ? 'true' : 'false'"
            :aria-label="playing ? 'Pause' : playhead != null ? 'Resume' : 'Play'"
            title="Play the walk: the map moves with the clock"
            @click="playing ? pausePlay() : startPlay()"
          >
            <svg class="ki" viewBox="0 0 24 24" aria-hidden="true" style="fill: currentColor; stroke: none; width: 16px; height: 16px"><path :d="playing ? 'M7 5h4v14H7zM13 5h4v14h-4z' : 'M7 4v16l13-8z'"></path></svg>
          </button>
          <button v-if="playhead != null" type="button" class="ib" aria-label="Stop: back to editing" data-testid="play-stop" title="Back to editing" @click="stopPlay">
            <svg class="ki" viewBox="0 0 24 24" aria-hidden="true" style="fill: currentColor; stroke: none"><path d="M6 6h12v12H6z"></path></svg>
          </button>
          <div v-if="frames.length" class="ksel">
            <select v-model.number="speed" aria-label="Playback speed" class="k2-sel-sm" data-testid="play-speed">
              <option v-for="option in PLAY_SPEEDS" :key="option" :value="option">{{ option }}×</option>
            </select>
          </div>
          <span v-if="playhead != null" class="pv-play-clock" data-testid="play-clock">{{ playClock }}</span>
          <span v-if="playhead == null" class="mut k2-hm" style="font-size: 13px; font-weight: 700">{{ frames.length }} frame{{ frames.length === 1 ? '' : 's' }} · time from T+0</span>
          <span class="sp"></span>
          <template v-if="props.canEdit">
            <button type="button" class="kb kb-line kb-sm" data-testid="frame-add" :disabled="busy" title="Add a frame after the open one" @click="addFrame"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>Add frame</button>
            <button type="button" class="ib" data-testid="frame-duplicate" aria-label="Duplicate frame" :disabled="busy || !selected" title="Duplicate frame" @click="duplicateFrame"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 9h11v11H9zM5 15H4V4h11v1"></path></svg></button>
            <button
              type="button"
              class="ib k2-lockbtn"
              data-testid="plan-lock"
              :aria-pressed="moveLock ? 'true' : 'false'"
              :aria-label="moveLock ? 'Unlock frames and groups' : 'Lock frames and groups'"
              :title="moveLock ? 'Unlock to drag frames and groups again' : 'Lock so frames and groups cannot be dragged by accident'"
              @click="toggleLock"
            ><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 11h12v10H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3"></path></svg></button>
          </template>
          <span class="k2-mini" role="group" aria-label="Zoom the time bar">
            <button type="button" data-testid="zoom-out" title="Zoom the strip out" aria-label="Zoom timeline out" @click="zoom(0.5)">−</button>
            <button type="button" data-testid="zoom-in" title="Zoom the strip in" aria-label="Zoom timeline in" @click="zoom(2)">+</button>
          </span>
        </div>
        <div ref="trackEl" class="pv-track" :class="{ 'k2-track-locked': moveLock }">
          <!-- A sweep anywhere on the strip that is not a dot selects the run it touches. -->
          <div class="pv-track-inner" :style="{ width: trackWidth + 'px' }" @pointerdown="startSweep">
            <!-- The ruler is the scrub handle: press anywhere on it and drag to move the cursor to any moment. -->
            <div
              class="pv-ruler"
              :class="{ 'is-scrubbable': frames.length > 0 }"
              data-testid="scrub-ruler"
              title="Drag along the ruler to see any moment"
              @pointerdown.stop.prevent="startScrub"
            >
              <div v-for="tick in ticks" :key="'t' + tick.t" class="pv-tick" :style="{ left: xOf(tick.t) + 'px' }">
                <span>{{ tick.label }}</span>
              </div>
            </div>

            <div class="pv-band" v-for="(warn, i) in analysis.bands" :key="'b' + i"
                 :style="{ left: xOf(warn.from_t_s) + 'px', width: Math.max(widthOf(warn.to_t_s - warn.from_t_s), 4) + 'px' }"></div>

            <!-- The stretch that is selected: a band along the strip, so "what will move" is visible before a drag. -->
            <div v-if="selectionSpan" class="pv-selection" data-testid="selection-band"
                 :style="{ left: xOf(selectionSpan.from_s) + 'px', width: Math.max(widthOf(selectionSpan.to_s - selectionSpan.from_s), 4) + 'px' }"></div>

            <div v-if="sweepStyle" class="pv-sweep" :style="sweepStyle"></div>

            <div v-if="selected" class="pv-now" :style="{ left: xOf(selected.t_s) + 'px' }"></div>

            <!-- The run's cursor: a line between the moments, because the clock is between them. -->
            <div
              v-if="playhead != null"
              class="pv-playhead"
              :class="{ 'is-scrubbing': scrubbing }"
              data-testid="play-head"
              :style="{ left: xOf(playhead) + 'px' }"
              @pointerdown.stop.prevent="startScrub"
            ></div>

            <div class="pv-frames">
              <button
                v-for="frame in frames"
                :key="frame.id"
                class="pv-frame"
                :data-frame-id="frame.id"
                :data-cut="isCutFrame(frame) ? 'true' : null"
                :class="{
                  'is-selected': isFrameSelected(frame.id),
                  'is-bad': analysis.frameIds.has(frame.id),
                  'is-cut': isCutFrame(frame),
                  'is-behind': playhead != null && frame.t_s <= playhead,
                  'is-problem-node': !!problemNodeTag(frame),
                  'is-problem-from': shownProblem && frame.id === shownProblem.fromFrame,
                }"
                :style="{ left: frameLeft(frame) + 'px' }"
                :title="'Frame ' + formatOffset(frame.t_s) + (frame.note ? ' — ' + frame.note : '')"
                :aria-pressed="isFrameSelected(frame.id)"
                @click="selectFrame(frame.id, $event)"
                @pointerdown.stop.prevent="startDrag(frame, $event)"
              >
                <span class="pv-frame-dot"></span>
                <span class="pv-frame-pole"></span>
                <span v-if="problemNodeTag(frame)" class="pv-frame-tag" data-testid="problem-node">{{ problemNodeTag(frame) }}</span>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Under the time bar: a problem names its dots, and the two are read together. -->
      <PlanProblems
        ref="problemsPanel"
        class="k"
        :problems="problemCards"
        :shown-id="shownProblemId"
        :can-edit="props.canEdit"
        :busy="busy"
        @show="showProblemOnMap"
        @timeline="showProblemOnTimeline"
        @act="actOnProblem"
        @fix-all="fixAllTiming"
        :preview="walkFix"
        :result="walkFixResult"
        :result-can-undo="!!walkFixResult && walkFixResult.canUndo && walkFixResult.frames === frames"
        @apply-fix="applyWalkFix"
        @cancel-fix="cancelWalkFix"
        @undo-fix="undoWalkFix"
        @clear-result="walkFixResult = null"
        @dismiss-all="dismissAllWarnings"
        @dismiss="(p) => setDismissed(p, true)"
        @restore="(p) => setDismissed(p, false)"
      />

      <div class="pv-inspector k k2-insp">
        <div v-if="errorMsg" class="pv-warnings">{{ errorMsg }}</div>

        <template v-if="selectionSpan">
          <div class="k2-tabs" role="tablist" aria-label="Inspector">
            <button type="button" role="tab" :aria-selected="inspectorTab === 'frame' ? 'true' : 'false'" data-testid="insp-tab-frame" @click="inspectorTab = 'frame'">{{ selectionSpan.count > 1 ? 'Stretch' : 'Frame' }}</button>
            <button type="button" role="tab" :aria-selected="inspectorTab === 'groups' ? 'true' : 'false'" data-testid="insp-tab-groups" @click="inspectorTab = 'groups'">{{ props.onlyGroupId ? 'Your group' : 'Groups' }}<span class="n">{{ shownGroups.length }}</span></button>
          </div>

          <!-- ===== Frame ===== -->
          <section v-show="inspectorTab === 'frame'" role="tabpanel">
            <!-- Why the open dot is red: the walk it belongs to, and the span that walk covers. -->
            <p v-if="stretchAtSelected.length" class="k2-hint" style="margin-top: 0; margin-bottom: 10px" data-testid="frame-stretch">
              This moment is in a stretch that can't be walked in time:
              <template v-for="(s, i) in stretchAtSelected" :key="s.groupId + i"><strong>{{ groupName(s.groupId) }}</strong>, {{ formatOffset(s.from_t_s) }} → {{ formatOffset(s.to_t_s) }}<template v-if="i < stretchAtSelected.length - 1">; </template></template>.
            </p>

            <!-- One frame: its time and its note. Several: the span they cover, and nothing to type into. -->
            <p v-if="selectionSpan.count > 1" class="k2-hint" style="margin-top: 0; margin-bottom: 10px" data-testid="selection-span">
              {{ countLabel(selectionSpan.count) }}, {{ formatOffset(selectionSpan.from_s) }} → {{ formatOffset(selectionSpan.to_s) }}.
              They move together.
            </p>
            <template v-else-if="selected">
              <div class="k2-field">
                <label for="pv-frame-time">Time from T+0</label>
                <input
                  id="pv-frame-time"
                  class="kin"
                  style="height: 40px; width: 100%"
                  :value="formatOffset(selected.t_s)"
                  :disabled="!props.canEdit || isCutFrame(selected)"
                  :title="isCutFrame(selected) ? 'A copy starts here, so this frame cannot move.' : ''"
                  @blur="setFrameTime(selected.id, $event.target.value, $event.target)"
                  @keyup.enter="$event.target.blur()"
                />
              </div>
              <div class="k2-field">
                <label for="pv-frame-note">Note</label>
                <input
                  id="pv-frame-note"
                  class="kin"
                  style="height: 40px; width: 100%"
                  :value="selected.note || ''"
                  :disabled="!props.canEdit || frameLocked"
                  placeholder="e.g. doors"
                  @blur="commitNote(selected.id, $event.target.value)"
                  @keyup.enter="$event.target.blur()"
                />
              </div>
              <!-- The copy's starting frame: the one moment the board will not let the plan be written before. -->
              <p v-if="isCutFrame(selected)" class="k2-hint" data-testid="frame-cut-note">
                This copy starts here, at {{ formatOffset(selected.t_s) }}. Earlier moments stay on the original plan.
              </p>
            </template>

            <!-- The push controls act on the selection, so there is one set of them whether one frame or six. -->
            <template v-if="props.canEdit">
              <div class="k2-sub">Shift time</div>
              <div class="row" style="gap: 6px; flex-wrap: wrap">
                <button type="button" class="k2-pillbtn" data-testid="push-minus-60" :disabled="busy" title="1 minute earlier" @click="push(-60)">−1m</button>
                <button type="button" class="k2-pillbtn" data-testid="push-60" :disabled="busy" title="1 minute later" @click="push(60)">+1m</button>
                <button type="button" class="k2-pillbtn" data-testid="push-300" :disabled="busy" title="5 minutes later" @click="push(300)">+5m</button>
              </div>
              <p v-if="selectionSpan.count === 1" style="margin: 14px 0 0">
                <button
                  type="button"
                  class="k2-link danger"
                  data-testid="frame-delete"
                  :disabled="busy || isCutFrame(selected)"
                  :title="isCutFrame(selected) ? 'A copy starts here, so this frame cannot be deleted.' : ''"
                  @click="removeFrame"
                >Delete frame</button>
              </p>
              <p v-if="moveLock" class="k2-hint" data-testid="lock-hint">Locked: frames and groups can't be dragged. Press the lock to change that.</p>
            </template>
            <p class="k2-hint">{{ formatOffset(0) }} is the start of the run.</p>
          </section>

          <!-- ===== Groups ===== -->
          <section v-show="inspectorTab === 'groups'" role="tabpanel">
            <template v-if="selected">
              <div v-if="props.canEdit && shownGroups.length > 1" class="k2-row k2-selectall">
                <button
                  type="button"
                  class="k2-chk"
                  role="checkbox"
                  data-testid="select-all-groups"
                  :aria-checked="allGroupsTicked ? 'true' : selectedGroups.size ? 'mixed' : 'false'"
                  aria-labelledby="k2-selectall-label"
                  @click="toggleAllGroups"
                >
                  <svg v-if="allGroupsTicked" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5 9-10"></path></svg>
                  <svg v-else-if="selectedGroups.size" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 12h12"></path></svg>
                </button>
                <b id="k2-selectall-label" style="font-size: 14px; cursor: pointer" @click="toggleAllGroups">Select all</b>
              </div>
              <div v-for="group in shownGroups" :key="group.id" class="k2-row k2-grouprow" :class="{ 'is-bad': framePosition(selected, group.id) && flaggedCells.has(group.id + '|' + selected.id) }">
                <div class="row" style="gap: 10px; width: 100%">
                  <button
                    type="button"
                    class="k2-chk"
                    role="checkbox"
                    data-testid="group-row"
                    :aria-checked="isGroupSelected(group.id) ? 'true' : 'false'"
                    :aria-label="'Select ' + group.name"
                    @click="toggleGroup(group.id)"
                  ><svg v-if="isGroupSelected(group.id)" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5 9-10"></path></svg></button>
                  <span class="pv-marker k2-rowmarker" :style="{ background: colorOf.get(group.id) }" aria-hidden="true" data-testid="group-row-marker">{{ initials(group.name) }}</span>
                  <b class="text-truncate" style="font-size: 14px; flex: 1; min-width: 0">{{ group.name }}</b>
                  <span class="mut" style="font-size: 12px; font-weight: 700">{{ stateWord(framePosition(selected, group.id)) }}</span>
                </div>
                <template v-if="props.canEdit && selectionSpan.count === 1">
                  <!-- A group the frame says nothing about has no badge to drag: Place arms the map for one tap. -->
                  <button
                    v-if="!framePosition(selected, group.id)"
                    type="button"
                    class="k2-pillbtn"
                    data-testid="place-group"
                    :data-group="group.id"
                    :aria-pressed="placing === group.id ? 'true' : 'false'"
                    :disabled="busy"
                    @click="startPlacing(group.id)"
                  >{{ placing === group.id ? 'Tap the map…' : 'Place on map' }}</button>
                  <!-- The two flags on this group's position: what is true now is filled, and pressing the other half is
                       the edit. A confirmation can only be given to a position this frame actually states. -->
                  <div v-else class="row" style="gap: 6px; flex-wrap: wrap" role="group" :aria-label="`Flags for ${group.name}`">
                    <span class="k2-mini">
                      <button type="button" data-testid="state-on" :data-group="group.id" :disabled="busy" :aria-pressed="!isOffSite(selected, group.id) ? 'true' : 'false'" title="Standing on the map at this moment" @click="setGroupState(group.id, 'on_site')">On site</button>
                      <button type="button" data-testid="state-off" :data-group="group.id" :disabled="busy" :aria-pressed="isOffSite(selected, group.id) ? 'true' : 'false'" title="Not on the map at this moment, so no walk is checked" @click="setGroupState(group.id, 'off_site')">Off site</button>
                    </span>
                    <span class="k2-mini">
                      <button type="button" data-testid="verify-auto" :data-group="group.id" :disabled="busy || !isStated(selected, group.id)" :aria-pressed="isStated(selected, group.id) && !isManual(selected, group.id) ? 'true' : 'false'" title="Trusted as drawn" @click="setGroupVerify(group.id, 'auto')">Auto</button>
                      <button type="button" data-testid="verify-manual" :data-group="group.id" :disabled="busy || !isStated(selected, group.id)" :aria-pressed="isStated(selected, group.id) && isManual(selected, group.id) ? 'true' : 'false'" title="Somebody has to confirm this by hand" @click="setGroupVerify(group.id, 'manual')">Manual</button>
                    </span>
                  </div>
                </template>
              </div>
            </template>

            <template v-if="props.canEdit && selected">
              <!-- Hold and the flags act on the ticked groups; a stretch of frames can also act on everyone standing -->
              <div v-if="selectedGroups.size || selectionSpan.count > 1" class="k2-sel" data-testid="selection-panel">
                <div class="row">
                  <b style="font-size: 14px; flex: 1">{{ selectedGroups.size ? selectedGroups.size + (selectedGroups.size === 1 ? ' group' : ' groups') + ' selected' : 'All groups' }}</b>
                  <button v-if="selectedGroups.size" type="button" class="k2-link" style="color: var(--lime)" data-testid="clear-groups" @click="clearGroups">Clear</button>
                </div>
                <template v-if="selectionSpan.count === 1">
                  <!-- Hold: state these groups again, here, at a later moment -->
                  <div class="k2-sub" data-testid="hold-target">Hold in place for</div>
                  <div class="row" style="gap: 6px; flex-wrap: wrap">
                    <button type="button" class="k2-pillbtn" data-testid="hold-60" :disabled="busy || !standingTargets.length" @click="hold(60)">+1m</button>
                    <button type="button" class="k2-pillbtn" data-testid="hold-300" :disabled="busy || !standingTargets.length" @click="hold(300)">+5m</button>
                    <button type="button" class="k2-pillbtn" data-testid="hold-600" :disabled="busy || !standingTargets.length" @click="hold(600)">+10m</button>
                  </div>
                </template>
                <!-- The state buttons act on the open frame; the confirmation buttons on the whole selected stretch -->
                <div class="k2-sub" data-testid="flag-target">On the map at {{ formatOffset(selected.t_s) }}</div>
                <div class="row" style="gap: 6px; flex-wrap: wrap">
                  <button type="button" class="k2-pillbtn" data-testid="bulk-state-on" :disabled="busy || !standingTargets.length" @click="bulkState('on_site')">On site</button>
                  <button type="button" class="k2-pillbtn" data-testid="bulk-state-off" :disabled="busy || !standingTargets.length" @click="bulkState('off_site')">Off site</button>
                </div>
                <div class="k2-sub" data-testid="verify-scope">Confirm positions</div>
                <div class="row" style="gap: 6px; flex-wrap: wrap">
                  <button type="button" class="k2-pillbtn" data-testid="bulk-verify-auto" :disabled="busy || !verifyRows" @click="bulkVerify('auto')">Automatic</button>
                  <button type="button" class="k2-pillbtn" data-testid="bulk-verify-manual" :disabled="busy || !verifyRows" @click="bulkVerify('manual')">By hand</button>
                </div>
              </div>
              <p v-else class="k2-hint">Tick groups to hold them or set flags together.</p>
            </template>
          </section>
        </template>

        <template v-else-if="!frames.length">
          <h3>No moments yet</h3>
          <p class="pv-note" data-testid="plan-no-frames">
            At each moment you set where every group is, and the app works out the walk in between.<template v-if="props.canEdit"> Add the first frame, then place each group on the map.</template>
          </p>
          <div v-if="props.canEdit" class="pv-stack">
            <button class="pv-btn is-primary" data-testid="frame-add-first" :disabled="busy" @click="addFrame">
              Add the first frame
            </button>
          </div>
        </template>
        <template v-else>
          <h3>Nothing selected</h3>
          <p class="pv-note">
            Pick a dot on the time bar to open that moment.<template v-if="props.canEdit"> Add a frame to move everyone somewhere new.</template>
          </p>
        </template>

      </div>
      </div>
    </div>
  </div>
</template>
