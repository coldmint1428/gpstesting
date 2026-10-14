<script setup>
// The planner drawing bench at /polygon.
//
// A standalone showcase: it is NOT tied to an event, and it touches none of the tables the event pages
// use. There is ONE bench, shared by everyone who signs in, and everybody may work on it at once -- one
// SHAPE at a time, decided by the database (see supabase/migrations/016_object_locks.sql).
//
// This page owns the data and the writes. AreaBench only draws it and reports what the planner did, so
// there is exactly one place that writes.
//
// A WRITE IS A PATCH OF ONE SHAPE, and it happens when a change SETTLES: at the end of a gesture, or a
// moment after an edit that is not one. `mode` going back to null no longer saves anything -- it only
// lets go of the lock -- which is what 017_object_rows.sql changed and what
// composables/useBenchDoc.js is written around.
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useBenchDoc } from '../composables/useBenchDoc'
import { useDocHistory } from '../composables/useDocHistory'
import { useBenchPresence } from '../composables/useBenchPresence'
import { useBenchLocks } from '../composables/useBenchLocks'
import { useBenchFrames } from '../composables/useBenchFrames'
import { PASTE_OFFSET_M, copyName, offsetLatLng, useBenchClipboard } from '../composables/useBenchClipboard'
import { MAX_LAYOUT_BYTES, LAYOUT_TOO_LARGE_MESSAGE, addedBytes } from '../utils/layoutLimits'
import { applyAreaFrame, applyPlanFrame } from '../utils/benchFrame'
import { formatBytes } from '../utils/imageShrink'
import AreaBench from '../components/AreaBench.vue'
import AreaList from '../components/AreaList.vue'
import BenchAlert from '../components/BenchAlert.vue'

// Who may change which shape (see composables/useBenchLocks.js). Created first, because the data layer
// below reports a refusal through it: one strip of text, one source, whichever way the refusal arrived.
const locks = useBenchLocks()

// The canvas. The database keeps one row per shape (017_object_rows.sql) and this is what turns them
// into the one document the bench draws -- and a planner's change back into a row. The options are the
// three things it deliberately does not know: whether a shape is held by this tab, where a refusal is
// said, and that a shape refused on its lock is no longer this tab's to hold.
const bench = useBenchDoc({
  holds: (id) => locks.holds(id),
  refuse: (id, row) => locks.refuse(id, row),
  say: (id, sentence) => locks.say(id, sentence),
  lost: (id) => locks.end(id),
})

// "Has this shape got a change that has not been written yet?" A lock may only be let go of when the
// answer is no, or the write that is still coming is refused by the database -- so the page tells the
// locks, once, rather than the locks guessing from timestamps (see useBenchLocks).
locks.watchBusy(bench.busy)

const { data: layout, loading, errorMsg, saving, bytes, open, layoutId, myView, saveView } = bench

// null | 'floorplan:<id>' | 'polygons' | 'area:<id>' -- what is being worked on, or nothing. It has
// nothing to say about the view: the map pans and zooms in every one of these states, except while an
// area is being drawn.
const mode = ref(null)

// One undo stack for the whole canvas, and it reads the document through this getter so the state it
// captures is always the state as it is at that moment (see composables/useDocHistory).
const history = useDocHistory(() => layout.value)

// What the toolbar buttons bind to. A ref nested inside a plain object is NOT unwrapped in a template --
// `:disabled="!history.canUndo"` would read the ref itself, which is always truthy -- so these are real
// computeds, so the ref is read where Vue can see it.
const canUndo = computed(() => history.canUndo.value)
const canRedo = computed(() => history.canRedo.value)
const stepsText = computed(() => {
  const steps = history.steps.value
  if (steps === 0) return 'No changes yet'
  return steps + (steps === 1 ? ' change' : ' changes')
})

// The bench's clipboard: one floor plan or one area, held for the session (see
// composables/useBenchClipboard.js). Not the system clipboard, and not local storage.
const clipboard = useBenchClipboard()

// Who else is on the bench, and what each of them has open (see composables/useBenchPresence.js).
// Created here and handed down like the clipboard and the history, because there is one row, one socket
// and one heartbeat per open page -- not one per component.
const presence = useBenchPresence()

