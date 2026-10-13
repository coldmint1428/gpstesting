<script setup>
// The planner drawing bench at /polygon.
//
// A standalone showcase: it is NOT tied to an event, and it touches none of the tables the
// event pages use. There is ONE bench, shared by everyone who signs in, and only one person
// may edit it at a time -- see composables/useBenchClaim.js for how that is arbitrated.
//
// This page owns the data and the saving. AreaBench only draws it and reports what the
// planner did, so there is exactly one place that writes.
//
// EVERY LOCK IS A SAVE. `mode` going back to null is the only save trigger there is, which
// is why there is no Save button anywhere on this page.
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { useBenchClaim } from '../composables/useBenchClaim'
import { useDocHistory } from '../composables/useDocHistory'
import { useBenchPresence } from '../composables/useBenchPresence'
import { PASTE_OFFSET_M, copyName, offsetLatLng, useBenchClipboard } from '../composables/useBenchClipboard'
import { MAX_LAYOUT_BYTES, LAYOUT_TOO_LARGE_MESSAGE, layoutBytes } from '../utils/layoutLimits'
import { firstAreaProblem } from '../utils/areaKinds'
import { formatBytes } from '../utils/imageShrink'
import AreaBench from '../components/AreaBench.vue'
import AreaList from '../components/AreaList.vue'
import BenchAlert from '../components/BenchAlert.vue'

const {
  data: layout,
  loading,
  errorMsg,
  save,
  saving,
  open,
  reload,
  // Per-session state that is not the document: the bench's id, and where this planner left the map.
  layoutId,
  myView,
  saveView,
} = useBenchClaim()

// null | 'floorplan:<id>' | 'polygons' | 'area:<id>' -- what is being worked on, or nothing. It no
// longer has anything to say about the view: the map pans and zooms in every one of these states,
// except while an area is being drawn.
const mode = ref(null)

// One undo stack for the whole canvas, and it reads the document through this getter so the
// state it captures is always the state as it is at that moment (see composables/useDocHistory).
const history = useDocHistory(() => layout.value)

// What the toolbar buttons bind to. A ref nested inside a plain object is NOT unwrapped in a
// template -- `:disabled="!history.canUndo"` would read the ref itself, which is always truthy, and
// the button would look enabled forever and do nothing when pressed. These are real computeds, so
// the ref is read where Vue can see it.
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
// Created here and handed down like the clipboard and the history, because there is one row, one
// socket and one heartbeat per open page -- not one per component.
const presence = useBenchPresence()

// Who may change which shape, decided one object at a time (see composables/useBenchLocks.js).
// Handed down for the same reason as the clipboard and the history, and for one more: every write
// on this page asks it for the object first, so a change to something another planner is holding
// never happens at all.
const locks = useBenchLocks()

// A ref inside a plain object is not unwrapped in a template (see the note on canUndo above), so
// what the header draws is a real computed rather than presence.others.
const hereNow = computed(() => presence.others.value)

const plans = computed(() => layout.value.floorPlans)
const areas = computed(() => layout.value.polygons)

// Where this map opens: this planner's own last view if they have one, and otherwise the view
// stored in the document -- which nothing writes any more, so it is the bench's HOME view rather
// than wherever the last planner happened to pan (see 007_presence_and_views.sql).
const startView = computed(() => myView.value || layout.value.view)

// Presence is filed under the bench's id, which only exists once the bench has been opened, so
// joining waits for it instead of guessing.
watch(layoutId, (id) => {
  if (id) presence.join(id)
})

// Build the canvas as JSON text, which is what save_bench() counts the bytes of. The
// round-trip through a string also strips Vue's reactive proxies, so supabase-js never sees
// anything unexpected. The one string serves both the size check and the request body, so
// the document is serialised once per save instead of twice.
const canvasText = computed(() => JSON.stringify(layout.value))

// Why the database refused, in words the planner can act on.
//
// It only speaks for the areas, because that is the one rule this page can check for itself
// and name the culprit for. Anything else -- a floor plan hanging off the map, say -- is left
// to layout_problem() in the database, which sees the row as it is actually stored.
function diagnose(payload) {
  const areas = payload && Array.isArray(payload.polygons) ? payload.polygons : null
  return firstAreaProblem(areas)
}