// What everybody else is doing to a shape RIGHT NOW (see composables/useBenchFrames.js). A frame is
// published by the page that is moving something and drawn by everybody else, which is what makes one
// planner's drag visible on another planner's screen instead of arriving as a jump when the shape is
// finally put down. Like the clipboard and the history, there is one of these per page.
const frames = useBenchFrames()

// A ref inside a plain object is not unwrapped in a template (see the note on canUndo above), so what
// the header draws is a real computed rather than presence.others.
const hereNow = computed(() => presence.others.value)

const plans = computed(() => layout.value.floorPlans)
const areas = computed(() => layout.value.polygons)

// Where this map opens: this planner's own last view if they have one, and otherwise the bench's HOME
// view -- which is the copy still inside the frozen document, read by open_bench() (see 015 and 017).
const startView = computed(() => myView.value || layout.value.view)

// Presence is filed under the bench's id, which only exists once the bench has been opened, so joining
// waits for it instead of guessing. Live frames go out on the same moment: they are published under the
// SAME tag presence publishes and never under the session the database authorises with, which is the
// rule 015 set and this is the second thing to obey it (see composables/useBenchFrames.js).
watch(layoutId, (id) => {
  if (!id) return
  presence.join(id)
  frames.start(id, presence.myPresenceId.value, applyFrame)
})

// How close the bench is to the 4 MB the database enforces. THE NUMBER IS THE DATABASE'S: it is counted
// by layout_bytes() over the rows themselves (017) and arrives with open_bench() and with every write's
// reply, so it cannot disagree with what is really stored.
//
// This page used to count the document itself, byte for byte, and that stopped being possible the moment
// a picture became a row of its own: the same picture used by two floor plans is stored ONCE, so a count
// of what is on screen would report more than the bench costs. `addedBytes` below is what is left of the
// arithmetic -- one shape, before it is added.
const sizeText = computed(() => formatBytes(bytes.value) + ' of ' + formatBytes(MAX_LAYOUT_BYTES))
const sizeRatio = computed(() => bytes.value / MAX_LAYOUT_BYTES)

// Would this floor plan fit? A picture that cannot be stored should be refused before it joins the
// canvas rather than taken back off it afterwards. Asked of the page because the page is the only side
// that knows both the bench's size and which pictures are already on it.
function planFits(plan) {
  return bytes.value + addedBytes(plan, plans.value) <= MAX_LAYOUT_BYTES
}

// Leaving a shape. Whatever is still unwritten for it goes FIRST, because a lock may only be let go of
// once the change it protects has been written: released early, the database refuses the write that is
// still coming and the planner's work is gone with no error anywhere (see useBenchLocks.end).
//
// This is now the only thing `mode` does. It used to be the save trigger for the entire document --
// "putting it down is the save" -- and now that a shape is its own row there is nothing left for it to
// trigger: the change was written at the end of the gesture that made it.
watch(mode, async (value, oldValue) => {
  const was = objectIdOf(oldValue)
  if (!was) return
  await bench.flush(was)
  locks.end(was)
  presence.setHolding('')
})

// What I have open, reported to everyone else. This is how my name gets onto a shape on another
// planner's screen before either of us has touched anything -- and it is a HINT that decides nothing:
// the only thing that will ever refuse a change is the database (see the composable).
watch(mode, (value) => presence.setSelection(objectIdOf(value)), { immediate: true })

// A shape that is not on the canvas cannot be the thing being edited. That happens two ways: this
// planner deleted it, or somebody else did -- and the second one used to leave the panel open on a shape
// that does not exist. Nothing is written here: letting go of `mode` only releases a lock.
watch([plans, areas, mode], () => {
  const id = objectIdOf(mode.value)
  if (!id) return
  if (!plans.value.some((p) => p.id === id) && !areas.value.some((a) => a.id === id)) mode.value = null
})

// 'area:<id>' and 'floorplan:<id>' both name a shape. 'polygons' -- a ring being drawn -- names nothing,
// because what is being drawn is not part of the canvas yet.
function objectIdOf(value) {
  if (typeof value !== 'string') return ''
  const cut = value.indexOf(':')
  return cut === -1 ? '' : value.slice(cut + 1)
}

// A pointer coming up anywhere is reliably the end of a drag: it is when a run of changes becomes the
// one step it earned, and it is when what they changed is written. NOTHING IS WRITTEN WHILE A POINTER IS
// DOWN (see useBenchDoc): a shape in motion is not a shape anybody should be sent, and "what the planner
// meant" is not knowable until they let go.
function beginGesture() {
  bench.beginGesture()
}

function endGesture() {
  history.endRun()
  bench.endGesture()
}

// Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y for the whole document, and Ctrl+C / Ctrl+V for the thing being worked
// on. One listener for the page, because there is one timeline; the bench forwards the press here for
// everything except the ring being drawn, which is not part of the document yet.
function onKeyDown(event) {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return
  const el = event.target
  const tag = el && el.tagName
  // Inside a text field every one of these belongs to the browser: a mistyped area name must come back
  // as text, and a copied name as text too, not as a whole area.
  if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return
  const key = String(event.key || '').toLowerCase()

  if (key === 'c' && !event.shiftKey) {
    if (copySelection()) event.preventDefault()
    return
  }

  if (key === 'v' && !event.shiftKey) {
    if (pasteSelection()) event.preventDefault()
    return
  }

  const isUndo = key === 'z' && !event.shiftKey
  const isRedo = (key === 'z' && event.shiftKey) || key === 'y'
  if (!isUndo && !isRedo) return
  const available = isUndo ? history.canUndo.value : history.canRedo.value
  if (!available) return // nothing to do: leave the press to the browser
  event.preventDefault()
  if (isUndo) undo()
  else redo()
}

// The id of the area being worked on, for highlighting its row in the list. Empty when the bench is not
// in an area mode.
const selectedAreaId = computed(() => {
  const value = mode.value
  return typeof value === 'string' && value.startsWith('area:') ? value.slice('area:'.length) : ''
})

// The thing being worked on, if any, for the Ctrl+C shortcut: "copy what I am holding". The bench
// derives these from `mode` too, and the two must agree, because the mode string is the single source of
// truth for what is open.
const selectedArea = computed(() => {
  const id = selectedAreaId.value
  return id ? areas.value.find((a) => a.id === id) || null : null
})

const selectedPlan = computed(() => {
  const value = mode.value
  if (typeof value !== 'string' || !value.startsWith('floorplan:')) return null
  const id = value.slice('floorplan:'.length)
  return plans.value.find((p) => p.id === id) || null
})

// Ctrl+C copies whatever is being worked on: the floor plan or the area the panel is showing. Nothing
// open means nothing to copy, and the press is left to the browser -- so selecting text on the page
// still copies text.
function copySelection() {
  if (selectedArea.value) {
    copyArea(selectedArea.value)
    return true
  }
  if (selectedPlan.value) {
    copyPlan(selectedPlan.value)
    return true
  }
  return false
}

// Ctrl+V pastes whichever kind is on the clipboard. Which one is not a question: the clipboard holds one
// thing at a time, and it remembers which.
function pasteSelection() {
  if (clipboard.area.value) {
    pasteArea()
    return true
  }
  if (clipboard.plan.value) {
    pastePlan()
    return true
  }
  return false
}

// ---------- What other planners are doing right now ----------
// A live frame arrives while somebody else is dragging a shape, and is drawn on this screen so the work
// is visible as it happens. That is ALL it does, and each of the three things it does not do is
// load-bearing:
//
//   - it is not a save. Nothing here goes near the database, and it never will: a frame is published by
//     a browser, so a page that treated one as authoritative would be handing the bench to whoever felt
//     like publishing. What makes it safe is the LOCK -- save_object() writes nothing for a shape the
//     caller does not hold -- so the geometry a frame put on this screen is in the patch of the next
//     write and never wins anything with it.
//   - it is not a step. `history.record()` is called by the write handlers below and by nothing else,
//     and a shape this planner does not hold is never changed by an event (see useBenchDoc), so Ctrl+Z
//     cannot reach into somebody else's hand.
//   - it is not the whole shape. utils/benchFrame.js decides what a frame may carry (no id, no image)
//     and refuses one that would leave this planner's canvas in a state the database would not store --
//     which matters, because that canvas is what the next write of that shape sends, and the database
//     checks the merged shape before it stores it.
function applyFrame({ kind, id, patch }) {
  // The database says this shape is mine, so somebody else's frames for it are not to be believed. Two
  // planners can be on one shape for the moment before the lock answers, and that is the moment this is
  // for: the one that loses is told, stops, and its geometry is never committed.
  if (locks.holds(id)) return

  if (kind === 'plan') {
    const plan = layout.value.floorPlans.find((p) => p.id === id)
    const next = plan ? applyPlanFrame(plan, patch) : null
    if (next) layout.value.floorPlans = layout.value.floorPlans.map((p) => (p.id === id ? next : p))
    return
  }

  const area = layout.value.polygons.find((a) => a.id === id)
  const next = area ? applyAreaFrame(area, patch) : null
  if (next) layout.value.polygons = layout.value.polygons.map((a) => (a.id === id ? next : a))
}