async function saveNow() {
  const text = canvasText.value
  const overruled = await save(JSON.parse(text), {
    jsonText: text,
    diagnose,
    session: locks.session.value,
  })

  // The server kept its own version of something this save carried -- an object somebody else was
  // holding, or one this page's copy was simply behind on. Everything it did not take has to come
  // back, and the merge decides what that means: what I hold stays on screen, because the planner
  // may have moved it on since the save left, and everything else is taken from the bench as it
  // now stands.
  if (overruled && overruled.length) await resync()
}

async function resync() {
  const server = await reload()
  if (!server) return
  layout.value = {
    view: layout.value.view,
    floorPlans: mergeById(server.floorPlans, layout.value.floorPlans),
    polygons: mergeById(server.polygons, layout.value.polygons),
  }
}

// How close the canvas is to the 4 MB cap save_bench() enforces. The planner cannot see a
// 3.9 MB document, so this is the only warning they get before a save is refused.
//
// Measured from the very string a save would send (canvasText, above), and measured on every
// change rather than only when a save happens: this is what makes the ring in the floor plans card
// move as a picture is added or deleted, instead of jumping at the next lock.
//
// The page measures it rather than useBenchClaim, which measures its own copy of the document --
// that copy has no `view`, so it would report the wrong number.
const bytes = computed(() => layoutBytes(canvasText.value))
const sizeText = computed(() => formatBytes(bytes.value) + ' of ' + formatBytes(MAX_LAYOUT_BYTES))
const sizeRatio = computed(() => bytes.value / MAX_LAYOUT_BYTES)

// The one and only save trigger, and the one and only place a shape is let go of -- which is why
// they are the same watcher. Letting go has to happen AFTER the save and not beside it: an unlock
// that overtook its own save would leave that save holding no lock at all, and the database would
// (quite correctly) refuse every object in it, throwing the planner's work away.
//
// Leaving a shape for another one needs no save and nothing in flight, so it lets go at once.
watch(mode, async (value, oldValue) => {
  const was = objectIdOf(oldValue)

  if (value === null) {
    if (oldValue !== null) await saveNow()
    if (was) {
      locks.end(was)
      presence.setHolding('')
    }
    return
  }

  if (was && was !== objectIdOf(value)) {
    locks.end(was)
    presence.setHolding('')
  }
})

// What I have open, reported to everyone else. This is how my name gets onto a shape on another
// planner's screen before either of us has touched anything -- and it is a HINT that decides
// nothing: the only thing that will ever refuse a change is the database (see the composable).
watch(mode, (value) => presence.setSelection(objectIdOf(value)), { immediate: true })

// 'area:<id>' and 'floorplan:<id>' both name a shape. 'polygons' -- a ring being drawn -- names
// nothing, because what is being drawn is not part of the canvas yet.
function objectIdOf(value) {
  if (typeof value !== 'string') return ''
  const cut = value.indexOf(':')
  return cut === -1 ? '' : value.slice(cut + 1)
}

// There is no editing session to start or stop any more, and nothing resets the history: everyone
// works on the bench whenever they like, one object at a time. The stack belongs to this page, and
// mergeById is what keeps Ctrl+Z from reaching into anybody else's work.

// A pointer coming up anywhere is reliably the end of a drag, and the end of a drag is when a
// run of changes becomes the one step it earned -- see endGesture and the listeners at the
// bottom of this script.

// Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y for the whole document, and Ctrl+C / Ctrl+V for the thing
// being worked on. One listener for the page, because there is one timeline; the bench forwards
// the press here for everything except the ring being drawn, which is not part of the document
// yet.
function onKeyDown(event) {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return
  const el = event.target
  const tag = el && el.tagName
  // Inside a text field every one of these belongs to the browser: a mistyped area name must come
  // back as text, and a copied name as text too, not as a whole area.
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

// The id of the area being worked on, for highlighting its row in the list. Empty when the
// bench is not in an area mode.
const selectedAreaId = computed(() => {
  const value = mode.value
  return typeof value === 'string' && value.startsWith('area:') ? value.slice('area:'.length) : ''
})

// The thing being worked on, if any, for the Ctrl+C shortcut: "copy what I am holding". The
// bench derives these from `mode` too, and the two must agree, because the mode string is the
// single source of truth for what is open.
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

// Ctrl+C copies whatever is being worked on: the floor plan or the area the panel is showing.
// Nothing open means nothing to copy, and the press is left to the browser -- so selecting text
// on the page still copies text.
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

// Ctrl+V pastes whichever kind is on the clipboard. Which one is not a question: the clipboard
// holds one thing at a time, and it remembers which.
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

// ---------- What AreaBench reports ----------
// EVERY write records a step first. `history.record()` reads the document as it stands, so the
// state it captures is the one before the change -- which is exactly what Undo has to put back.
// Doing it here, at the one place that writes, is what makes the stack cover everything: a
// dropped dot, a new area, a deleted floor plan and a renamed area are all just writes.
//
// AND EVERY WRITE ASKS FOR THE OBJECT'S LOCK FIRST. This is the one place a change to the canvas
// begins, and the database will not store a change to an object nobody holds (see save_bench in
// 008_object_locks.sql) -- so the refusal is taken here, before the change happens at all: the
// shape never moves, no step is recorded, and useBenchLocks has already put the reason on screen.
async function mayWrite(id) {
  if (!id) return true
  const granted = await locks.ensure(id)
  // Tell the others what I am holding. A page carries one active object in its presence row, so
  // this is the most recent one rather than the whole set -- a hint for their screens, while the
  // database holds every lock and is what actually refuses them.
  if (granted) presence.setHolding(id)
  return granted
}

async function addPlan(plan) {
  if (!(await mayWrite(plan.id))) return
  history.record()
  layout.value.floorPlans = [...layout.value.floorPlans, plan]
}

async function updatePlan({ id, patch }) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.floorPlans = layout.value.floorPlans.map((p) => (p.id === id ? { ...p, ...patch } : p))
}

async function deletePlan(id) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.floorPlans = layout.value.floorPlans.filter((p) => p.id !== id)
}

async function addArea(area) {
  if (!(await mayWrite(area.id))) return
  history.record()
  layout.value.polygons = [...layout.value.polygons, area]
}

async function updateArea({ id, patch }) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.polygons = layout.value.polygons.map((a) => (a.id === id ? { ...a, ...patch } : a))
}

async function deleteArea(id) {
  if (!(await mayWrite(id))) return
  history.record()
  layout.value.polygons = layout.value.polygons.filter((a) => a.id !== id)
}

// The view is NOT a step, and it is not the document's business either. Panning and zooming report
// on every settle, so recording them would bury every real edit under a pile of steps that only
// move the camera; and the camera is the one thing two planners must NOT share, or one of them
// panning would carry the other's map along with it (see 007_presence_and_views.sql). It goes to
// this planner's own row instead, and Undo stays about what was drawn.
function setView(view) {
  saveView(view)
}

// Everything is over: the run of changes becomes one step. Called on pointerup, which is the one
// moment that is reliably the end of a drag, so a dragged dot is one step rather than sixty.
function endGesture() {
  history.endRun()
}

// ---------- Undo / redo of the whole document ----------
// A restore is NOT a reset: the states ahead of the one being put back have to stay reachable,
// or redo would clear itself the moment undo ran. `settle` tells the stack what is on screen
// now; only starting or ending a session resets it.
// Objects I hold the lock on come from `preferred` (a snapshot, or the bench as the server has it);
// everything else stays exactly as it is, because it is not mine to say. This is the SAME rule the
// database applies to a save (see save_bench in 008_object_locks.sql), and it is what stops Ctrl+Z
// from undoing somebody else's work -- with ONE stack for the whole canvas, putting a snapshot back
// wholesale would do exactly that.
function mergeById(preferred, current) {
  const out = []
  const seen = new Set()

  for (const item of preferred) {
    const here = current.find((c) => c.id === item.id)
    out.push(!here || locks.holds(item.id) ? item : here)
    seen.add(item.id)
  }

  // Anything the other side has never heard of is not mine to remove either: another planner may
  // have made it since.
  for (const item of current) {
    if (!seen.has(item.id)) out.push(item)
  }
  return out
}