// ---------- What AreaBench reports ----------
// EVERY write records a step first. `history.record()` reads the document as it stands, so the state it
// captures is the one before the change -- which is exactly what Undo has to put back. Doing it here, at
// the one place that writes, is what makes the stack cover everything: a dropped dot, a new area, a
// deleted floor plan and a renamed area are all just writes.
//
// AND EVERY WRITE ASKS FOR THE SHAPE'S LOCK FIRST. This is where a change to the canvas begins, and the
// database will not store a change to a shape nobody holds (see save_object in 017_object_rows.sql) --
// so the refusal is taken here, before the change happens at all: the shape never moves, no step is
// recorded, and useBenchLocks has already put the reason on screen.
async function mayWrite(id) {
  if (!id) return true
  const granted = await locks.ensure(id)
  // Tell the others what I am holding. A page carries one active shape in its presence row, so this is
  // the most recent one rather than the whole set -- a hint for their screens, while the database holds
  // every lock and is what actually refuses them.
  if (granted) presence.setHolding(id)
  return granted
}

// A shape being dragged, reported BEFORE it is committed. A dot's drag deliberately tells the page
// nothing until it is let go (see AreaBench), so this is the only route the ring in flight has to the
// other planners -- and it takes the same lock a change does, through the same `mayWrite`. That is not a
// formality: a planner whose frames the others follow has to be the planner who owns the shape, or two
// screens would be following two different answers. It also means the loser of a race finds out at the
// first move instead of at the drop, while the shape is still under their finger.
async function streamArea({ id, patch }) {
  if (!(await mayWrite(id))) return
  frames.send('area', id, patch)
}

// A NEW shape is written at once, and waited for: everything else here is written when the change
// settles, but a shape that only exists on one screen is not something the others can be told about
// later -- and the planner's very next act is usually to click away from it, which must not be able to
// leave it behind. (That was a measured bug of the whole-document save: draw an area, wait for the save,
// reload in a second browser, and it was not there.)
async function addPlan(plan) {
  if (!(await mayWrite(plan.id))) return
  history.record()
  madeHere.add(plan.id)
  layout.value.floorPlans = [...layout.value.floorPlans, plan]
  bench.change('plan', plan.id, plan)
  await bench.flush(plan.id)
}

async function updatePlan({ id, patch }) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.floorPlans = layout.value.floorPlans.map((p) => (p.id === id ? { ...p, ...patch } : p))
  // And tell the others, so a picture being moved or turned travels across their screens instead of
  // teleporting when it is put down. Whatever the drag reports -- a centre, an angle, a size, a rename
  // -- is exactly what a frame may carry (see utils/benchFrame.js).
  frames.send('plan', id, patch)
  bench.change('plan', id, patch)
}

async function deletePlan(id) {
  if (!(await mayWrite(id))) return
  history.record()
  madeHere.delete(id)
  layout.value.floorPlans = layout.value.floorPlans.filter((p) => p.id !== id)
  // Deleting the picture that is open puts it down at once. See deleteArea.
  if (mode.value === 'floorplan:' + id) mode.value = null
  await bench.remove('plan', id)
}

async function addArea(area) {
  if (!(await mayWrite(area.id))) return
  history.record()
  madeHere.add(area.id)
  layout.value.polygons = [...layout.value.polygons, area]
  bench.change('area', area.id, area)
  await bench.flush(area.id)
}

async function updateArea({ id, patch }) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.polygons = layout.value.polygons.map((a) => (a.id === id ? { ...a, ...patch } : a))
  // And tell the others. An outline dragged across the map reports on every move, so this is what the
  // other planners watch it with: twenty frames a second, and one write when it is let go of.
  frames.send('area', id, patch)
  bench.change('area', id, patch)
}

async function deleteArea(id) {
  if (!(await mayWrite(id))) return
  history.record()
  madeHere.delete(id)
  layout.value.polygons = layout.value.polygons.filter((a) => a.id !== id)
  // Deleting the shape that is open puts it down at once: `mode` would otherwise point at a shape that
  // no longer exists. Nothing is saved by doing it any more -- the deletion is written by the call below
  // -- but the panel would otherwise stay open on a shape that is gone.
  if (mode.value === 'area:' + id) mode.value = null
  await bench.remove('area', id)
}

// The view is NOT a step, and it is not the document's business either. Panning and zooming report on
// every settle, so recording them would bury every real edit under a pile of steps that only move the
// camera; and the camera is the one thing two planners must NOT share, or one of them panning would
// carry the other's map along with it (see 015_presence_and_views.sql). It goes to this planner's own
// row instead, and Undo stays about what was drawn.
function setView(view) {
  saveView(view)
}

// ---------- Undo / redo of the whole document ----------
// A restore is NOT a reset: the states ahead of the one being put back have to stay reachable, or redo
// would clear itself the moment undo ran.
//
// WHAT A STEP MEANS NOW. Before 017 a restore only changed what was on screen and the next save carried
// it; a step is now a set of WRITES -- a shape put back is a shape written, and a shape Undo takes away
// is a shape deleted -- so this is the one place on the page that touches more than one shape at once.
//
// Shapes this planner does not hold are left exactly as they are, which is what stops Ctrl+Z from
// reaching into somebody else's work. And a shape the step does not have, which THIS PLANNER made, is
// one Undo made -- so Undo takes it away. That last rule is the one that was wrong before: the old merge
// kept every shape its snapshot did not mention, on the reasoning that another planner might have made
// it since, and the effect was that drawing an area and pressing Ctrl+Z left the area on the bench.
const madeHere = new Set()

// One list of shapes, put back to the state the step was taken in.
//
//   - a shape the step has: the step's version if it is mine to say, and otherwise the one on screen;
//   - a shape the step does not have, which I made: taken away;
//   - a shape the step does not have, which I did not make: left exactly where it is.
//
// Everything that has to be written is named, because a restore has to SAY what it changed rather than
// rely on a later save to notice -- there is no later save any more.
function restoreList(step, current, wasHeld) {
  const list = []
  const write = []
  const drop = []
  const seen = new Set()

  for (const shape of step) {
    const here = current.find((c) => c.id === shape.id)
    seen.add(shape.id)
    if (!here || wasHeld(shape.id)) {
      list.push(shape)
      if (here !== shape) write.push(shape)
    } else {
      list.push(here)
    }
  }

  for (const shape of current) {
    if (seen.has(shape.id)) continue
    if (madeHere.has(shape.id)) {
      drop.push(shape.id)
      continue
    }
    list.push(shape)
  }

  return { list, write, drop }
}

function restore(snapshot) {
  if (!snapshot) return
  // Put down whatever is being worked on first: restoring can remove the very shape being adjusted, and
  // a mode pointing at something that is no longer there would leave the panel showing controls for a
  // shape that does not exist. Leaving the mode alone when it is already null also avoids writing the
  // pre-restore state of a shape nobody is working on.
  if (mode.value !== null) mode.value = null

  const before = layout.value
  const floorPlans = restoreList(snapshot.floorPlans, before.floorPlans, locks.holds)
  const polygons = restoreList(snapshot.polygons, before.polygons, locks.holds)

  // The view is not the document's any more, so Undo leaves the camera where the planner has it.
  layout.value = { view: before.view, floorPlans: floorPlans.list, polygons: polygons.list }
  history.settle(snapshot)

  for (const shape of floorPlans.write) putBack('plan', shape)
  for (const shape of polygons.write) putBack('area', shape)
  for (const id of floorPlans.drop) takeAway('plan', id)
  for (const id of polygons.drop) takeAway('area', id)
}

async function putBack(kind, shape) {
  if (!(await mayWrite(shape.id))) return
  // A shape the bench does not have is one this page is CREATING (again), and Undo has to know it made
  // it -- or the next Undo would leave it behind. See `madeHere` below.
  if (!bench.known(shape.id)) madeHere.add(shape.id)
  bench.replace(kind, shape.id, shape)
}

async function takeAway(kind, id) {
  if (!(await mayWrite(id))) return
  madeHere.delete(id)
  await bench.remove(kind, id)
}