function restore(snapshot) {
  if (!snapshot) return
  // Put down whatever is being worked on first. Restoring can remove the very area being
  // adjusted, and a mode pointing at something that is no longer there would leave the panel
  // showing controls for a shape that does not exist. Leaving the mode alone when it is already
  // null also avoids a pointless save of the pre-restore state.
  if (mode.value !== null) mode.value = null
  layout.value = {
    // The view is not the document's any more, so Undo leaves the camera where the planner has it
    // (see setView below).
    view: layout.value.view,
    floorPlans: mergeById(snapshot.floorPlans, layout.value.floorPlans),
    polygons: mergeById(snapshot.polygons, layout.value.polygons),
  }
  history.settle(snapshot)
}

// Called by the bench for the toolbar and for Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y. One timeline for
// the whole page, so there is no question of which stack a press means.
function undo() {
  restore(history.undo())
}

function redo() {
  restore(history.redo())
}

// ---------- Copy and paste ----------
// A duplicate is a NEW thing built from the old one: a fresh id (or the two rows would be the
// same row as far as the map, the list and Realtime are concerned), a name that is not already
// taken, and a position a short step away so the copy is not hidden underneath the original.
//
// The duplicate is an ordinary change, so it records a step first and Undo takes it back -- a
// paste that could not be undone would be a trap.

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
  // Selected, so the copy is the thing on screen: its name is in the list, and its dots can be
  // dragged straight away. Pasting into the middle of a drawing session puts that down first, so
  // the planner is looking at what they just made.
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
  // The document is whole-canvas, so a copy of a floor plan is a copy of its image too: pasting
  // enough of them can cross the 4 MB that save_bench() accepts. Measured before anything is
  // added, so a paste that could not be saved never happens.
  if (documentWouldOverflow(plan)) return
  // addPlan records the step, like every other write (see the section above).
  addPlan(plan)
  // Selected, so the copy is the thing on screen: its corners and its rotate knob appear
  // straight away. The bench draws them from the new mode on its own.
  mode.value = 'floorplan:' + plan.id
}

// Would adding this floor plan push the canvas over the cap save_bench() enforces? The document
// is rebuilt the way the page builds it (view + floorPlans + polygons), and measured with the
// same helper and the same byte count the save itself uses, so the two cannot disagree.
function documentWouldOverflow(addedPlan) {
  const doc = { view: layout.value.view, floorPlans: [...plans.value, addedPlan], polygons: areas.value }
  if (layoutBytes(JSON.stringify(doc)) <= MAX_LAYOUT_BYTES) return false
  errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
  return true
}

// A fresh id for a pasted thing. crypto.randomUUID is not available in every browser the app
// runs in (and not over plain http), so there is a fallback -- two rows sharing an id would be a
// far worse bug than a slightly weaker one.
function newId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'x' + Math.random().toString(36).slice(2) + Date.now().toString(36)
}

// Clicking an area -- on the map or in the list -- selects it. Clicking it again puts it
// back down, which is a lock, which is the save.
function selectArea(id) {
  mode.value = mode.value === 'area:' + id ? null : 'area:' + id
}

onMounted(() => {
  open()
  locks.start()
  window.addEventListener('keydown', onKeyDown)
  // A gesture ends when the pointer comes up, wherever it is: that is when a run of changes
  // becomes the one step it earned, rather than waiting for the quiet timer.
  window.addEventListener('pointerup', endGesture)
  window.addEventListener('pointercancel', endGesture)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeyDown)
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
      @plan-added="addPlan"
      @plan-updated="updatePlan"
      @plan-deleted="deletePlan"
      @plan-copied="copyPlan"
      @plan-pasted="pastePlan"
      @area-added="addArea"
      @area-updated="updateArea"
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