// Called by the bench for the toolbar and for Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y. One timeline for the whole
// page, so there is no question of which stack a press means.
function undo() {
  restore(history.undo())
}

function redo() {
  restore(history.redo())
}

// ---------- Copy and paste ----------
// A duplicate is a NEW thing built from the old one: a fresh id (or the two rows would be the same row as
// far as the map, the list and Realtime are concerned), a name that is not already taken, and a position
// a short step away so the copy is not hidden underneath the original.
//
// The duplicate is an ordinary change, so it records a step first and Undo takes it back -- a paste that
// could not be undone would be a trap.

function copyArea(area) {
  clipboard.copyArea(area)
}

function copyPlan(plan) {
  clipboard.copyPlan(plan)
}

function pasteArea() {
  const from = clipboard.area.value
  if (!from) return
  errorMsg.value = ''
  const taken = areas.value.map((a) => a.name)
  const area = {
    ...from,
    id: newId(),
    name: copyName(from.name, taken),
    points: from.points.map((point) => offsetLatLng(point, PASTE_OFFSET_M)),
  }
  // addArea records the step, like every other write (see the section above).
  addArea(area)
  // Selected, so the copy is the thing on screen: its name is in the list, and its dots can be dragged
  // straight away. Pasting into the middle of a drawing session puts that down first, so the planner is
  // looking at what they just made.
  mode.value = 'area:' + area.id
}

function pastePlan() {
  const from = clipboard.plan.value
  if (!from) return
  errorMsg.value = ''
  const taken = plans.value.map((p) => p.name)
  const plan = {
    ...from,
    id: newId(),
    name: copyName(from.name, taken),
    centre: offsetLatLng(from.centre, PASTE_OFFSET_M),
  }
  // A copy of a floor plan at least does not cost a second picture: the image is stored once, under the
  // md5 of the image itself (017), so a paste of one that is already here adds its placement and
  // nothing else. Measured here anyway, before anything is added.
  if (!planFits(plan)) {
    errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
    return
  }
  // addPlan records the step, like every other write (see the section above).
  addPlan(plan)
  // Selected, so the copy is the thing on screen: its corners and its rotate knob appear straight away.
  // The bench draws them from the new mode on its own.
  mode.value = 'floorplan:' + plan.id
}

// A fresh id for a pasted thing. crypto.randomUUID is not available in every browser the app runs in
// (and not over plain http), so there is a fallback -- two rows sharing an id would be a far worse bug
// than a slightly weaker one.
function newId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'x' + Math.random().toString(36).slice(2) + Date.now().toString(36)
}

// Clicking an area -- on the map or in the list -- selects it. Clicking it again puts it back down.
function selectArea(id) {
  mode.value = mode.value === 'area:' + id ? null : 'area:' + id
}

onMounted(() => {
  open()
  locks.start()
  window.addEventListener('keydown', onKeyDown)
  // A gesture begins when a pointer goes down anywhere and ends when it comes up, wherever it is: that
  // is when a run of changes becomes the one step it earned, and when what it changed is written.
  window.addEventListener('pointerdown', beginGesture)
  window.addEventListener('pointerup', endGesture)
  window.addEventListener('pointercancel', endGesture)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeyDown)
  window.removeEventListener('pointerdown', beginGesture)
  window.removeEventListener('pointerup', endGesture)
  window.removeEventListener('pointercancel', endGesture)
})
</script>

<template>
  <main class="container py-3">
    <div class="d-flex flex-wrap align-items-start justify-content-between gap-2 mb-2">
      <div>
        <h1 class="h4 mb-1">Polygon bench</h1>
        <!-- Who else is on the bench. A planner working alone sees nothing here at all, which is
             the point: collaboration chrome on an empty bench is noise. A planner's own other
             window is listed too, labelled, because that is the case that used to be invisible. -->
        <div
          v-if="hereNow.length"
          class="d-flex flex-wrap align-items-center gap-1"
          data-testid="bench-here-now"
        >
          <span class="small text-muted">Also here:</span>
          <span
            v-for="who in hereNow"
            :key="who.presenceId"
            class="badge rounded-pill bench-who"
            :style="{ color: who.colour, borderColor: who.colour, background: who.colour + '22' }"
            :data-testid="'bench-who-' + who.name"
          >
            {{ who.label }}
          </span>
        </div>
      </div>

      <div class="d-flex flex-wrap align-items-center gap-2">
        <!-- Undo and redo of the WHOLE document, on the page rather than over the map or inside a
             panel. A step can be a dot, an area, a floor plan or a rename, so it belongs to none
             of them -- and a button that lived inside the thing being edited was the bug: it went
             away, and its stack with it, the moment the planner clicked somewhere else.
             Arrows rather than the words: at this size the words are the wider half of the
             control and the meaning is in the direction. Both carry a title and an aria-label, so
             the word is still there for anyone who needs it, and Ctrl+Z / Ctrl+Shift+Z work too. -->
        <div class="btn-group btn-group-sm" role="group" aria-label="Undo and redo the whole bench">
          <button
            type="button"
            class="btn btn-outline-secondary"
            :disabled="!canUndo"
            :title="canUndo ? 'Undo the last change, anywhere on the bench (Ctrl+Z)' : 'Nothing to undo'"
            aria-label="Undo"
            data-testid="bench-undo"
            @click="undo"
          >
            <svg class="bench-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M9.5 6.5v4H14a4.5 4.5 0 0 1 0 9h-5" />
              <polyline points="12.5,3.5 9.5,6.5 12.5,9.5" />
            </svg>
          </button>
          <button
            type="button"
            class="btn btn-outline-secondary"
            :disabled="!canRedo"
            :title="canRedo ? 'Redo (Ctrl+Shift+Z)' : 'Nothing to redo'"
            aria-label="Redo"
            data-testid="bench-redo"
            @click="redo"
          >
            <svg class="bench-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M14.5 6.5v4H10a4.5 4.5 0 0 0 0 9h5" />
              <polyline points="11.5,3.5 14.5,6.5 11.5,9.5" />
            </svg>
          </button>
        </div>

        <!-- How far back the stack goes. A browser-side stack is invisible, and "nothing to undo"
             is otherwise indistinguishable from "Undo is broken". -->
        <span
          class="badge text-bg-light"
          data-testid="history-steps"
          :title="'Changes that can be undone, one step per thing you did'"
        >
          {{ stepsText }}
        </span>

        <span v-if="saving" class="badge text-bg-light" data-testid="saving-badge">Saving...</span>
      </div>
    </div>

    <BenchAlert v-if="errorMsg" data-testid="page-error" @dismiss="errorMsg = ''">
      {{ errorMsg }}
    </BenchAlert>

    <p v-if="loading" class="text-muted">Loading the bench...</p>

    <AreaBench
      v-else
      v-model:mode="mode"
      :plans="plans"
      :areas="areas"
      :view="startView"
      :locks="locks"
      :history="history"
      :clipboard="clipboard"
      :presence="presence"
      :size-text="sizeText"
      :size-ratio="sizeRatio"
      :plan-fits="planFits"
      @plan-added="addPlan"
      @plan-updated="updatePlan"
      @plan-deleted="deletePlan"
      @plan-copied="copyPlan"
      @plan-pasted="pastePlan"
      @area-added="addArea"
      @area-updated="updateArea"
      @area-frame="streamArea"
      @area-copied="copyArea"
      @area-pasted="pasteArea"
      @view-changed="setView"
    >
      <AreaList
        :areas="areas"
        :editable="true"
        :locks="locks"
        :selected="selectedAreaId"
        :clipboard="clipboard"
        :presence="presence"
        @area-updated="updateArea"
        @area-copied="copyArea"
        @area-pasted="pasteArea"
        @area-deleted="deleteArea"
        @area-edit="selectArea"
      />
    </AreaBench>
  </main>
</template>

<style scoped>
/* The undo and redo arrows.
   Inline SVG rather than an icon font, because the project has no icon font and adding one for two
   glyphs would be a download the page does not otherwise need. Stroke, no fill, so `currentColor`
   picks up the button's own colour -- including the grey Bootstrap uses for a disabled button. */
.bench-arrow {
  width: 1rem;
  height: 1rem;
  display: block;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* A planner's badge: their own colour for the text and the outline, and the same colour at 13%
   for the fill. Tinted rather than white-on-colour, because the palette has to be readable at
   both ends of it -- white text disappears on a pale hue and black disappears on a dark one. */
.bench-who {
  border: 1px solid;
  font-weight: 600;
}
</style>
