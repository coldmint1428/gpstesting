<script setup>
// AreaBench - the drawing bench itself: the map, the floor plans on it, the areas drawn on
// top, and the controls that operate them.
//
// Six things are deliberate and worth knowing before changing anything:
//
// 1. ONE THING IS UNLOCKED AT A TIME. `mode` is null | 'floorplan:<id>' | 'polygons' |
//    'area:<id>'. Picking one locks the others, because two unlocked things is not a state the
//    value can express.
//
// 2. THE MAP ALWAYS PANS AND ALWAYS ZOOMS, and this component moves it -- Leaflet's own drag is
//    switched off (see startPan). The middle button pans EVERYWHERE: on the map, on a picture, on
//    an outline, on a handle, and while an area is being drawn. The left button pans wherever there
//    is nothing else for it to mean; a shape is picked up by its OWN parts -- an outline by its
//    body, a picture by the picture -- and those stop the press from reaching the map, so grabbing
//    one moves that shape and never the view.
//
// 3. LOCKED IS GONE, BUT `mode` STILL DECIDES WHAT IS CLICKABLE. Nothing on the map takes a click
//    while an area is being drawn, because every click there is a point. The middle button is the
//    exception to the exception: it moves the view there too.
//
// 4. A SHAPE AND THE VIEW NEVER MOVE TOGETHER. While a shape is dragged the view is still, and
//    when the drag reaches the edge of the map the view follows it -- so something can be put
//    somewhere that is not on screen yet without letting go. In the other direction, panning while
//    a shape is held moves the view alone: the shape keeps its geography and stays where it is on
//    screen, and the frame loop is stopped so it does not jump when the drag resumes.
//
// 5. THE PAGE OWNS THE DATA. This component only draws it and reports what the planner
//    did (emit), so there is exactly one place that saves. Undo is the page's too: the stack
//    is one timeline of the whole document (composables/useDocHistory.js), and the buttons for
//    it are on the page next to the other document-wide controls. All the bench does with the
//    stack is close a run of changes when a drag ends -- a dragged dot is one step, not sixty.
//
// 6. AN OUTLINE MAY NEVER CROSS ITSELF, and the answer to "would it?" is given while the
//    planner is still moving rather than when they let go: the outline turns red under a dot
//    that would cross, the way the loose end of the rubber band does while a ring is being
//    drawn. Nothing is committed until the drop, so the red is a look, not a state.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles (c) Singapore Land Authority - https://www.onemap.gov.sg
import { askConfirm } from '../composables/useNotify'
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { escapeHtml } from '../utils/people'
import {
  AREA_KINDS,
  AREA_MAX_POINTS,
  AREA_MIN_POINTS,
  areaStyle,
  areaTooltipHtml,
  isValidAreaName,
} from '../utils/areaKinds'
import {
  PLAN_NAME_MAX,
  angleFromPoints,
  cornersOf,
  defaultPlan,
  isValidPlanName,
  knobLatLng,
  latLngToMetres,
  metresToLatLng,
  pixelSize,
  planLabel,
  sizeFromCorner,
} from '../utils/floorPlan'
import { closingCrosses, pathCrossing, ringCrossing } from '../utils/areaShape'
import { growRing } from '../utils/areaGrow.js'
import { shrinkToUnder } from '../utils/imageShrink'
import { LAYOUT_TOO_LARGE_MESSAGE } from '../utils/layoutLimits'
import { useHistory } from '../composables/useHistory'

const props = defineProps({
  plans: { type: Array, default: () => [] },
  areas: { type: Array, default: () => [] },
  view: { type: Object, default: null }, // where the map was left
  // How close the bench is to the 4 MB cap the DATABASE enforces, and the same thing as a fraction for
  // the ring that shows it. Handed in rather than measured here because the PAGE owns the document: the
  // number is the database's own (counted over the rows, see 017_object_rows.sql) and only the page
  // knows it. See views/PolygonTestView.vue.
  sizeText: { type: String, default: '' },
  sizeRatio: { type: Number, default: 0 },
  // Would this floor plan fit? A function from the page for the same reason `sizeText` is a string from
  // it: a picture is stored ONCE however many floor plans use it, so what a new plan costs cannot be
  // worked out from the shapes alone -- see utils/layoutLimits.addedBytes and the planFits() in
  // PolygonTestView. Null means "do not ask" (an upload is then only checked by the database).
  planFits: { type: Function, default: null },
  // May this planner work on the bench at all? TRUE for everybody now: there is no claim to hold
  // and no Start editing to press, and who may change a particular SHAPE is settled one object at a
  // time by `locks` below (see 016_object_locks.sql). Looking and working are the same state.
  canEdit: { type: Boolean, default: true },
  // The per-object locks (composables/useBenchLocks.js). Handed in like the history and the
  // clipboard, because it is the page's session. Read here for two things: the sentence in the
  // strip, and refusing a press on a shape somebody else is holding before it moves at all.
  locks: { type: Object, default: null },
  // The undo stack of the whole document (see composables/useDocHistory.js). Handed in rather
  // than owned here, because a step is a change to the PAGE's document, not to one panel -- and
  // because a history that reset when the planner clicked away was the bug. All the bench does
  // with it is close a run of changes when a drag ends; the buttons live on the page.
  history: { type: Object, default: null },
  // What has been copied, so the paste buttons can say whether they have anything to paste.
  // The clipboard itself lives on the page (composables/useBenchClipboard.js).
  clipboard: { type: Object, default: null },
  // Who else is on the bench and what each of them has open (composables/useBenchPresence.js).
  // Handed in rather than owned here, like the history and the clipboard, because it is the PAGE's
  // session -- one row and one socket. This component only draws it.
  presence: { type: Object, default: null },
})

const emit = defineEmits([
  'plan-added',
  'plan-updated',
  'plan-deleted',
  'area-added',
  'area-updated',
  'area-deleted', // the Delete key on a selected area (the list's Delete button sends the same)
  // A shape being dragged, before the drop: the ring as it is at this moment, reported so the page
  // can publish it to the other planners (see useBenchFrames). NOT `area-updated`: nothing has been
  // decided yet, and a dot's drag is deliberately kept out of the document until it is let go.
  'area-frame',
  'view-changed',
  // A copy is just news -- the page keeps the clipboard. A paste is a request for a new thing,
  // built by the page because the page owns the document.
  'area-copied',
  'area-pasted',
  'plan-copied',
  'plan-pasted',
])

// null | 'floorplan:<id>' | 'polygons' | 'area:<id>'
const mode = defineModel('mode', { default: null })

const mapEl = ref(null)
const fileInput = ref(null)
const nameInput = ref(null)
// Anything the PLANNER has to read before they can put a dot down, or while they are dragging
// one: a refused point, an outline that would cross itself, the name a shape still needs. Every
// one of these is one sentence, they replace each other, and they are all about the map -- which
// is why they are one variable.
//
// They used to arrive in two places: the drawing hint along the top of the map while a ring was
// being drawn, and a Bootstrap alert in the controls column while an existing shape was being
// edited. The same sentence about the same outline coming out of two different places, at two
// different ends of the page, is what made the bench feel like two tools. There is one place now:
// the strip along the top of the map, red, for both.
const errorMsg = ref('')
const busy = ref(false)

// Leaflet objects are plain variables, never reactive: they are not Vue's to manage.
let map = null
const planLayers = {} // plan id -> { img, plan, place, add, remove }
const areaLayers = {} // area id -> L.polygon

// Who else has what open, drawn as a name chip on the shape (see renderPresence). A chip is a
// Leaflet marker carrying a divIcon, which lands in the marker pane ABOVE the floor-plan pictures
// and the drawn outlines -- so a chip is never buried under the shape it belongs to.
let presenceGroup = null
const presenceChips = {} // presence id -> { marker, key }

// Drawing state
const draftPoints = ref([])
const draftClosed = ref(false)
const draftName = ref('')
const draftKind = ref('zone')
// True while the cursor is close enough to the first point that clicking would close the
// ring. Drives both the rubber band and the look of the first dot.
const snapActive = ref(false)
// True while a click where the cursor is would make the outline cross a line already drawn.
// That click is refused, so the rubber band turns red before it is made rather than after.
const crossWarn = ref(false)
let cursorLatLng = null
let draftVertexMarkers = []
let draftLine = null
let draftFill = null

// Undo belongs to the PAGE: one timeline of the whole document (see
// composables/useDocHistory.js), handed in as `history` so the buttons can sit over the map
// instead of inside each panel. The one thing that is still local is the ring being DRAWN: it
// is not part of the document until Save, so `draftSteps` is its own small stack, and it is
// thrown away whenever the drawing session ends.
const HISTORY_LIMIT = 50
const draftSteps = useHistory(HISTORY_LIMIT)
// Above this line the history is a PROP, and all the bench does with it is close a run of changes
// when a drag ends (endDrag / endAreaDrag -> endHistoryRun). The Undo and Redo buttons are on the
// page, next to the document-wide controls, because a step is not a property of the map -- see
// views/PolygonTestView.vue.

// Handle positions, in pixels inside the map container
const handlePoints = ref([])
const knobPoint = ref(null)
let dragState = null
let areaDrag = null
// A dot's own drag, latched the same way and for the same reason: `point` is the dot as it was when
// the pointer's offset was last taken and `from` is where the pointer was then. One measurement, so
// reanchor has to move the two together -- see there.
let vertexDrag = null
// Whether the press on a dot has travelled far enough to be a drag rather than a click. It decides
// both what the drop does and whether the click that ends the gesture means "remove this point".
let vertexMoved = false
// How far a press on a dot may wobble and still count as a click on it rather than a drag of it.
// Leaflet's own drag used 3 px as its click tolerance, and clicking a dot to remove it has to stay
// exactly as easy to do as it was.
const VERTEX_SLOP_PX = 3

// Vertices of the area whose shape is being adjusted
let areaVertexMarkers = []
let zoomAnimating = false

// The middle button, wherever it is pressed, and whatever happens to be under it.
//
// A shape is grabbed with the LEFT button, because that is what a press on a shape means. The
// middle button means the same thing everywhere on the map -- move the view -- which is the way out
// when the thing being dragged covers most of what can be seen: a picture is often the size of the
// screen, and left-dragging it moves the picture rather than the view.
//
// It used to be handed to Leaflet's own drag handler, which does accept the middle button, by
// declining the press and letting it through. That is NOT enough any more: Leaflet binds its drag
// to the map container and unbinds it while an area is drawn, so the very mode that most needs to
// be pannable had no handler to receive the press. The view is now moved here instead, by
// startPan -- see "The view is moved here" below.
function wantsMapPan(event) {
  return event.button === 1
}

// How near the edge of the map a drag has to come before the view starts following it, how fast it
// follows once the pointer reaches the map's own edge, how much faster each further pixel of
// overshoot makes it, and the speed the climb stops at. See beginAutoPan and panSpeed.
const EDGE_PX = 40
const AUTO_PAN_EDGE_PX = 8
const AUTO_PAN_GAIN = 0.1
const AUTO_PAN_MAX_PX = 32

// The view follows a shape that is dragged past the edge of the map. Without it, moving something
// somewhere that is not on screen is two gestures -- drop it, pan, pick it up again -- and the
// second one lands it somewhere other than where the planner was pointing.
let autoPanFrame = null
let autoPanPointer = null
let autoPanMove = null
// Whether the follow in flight is a HOVER's rather than a drag's. The two differ in one way that
// matters to the frame loop: a drag is held, so the loop keeps asking even when there is nothing to
// do; a hover is not, so an idle frame ends it and the next move re-arms it. See autoPanStep.
let autoPanHover = false
// Whether the drawing hover's listener is installed. It comes and goes with the mode.
let hoverFollowOn = false

// The view moves whenever the planner asks it to, and what "asks" means is: the middle button
// anywhere, or the left button anywhere there is nothing else for it to mean. Drawing an area is
// the one place the LEFT button does not move the view, because a click there IS a point.
//
// Zooming never needs any of this. The wheel zooms AROUND THE CURSOR, so the place under the cursor
// stays under the cursor; the corner handles and the knob are re-placed on zoomend, and the draft
// ring is geographic, so it lands exactly right too.
//
// A wheel over the map must never scroll the page and never zoom the browser -- see onMapWheel,
// which is what actually guarantees that.
const ZOOM_HANDLERS = ['scrollWheelZoom', 'touchZoom']

// ---------- The view is moved here ----------
// Leaflet's own drag is switched OFF, and the view is moved by the code below instead. The reason
// is that a shape drag and a map drag cannot both be live: Leaflet binds its drag to the map
// container and starts it from the same press a shape takes, so dragging a shape moved the view as
// well. That is not a detail -- it is what made a picture look as though it slid out from under
// the cursor, and an outline look as though it stayed still while the map ran away underneath it.
//
// Owning it also buys the one thing Leaflet cannot be asked for: panning by the middle button in
// EVERY mode. Leaflet's drag handler is enabled or disabled as a whole, and drawing an area needs
// it off, so a middle press while drawing had no handler left to receive it.
//
// `panFrom` is the geography under the pointer at the moment of the press. Every move asks where
// that same place is now and puts it back under the pointer. Working in geography rather than in
// pixels means the pan stays correct across a zoom, with nothing to keep in step by hand.
let panFrom = null
let panPoint = null
let panPointerId = null
// How far the pointer has travelled in total, and whether that was far enough to call the press a
// pan. Both are about the click that arrives at the END of a press: the browser fires one whether
// or not the view moved, and while drawing a click is a point -- so a drag of the map must not
// leave a dot behind it. Half a pixel of jitter is not a drag.
const PAN_SLOP_PX = 2
let panTravel = 0
let panMoved = false

// Leaflet animates a zoom by transforming each `.leaflet-zoom-animated` element and letting
// CSS carry it across in 250 ms. A hand-built <img> gets none of that: it used to sit still
// through the whole animation and then jump. Two facts make it easy to fix: while the
// animation runs, `map.getZoom()` is already the NEW zoom, so the final pixel geometry can
// be written straight away; and CSS interpolates left/top/width/height with the very same
// curve Leaflet uses for its transform, so the picture travels with the tiles, exactly.
const ZOOM_MS = 250
const ZOOM_EASE = 'cubic-bezier(0, 0, 0.25, 1)'
const ZOOM_TRANSITION = ['left', 'top', 'width', 'height']
  .map((prop) => prop + ' ' + ZOOM_MS + 'ms ' + ZOOM_EASE)
  .join(', ')

// Where a floor plan sits among its siblings inside Leaflet's overlay pane. The vector renderer for
// the area outlines is at z-index 200 in that same pane, so these two numbers are what decide
// whether a plan can be pressed where an outline overlaps it. See place().
const PLAN_ON_TOP_Z = '300' // the one being worked on: above the outlines, below the marker pane
const PLAN_UNDER_Z = '-1' // every other plan: behind the outlines, as a background should be

// How near the cursor has to come to the first point before the ring snaps shut, in screen
// pixels. Generous on purpose: closing a shape should not be a test of aim, and a fingertip
// covers far more than a mouse pointer does.
const SNAP_PX = 15

// How near a click has to land to the previous point to not be a point at all. A double-click
// fires two clicks in the same place, and two points in the same place would be a zero-length
// edge -- which the crossing check would then read as a shape touching itself, and the planner
// would be told their next click crosses a line when all they did was double-click.
const DUPLICATE_PX = 2

// The red shared by every "this is the thing that will not be allowed to exist": the loose end of
// the rubber band while it would cross a line already drawn, and an existing outline while a dot
// is being dragged somewhere it would cross itself. One colour for one idea.
const CROSS_COLOUR = '#dc3545'

// The few things worth a sentence, and no more than a sentence each. The red on the outline says
// "not there" while the planner is still moving, so a message that only repeats it is noise: there
// is deliberately no "the outline would cross itself" while a dot is being dragged, and no "a new
// point would cross this outline" when Add point cannot find a place -- in both cases the shape
// visibly does not change, which is the answer. What is left is what the planner cannot see.
const CROSS_DRAW_MESSAGE = 'That line would cross one you have already drawn.'
const CROSS_CLOSE_MESSAGE = 'The closing line would cross the shape. Add another point.'
const CROSS_VERTEX_MESSAGE = 'That would cross the outline, so the dot went back.'
const CROSS_REMOVE_MESSAGE = 'Removing that point would cross the outline.'
const CROSS_ADD_MESSAGE = 'A point there would cross the outline.'

const editingPlan = computed(() => {
  if (typeof mode.value !== 'string' || !mode.value.startsWith('floorplan:')) return null
  const id = mode.value.slice('floorplan:'.length)
  return props.plans.find((p) => p.id === id) || null
})

const editingArea = computed(() => {
  if (typeof mode.value !== 'string' || !mode.value.startsWith('area:')) return null
  const id = mode.value.slice('area:'.length)
  return props.areas.find((a) => a.id === id) || null
})

// What on the map takes a click. Nothing does while an area is being DRAWN -- every click there is
// a point, and a picture or an outline that took one would swallow it. Otherwise a floor plan and
// an outline can both be picked up, and each of them stops the press from also reaching the map, so
// grabbing one never pans.
const shapesClickable = computed(() => props.canEdit && mode.value !== 'polygons')

// What the strip along the top of the map says while a shape is open. One line, about the one
// thing the planner cannot guess -- what a dot does. A floor plan says nothing: its handles and its
// knob are already the only things on it that can be pressed.
const editHint = computed(() =>
  editingArea.value ? 'Drag a dot to move it, click a dot to remove it, click an edge to add one.' : '',
)

// Is anything at all wanted along the top of the map? While drawing, yes -- there is always
// something to say, and a refusal is inside that same chain of messages.
// Who else has this shape, if anyone. Read from PRESENCE -- the hint streamed by
// useBenchPresence -- so that a press is refused instantly, without a round trip. A planner who
// really is holding it still has the last word, from the database, in the page's write handlers;
// nothing this display says ever decides anything.
function holderOf(objectId) {
  if (!objectId) return null
  const watchers = props.presence ? props.presence.byObject.value[objectId] : null
  return watchers ? watchers.find((who) => who.active) || null : null
}

// Is this shape blocked for me -- by the hint above, or by a refusal the database has already given
// this page? One predicate, and every press asks it.
function blockedBy(objectId) {
  if (!objectId) return null
  const holding = holderOf(objectId)
  if (holding) return holding

  const refused = props.locks ? props.locks.refused.value : null
  return refused && refused.objectId === objectId ? refused : null
}

// A press on a shape somebody else is holding: refused, AND SAID. The sentence goes through the same
// refusal the database's own refusals use (see useBenchLocks.refuseHere), so the strip has one source
// for it and one timer behind it -- and a planner who presses a locked shape is told who has it,
// instead of watching nothing happen. Presence is only a hint, so this is a courtesy: the shape does
// not move either way, and what would refuse a change is the lock. Returns whatever blocked the
// press, or null when nothing did.
function refusePress(objectId) {
  const holding = holderOf(objectId)
  if (!holding) return blockedBy(objectId)
  if (props.locks) props.locks.refuseHere(objectId, holding.label, holding.mine)
  return holding
}

// The sentence the strip says when a change was refused because somebody else is on that shape --
// or because it is this planner's own other window, or because the database will not store the shape at
// all (a ring dragged off the edge of Singapore, say). One place says no, and this is it.
const lockNotice = computed(() => {
  const refused = props.locks ? props.locks.refused.value : null
  if (!refused) return ''
  if (refused.error) return refused.error
  if (refused.problem) return refused.problem
  if (refused.mine) return 'You are editing this in another window.'
  return (refused.name || 'Somebody else') + ' is editing this.'
})

const showHint = computed(
  () => mode.value === 'polygons' || Boolean(editHint.value) || Boolean(lockNotice.value),
)

// A refusal has to be SEEN to have happened. A drag draws the shape under the pointer as it goes
// (see onAreaDragMove), so a change the page then refuses would leave the outline displaced until
// something else happened to repaint it. Redrawing from the document puts it back where it really
// is, at the moment the refusal lands.
watch(
  () => (props.locks ? props.locks.refused.value : null),
  () => render(),
)

// How full the size ring is, and what colour it is. The ring is drawn with `pathLength="100"`, so
// the numbers are percentages and there is no circumference to keep in step with the radius.
// Green well clear of the cap, amber when the next picture is worth thinking about twice, red when
// a save is about to be refused -- the same three colours a progress bar uses.
const ringPercent = computed(() => Math.round(Math.min(Math.max(props.sizeRatio, 0), 1) * 100))

const ringVariant = computed(() => {
  if (props.sizeRatio >= 0.9) return 'danger'
  if (props.sizeRatio >= 0.75) return 'warning'
  return 'success'
})


// The ring has all the points it is allowed. The map stops taking clicks at this point, so
// the hint has to say so -- otherwise the crosshair simply stops responding and it looks
// like the map has broken.
const reachedPointCap = computed(() => draftPoints.value.length >= AREA_MAX_POINTS)

// Would closing the ring now make the last line cross the shape? A shape can be perfectly
// legal as far as the drawn path goes and still be impossible to close -- an inward spiral is
// the plain example -- so this is a different question from the one asked of each point, and
// it is what the Finish button and the hint report.
const closeBlocked = computed(
  () => draftPoints.value.length >= AREA_MIN_POINTS && closingCrosses(draftPoints.value),
)

// Would a click here make the outline cross a line already drawn? Asked on every mouse move so
// the answer is on screen before the click rather than after it, and again when the click
// arrives. A path of fewer than three points cannot cross anything: it has at most two edges,
// and two edges that meet only at the end they share are not a crossing.
function wouldCrossNext(latlng) {
  if (draftPoints.value.length < 3) return false
  return Boolean(pathCrossing([...draftPoints.value, [latlng.lat, latlng.lng]]))
}

// Does the shape being adjusted already cross itself? An older build could leave one behind, and
// every edit to it is refused until it is put right -- which is correct, but looks exactly like
// a broken page unless it is said out loud. The repair is one drag that lands on a legal shape,
// or Delete and draw it again.
const editingAreaCrosses = computed(() => {
  const area = editingArea.value
  return Boolean(area && Array.isArray(area.points) && ringCrossing(area.points))
})

// Does the bench have an area or a floor plan on its clipboard? Asked so the Paste buttons can
// say whether they have anything to paste, and what.
const canPasteArea = computed(() => Boolean(props.clipboard && props.clipboard.area.value))
const canPastePlan = computed(() => Boolean(props.clipboard && props.clipboard.plan.value))
const clipboardAreaName = computed(() =>
  props.clipboard && props.clipboard.area.value ? props.clipboard.area.value.name : '',
)
const clipboardPlanName = computed(() =>
  props.clipboard && props.clipboard.plan.value ? props.clipboard.plan.value.name : '',
)

// Copying and pasting. The copy is reported because the PAGE holds the clipboard; the paste is
// reported because the PAGE holds the document. Both go through the page so there is one place
// that decides what a duplicate is -- a new id, a name that is not already taken, and a place to
// put it.
function copyArea(area) {
  if (!area) return
  emit('area-copied', area)
}

function pasteArea() {
  if (!props.clipboard || !props.clipboard.area.value) return
  emit('area-pasted')
}

function copyPlan(plan) {
  if (!plan) return
  emit('plan-copied', plan)
}

function pastePlan() {
  if (!props.clipboard || !props.clipboard.plan.value) return
  emit('plan-pasted')
}

function newId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'x' + Math.random().toString(36).slice(2) + Date.now().toString(36)
}

// ---------- Floor plan layers ----------
// Leaflet's own image overlay cannot rotate, so the picture is an <img> in the overlay
// pane, positioned from its geographic centre and sized in pixels at the current zoom.
// Because the placement is geographic, panning needs nothing; only zoom changes it.
function makePlanLayer(plan) {
  const img = document.createElement('img')
  img.className = 'bench-plan'
  img.src = plan.image
  img.alt = ''
  img.draggable = false

  // `layer.plan` is swapped for the new object on every update and `place()` reads it each
  // time. Reading the `plan` ARGUMENT instead would freeze the picture at whatever the plan
  // looked like when its <img> was created -- which is exactly why turning, resizing and
  // fading a floor plan only appeared after a reload.
  const layer = {
    img,
    plan,
    sourceImage: plan.image,
    onMap: false,

    place(animate) {
      if (!layer.onMap || !map) return
      const p = layer.plan
      const mine = mode.value === 'floorplan:' + p.id

      const point = map.latLngToLayerPoint(L.latLng(p.centre[0], p.centre[1]))
      const { wPx, hPx } = pixelSize(p, p.centre[0], map.getZoom())

      // Only a zoom animation gets a transition: a drag, a slider or a pan must land
      // exactly where it is put, with no easing in between.
      img.style.transition = animate ? ZOOM_TRANSITION : ''
      img.style.left = point.x + 'px'
      img.style.top = point.y + 'px'
      img.style.width = wPx + 'px'
      img.style.height = hPx + 'px'
      img.style.transform = 'translate(-50%, -50%) rotate(' + (p.angleDeg || 0) + 'deg)'
      img.style.opacity = String(p.opacity)
      img.style.display = p.visible === false ? 'none' : ''

      // A picture that accepts pointer events swallows the map's own drags and taps -- which is
      // exactly what is wanted: a drag that starts on the picture moves the picture, and a drag
      // that starts anywhere else moves the view. So it takes them whenever a click on it means
      // something, and never while an area is being drawn.
      const grabbable = shapesClickable.value
      img.style.pointerEvents = grabbable ? 'auto' : 'none'
      img.style.touchAction = grabbable ? 'none' : ''
      img.style.cursor = grabbable ? (mine ? 'move' : 'pointer') : ''
      // The one being worked on sits above its neighbours, and above the area outlines.
      //
      // That second part is not decoration. Leaflet's SVG renderer sits at z-index 200 inside this
      // same pane, so a plan left at 0 or -1 is BELOW every area outline -- and an outline takes the
      // press, so a floor plan could not be grabbed at all wherever an area overlapped it. Measured,
      // not guessed: with the plan selected the browser still reported a `<path>` under the cursor.
      // 300 puts the selected plan over the vector layer and still under the marker and tooltip
      // panes (600 and 650), so it can never cover the map's own controls.
      img.style.zIndex = mine ? PLAN_ON_TOP_Z : PLAN_UNDER_Z
    },

    add() {
      if (layer.onMap || !map) return
      map.getPanes().overlayPane.appendChild(img)
      layer.onMap = true
      layer.place()
    },

    remove() {
      if (!layer.onMap) return
      if (img.parentNode) img.parentNode.removeChild(img)
      layer.onMap = false
    },
  }

  img.addEventListener('pointerdown', (event) => onPlanPointerDown(layer, event))

  return layer
}

// Picking a floor plan up off the map. The same gesture also selects it, so a plan can be
// chosen and then moved without letting go in between. The press never reaches the map, so it does
// not pan as well.
function onPlanPointerDown(layer, event) {
  // The middle button is for moving the view, never for picking a picture up. Leaflet's own
  // draggables already ignore it; this one has to be told.
  // A press with anything but the left button belongs to the map. See wantsMapPan.
  if (wantsMapPan(event)) {
    if (event.preventDefault) event.preventDefault() // no middle-click autoscroll cursor
    return
  }
  if (!shapesClickable.value) return
  const plan = layer.plan
  const myMode = 'floorplan:' + plan.id

  // A press on a picture is a fresh start: whatever was refused about something else goes away.
  errorMsg.value = ''

  // Picking the picture up leaves the view alone: it is under the cursor, and a fit to it would move
  // the ground under the drag that is about to begin -- see viewAlreadyRight.
  if (mode.value !== myMode) {
    viewAlreadyRight = true
    mode.value = myMode
  }
  startDrag('move', plan, event)
}

function areaKey(area) {
  return JSON.stringify([area.kind, area.name, area.points])
}

// Move an area's outline, and its label with it.
//
// `crossing` is the one thing about an outline that is not in the area's kind: the shape the
// planner is dragging right now, which would cross itself if they let go. It is drawn in the same
// red as the refused line while a ring is being drawn, so the answer to "may I drop it here?"
// arrives while the dot is moving rather than on release -- and it is only ever a LOOK, never a
// second source of truth: the area's own points are not touched until the drop.
//
// A permanent Leaflet tooltip works out its own position ONCE, when it opens, and never
// looks again -- so moving the polygon leaves the name behind. Setting the label's latlng to
// the polygon's new centre is what puts it back on top of the shape.
function applyAreaPoints(layer, points, crossing = false) {
  if (!layer) return
  layer.setLatLngs(points)

  if (layer.benchCrossing !== crossing) {
    layer.benchCrossing = crossing
    const style = areaStyle(layer.benchKind)
    layer.setStyle(
      crossing
        ? { ...style, color: CROSS_COLOUR, weight: 3, opacity: 1, fillOpacity: 0.32 }
        : style,
    )
  }

  const tip = layer.getTooltip()
  if (!tip) return

  let centre = null
  try {
    centre = layer.getCenter() // the area's centroid, not just the middle of its bounds
  } catch {
    centre = null
  }
  if (!centre || !Number.isFinite(centre.lat) || !Number.isFinite(centre.lng)) {
    const bounds = layer.getBounds()
    if (!bounds || !bounds.isValid()) return
    centre = bounds.getCenter()
  }
  tip.setLatLng(centre)
}

// ---------- Who else is on the bench ----------
// Presence is drawn from what is ALREADY on the map (the layers) rather than from the document, so
// a chip stays on a shape that is being dragged -- and it is drawn on a layer of its own, because
// presence changes on every heartbeat and none of that should cost a repaint of the shapes.
//
// Nothing here decides anything. A chip says "Ali has this open"; whether Ali may change it, and
// whether I may, is settled by the database when a change is actually attempted (step 8).
function presenceAnchor(objectId) {
  const layer = areaLayers[objectId]
  if (layer) {
    try {
      const centre = layer.getCenter() // the area's centroid, not the middle of its bounds
      if (centre && Number.isFinite(centre.lat) && Number.isFinite(centre.lng)) return centre
    } catch {
      // A ring with too few points to have a centroid; the bounds below still describe it.
    }
    const bounds = layer.getBounds()
    return bounds && bounds.isValid() ? bounds.getCenter() : null
  }

  const plan = props.plans.find((p) => p.id === objectId)
  if (!plan) return null
  // The four corners go through the same helper the handles use, so a chip on a turned picture
  // sits where the picture is actually drawn rather than where its centre happens to be stored.
  const bounds = L.latLngBounds(cornersOf(plan).map(([lat, lng]) => L.latLng(lat, lng)))
  return bounds.isValid() ? bounds.getCenter() : null
}

// The chip itself. `offset` lifts each extra planner above the one below, so two people on one
// shape read as a small stack instead of one smudged label; the constant 22px is what clears the
// area's own name label, which Leaflet pins to the same centre point.
function chipHtml(who, offset) {
  const lock = who.active ? '<span class="bench-chip-lock" aria-hidden="true">&#128274;</span>' : ''
  return (
    '<div class="bench-chip" style="--chip:' +
    who.colour +
    '; transform: translate(-50%, calc(-50% - ' +
    (22 + offset) +
    'px))">' +
    lock +
    escapeHtml(who.label) +
    '</div>'
  )
}

function renderPresence() {
  if (!map) return
  if (!presenceGroup) presenceGroup = L.layerGroup().addTo(map)

  const byObject = props.presence ? props.presence.byObject.value : {}
  const seen = new Set()

  for (const objectId of Object.keys(byObject)) {
    const anchor = presenceAnchor(objectId)
    if (!anchor) continue

    byObject[objectId].forEach((who, index) => {
      seen.add(who.presenceId)
      const key = who.colour + '|' + who.label + '|' + (who.active ? '1' : '0') + '|' + index
      let chip = presenceChips[who.presenceId]

      if (chip && chip.key !== key) {
        // The name, the colour or the stack position changed: redraw the icon in place rather than
        // tearing the marker down, which would make every chip flicker on every heartbeat.
        chip.marker.setIcon(
          L.divIcon({ className: 'bench-chip-wrap', html: chipHtml(who, index * 18), iconSize: [0, 0] }),
        )
        chip.key = key
      } else if (!chip) {
        chip = {
          key,
          marker: L.marker(anchor, {
            interactive: false, // a chip is a label: it must never swallow a press meant for the shape
            keyboard: false,
            icon: L.divIcon({ className: 'bench-chip-wrap', html: chipHtml(who, index * 18), iconSize: [0, 0] }),
          }),
        }
        chip.marker.addTo(presenceGroup)
        presenceChips[who.presenceId] = chip
      }

      chip.marker.setLatLng(anchor)
    })
  }

  // Anyone who has left, or who has nothing open any more, loses their chip.
  for (const id of Object.keys(presenceChips)) {
    if (seen.has(id)) continue
    presenceChips[id].marker.remove()
    delete presenceChips[id]
  }
}

// Is a dot of this area under the planner's finger right now? A dot's drag is the one gesture that
// does NOT report to the page until it is let go (see onVertexMove), so while it is happening the
// props still hold the ring as it was and the layer is ahead of them. Everything that would draw the
// shape from the document has to leave both the dot and the outline alone until the drop, or a
// render caused by anything else at all -- another planner's live frame, most of all -- would flick
// the outline back to where the drag started, twenty times a second.
function draggingVertices(objectId) {
  return Boolean(vertexDrag && vertexDrag.id === objectId)
}

function render() {
  if (!map) return

  // Floor plans. Each one carries its own show/hide, so there is nothing global to consult.
  const seenPlans = new Set()
  for (const plan of props.plans) {
    seenPlans.add(plan.id)
    let layer = planLayers[plan.id]
    if (layer && layer.sourceImage !== plan.image) {
      layer.remove()
      delete planLayers[plan.id]
      layer = null
    }
    if (!layer) {
      layer = makePlanLayer(plan)
      planLayers[plan.id] = layer
      layer.add()
    } else {
      layer.plan = plan
      const shouldShow = plan.visible !== false
      const isShown = layer.img.parentNode != null
      if (shouldShow && !isShown) layer.add()
      else if (!shouldShow && isShown) layer.remove()
    }
    layer.place()
  }
  for (const id of Object.keys(planLayers)) {
    if (!seenPlans.has(id)) {
      planLayers[id].remove()
      delete planLayers[id]
    }
  }

  // Areas. An interactive polygon swallows the drags and taps underneath it, which is what makes a
  // drag that starts on the outline move the outline rather than the view -- so it is interactive
  // whenever a click on it means something, and never while an area is being drawn, where every
  // click on the map is a point.
  const clickable = shapesClickable.value
  const seenAreas = new Set()
  for (const area of props.areas) {
    seenAreas.add(area.id)
    const key = areaKey(area)
    let layer = areaLayers[area.id]
    if (layer && layer.benchClickable !== clickable) {
      layer.remove()
      delete areaLayers[area.id]
      layer = null
    }
    if (!layer) {
      layer = L.polygon(area.points, { ...areaStyle(area.kind), interactive: clickable }).addTo(map)
      layer.bindTooltip(areaTooltipHtml(area.kind, escapeHtml(area.name)), {
        permanent: true,
        direction: 'center',
        className: 'area-label',
      })
      layer.benchKey = key
      layer.benchStyleKey = area.kind + '\u0000' + area.name
      layer.benchKind = area.kind
      // Whatever this layer was reddened for mid-drag, it is drawn fresh here, and the area's own
      // points are by definition not crossing.
      layer.benchCrossing = false
      layer.benchClickable = clickable
      areaLayers[area.id] = layer
      if (clickable) {
        // A native pointer event, not Leaflet's `mousedown`: pointer events cover mouse,
        // finger and stylus with one path, and Leaflet's own touch events would never reach
        // this handler. The handler stops the press reaching the map, which is what keeps a drag
        // of the outline from panning the view as well.
        const el = layer.getElement()
        if (el) {
          el.style.cursor = 'move'
          el.addEventListener('pointerdown', (event) => onAreaPointerDown(area.id, event))
        }
      }
    } else {
      // Shape and look are compared separately: dragging an area rewrites its points many
      // times a second, and there is no reason to rewrite the colour and the label too.
      const styleKey = area.kind + '\u0000' + area.name
      if (layer.benchKey !== key && !draggingVertices(area.id)) {
        // `benchKey` is deliberately NOT updated for an area whose dot is being dragged: the layer
        // is where the drag has drawn it, the props are behind, and leaving the key alone is what
        // makes the next render after the drop put the shape back in step with the document.
        applyAreaPoints(layer, area.points)
        layer.benchKey = key
      }
      if (layer.benchStyleKey !== styleKey) {
        layer.benchKind = area.kind
        layer.benchCrossing = false // re-styled from the area, which is not crossing
        layer.setStyle(areaStyle(area.kind))
        layer.setTooltipContent(areaTooltipHtml(area.kind, escapeHtml(area.name)))
        layer.benchStyleKey = styleKey
      }
    }
  }
  for (const id of Object.keys(areaLayers)) {
    if (!seenAreas.has(id)) {
      areaLayers[id].remove()
      delete areaLayers[id]
    }
  }

  // Drawn last, so a chip lands on a shape that already exists this pass. Everything that moves a
  // shape ends up here (the page replaces the area or the plan and the watchers below call render),
  // which is why the chips need no hooks of their own on the drag paths.
  renderPresence()
}

// ---------- What the map's own pointer does ----------
// Nothing here is a lock. `mode` decides what the LEFT button means and what takes a click; the
// view is moved by the middle button in every mode, and by the left button wherever there is
// nothing else for it to mean. See wantsPan.
function applyMapHandlers() {
  if (!map) return
  const set = (name, on) => {
    const handler = map[name]
    if (!handler) return
    if (on) handler.enable()
    else handler.disable()
  }
  const drawing = mode.value === 'polygons'
  // The view is moved by this component now, never by Leaflet -- see startPan. Leaflet's drag has
  // to be off in EVERY mode, not only while drawing: left on, it would take the same press a shape
  // takes and drag the view at the same time as the shape.
  set('dragging', false)
  // Box zoom is a left-drag on the map that draws a rectangle. That is the same gesture as moving
  // the view, so the two cannot both be bound; the view is the one the planner expects, and the
  // wheel already zooms.
  set('boxZoom', false)
  set('keyboard', !drawing)
  for (const name of ZOOM_HANDLERS) set(name, true)
  // Drawing an area is a run of quick clicks on the map, so a double-click there is two points
  // in one spot rather than a zoom. Everywhere else it is an ordinary way to zoom in.
  set('doubleClickZoom', !drawing)
  // The view follows the pointer while a ring is being drawn -- see onHoverMove. Its listener comes
  // and goes with the mode for the same reason the handlers above do.
  setHoverFollow(drawing && props.canEdit)
}

// The page must never scroll or zoom because of a wheel over the map. Leaflet's own wheel
// handler already does this while it is enabled -- it calls preventDefault and stopPropagation
// on every wheel event it sees -- but a handler that is disabled lets the event through, and
// that is how reaching for the map scrolled the page. This listener is attached ONCE and never
// toggled, so the map is a wall against page scrolling whatever state it is in. It deliberately
// does not stop propagation of its own: Leaflet still sees the event and zooms.
function onMapWheel(event) {
  if (event.cancelable) event.preventDefault()
}

// A wheel event is only cancelable if the browser is told not to treat the listener as passive,
// which is the third argument of addEventListener -- hence the explicit option rather than the
// default.
const WHEEL_OPTIONS = { passive: false }

// The view is remembered whenever the map settles, not only while a shape is open: looking around
// works in every mode, and coming back to the bench at the view you left it at is the whole point of
// remembering it. Only the final resting view is reported -- moveend and zoomend are the settling
// events, so a drag of the view does not send a request per frame.
function emitView() {
  if (!map) return
  const centre = map.getCenter()
  emit('view-changed', { lat: centre.lat, lng: centre.lng, zoom: map.getZoom() })
}

// ---------- Handles and knob ----------
function renderHandles() {
  const plan = editingPlan.value
  if (!map || !plan) {
    handlePoints.value = []
    knobPoint.value = null
    return
  }

  // Handles are kept inside the map, so a plan that hangs off the edge can still be
  // grabbed. Nudging one is safe because a drag measures itself from the CURSOR, never
  // from the handle: a pulled-in corner resizes and turns exactly as it should.
  const size = map.getSize()
  const inset = 12
  const clamp = (point) => ({
    x: Math.min(Math.max(point.x, inset), Math.max(inset, size.x - inset)),
    y: Math.min(Math.max(point.y, inset), Math.max(inset, size.y - inset)),
  })

  handlePoints.value = cornersOf(plan).map((corner) => {
    const p = map.latLngToContainerPoint(L.latLng(corner[0], corner[1]))
    return clamp(p)
  })

  const k = knobLatLng(plan)
  const kp = map.latLngToContainerPoint(L.latLng(k[0], k[1]))
  knobPoint.value = clamp(kp)
}

// `plan` is passed in rather than read from `editingPlan`, because the plan being dragged is the
// one this press belongs to -- the mode may not have caught up yet.
function startDrag(kind, plan, event, index) {
  if (!props.canEdit) return
  // A press with anything but the left button belongs to the map. See wantsMapPan.
  if (wantsMapPan(event)) {
    if (event.preventDefault) event.preventDefault() // no middle-click autoscroll cursor
    return
  }
  if (!plan || !map) return
  // A floor plan is an object like any other, so picking one up is refused exactly as an outline is
  // (see refusePress). This was missing: a picture somebody else was holding could be dragged out
  // from under them on this screen and only snapped back when the save came back refused.
  if (refusePress(plan.id)) return
  event.preventDefault()
  event.stopPropagation()
  dragState = { kind, plan, index }
  if (kind === 'move') {
    // Recorded once, in geography: every move is then measured from here, so the picture
    // follows the pointer exactly instead of accumulating rounding at every step.
    dragState.from = map.containerPointToLatLng(map.mouseEventToContainerPoint(event))
    dragState.centre = [plan.centre[0], plan.centre[1]]
    beginAutoPan(event)
  }
  window.addEventListener('pointermove', onDragMove)
  window.addEventListener('pointerup', endDrag)
  window.addEventListener('pointercancel', endDrag)
}

// Put a drag that is still in progress back in step with the view, AFTER the view has moved.
//
// A shape drag is measured as "where the shape was when the offset was last taken, plus how far
// the pointer has come since": `from` is the geography the pointer was over then, and `points` /
// `centre` is the shape as it was then. The two are one measurement, so they have to move together.
// A dragged dot is the same thing with one coordinate instead of a ring: `from` is still the
// pointer, `point` is the dot.
//
// This used to move `from` on its own, and that silently threw away every metre the shape had
// already travelled -- the drag restarted from where it began. Measured on the real page, with the
// map 550 px wide: a floor plan dragged out through the right-hand edge followed the cursor for
// 195 px, and the moment the auto-pan started it jumped back to where it had been picked up and
// then travelled with the map instead of with the cursor. An outline did the same, and worse: the
// anchor it was writing there was a lat/lng where a pixel point belonged (see onAreaDragMove), so
// the next move measured from NaN and the shape was gone.
//
// Re-basing first and re-anchoring second is what makes it a no-op on screen: the shape is moved
// on by exactly what the view moved under it, so it is left where the cursor is. The move handler
// is then run with the pointer where it already is, which draws the shape from the new anchor and
// reports it -- so the page's copy of the document never lags the drag, not even while the pointer
// is held still against the edge and no move events are arriving at all.
function reanchor() {
  // A corner or the rotation knob has no anchor and no base -- both are measured from the CURSOR on
  // every move (see renderHandles), so there is nothing here to put back in step.
  const moving = dragState && dragState.from ? dragState : null
  const latch = moving || areaDrag || vertexDrag
  if (!latch || !map || !autoPanPointer) return
  const here = map.containerPointToLatLng(map.mouseEventToContainerPoint(autoPanPointer))
  const moved = latLngToMetres(latch.from, here)
  // Nothing has changed under the pointer, so there is nothing to put right.
  if (!moved.x && !moved.y) return

  if (moving) {
    moving.centre = metresToLatLng(moving.centre, moved.x, moved.y)
    moving.from = here
    onDragMove(autoPanPointer)
    return
  }
  if (areaDrag) {
    areaDrag.points = areaDrag.points.map((p) => metresToLatLng(p, moved.x, moved.y))
    areaDrag.from = here
    onAreaDragMove(autoPanPointer)
    return
  }
  // A dot: the dot IS the whole of what is held, so it is the base as well as the thing that moves.
  vertexDrag.point = metresToLatLng(vertexDrag.point, moved.x, moved.y)
  vertexDrag.from = here
  onVertexMove(autoPanPointer)
}

function onDragMove(event) {
  if (!dragState || !dragState.plan || !map) return
  trackPointer(event)
  const plan = dragState.plan
  const latlng = map.containerPointToLatLng(map.mouseEventToContainerPoint(event))

  if (dragState.kind === 'move') {
    const moved = latLngToMetres(dragState.from, latlng)
    const centre = metresToLatLng(dragState.centre, moved.x, moved.y)
    emit('plan-updated', { id: plan.id, patch: { centre } })
  } else if (dragState.kind === 'knob') {
    emit('plan-updated', { id: plan.id, patch: { angleDeg: angleFromPoints(plan.centre, latlng) } })
  } else {
    emit('plan-updated', { id: plan.id, patch: sizeFromCorner(plan, latlng) })
  }
}

function endDrag() {
  dragState = null
  window.removeEventListener('pointermove', onDragMove)
  window.removeEventListener('pointerup', endDrag)
  window.removeEventListener('pointercancel', endDrag)
  stopAutoPan()
  endHistoryRun()
}

// ---------- The view follows a drag ----------
// A shape dragged towards the edge of the map takes the map with it, so something can be moved
// somewhere that is not on screen yet without letting go first. Letting go and panning would be
// two gestures, and the second one lands the thing somewhere other than where the planner was
// pointing.
//
// It runs on the animation frame rather than on the pointer's move events, which is what makes it
// keep going while the pointer is held still against the edge -- the case it exists for. The band it
// works from is measured from the map's own edge, so everything outside the map is past it; how far
// past it is allowed to matter differs between a drag and the drawing hover, and the hover says why.
//
// `move` is what the follow does once the view has moved: `reanchor` for anything being dragged --
// see there -- and `followCursor` for the hover that follows the pointer while a ring is being
// drawn. Either way the order matters: the pan changes the geography under the pointer, and a
// follow that worked from the geography of BEFORE the pan would be one frame behind for ever, so
// the shape would sit a pan's width away from the cursor and follow it at a remove.
function beginAutoPan(event, move = reanchor, hover = false) {
  autoPanMove = move
  autoPanHover = hover
  trackPointer(event)
  // A frame is only ever outstanding through the gesture that asked for it. The check is here rather
  // than implied by the callers so that a drag which does not want the view to follow (a corner, a
  // rotation knob) can arm nothing at all by not calling this.
  if (autoPanFrame === null) autoPanFrame = requestAnimationFrame(autoPanStep)
}

// Where the pointer is, in the browser's coordinates. Kept up to date from every move AND from the
// press that started the drag, so a shape can be dragged straight into the edge without a move
// event in between. The numbers are copied out of the event rather than the event itself being
// kept: a listener of the same kind that runs later is handed the SAME object, so holding one is
// holding a value that quietly changes under it.
function trackPointer(event) {
  autoPanPointer = { clientX: event.clientX, clientY: event.clientY }
}

function stopAutoPan() {
  if (autoPanFrame !== null) cancelAnimationFrame(autoPanFrame)
  autoPanFrame = null
  autoPanMove = null
  autoPanHover = false
  autoPanPointer = null
}

function autoPanStep() {
  autoPanFrame = null
  if (!autoPanMove || !map) return

  const size = map.getSize()
  let x = 0
  let y = 0
  if (autoPanPointer) {
    const point = map.mouseEventToContainerPoint(autoPanPointer)
    if (point.x < EDGE_PX) x = -panSpeed(EDGE_PX - point.x)
    else if (point.x > size.x - EDGE_PX) x = panSpeed(point.x - (size.x - EDGE_PX))
    if (point.y < EDGE_PX) y = -panSpeed(EDGE_PX - point.y)
    else if (point.y > size.y - EDGE_PX) y = panSpeed(point.y - (size.y - EDGE_PX))
  }

  if (x || y) {
    // The view moves first, and the shape is put back in step with it second, so that the shape
    // ends the frame exactly where the cursor is rather than one frame's worth of pan away.
    map.panBy([x, y], { animate: false })
    autoPanMove()
    autoPanFrame = requestAnimationFrame(autoPanStep)
    return
  }
  // Nothing to do this frame. A DRAG keeps asking anyway: it is held, so the pointer can reach the
  // edge without a move event, and the next frame has to notice -- the loop ends when the drag does,
  // in stopAutoPan. A HOVER is not held: its pointer position only ever changes with a move event,
  // and every one of those re-arms this -- so an idle hover frame ends the loop rather than spinning
  // one for as long as a ring is being drawn.
  if (!autoPanHover) autoPanFrame = requestAnimationFrame(autoPanStep)
}

// How fast the view follows, in pixels per frame, for a pointer `distance` px past the inner line
// where the following starts. Nothing at the line, AUTO_PAN_EDGE_PX by the time the pointer has
// reached the map's own edge, and from there AUTO_PAN_GAIN faster for every further pixel out -- so
// pushing the pointer further out of the map pans proportionally faster, which is what makes a long
// distance one gesture instead of a drag followed by a pan. The climb stops at AUTO_PAN_MAX_PX, so a
// pointer parked off the far side of the window cannot throw the view across Singapore in one frame;
// it reaches that 240 px outside the map, which the window has room for in every direction.
//
// The two segments are written out rather than folded into one expression: past the edge the first
// segment keeps growing too, and the sum of the two slopes reached the cap in 80 px -- too short to
// aim with, since every distance beyond it would pan at the same speed.
//
// The climb used to stop AT the edge: the formula measured the distance past the inner line and
// capped the result at the edge speed, so the whole world outside the map -- which is all the same
// distance as far as that was concerned -- moved at one fixed 8 px a frame however far out it went.
function panSpeed(distance) {
  const speed = distance <= EDGE_PX
    ? (distance / EDGE_PX) * AUTO_PAN_EDGE_PX
    : AUTO_PAN_EDGE_PX + (distance - EDGE_PX) * AUTO_PAN_GAIN
  return Math.max(1, Math.round(Math.min(AUTO_PAN_MAX_PX, speed)))
}

// ---------- The view follows the pointer while a ring is being drawn ----------
// Drawing is the one mode where the left button cannot move the view, because there a click IS a
// point -- so without this the only way to reach ground that is off screen is the middle button, with
// the hand that is busy placing points. The view follows the pointer instead, so the ground under the
// pointer keeps being refreshed and the next click can land on somewhere that was off screen a moment
// ago.
//
// It follows with the SAME law a dragged dot follows: the same EDGE_PX band, the same panSpeed, and
// the same reach -- everything outside the map, however far out, at a speed that climbs with the
// distance. A ring drawn around a venue grows in one direction for several screens, and the whole
// point of the follow is that growing costs one gesture rather than "place a point, pan, place the
// next point".
//
// It used to stop EDGE_PX outside the map, on the argument that nothing is held, so a pointer parked
// over the controls column means "I am reaching for Undo" at least as often as it means "keep going".
// That got the answer wrong where it counts. The map is ONE COLUMN of the page: the controls are
// directly beside its right-hand edge, so a pointer pushed past that edge -- the direction a ring
// most often needs to grow -- is over them immediately, and the follow died exactly where it was
// wanted. The button a drag has to say "still travelling" is not replaced by anything, so the band
// does the whole job: see autoPanStep, where a pointer that is inside the map and away from its edges
// still ends the follow on the first frame with nothing to do.
function setHoverFollow(on) {
  if (on === hoverFollowOn) return
  hoverFollowOn = on
  if (on) {
    window.addEventListener('pointermove', onHoverMove)
    return
  }
  window.removeEventListener('pointermove', onHoverMove)
  // Leaving the mode ends the follow that mode asked for -- but only if it is the hover's own: a
  // drag's follow is ended by the drag, and nothing here may cut one of those short.
  if (autoPanHover) stopAutoPan()
}

// A pointer with a button down is a different gesture, and every one of those has a follow of its own:
// a dot being dragged, a picture being dragged, the middle-button pan. This one is only ever the
// pointer by itself.
//
// A ring has to be under way for it to run at all: at least one point placed, so the next click is
// the next point. Watch mode alone is not enough to know that travel is wanted -- entering drawing
// puts the pointer ON the controls, and the pointer's first move is from there to the map, across a
// column at the far end of the ramp. That is a view that runs away before a single point is placed.
function onHoverMove(event) {
  if (
    event.buttons ||
    !map ||
    !props.canEdit ||
    mode.value !== 'polygons' ||
    draftClosed.value ||
    draftPoints.value.length === 0
  ) {
    if (autoPanHover) stopAutoPan()
    return
  }
  // The bench's own controls sit OVER the map rather than beside it, and moving the view because the
  // pointer crossed the hint along the top would make reading it impossible. Same rule, and the same
  // elements, as the two clicks on the map.
  const target = event.target
  // A control is somewhere the planner is reaching for, not somewhere they are steering the view to.
  if (target && target.closest && target.closest('.bench-hint, .bench-draft, button, input, select, textarea, a, label')) {
    if (autoPanHover) stopAutoPan()
    return
  }
  // After a click elsewhere on the page the ring is kept (see onDocumentPointerDown), but the view
  // must not run off after a pointer that is busy outside the map: it waits until the pointer is back.
  if (hoverPaused) {
    if (!map.getContainer().contains(target)) {
      if (autoPanHover) stopAutoPan()
      return
    }
    hoverPaused = false
  }
  beginAutoPan(event, followCursor, true)
}
let hoverPaused = false

// What the hover's follow does once the view has moved: ask where the pointer is NOW, and let the
// drawing code put the loose end of the rubber band there. Nothing is latched and nothing is held, so
// that is the whole of it -- onMapMove is the same thing a move inside the map does, and running it
// here is what keeps the loose end, the snap and the crossing warning right while the view slides
// underneath a pointer that is not itself moving at all.
function followCursor() {
  if (!map || !autoPanPointer) return
  onMapMove({ latlng: map.containerPointToLatLng(map.mouseEventToContainerPoint(autoPanPointer)) })
}

// ---------- Moving the view ----------
// A press moves the view when it is the middle button, wherever it lands -- the map, a picture, an
// outline, a corner handle, the middle of drawing an area -- and that is the only press that
// always does. The LEFT button moves the view only where there is nothing else for it to mean,
// which is what keeps a drag that starts on a shape moving that shape.
//
// The shape test reads the event's TARGET, not `dragState`: a press on a shape has already been
// taken by that shape's own handler by the time this runs, and the only question left is whether
// the press was for the map or for the shape.
function wantsPan(event) {
  if (wantsMapPan(event)) return true
  if (event.button !== 0) return false
  // While an area is being drawn every click is a point, so the LEFT button belongs to the ring.
  // The middle button is above this line and still pans.
  if (mode.value === 'polygons') return false
  const target = event.target
  if (!target || !target.closest) return true
  // Everything the bench puts on the map under its own name, plus Leaflet's own interactive
  // layers: each of those has a press of its own to handle.
  return !target.closest('.bench-plan, .bench-handle, .bench-knob, .leaflet-interactive')
}

// Every press on the map passes through here, whatever it turns out to be for. The one thing that
// has to happen for ALL of them is forgetting whether the LAST press was a pan: a left click a
// moment after a middle pan is an ordinary click, and leaving the answer from the previous press
// standing would throw its point away.
function onMapPointerDown(event) {
  if (event.benchHandled) return
  // Just outside the outline (the stroke is thin) still counts as its edge: see addPointOnEdge.
  if (addPointOnEdge(event)) {
    if (event.preventDefault) event.preventDefault()
    return
  }
  // A second finger on a touch screen is a pinch, and the pinch is Leaflet's (touchZoom). The pan the
  // first finger started has to stop, or it moves the view at the same time as the zoom and the two
  // fight. endPan is called without the event because it ignores any pointer but the pan's own.
  if (panFrom && event.pointerId !== panPointerId) {
    endPan()
    return
  }
  panMoved = false
  startPan(event)
}

// Put a shape drag that is in progress back in step with the view, without moving the shape on
// screen. Called at the START of a pan, because the shape's anchor is geography: once the view
// moves, that geography is somewhere else on screen, and a drag that resumed with the old anchor
// would jump by the whole width of the pan to catch up.
//
// One helper rather than a branch at the call site: both drags re-anchor identically, and the only
// thing that differs is which of them is running.
function followShape(event) {
  if (!areaDrag && !dragState && !vertexDrag) return
  if (event) trackPointer(event)
  reanchor()
}

function startPan(event) {
  if (!map || panFrom) return
  if (!wantsPan(event)) return

  // Middle-click on a desktop browser otherwise starts its autoscroll cursor, which scrolls the
  // page at the same time as the pan.
  if (event.preventDefault) event.preventDefault()

  // The press belongs to the view now, so a shape drag in progress must stop following the
  // pointer: if it carried on, the shape would jump by the whole width of the pan on the next
  // move. It keeps its geography and the view moves under it, which is the only thing "pan while
  // holding something" can mean.
  stopAutoPan()
  // The shape's anchor is left on the geography it had at the press, which is now somewhere else on
  // screen -- so when the pan ends and the drag resumes, the first move would measure from there and
  // the shape would jump. Re-anchoring onto the pointer's new geography at the same screen point
  // puts that right, and is a no-op on screen: same place under the cursor, new coordinates for it.
  followShape(event)

  panFrom = map.containerPointToLatLng(map.mouseEventToContainerPoint(event))
  panPoint = { clientX: event.clientX, clientY: event.clientY }
  panPointerId = event.pointerId
  panTravel = 0
  setPanning(true)
  // CAPTURE, so the view keeps following a pointer that has left the map -- over another card, or
  // off the window entirely. Without it the moves stop at the edge and the pan dies with them.
  // A capture also fails on its own if the pointer is gone by the time it is asked for, and there
  // is nothing to recover from in that case: the pan simply follows the events it does get.
  if (panPointerId !== undefined && map.getContainer().setPointerCapture) {
    try { map.getContainer().setPointerCapture(panPointerId) } catch { /* pointer already gone */ }
  }

  window.addEventListener('pointermove', onPanMove)
  window.addEventListener('pointerup', endPan)
  window.addEventListener('pointercancel', endPan)
  window.addEventListener('blur', endPan)
}

function onPanMove(event) {
  if (!panFrom || !map) return
  if (panPointerId !== null && event.pointerId !== panPointerId) return

  // Where the place the press grabbed sits now, and where it sat then. Both are in the map's own
  // pixels, so a zoom in between is already accounted for and nothing has to be scaled by hand.
  const way = map.mouseEventToContainerPoint(event)
  const at = map.mouseEventToContainerPoint(panPoint)
  const dx = way.x - at.x
  const dy = way.y - at.y
  panPoint = { clientX: event.clientX, clientY: event.clientY }
  // Kept up to date here as well, so that a shape drag resumed after this pan starts from where the
  // cursor actually is rather than from wherever it was when the pan began.
  trackPointer(event)

  panTravel += Math.abs(dx) + Math.abs(dy)
  // Below the slop the press is not a drag yet, and nothing is moved: a click that wobbles by a
  // pixel must still be a click, and still place its point.
  if (!panMoved && panTravel < PAN_SLOP_PX) return
  panMoved = true

  // The numbers handed to `panBy` are the pointer's movement, NEGATED. Leaflet's `panBy(offset)`
  // moves the CENTRE of the view by `offset`, so a positive x means "show more of the east", which
  // is a LARGER world x. Dragging the pointer to the right has to show more of the WEST -- the map
  // follows the hand -- so a positive `dx` needs a NEGATIVE offset. Getting this the wrong way round
  // makes the map run away from the cursor at twice the speed, which is the exact bug this code was
  // rewritten to fix. The sign is not taken on trust: the harness tries all four combinations and
  // requires exactly one of them to keep the geography under the cursor at the press still under it.
  map.panBy([-dx, -dy], { animate: false })
}

function endPan(event) {
  if (!panFrom) return
  // One pointer, one pan. A second finger arriving must not end the first one's pan.
  if (event && panPointerId !== null && event.pointerId !== undefined && event.pointerId !== panPointerId) return
  const id = panPointerId
  panFrom = null
  panPoint = null
  panPointerId = null
  setPanning(false)
  if (map && id !== null && map.getContainer().releasePointerCapture) {
    // A capture that is already gone throws rather than failing quietly, and there would be nothing
    // to do about it either way: the pan is over.
    try { map.getContainer().releasePointerCapture(id) } catch { /* already released */ }
  }
  window.removeEventListener('pointermove', onPanMove)
  window.removeEventListener('pointerup', endPan)
  window.removeEventListener('pointercancel', endPan)
  window.removeEventListener('blur', endPan)
}

// The grabbing hand, while the view is being moved by a press rather than by the wheel. Leaflet's
// own `.leaflet-grab` class no longer means anything -- its drag is off -- so this is the cursor
// state now.
function setPanning(on) {
  if (map) map.getContainer().classList.toggle('bench-panning', Boolean(on))
}

// A gesture that reported many changes is over, so the one step it earned is closed now rather
// than when the changes happen to stop coming. Called from every pointerup path, which is the
// one moment that is reliably the end of a drag.
function endHistoryRun() {
  if (props.history) props.history.endRun()
}

// ---------- Drawing ----------
function clearDraftLayers() {
  for (const marker of draftVertexMarkers) marker.remove()
  draftVertexMarkers = []
  if (draftLine) {
    draftLine.remove()
    draftLine = null
  }
  if (draftFill) {
    draftFill.remove()
    draftFill = null
  }
}

function drawDraftVertices() {
  for (const marker of draftVertexMarkers) marker.remove()
  draftVertexMarkers = []
  draftPoints.value.forEach((point, index) => {
    const marker = L.circleMarker(point, {
      radius: index === 0 ? 7 : 5,
      color: '#fff',
      weight: 2,
      fillColor: index === 0 ? '#0d6efd' : '#fd7e14',
      fillOpacity: 1,
      interactive: false,
    }).addTo(map)
    draftVertexMarkers.push(marker)
  })
  applySnapLook()
}

// Closing the ring must not depend on pixel-perfect aim. Once there are enough points to
// make an area, coming near the FIRST one makes the loose end of the rubber band snap onto
// it and turns the line green: what is on screen is what will be created.
//
// Not offered when the ring cannot be closed at all: a green line that promises a shape the
// bench then refuses would be a lie.
function updateSnap() {
  if (
    draftClosed.value ||
    draftPoints.value.length < AREA_MIN_POINTS ||
    !cursorLatLng ||
    !map ||
    closeBlocked.value
  ) {
    snapActive.value = false
    return
  }
  const first = draftPoints.value[0]
  const target = map.latLngToContainerPoint(L.latLng(first[0], first[1]))
  const here = map.latLngToContainerPoint(L.latLng(cursorLatLng.lat, cursorLatLng.lng))
  snapActive.value = here.distanceTo(target) <= SNAP_PX
}

// The first dot grows and turns into a ring when a click would close the shape.
function applySnapLook() {
  if (!draftVertexMarkers.length) return
  draftVertexMarkers[0].setStyle(
    snapActive.value
      ? { radius: 9, color: '#198754', weight: 3, fillColor: '#fff' }
      : { radius: 7, color: '#fff', weight: 2, fillColor: '#0d6efd' },
  )
}

function drawDraftLine() {
  if (draftLine) {
    draftLine.remove()
    draftLine = null
  }
  const points = draftPoints.value
  if (points.length === 0) return

  // While snapping, the loose end is the first point rather than the cursor.
  const looseEnd = snapActive.value ? points[0] : cursorLatLng
  const path = draftClosed.value ? points : looseEnd ? [...points, looseEnd] : points
  if (path.length < 2) return

  draftLine = L.polyline(path, {
    // Red is the line that will not be allowed to exist: it would cross one already drawn,
    // and the click that would end it here is refused.
    color: crossWarn.value ? '#dc3545' : snapActive.value ? '#198754' : '#0d6efd',
    weight: snapActive.value ? 3 : 2,
    dashArray: draftClosed.value ? null : '6 6',
    interactive: false,
  }).addTo(map)
}

function drawDraftFill() {
  if (draftFill) {
    draftFill.remove()
    draftFill = null
  }
  if (!draftClosed.value || draftPoints.value.length < AREA_MIN_POINTS) return
  draftFill = L.polygon(draftPoints.value, { ...areaStyle(draftKind.value), interactive: false }).addTo(map)
}

function redrawDraft() {
  drawDraftVertices()
  drawDraftLine()
  drawDraftFill()
}

// ---------- Adjusting an existing area's shape ----------
// Dragging a vertex moves it; clicking a vertex removes it. Points stay in [[lat,lng]]
// order, which is what makes an area a ring rather than a bag of coordinates.
//
// The handlers below always re-read the points from the props rather than closing over a
// copy, so they can never act on a stale shape.
function currentAreaPoints() {
  const area = editingArea.value
  return area ? area.points.map((p) => [p[0], p[1]]) : []
}

function clearAreaVertices() {
  for (const marker of areaVertexMarkers) marker.remove()
  areaVertexMarkers = []
}

function drawAreaVertices() {
  const area = editingArea.value
  if (!area || !map || !props.canEdit) {
    clearAreaVertices()
    return
  }

  const points = currentAreaPoints()

  // Same area and same number of points: the dots only have to move. Rebuilding them --
  // which an added or removed point genuinely needs -- is too much to do once per frame of
  // a drag, and it would destroy the very dot being dragged.
  if (areaVertexMarkers.benchArea === area.id && areaVertexMarkers.length === points.length) {
    points.forEach((point, index) => {
      // The dot under the planner's finger is not the props' business. This runs whenever the areas
      // change at all, and since a live frame from another planner arrives twenty times a second
      // while they drag anything (see useBenchFrames), that is now often: putting the dragged dot
      // back where the document still has it would make it fight the finger it is following.
      if (vertexDrag && vertexDrag.id === area.id && vertexDrag.index === index) return
      areaVertexMarkers[index].setLatLng(point)
    })
    return
  }

  clearAreaVertices()

  points.forEach((point, index) => {
    const marker = L.marker(point, {
      // NOT Leaflet's own drag, and this is the one place the component cannot use it. It moves the
      // icon by the pointer's travel in PIXELS and reads the geography back out of where that put it
      // (`_newPos = _startPos + offset`, then `layerPointToLatLng(getPosition(icon))`), so it has no
      // idea the view moved: a pan underneath would leave the dot slipping behind the cursor with its
      // coordinates frozen where the pan started. It also cannot arm the auto-pan at all, because
      // that only happens for a press this component handles. See onVertexPointerDown.
      draggable: false,
      keyboard: false,
      icon: L.divIcon({
        className: '',
        html: '<div class="bench-vertex"></div>',
        iconSize: [16, 16],
        iconAnchor: [8, 8],
      }),
    }).addTo(map)

    // The press is taken on the dot's own element, so it is handled exactly like a press on a picture
    // or on an outline rather than like a Leaflet drag.
    const element = marker.getElement()
    if (element) {
      element.addEventListener('pointerdown', (event) => onVertexPointerDown(area.id, index, event))
    }

    marker.on('click', (event) => {
      L.DomEvent.stopPropagation(event)
      // The click the browser fires as the press ends is not always a click ON the dot: at the end of
      // a drag it is only how the gesture finished, and acting on it would delete the very point the
      // planner has just placed. Leaflet suppressed that click for its own drags (see
      // Map._draggableMoved); owning the drag means owning that too. `vertexMoved` is cleared by the
      // next press on a dot, so the only click it can swallow is the one at the end of a drag.
      if (vertexMoved) return
      const before = currentAreaPoints()
      if (before.length <= AREA_MIN_POINTS) {
        errorMsg.value = 'That is the ' + AREA_MIN_POINTS + '-point minimum.'
        return
      }
      const next = before.filter((_, i) => i !== index)
      // Taking a point out can leave a ring that crosses itself just as surely as moving one
      // can, so it is checked the same way -- and with no exception for a shape that already
      // crosses, because that exception was the bypass.
      if (ringCrossing(next)) {
        errorMsg.value = CROSS_REMOVE_MESSAGE
        return
      }
      errorMsg.value = ''
      emit('area-updated', { id: area.id, patch: { points: next } })
    })

    areaVertexMarkers.push(marker)
  })

  areaVertexMarkers.benchArea = area.id
}

// ---------- Moving one point of an area ----------
// The dot follows the pointer the way a picture does -- measured from where the pointer was at the
// press and never accumulated -- and the outline is redrawn from the ring that gives, so the planner
// watches the lines move and go red over somewhere the ring cannot go.
//
// Owned here rather than by Leaflet's marker drag, for the reason written at the marker: nothing but
// this can take the view along, and a dot that cannot leave the map can only ever be placed on
// ground that is already on screen. Making the press look like a picture's is also what lets
// `reanchor` keep the dot in step with a pan, which is what makes the two work together.
//
// Nothing is reported to the page until the drop: the props still hold the ring as it was, the dot
// and the outline are drawn from the ring as it is being dragged, and the one thing a drop can do
// that a move cannot is refuse.
function onVertexPointerDown(id, index, event) {
  // A press with anything but the left button belongs to the map -- see wantsMapPan.
  if (wantsMapPan(event)) {
    if (event.preventDefault) event.preventDefault() // no middle-click autoscroll cursor
    return
  }
  if (!props.canEdit || !map || refusePress(id)) return
  const area = props.areas.find((a) => a.id === id)
  if (!area || !area.points[index]) return

  // The browser must not start a text selection instead of a drag.
  if (event.preventDefault) event.preventDefault()

  // The message from the last thing that was refused goes away as soon as a new drag begins. Without
  // this the refusal would sit there while the planner was busy fixing the shape, saying something
  // that is no longer true.
  errorMsg.value = ''

  vertexMoved = false
  vertexDrag = {
    id,
    index,
    // The dot itself, held for the whole gesture: the array it came from is rebuilt whenever the
    // shape gains or loses a point, and a drag that outlived that would be moving a marker that is
    // no longer on the map.
    marker: areaVertexMarkers[index],
    // Geography, like every other drag, and the dot's own place at the press: the two halves of the
    // measurement reanchor has to move together.
    from: map.containerPointToLatLng(map.mouseEventToContainerPoint(event)),
    point: [area.points[index][0], area.points[index][1]],
    press: map.mouseEventToContainerPoint(event),
    dot: null,
  }
  window.addEventListener('pointermove', onVertexMove)
  window.addEventListener('pointerup', endVertexDrag)
  window.addEventListener('pointercancel', endVertexDrag)
}

function onVertexMove(event) {
  if (!vertexDrag || !map) return

  // The refusal can arrive while the finger is still down: the lock is answered by the database
  // while this drag is being drawn. A drag that carried on would leave the outline somewhere that
  // is not saved and cannot be, so the gesture ends here and the ring goes back -- see
  // cancelVertexDrag.
  if (blockedBy(vertexDrag.id)) {
    cancelVertexDrag()
    return
  }

  trackPointer(event)
  const here = map.mouseEventToContainerPoint(event)

  // Below the tolerance the press is still a click on the dot rather than a drag of it, so the dot
  // has not moved and the drop has nothing to report.
  if (!vertexMoved) {
    if (here.distanceTo(vertexDrag.press) < VERTEX_SLOP_PX) return
    vertexMoved = true
    // The view starts following once the press has become a drag OF the dot, not at the press itself
    // -- which is where a picture arms it, a picture having no click of its own. A dot does: a click
    // on one takes the point out, and a click that removed a point AND scrolled the map underneath
    // would be two answers to one gesture.
    beginAutoPan(event)
  }

  const moved = latLngToMetres(vertexDrag.from, map.containerPointToLatLng(here))
  const dot = metresToLatLng(vertexDrag.point, moved.x, moved.y)
  vertexDrag.dot = dot

  const next = currentAreaPoints()
  next[vertexDrag.index] = dot
  // The dot is moved here rather than by Leaflet: nothing has been reported to the page yet, so the
  // props still hold the ring as it was and nothing else would move it off its old spot.
  if (vertexDrag.marker) vertexDrag.marker.setLatLng(dot)

  // The answer to "would this cross?" is worked out on every frame, not on release, which is too late
  // to be any use: the outline turns red while the dot is somewhere it would cross itself, and turns
  // back the moment it is inside again, so the planner is told where the line is instead of being
  // snapped away from it. This is feedback only, and the red IS the message: the planner can see the
  // line that overlaps, and a paragraph repeating it would be noise in the corner of the thing they
  // are looking at. The one thing said out loud is the refusal they cannot see, on the drop.
  const crossing = Boolean(ringCrossing(next))
  applyAreaPoints(areaLayers[vertexDrag.id], next, crossing)

  // The others watch the dot travel -- that is what a live frame is for. They do NOT watch it
  // somewhere the drop would refuse: refusing a crossing ring is the bench's own rule, not the
  // database's, so a frame carrying one would put a shape on every other screen that no drop can
  // ever commit. What they see instead is the dot stop at the last place it could have been let go.
  if (!crossing) emit('area-frame', { id: vertexDrag.id, patch: { points: next } })
}

// The drop, judged on where the dot LANDS and never on the path it took to get there. One drag that
// ends on a legal shape repairs a broken outline, and the outline follows the dot the whole way, so
// the planner watches the lines come apart before letting go.
function endVertexDrag() {
  const drag = vertexDrag
  stopVertexDrag()
  if (!drag || !vertexMoved || !drag.dot) return

  const before = currentAreaPoints()
  const next = currentAreaPoints()
  next[drag.index] = drag.dot

  // NO CROSSING LINES, with no way round it. An earlier version let a shape that already crossed
  // itself off the hook -- "it is broken, so anything goes" -- and that WAS the way round: any drag
  // on a broken outline was accepted, crossings and all.
  if (ringCrossing(next)) {
    errorMsg.value = CROSS_VERTEX_MESSAGE
    if (drag.marker) drag.marker.setLatLng(before[drag.index])
    applyAreaPoints(areaLayers[drag.id], before)
    return
  }

  errorMsg.value = ''
  emit('area-updated', { id: drag.id, patch: { points: next } })
}

// The gesture is over, whatever became of it -- including a cancelled press, which must not leave the
// latch or the frame loop behind. This is also what the unmount runs, so a drag in flight can never
// outlive the map it was moving.
function stopVertexDrag() {
  vertexDrag = null
  window.removeEventListener('pointermove', onVertexMove)
  window.removeEventListener('pointerup', endVertexDrag)
  window.removeEventListener('pointercancel', endVertexDrag)
  stopAutoPan()
  endHistoryRun()
}

// A dot stopped being this planner's to move, mid-drag. The gesture ends and the ring is drawn from
// the document again, because the document is the only thing here that is true: the drag was drawing
// a shape that was never reported to the page (see onVertexMove), so what the props hold is what is
// really there. The watcher in the page does the same for a refusal that lands with no drag in
// flight; this is the case it cannot cover, because the drag would redraw its own ring on the very
// next move.
function cancelVertexDrag() {
  const drag = vertexDrag
  stopVertexDrag()
  if (!drag) return

  const area = props.areas.find((a) => a.id === drag.id)
  if (!area) return
  if (drag.marker) drag.marker.setLatLng(area.points[drag.index] || area.points[0])
  applyAreaPoints(areaLayers[drag.id], area.points)
}

// ---------- Adding a point where the planner clicks an edge ----------
// While an area is being edited, hovering one of its edges turns the cursor into a "+" and a press
// there adds a point at that spot, between the two dots the edge joins. A point ON an edge cannot
// make the ring cross itself (the two new edges lie along the old one), but it is checked anyway,
// like every other change. Near a dot the dot wins, so its own click (remove) and drag (move) still
// work. (Linus's test notes: Add point put the new point somewhere unexpected.)
const EDGE_HIT_PX = 8
const DOT_CLEAR_PX = 12

function edgeUnder(event) {
  const area = editingArea.value
  if (!area || !map || !props.canEdit || vertexDrag || areaDrag) return null
  const p = map.mouseEventToContainerPoint(event)
  const dots = area.points.map((q) => map.latLngToContainerPoint(L.latLng(q[0], q[1])))
  if (dots.some((q) => q.distanceTo(p) < DOT_CLEAR_PX)) return null
  let best = null
  for (let i = 0; i < dots.length; i++) {
    const a = dots[i]
    const b = dots[(i + 1) % dots.length]
    const dx = b.x - a.x
    const dy = b.y - a.y
    const len2 = dx * dx + dy * dy
    const t = len2 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
    const near = L.point(a.x + t * dx, a.y + t * dy)
    const d = near.distanceTo(p)
    if (d <= EDGE_HIT_PX && (!best || d < best.d)) best = { d, index: i + 1, at: map.containerPointToLatLng(near) }
  }
  return best
}

// True when the press was on an edge and has been dealt with (point added, or refused with a reason).
function addPointOnEdge(event) {
  if (event.button !== undefined && event.button !== 0) return false
  const edge = edgeUnder(event)
  if (!edge) return false
  const area = editingArea.value
  if (refusePress(area.id)) return true
  if (area.points.length >= AREA_MAX_POINTS) {
    errorMsg.value = 'An area can have at most ' + AREA_MAX_POINTS + ' points.'
    return true
  }
  const next = currentAreaPoints()
  next.splice(edge.index, 0, [edge.at.lat, edge.at.lng])
  if (ringCrossing(next)) {
    errorMsg.value = CROSS_ADD_MESSAGE
    return true
  }
  errorMsg.value = ''
  emit('area-updated', { id: area.id, patch: { points: next } })
  return true
}

// The "+" cursor: a class on the map, so it also beats the outline's own "move" cursor.
function onEdgeHover(event) {
  if (!map) return
  map.getContainer().classList.toggle('bench-edge-hover', Boolean(edgeUnder(event)))
}

// A new point has to go somewhere legal, and then the planner drags it into place.
//
// Where "somewhere legal" is turns out to be the whole difficulty, which is why the search lives
// in utils/areaGrow.js with its own tests. Appending a point at the end of the ring -- one short
// step east of the last dot, which is what this used to do -- is joined to TWO neighbours, because
// the ring closes: the dot that was last, and the dot that was first. For a three-point ring that
// often leaves no legal spot at all, and the planner was simply told their point would cross
// something no matter where they asked for it. growRing tries the end of the ring first, next to
// the dot they were last looking at, and splits an edge if that is refused.
//
// AREA_MAX_POINTS is the same ceiling public.area_ok() enforces. Refusing the point here
// rather than letting the save discover it is the difference between an action that cannot
// be taken and a completed edit that is silently thrown away.
function addAreaPoint() {
  const area = editingArea.value
  if (!area) return
  // Adding a point changes the area like any other change, so it is refused the same way -- and
  // saying so here is better than a dot that appears and then cannot be saved.
  if (refusePress(area.id)) return
  if (area.points.length >= AREA_MAX_POINTS) {
    errorMsg.value = 'An area can have at most ' + AREA_MAX_POINTS + ' points.'
    return
  }

  const { points, insertedAt } = growRing(currentAreaPoints())
  if (insertedAt === null) return // nowhere legal to put it: the shape is left exactly as it is

  errorMsg.value = ''
  emit('area-updated', { id: area.id, patch: { points } })
}

// ---------- Selecting and moving areas ----------
// Pressing an area selects it -- the list row highlights and its dots appear -- and dragging
// carries the whole shape along, exactly the way a floor plan moves. A plain press with no
// movement is therefore just a selection.
function onAreaPointerDown(id, event) {
  // A press with anything but the left button belongs to the map -- including one that lands on a
  // dot, which is the whole point: the map may be covered in shapes, and there is nowhere else left
  // to grab it. See wantsMapPan.
  if (wantsMapPan(event)) {
    if (event.preventDefault) event.preventDefault() // no middle-click autoscroll cursor
    return
  }

  // On the edge of the area being edited, a press adds a point there instead of moving the outline.
  if (addPointOnEdge(event)) {
    event.benchHandled = true // the map's own listener sees this press next and must leave it alone
    if (event.preventDefault) event.preventDefault()
    return
  }

  if (!shapesClickable.value || !map || refusePress(id)) return
  const area = props.areas.find((a) => a.id === id)
  if (!area) return

  // A dot's own press is not the outline's. The map has to stay pannable now, so the check that a
  // press meant the outline rather than the map is this one -- and it has to happen on POINTERDOWN,
  // not on click: the vertex stops its own click from propagating, which means the browser fires no
  // click at all, and a press that reaches the map would also put the shape down on the way.
  const pressed = event.target && event.target.getAttribute && event.target.getAttribute('class')
  if (pressed && pressed.indexOf('bench-vertex') >= 0) return

  // The browser must not start a text selection or a page scroll instead of a drag.
  if (event.preventDefault) event.preventDefault()

  // Picking a shape up is a fresh start, so whatever was last refused about a different one goes
  // away -- the same reason every other action clears it where the action begins.
  errorMsg.value = ''

  // The press is stopped from reaching the map, so this drag moves the outline and nothing else. The
  // view stays where it is: this shape is under the cursor, and a fit to it would move the ground
  // under the drag that is about to begin -- see viewAlreadyRight.
  if (mode.value !== 'area:' + id) {
    viewAlreadyRight = true
    mode.value = 'area:' + id
  }

  areaDrag = {
    id,
    // Geography, not a pixel point -- the same thing a picture's drag is measured from, and for the
    // same reason: a pan changes where a pixel is, and a re-anchor has to be able to move this.
    from: map.containerPointToLatLng(map.mouseEventToContainerPoint(event)),
    points: area.points.map((p) => [p[0], p[1]]),
  }
  window.addEventListener('pointermove', onAreaDragMove)
  window.addEventListener('pointerup', endAreaDrag)
  window.addEventListener('pointercancel', endAreaDrag)
  beginAutoPan(event)
}

// The outline is drawn from `areaDrag.from`, which is geography for the same reason a picture's
// anchor is: see reanchor, which moves it while the view moves under the drag.
function onAreaDragMove(event) {
  if (!areaDrag || !map) return

  // Same as a dragged dot: losing the shape mid-gesture ends the gesture, rather than letting the
  // outline carry on to a place the save will refuse. Unlike a dot, the outline may already have
  // been reported (this drag reports on every move), so what the document holds is the last
  // position that WAS accepted -- which is what the shape goes back to.
  if (blockedBy(areaDrag.id)) {
    cancelAreaDrag()
    return
  }

  trackPointer(event)
  const from = areaDrag.from
  const here = map.containerPointToLatLng(map.mouseEventToContainerPoint(event))
  const moved = latLngToMetres(from, here)
  const points = areaDrag.points.map((p) => metresToLatLng(p, moved.x, moved.y))
  applyAreaPoints(areaLayers[areaDrag.id], points) // immediate, so the shape keeps up
  emit('area-updated', { id: areaDrag.id, patch: { points } })
}

function endAreaDrag() {
  areaDrag = null
  window.removeEventListener('pointermove', onAreaDragMove)
  window.removeEventListener('pointerup', endAreaDrag)
  window.removeEventListener('pointercancel', endAreaDrag)
  stopAutoPan()
  endHistoryRun()
}

// The outline stopped being this planner's to move, mid-drag. See onAreaDragMove.
function cancelAreaDrag() {
  const drag = areaDrag
  endAreaDrag()
  if (!drag) return

  const area = props.areas.find((a) => a.id === drag.id)
  if (area) applyAreaPoints(areaLayers[drag.id], area.points)
}

// ---------- Drawing, and the map's two clicks ----------
// The map has exactly two clicks.
//
//   - drawing: the click adds a point, or closes the ring. Nothing else on the map takes a click
//     while a ring is open, so this is every click there is.
//   - otherwise: the click puts down whatever was being worked on. Nothing open means nothing to
//     put down, so it does nothing at all -- which is the common case, because the view can be
//     dragged whenever the planner likes.
function onMapClick(event) {
  const native = event.originalEvent
  // The click the browser fires at the end of a press is a click on the map only if the press was
  // one. A press that moved the view was the middle button, or a drag, and neither places a point.
  if (!native || native.button !== 0 || panMoved) return
  const target = native && native.target
  // A click that landed on a floor plan picture or on a drawn area already belongs to that
  // thing, so it is not a click on the map.
  if (target && target.closest && target.closest('.leaflet-overlay-pane')) return
  // Neither is a click on the bench's own controls, which sit over the map rather than beside
  // it: the strip along the top, and the name-and-type form in the corner while a ring is
  // being closed.
  if (target && target.closest && target.closest('.bench-hint, .bench-draft')) return
  if (!props.canEdit) return

  // A press on the map is the planner moving on from whatever was last refused, so the refusal
  // goes away. Every other route back to a clean message -- drawing a point, starting a drag,
  // pressing a button -- clears it where that action begins.
  errorMsg.value = ''

  if (mode.value === 'polygons') {
    addDraftPoint(event)
    return
  }

  // Putting it down is the save -- so this keeps what was done, it does not throw it away. The
  // view is not affected either way: the map is always free to pan.
  if (mode.value !== null) mode.value = null
}

function addDraftPoint(event) {
  if (draftClosed.value) return

  const points = draftPoints.value
  const here = map.latLngToContainerPoint(event.latlng)

  if (points.length >= AREA_MIN_POINTS) {
    // Same tolerance as the snap, so "it looked closed" and "it closed" are the same thing.
    // The panel's Finish button closes it too, for anyone who would rather not aim at all.
    const first = map.latLngToContainerPoint(L.latLng(points[0][0], points[0][1]))
    if (here.distanceTo(first) <= SNAP_PX) {
      closeDraft()
      return
    }
  } else if (points.length === AREA_MIN_POINTS - 1) {
    // Two points down and a click back on the first one: the planner is trying to close a ring
    // that is not a shape yet. Saying so beats adding a second point on top of the first, which
    // would leave a three-point ring with no area in it at all.
    const first = map.latLngToContainerPoint(L.latLng(points[0][0], points[0][1]))
    if (here.distanceTo(first) <= SNAP_PX) {
      errorMsg.value = 'That is the ' + AREA_MIN_POINTS + '-point minimum.'
      return
    }
  }

  // A double-click fires two clicks in the same place. The first is a point and the second is
  // that same point again, which would leave a zero-length edge behind -- and the crossing
  // check below would then read it as a shape touching itself. Dropping it is also what the
  // planner means: two clicks in one spot is one point.
  if (points.length > 0) {
    const last = points[points.length - 1]
    const previous = map.latLngToContainerPoint(L.latLng(last[0], last[1]))
    if (here.distanceTo(previous) <= DUPLICATE_PX) return
  }

  // NO CROSSING LINES. A ring that crosses itself is not a shape, so the point that would
  // cross one is refused -- before it is drawn, not at the next save.
  //
  // This asks about the edge the click would ADD and nothing else, which is what makes it safe
  // to be strict: the edges of a legal ring never cross each other, so neither does any part
  // of drawing one, and this can never refuse a point of a shape that is legal when it closes.
  if (wouldCrossNext(event.latlng)) {
    errorMsg.value = CROSS_DRAW_MESSAGE
    return
  }

  // The ceiling is checked BEFORE the point joins the ring, so a ring that cannot be saved is
  // never drawn. Without this a long enough outline is accepted here, drawn in full, and then
  // thrown away by the database at the next lock -- with one generic sentence to explain it.
  // 200 is the same limit public.area_ok() enforces.
  if (points.length >= AREA_MAX_POINTS) {
    errorMsg.value = 'That is the ' + AREA_MAX_POINTS + '-point limit.'
    return
  }

  recordDraft()
  errorMsg.value = ''
  points.push([event.latlng.lat, event.latlng.lng])
  crossWarn.value = false
  cursorLatLng = event.latlng
  updateSnap()
  redrawDraft()
}

function onMapMove(event) {
  if (!props.canEdit || mode.value !== 'polygons' || draftClosed.value) return
  cursorLatLng = event.latlng
  updateSnap()
  applySnapLook()
  crossWarn.value = wouldCrossNext(event.latlng)
  drawDraftLine()
}

function closeDraft() {
  if (draftPoints.value.length < AREA_MIN_POINTS) return

  // Backstop. With every point checked as it is added, the closing line can only cross after
  // an undo, because taking a point out of a legal ring can leave one that closes across
  // itself. Refusing here is what keeps "it closed" and "it is a shape" the same thing.
  if (closingCrosses(draftPoints.value)) {
    errorMsg.value = CROSS_CLOSE_MESSAGE
    return
  }

  recordDraft()
  errorMsg.value = ''
  draftClosed.value = true
  // A closed ring is no longer being drawn, so the view stops following the pointer: the click that
  // closed it may well have been made inside the edge band, and the loop must not outlive the gesture
  // that asked for it.
  if (autoPanHover) stopAutoPan()
  snapActive.value = false
  crossWarn.value = false
  redrawDraft()
  nextTick(() => {
    if (nameInput.value) nameInput.value.focus()
  })
}

function finishDraft() {
  errorMsg.value = ''
  if (!isValidAreaName(draftName.value)) {
    errorMsg.value = 'Give the area a name.'
    return
  }
  emit('area-added', {
    id: newId(),
    name: draftName.value.trim(),
    kind: draftKind.value,
    points: draftPoints.value.map((p) => [p[0], p[1]]),
  })
  resetDraft()
  mode.value = null // putting it down is the save
}

function resetDraft() {
  clearDraftLayers()
  draftPoints.value = []
  draftClosed.value = false
  draftName.value = ''
  draftKind.value = 'zone'
  snapActive.value = false
  crossWarn.value = false
  cursorLatLng = null
}

// Escape and the Clear button both empty the ring. Clearing is recorded like any other change,
// so Undo brings the whole ring back -- which is what makes Escape safe to press at all.
function clearDraft() {
  if (draftPoints.value.length === 0 && !draftClosed.value) return
  recordDraft()
  resetDraft()
}

// ---------- Undo / redo ----------
// Two stacks (see composables/useHistory.js): the ring being drawn, and the shape of the area
// whose dots are being dragged. Whichever is open is the one Ctrl+Z reaches -- only one can be
// open at a time -- and the buttons in each panel offer the same thing for anyone who would
// rather not use a keyboard.
//
// Snapshots are copied on the way in and on the way out, so a state that has been stepped back
// to can never be altered by the editing that follows it.
function draftSnapshot() {
  return {
    points: draftPoints.value.map((p) => [p[0], p[1]]),
    closed: draftClosed.value,
    name: draftName.value,
    kind: draftKind.value,
  }
}

function applyDraftSnapshot(snapshot) {
  draftPoints.value = snapshot.points.map((p) => [p[0], p[1]])
  draftClosed.value = snapshot.closed
  draftName.value = snapshot.name
  draftKind.value = snapshot.kind
  snapActive.value = false
  crossWarn.value = false
  cursorLatLng = null
  errorMsg.value = ''
  redrawDraft()
}

function recordDraft() {
  draftSteps.record(draftSnapshot())
}

// Both of these report whether anything happened, which is how the keyboard handler knows
// whether the press was the bench's to consume or the browser's to keep.
function undoDraft() {
  const snapshot = draftSteps.undo(draftSnapshot())
  if (!snapshot) return false
  applyDraftSnapshot(snapshot)
  return true
}

function redoDraft() {
  const snapshot = draftSteps.redo(draftSnapshot())
  if (!snapshot) return false
  applyDraftSnapshot(snapshot)
  return true
}

// An existing area's shape has no stack of its own any more: a dragged dot, a removed point and
// an added one are all changes to the PAGE's document, so they are all steps on the one global
// timeline. That is the whole point -- the stack used to reset the moment the planner clicked
// away from the shape, so Ctrl+Z stopped working exactly when they came back to it.

// Would adding this floor plan push the bench over the 4 MB the database accepts?
//
// The PAGE answers (see the `planFits` prop), because only the page knows how big the bench really is
// and which pictures are already stored: the same picture used by two plans is stored once, so a copy of
// an existing floor plan costs its placement and nothing else. Catching it here means the file is never
// added, so the planner does not have to work out afterwards which edit was the one that did it.
//
// It is a courtesy rather than the rule. The rule is in save_object(), and a picture that gets past this
// is refused there and taken back off the canvas (see useBenchDoc).
function canvasWouldOverflow(addedPlan) {
  if (typeof props.planFits !== 'function' || props.planFits(addedPlan)) return false
  errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
  return true
}

// ---------- Floor plan upload ----------
async function onFileChosen(event) {
  const file = event.target.files && event.target.files[0]
  event.target.value = '' // so choosing the same file again still fires
  if (!file) return

  busy.value = true
  errorMsg.value = ''
  try {
    const shrunk = await shrinkToUnder(file)
    // The file's own name is almost always the level ("level-1.png"), which is a better
    // name than anything generated -- but it is only a starting point, and it is editable.
    const fromFile = String(file.name || '')
      .replace(/\.[^.]+$/, '')
      .replace(/[_-]+/g, ' ')
      .trim()
    const plan = defaultPlan({
      id: newId(),
      name: fromFile || 'Floor plan ' + (props.plans.length + 1),
      centre: map.getCenter(),
      zoom: map.getZoom(),
      image: shrunk.dataUrl,
      imageAspect: shrunk.width / shrunk.height,
    })
    // Measured before the plan joins the canvas: a plan that cannot be saved is not added.
    if (canvasWouldOverflow(plan)) return
    emit('plan-added', plan)
    // Selected, so its corners and its rotate knob are there to work with -- but the view is left
    // where it is: the picture was just placed at a quarter of THIS screen (see defaultPlan), so
    // fitting it would zoom in on a placement the planner never saw at the size it was made for.
    viewAlreadyRight = true
    mode.value = 'floorplan:' + plan.id
    nextTick(renderHandles)
  } catch (err) {
    errorMsg.value = err.message || String(err)
  } finally {
    busy.value = false
  }
}

function renamePlan(plan, index, event) {
  const input = event.target
  const name = String(input.value || '').trim()
  if (!isValidPlanName(name)) {
    input.value = planLabel(plan, index) // put the old name back rather than lose it
    return
  }
  if (name === plan.name) return
  emit('plan-updated', { id: plan.id, patch: { name } })
}

function setOpacity(plan, value) {
  emit('plan-updated', { id: plan.id, patch: { opacity: Number(value) } })
}

function togglePlanVisible(plan) {
  const hiding = plan.visible !== false
  // There is nothing to handle once the picture is gone, so hiding the one being worked on
  // puts it down first.
  if (hiding && mode.value === 'floorplan:' + plan.id) mode.value = null
  emit('plan-updated', { id: plan.id, patch: { visible: !hiding } })
}

// The Delete key on a selected area: the same question as the list's Delete button.
async function deleteAreaAsk(area) {
  if (refusePress(area.id)) return
  const ok = await askConfirm({
    title: 'Delete "' + area.name + '"?',
    message: area.code ? 'Its zone goes with it.' : '',
    confirmText: 'Delete',
    danger: true,
  })
  // NOT putting the shape down first: putting down saves it, and that save would land after the
  // delete and bring the area back. The page takes it out of the document, then puts it down.
  if (ok) emit('area-deleted', area.id)
}

async function deletePlan(plan) {
  const ok = await askConfirm({
    title: 'Delete this floor plan?',
    message: 'The areas you have drawn stay.',
    confirmText: 'Delete',
    danger: true,
  })
  if (!ok) return
  if (mode.value === 'floorplan:' + plan.id) mode.value = null
  emit('plan-deleted', plan.id)
}

// A row in the list of floor plans is a way of choosing one, exactly as a row in the list of areas
// is: choosing one is what puts its corners and its rotate knob on the map. What must NOT choose is
// anything ON the row that does something of its own -- the name field, the show/hide switch, Edit,
// Copy, Delete, the opacity slider -- so a click that lands on one of those is left to it.
//
// Choosing the plan already being worked on changes nothing. A row in the areas list toggles,
// because that row is the only handle an area has; a plan has an Edit button that says what pressing
// it again will do, and a card that put the plan down when the planner clicked its empty half would
// be the same button with no label on it.
const PLAN_ROW_CONTROLS = 'input, button, select, textarea, a, label'

function pickPlanCard(plan, event) {
  const target = event.target
  if (target && target.closest && target.closest(PLAN_ROW_CONTROLS)) return
  if (mode.value === 'floorplan:' + plan.id) return
  mode.value = 'floorplan:' + plan.id
}

// ---------- Map events ----------
function onMapMoved() {
  zoomAnimating = false
  for (const id of Object.keys(planLayers)) planLayers[id].place()
  renderHandles()
}

// A zoom start marks the beginning of a fresh animation, so the next zoomanim may ease.
function onZoomStart() {
  zoomAnimating = false
}

// Leaflet's own layers ease themselves across a zoom; the hand-built pictures have to be
// told to.
function onZoomAnim() {
  const animate = !zoomAnimating
  zoomAnimating = true
  for (const id of Object.keys(planLayers)) planLayers[id].place(animate)
}

// Keyboard: Ctrl+Z / Ctrl+Shift+Z (and Ctrl+Y) for undo and redo, Escape to back out.
//
// The DOCUMENT stack is the page's, and so is the listener that drives it (registered after this
// one, so a press reaches here first). What this handler owns is the ring being DRAWN, which the
// document knows nothing about. While a ring is being drawn every press belongs to the ring --
// including the presses that find nothing left to take back -- because the alternative is the
// page stepping the whole document back and dropping the half-drawn ring on the floor. The event
// is stopped so exactly one step is taken per press.
function onKeyDown(event) {
  const el = event.target
  const tag = el && el.tagName
  // A field comes first. Inside one, Ctrl+Z belongs to the browser's own text undo -- the
  // planner who mistypes an area name must get that back, not the last point they drew -- and
  // Escape commits what was typed, so a second Escape then backs out. Without this, pressing
  // Escape mid-rename would quietly drop the new name.
  const inField = tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA'

  if ((event.ctrlKey || event.metaKey) && !event.altKey) {
    const key = String(event.key || '').toLowerCase()
    const undo = key === 'z' && !event.shiftKey
    const redo = (key === 'z' && event.shiftKey) || key === 'y'
    // Closing a ring puts the cursor in its Name box, so an EMPTY name box does not count as a field
    // here: there is no typing to take back, and Ctrl+Z means "un-close the shape" (Linus's notes).
    const emptyNameBox = inField && el.id === 'draft-name' && !el.value
    if ((undo || redo) && (!inField || emptyNameBox) && mode.value === 'polygons') {
      if (undo) undoDraft()
      else redoDraft()
      event.preventDefault()
      event.stopImmediatePropagation()
    }
    return
  }

  if ((event.key === 'Delete' || event.key === 'Backspace') && !inField && !event.altKey) {
    if (editingArea.value) {
      event.preventDefault()
      deleteAreaAsk(editingArea.value)
    } else if (editingPlan.value) {
      event.preventDefault()
      deletePlan(editingPlan.value)
    }
    return
  }

  if (event.key !== 'Escape') return
  if (inField) {
    if (el.blur) el.blur()
    return
  }

  // Clearing is recorded, so this is safe to press: Undo brings the ring straight back.
  if (draftPoints.value.length > 0) {
    clearDraft()
    return
  }
  if (mode.value !== null) mode.value = null
}

// There is no longer a question of WHICH Undo: the document has one timeline, and it is the
// page's (see composables/useDocHistory.js), so a press reaches the last change whatever it was.
// Clicking away from a shape and back does not touch it.
//
// The one thing that is not on that timeline is the ring being DRAWN, because it is not part of
// the document until Save -- and that is what this component's own key handler takes first (see
// onKeyDown). Anything it does not take is left for the page's listener, which is registered
// after this component's, so this one has already run by the time the page sees the press.

// A press on the page, outside the bench, puts down whatever is being worked on. Everything a
// planner reaches for while working is exempt: the bench itself (the map handles its own clicks,
// and while drawing it has to be able to ADD a point), a row in the list of areas, and any control
// -- so reaching for the opacity slider or a name field never ends the edit they belong to.
const KEEPS_EDITING = '.bench-wrap, .plan-row, .area-row, input, select, textarea, button, a, label'

// A scrollbar grab is not a click on the page, and it must not be read as one.
//
// Both lists scroll now, and reaching for a scrollbar while drawing would otherwise count as
// clicking away -- which ends the drawing session and throws away a half-drawn ring, because
// the planner wanted to see the bottom of a list. The browser reports a scrollbar press as
// landing on the scroll CONTAINER itself, never on anything inside it, so this matches the
// container and nothing else: the cards and rows keep their ordinary behaviour.
const SCROLL_AREAS = ['plan-scroll', 'area-scroll']

function isScrollbarGrab(target) {
  if (!target || !target.classList) return false
  return SCROLL_AREAS.some((name) => target.classList.contains(name))
}

function onDocumentPointerDown(event) {
  if (!props.canEdit) return
  // A middle press asks for the view, never for a shape or a page -- so it is not "clicking away",
  // and it must not put down what is being worked on. Ending a resize because the planner reached
  // for the map to see the far edge of it would be its own small betrayal.
  if (wantsMapPan(event)) return
  if (mode.value === null) return
  const target = event.target
  if (!target || !target.closest) return
  // Things that OPERATE the bench are exempt, because reaching for one must not end the edit you
  // are in the middle of -- the opacity slider would vanish under your finger, and a rename would
  // be cut short. The map is exempt too: it handles its own clicks, and it has to be able to ADD a
  // point while drawing.
  if (isScrollbarGrab(target)) return
  if (target.closest(KEEPS_EDITING)) return
  // A ring being drawn is not saved by clicking away -- it is not a shape until it is closed and
  // named -- so clicking away could only throw it away (Linus's test notes). It stays; Escape or
  // Clear ends it.
  if (mode.value === 'polygons' && (draftPoints.value.length > 0 || draftClosed.value)) {
    hoverPaused = true
    if (autoPanHover) stopAutoPan()
    return
  }
  // A press anywhere else on the page puts down whatever is being worked on, which saves it.
  mode.value = null
}

function onWindowResize() {
  if (!map) return
  map.invalidateSize()
  onMapMoved()
}

onMounted(() => {
  map = createSingaporeMap(mapEl.value)
  if (props.view) map.setView([props.view.lat, props.view.lng], props.view.zoom)

  // The map is a wall against page scrolling: see onMapWheel.
  map.getContainer().addEventListener('wheel', onMapWheel, WHEEL_OPTIONS)
  // The same wall for a finger. With Leaflet's own drag off (see applyMapHandlers) its CSS leaves the
  // map at `touch-action: pan-x pan-y`, which tells a phone's browser that a one-finger swipe is a page
  // scroll: it takes the gesture over and sends pointercancel, so a shape or the view stopped following
  // the finger after a few pixels. Every touch gesture on the map is handled here or by Leaflet's
  // pinch zoom, so the browser gets none of them. Inline, because Leaflet only ever changes classes.
  map.getContainer().style.touchAction = 'none'
  // On the container rather than on the map, because Leaflet drops every press that has already
  // been stopped -- and a press on a shape has been. A pan has to be able to start there.
  map.getContainer().addEventListener('pointerdown', onMapPointerDown)
  map.getContainer().addEventListener('pointermove', onEdgeHover)

  map.on('click', onMapClick)
  map.on('mousemove', onMapMove)
  map.on('zoom zoomend viewreset moveend', onMapMoved)
  map.on('moveend zoomend', emitView)
  map.on('zoomstart', onZoomStart)
  map.on('zoomanim', onZoomAnim)

  applyMapHandlers()
  render()
  renderHandles()
  window.addEventListener('resize', onWindowResize)
  // CAPTURE, deliberately. The page listens for the same keys on `window` too (it drives the
  // document's undo stack), and the two are not ordered by anything either of them controls --
  // whichever registered first would win. Capturing puts this one first whatever the order is,
  // so the ring being drawn always gets the press before the document does. `stopImmediate-
  // Propagation` in the handler is then enough to keep the page out of it.
  window.addEventListener('keydown', onKeyDown, true)
  document.addEventListener('pointerdown', onDocumentPointerDown)
})

onUnmounted(() => {
  window.removeEventListener('resize', onWindowResize)
  window.removeEventListener('keydown', onKeyDown, true)
  document.removeEventListener('pointerdown', onDocumentPointerDown)
  if (map) {
    map.getContainer().removeEventListener('wheel', onMapWheel, WHEEL_OPTIONS)
    map.getContainer().removeEventListener('pointerdown', onMapPointerDown)
    map.getContainer().removeEventListener('pointermove', onEdgeHover)
  }
  // All of these stop the auto-pan as well, so the frame loop can never outlive the map it pans.
  endDrag()
  endAreaDrag()
  stopVertexDrag()
  setHoverFollow(false)
  stopAutoPan()
  endPan()
  clearDraftLayers()
  clearAreaVertices()
  if (map) {
    map.remove()
    map = null
  }
})

// ---------- Picking a shape brings it into view ----------
// A shape picked from a list can be anywhere. It can be off the side of the screen, and it can be
// drawn at a zoom where a room is a few pixels across -- so the panel changes to the shape and the
// map carries on showing somewhere else, and the planner is left reaching for the zoom control to
// find the thing they just asked for. Choosing a shape is choosing to work on it, and the first
// thing that needs is for it to be on screen.
//
// The room left around it is not decoration. An area's dots sit ON its outline and a floor plan's
// corner handles and rotate knob stick OUT beyond the picture, so a shape framed edge to edge would
// have the very handles it was picked for off the screen.
const FRAME_PADDING_PX = 56

// A pick made ON the map is a pick too -- it is how a shape is grabbed -- but it is also the
// beginning of a drag, and moving the view out from under a drag would pull the shape away from the
// cursor holding it. The bench's own gestures say so by raising this before they set the mode;
// everything else that sets the mode is somebody choosing a shape they are not pointing at, from a
// list, a paste, or the buttons beside it.
let viewAlreadyRight = false

// Where the picked shape is, or null when it is not there at all -- a list row whose area was
// deleted in another tab. A plan is framed on its four corners rather than on its width and height,
// so a turned picture is framed by what is actually on screen.
function frameBounds(value) {
  if (value.startsWith('floorplan:')) {
    const plan = props.plans.find((p) => p.id === value.slice('floorplan:'.length))
    if (!plan || !Array.isArray(plan.centre)) return null
    return L.latLngBounds(cornersOf(plan).map(([lat, lng]) => L.latLng(lat, lng)))
  }
  const area = props.areas.find((a) => a.id === value.slice('area:'.length))
  if (!area || !Array.isArray(area.points) || area.points.length === 0) return null
  return L.latLngBounds(area.points.map(([lat, lng]) => L.latLng(lat, lng)))
}

function framePick(value) {
  if (!map || typeof value !== 'string') return
  if (!value.startsWith('area:') && !value.startsWith('floorplan:')) return
  const bounds = frameBounds(value)
  if (!bounds || !bounds.isValid()) return
  // No animation: the shape is what was asked for, so the answer arrives with the click rather than
  // a moment later. Leaflet clamps the zoom to the map's own limits, which is the closest a very
  // large or very small shape can be shown.
  map.fitBounds(bounds, { padding: [FRAME_PADDING_PX, FRAME_PADDING_PX], animate: false })
}

// Redraw what the props now say. The one mode that changes what the map's own pointer does is
// drawing, so that is the one the handlers are re-applied for; putting a shape down is the page's
// cue to save. The repaint itself is not here: `render` watches shapesClickable, which is exactly
// "may a picture or an outline be clicked", and entering or leaving drawing is the only thing that
// changes it.
watch(mode, (value, oldValue) => {
  const pickedOnMap = viewAlreadyRight
  viewAlreadyRight = false
  if (value === 'polygons' || oldValue === 'polygons') applyMapHandlers()
  if (value !== 'polygons') {
    // A drawing session that is over has nothing left to undo: the areas it produced belong to
    // the page now, and the next session starts clean.
    resetDraft()
    draftSteps.reset()
  }
  renderHandles()
  // Taking hold of a plan changes where it sits in the layer order (see place), so the pictures have
  // to be laid out again -- otherwise the plan that was just picked up stays under the area
  // outlines until something else happens to move it, and cannot be dragged where they overlap it.
  if (value !== null && value !== 'polygons') render()
  drawAreaVertices()
  // Last, so the shape is drawn before the view moves to it: `fitBounds` reports the new centre
  // through moveend and zoomend (see emitView), and that report is the view the page keeps.
  if (!pickedOnMap) framePick(value)
})

watch(() => props.plans, () => {
  render()
  renderHandles()
}, { deep: true })

watch(() => props.areas, render, { deep: true })

// Who is on what is not part of the canvas, so it gets a repaint of its own: presence changes with
// every planner's heartbeat, and none of that should cost a re-render of every shape on the map.
watch(
  () => (props.presence ? props.presence.byObject.value : null),
  () => renderPresence(),
)

// What on the map takes a click changes with the mode, and that is baked into the Leaflet layers
// when they are built -- so it needs its own repaint.
watch(shapesClickable, render)

watch(editingPlan, renderHandles)

// The shape being adjusted is identified by its ID and never by the object. The page replaces
// the area object on every change (see PolygonTestView.updateArea), so comparing objects would
// look like a different area on every dragged dot -- and would throw the history away exactly
// when the planner reached for it.
const editingAreaId = computed(() => (editingArea.value ? editingArea.value.id : ''))

watch(editingAreaId, () => {
  // The red on a dragged outline belongs to the drag, and the drag is over: whatever the layer was
  // last told, the area's own points are what it should be drawing now. `dragend` normally does
  // this, but a drag that is cut short -- a lost pointer capture, an interrupted touch -- must not
  // leave a shape looking like it is still being refused. The shape being edited is skipped,
  // because a drag may be in progress right now and its red is the live answer.
  for (const id of Object.keys(areaLayers)) {
    if (id === editingAreaId.value) continue
    const layer = areaLayers[id]
    if (!layer.benchCrossing) continue
    const area = props.areas.find((a) => a.id === id)
    if (!area) continue
    applyAreaPoints(layer, area.points)
  }
  renderHandles()
})

// Gaining or losing the claim changes whether the pictures and the outlines may be picked up,
// which is a style on the layers rather than a Leaflet handler -- so it needs a repaint. The view
// moves either way: looking around is not editing.
watch(() => props.canEdit, () => {
  applyMapHandlers()
  render()
})

// Rebuild the vertex handles when the shape being adjusted changes, or when a point was
// added or removed. NOT driven from render(), so a half-finished drag is never torn down
// underneath the planner's finger.
watch([editingArea, () => props.areas], drawAreaVertices, { deep: true })
</script>

<template>
  <div class="row g-3">
    <!-- ============ The map ============ -->
    <div class="col-12 col-lg-6">
      <div
        class="bench-wrap position-relative"
        :class="{ 'bench-drawing': mode === 'polygons' }"
      >
        <div ref="mapEl" class="bench-map rounded border" data-testid="bench-map"></div>

        <!-- Undo and redo are NOT here. They act on the whole document, not on the map, so they
             live on the page next to the other document-wide controls -- see
             views/PolygonTestView.vue. Over the map they covered the corner of the very thing
             they changed. -->

        <!-- Floor-plan handles. They are placed in map pixels, so they are re-placed on every
             `zoom`, `zoomend`, `viewreset` and `moveend` (see onMapMoved) -- a pan or a zoom moves
             the ground under them. A drag of a handle measures itself from the CURSOR and not from
             the handle, so a handle pulled in from the edge of the map still resizes correctly. -->
        <template v-if="editingPlan">
          <div
            v-for="(point, index) in handlePoints"
            :key="index"
            class="bench-handle"
            :style="{ left: point.x + 'px', top: point.y + 'px' }"
            :data-testid="'corner-' + index"
            @pointerdown="startDrag('corner', editingPlan, $event, index)"
          ></div>
          <div
            v-if="knobPoint"
            class="bench-knob"
            :style="{ left: knobPoint.x + 'px', top: knobPoint.y + 'px' }"
            data-testid="rotate-knob"
            title="Drag to turn the floor plan"
            @pointerdown="startDrag('knob', editingPlan, $event)"
          >
            <span class="bench-knob-dot"></span>
          </div>
        </template>

        <!-- The one strip along the top of the map, and the only place a sentence is ever put on
             screen -- while a ring is being drawn and while a shape is being adjusted alike. The
             refusal wins over everything: it is red, and it is the same red as the line or the
             outline it is about. -->

        <!-- While a dot is being dragged the outline itself is the message: it is red exactly
             where it would cross. Nothing is written for that, and nothing is written when "Add
             point" finds nowhere legal to put the dot -- the shape plainly did not change. -->
        <div
          v-if="showHint"
          class="bench-hint shadow-sm"
          :class="{ 'bench-hint-bad': Boolean(errorMsg) }"
          data-testid="bench-hint"
        >
          <span v-if="errorMsg" data-testid="bench-error">{{ errorMsg }}</span>

          <!-- Somebody else is on this shape: the one sentence that explains why nothing moved. -->
          <span v-else-if="lockNotice" data-testid="lock-notice">{{ lockNotice }}</span>

          <template v-else-if="mode === 'polygons'">
            <span data-testid="draft-hint">
              <template v-if="draftClosed">Name it, then save.</template>
              <template v-else-if="crossWarn">That point would cross a line already drawn.</template>
              <template v-else-if="closeBlocked">The closing line would cross the shape.</template>
              <template v-else-if="reachedPointCap">That is the {{ AREA_MAX_POINTS }}-point limit.</template>
              <template v-else-if="draftPoints.length < 3">Click to add a point.</template>
              <template v-else>Click the first dot to close the shape.</template>
            </span>
          </template>

          <span v-else data-testid="edit-hint">{{ editHint }}</span>
        </div>

        <!-- The ring is closed: ask for a name and a type -->
        <div v-if="draftClosed" class="bench-draft shadow" data-testid="draft-form">
          <label class="form-label small mb-1" for="draft-name">Name</label>
          <input
            id="draft-name"
            ref="nameInput"
            v-model="draftName"
            class="form-control form-control-sm mb-2"
            placeholder="e.g. Trees"
            maxlength="50"
            data-testid="area-name"
            @keyup.enter="finishDraft"
          />

          <label class="form-label small mb-1" for="draft-kind">Type</label>
          <select id="draft-kind" v-model="draftKind" class="form-select form-select-sm mb-2" data-testid="area-kind" @change="drawDraftFill">
            <option v-for="kind in AREA_KINDS" :key="kind.value" :value="kind.value">{{ kind.label }}</option>
          </select>

          <div class="d-flex gap-2">
            <button class="btn btn-sm btn-success flex-grow-1" data-testid="area-save" @click="finishDraft">
              Save area
            </button>
            <button class="btn btn-sm btn-outline-secondary" data-testid="area-cancel" @click="clearDraft">
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- ============ Controls ============ -->
    <div class="col-12 col-lg-6">
      <!-- The controls take the right half of a large screen, split in two: the areas being
           drawn, and the pictures they are drawn over. Below lg the split collapses and
           everything stacks in this order. -->
      <div class="row g-3">
        <!-- Looking, not editing: the map moves, nothing else does. -->
        <div v-if="!canEdit" class="col-12">
          <div class="card">
            <div class="card-body">
              <h2 class="h6 card-title">Looking, not editing</h2>
              <p class="small text-muted mb-0">
                Only this event's root and planners can change its zones.
              </p>
            </div>
          </div>
        </div>

        <!-- There is no Map card any more. Lock and Unlock were its two buttons, and there is
             nothing left for them to do: the map is never held still for the view's sake, and the
             only thing that narrows what a press means is `mode`, which the shapes and the map's
             own clicks set by themselves. What is left of the idea is said where it is needed --
             along the top of the map, while a shape is open, which is the only time it is true. -->

        <!-- The areas come first: drawing them is what the bench is for, and the list of them
             is what the planner keeps coming back to. -->
        <div class="col-12" :class="{ 'col-lg-6': canEdit }">
          <!-- Drawing -->
          <div v-if="canEdit" class="card mb-3">
            <div class="card-body">
              <h2 class="h6 card-title">Areas</h2>

              <template v-if="mode === 'polygons'">
                <div class="d-flex flex-wrap gap-2">
                  <button
                    class="btn btn-sm btn-outline-secondary"
                    :disabled="draftPoints.length < 3 || draftClosed || closeBlocked"
                    :title="closeBlocked ? 'This shape would close across itself' : ''"
                    data-testid="area-finish"
                    @click="closeDraft"
                  >
                    Finish
                  </button>
                  <button
                    class="btn btn-sm btn-outline-danger"
                    :disabled="draftPoints.length === 0"
                    data-testid="area-clear"
                    @click="clearDraft"
                  >
                    Clear
                  </button>
                  <button class="btn btn-sm btn-outline-secondary" data-testid="area-done" @click="mode = null">
                    Done
                  </button>
                </div>
              </template>

              <template v-else-if="editingArea">
                <!-- The instruction is on the map, over the shape it is about. Saying it again here
                     would be the same sentence twice on one screen, which is what the old bench
                     did. An outline left crossing by an older build refuses every edit until it is
                     put right: that is correct but looks like a broken page, so it is the one
                     thing that does get said here, with the way out. -->
                <p v-if="editingAreaCrosses" class="small text-danger mb-2" data-testid="area-crosses">
                  This outline crosses itself. Drag a dot until the lines no longer cross.
                </p>
                <div class="d-flex flex-wrap gap-2">
                  <button
                    class="btn btn-sm btn-outline-secondary"
                    :disabled="editingArea.points.length >= AREA_MAX_POINTS"
                    :title="editingArea.points.length >= AREA_MAX_POINTS ? 'An area can have at most ' + AREA_MAX_POINTS + ' points' : ''"
                    data-testid="area-add-point"
                    @click="addAreaPoint"
                  >
                    Add point
                  </button>
                  <button
                    class="btn btn-sm btn-outline-secondary"
                    title="Copy this area, then paste it to draw the same shape again"
                    data-testid="area-copy"
                    @click="copyArea(editingArea)"
                  >
                    Copy
                  </button>
                  <button
                    class="btn btn-sm btn-outline-secondary"
                    data-testid="area-shape-done"
                    @click="mode = null"
                  >
                    Done
                  </button>
                </div>
              </template>

              <div v-else class="d-flex flex-wrap gap-2">
                <button
                  class="btn btn-success flex-grow-1"
                  data-testid="draw-areas"
                  @click="mode = 'polygons'"
                >
                  Draw areas
                </button>
                <!-- Paste makes a SECOND area out of the last one copied, offset so it does not
                     hide underneath it. It is offered here rather than on the list because an
                     area is what is being made, and this is where areas are made. -->
                <button
                  class="btn btn-outline-secondary"
                  :disabled="!canPasteArea"
                  :title="canPasteArea ? 'Paste a copy of ' + clipboardAreaName : 'Copy an area first'"
                  data-testid="area-paste"
                  @click="pasteArea"
                >
                  Paste
                </button>
              </div>
            </div>
          </div>

          <!-- The page drops the list of areas in here, so it lines up with the controls. -->
          <slot />
        </div>

        <!-- Floor plans. One card each, because each one has its own name, its own show/hide
             and its own placement. -->
        <div v-if="canEdit" class="col-12 col-lg-6">
          <div class="card">
            <div class="card-body">
              <!-- How full the bench is, against the 4 MB the database enforces, as a ring. This is
                   the one number in the bench that the planner cannot see any other way, and the
                   pictures BELOW are what make it big -- so it belongs on this heading, next to
                   the thing that spends it, rather than off in the page header where it used to
                   sit with no clue about what it was counting. The number itself is the database's
                   (layout_bytes in 017), handed in by the page. -->
              <div class="d-flex align-items-center justify-content-between gap-2 mb-3">
                <h2 class="h6 card-title mb-0">Floor plans</h2>
                <div
                  class="d-flex align-items-center gap-2"
                  data-testid="canvas-size"
                  :title="
                    'The whole canvas is ' + sizeText + '. Floor plan images live inside it, so ' +
                    'they are what makes it big.'
                  "
                >
                  <span class="small text-muted text-nowrap">{{ sizeText }}</span>
                  <svg
                    class="bench-ring"
                    :class="'text-' + ringVariant"
                    width="34"
                    height="34"
                    viewBox="0 0 34 34"
                    role="img"
                    :aria-label="'Canvas size: ' + sizeText"
                  >
                    <!-- The full circle behind, then the part used, drawn as a dash of the
                         circumference. `pathLength="100"` lets the numbers be percentages rather
                         than a length in pixels. Rotated a quarter turn so the ring starts at the
                         top and fills clockwise, the way a gauge is read. -->
                    <circle
                      cx="17"
                      cy="17"
                      r="14"
                      pathLength="100"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="4"
                      opacity="0.18"
                    />
                    <circle
                      cx="17"
                      cy="17"
                      r="14"
                      pathLength="100"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="4"
                      stroke-linecap="round"
                      :stroke-dasharray="ringPercent + ' 100'"
                      transform="rotate(-90 17 17)"
                    />
                  </svg>
                </div>
              </div>

              <input
                ref="fileInput"
                type="file"
                accept="image/*"
                class="d-none"
                data-testid="floorplan-file"
                @change="onFileChosen"
              />
              <button
                class="btn btn-outline-secondary w-100 mb-2"
                :disabled="busy"
                data-testid="add-floorplan"
                @click="fileInput.click()"
              >
                {{ busy ? 'Shrinking...' : 'Add a floor plan' }}
              </button>

              <!-- Paste makes a COPY of the last floor plan copied: the same picture and size,
                   a name of its own, and a position a short step from the original so the two
                   are not stacked exactly on top of each other. -->
              <button
                class="btn btn-outline-secondary w-100 mb-3"
                :disabled="!canPastePlan"
                :title="canPastePlan ? 'Paste a copy of ' + clipboardPlanName : 'Copy a floor plan first'"
                data-testid="paste-floorplan"
                @click="pastePlan"
              >
                Paste a floor plan
              </button>

              <p v-if="plans.length === 0" class="small text-muted mb-0" data-testid="no-plans">
                No floor plans yet.
              </p>
              <div v-else class="plan-scroll" data-testid="plan-list">
                <div
                  v-for="(plan, index) in plans"
                  :key="plan.id"
                  class="card mb-2 plan-row"
                  :class="{ 'border-primary': mode === 'floorplan:' + plan.id }"
                  :data-testid="'plan-' + index"
                  @click="pickPlanCard(plan, $event)"
                >
                  <div class="card-body p-2">
                    <div class="d-flex align-items-center gap-2">
                      <!-- The name is what the planner calls this level, and what identifies the
                           picture on the map. -->
                      <input
                        v-if="canEdit"
                        class="form-control form-control-sm"
                        :value="planLabel(plan, index)"
                        :maxlength="PLAN_NAME_MAX"
                        :aria-label="'Name of ' + planLabel(plan, index)"
                        :data-testid="'plan-name-' + index"
                        @change="renamePlan(plan, index, $event)"
                      />
                      <div v-else class="text-truncate">{{ planLabel(plan, index) }}</div>

                      <div class="form-check form-switch mb-0" :title="'Show or hide this floor plan'">
                        <input
                          class="form-check-input"
                          type="checkbox"
                          role="switch"
                          :checked="plan.visible !== false"
                          :aria-label="'Show ' + planLabel(plan, index)"
                          :data-testid="'plan-visible-' + index"
                          @change="togglePlanVisible(plan)"
                        />
                      </div>
                    </div>

                    <div class="d-flex align-items-center gap-2 mt-2">
                      <!-- Edit / Done deliberately does NOT toggle anything about the map: Done puts
                           the picture down, and putting it down is the save. The view was never held
                           still for this, so there is nothing to hand back -- but a press on the
                           picture belongs to the picture, and Done is how it stops belonging. -->
                      <button
                        class="btn btn-sm"
                        :class="mode === 'floorplan:' + plan.id ? 'btn-primary' : 'btn-outline-primary'"
                        :data-testid="'plan-edit-' + index"
                        @click="mode = mode === 'floorplan:' + plan.id ? null : 'floorplan:' + plan.id"
                      >
                        {{ mode === 'floorplan:' + plan.id ? 'Done' : 'Edit' }}
                      </button>
                      <button
                        class="btn btn-sm btn-outline-secondary"
                        title="Copy this floor plan, then paste it to place the same picture again"
                        :data-testid="'plan-copy-' + index"
                        @click="copyPlan(plan)"
                      >
                        Copy
                      </button>
                      <button
                        class="btn btn-sm btn-link text-danger ms-auto px-0"
                        :data-testid="'plan-delete-' + index"
                        @click="deletePlan(plan)"
                      >
                        Delete
                      </button>
                    </div>

                    <div v-if="mode === 'floorplan:' + plan.id" class="mt-2">
                      <label class="form-label small mb-1" :for="'opacity-' + plan.id">
                        Opacity {{ Math.round((plan.opacity || 0) * 100) }}%
                      </label>
                      <input
                        :id="'opacity-' + plan.id"
                        class="form-range"
                        type="range"
                        min="0.05"
                        max="1"
                        step="0.05"
                        :value="plan.opacity"
                        :data-testid="'plan-opacity-' + index"
                        @input="setOpacity(plan, $event.target.value)"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.bench-map {
  height: 70vh;
  min-height: 360px;
}

/* The list of floor plans, capped. A bench with a dozen plans used to grow this column until
   the drawing card and the list of areas were pushed off the bottom of the screen, and the
   controls the planner was reaching for moved every time a plan was added. Now the list
   scrolls inside its card instead: about three plan cards are visible at a time, and the rest
   are a wheel-turn away.
   The same cap is on the list of areas, in AreaList.vue -- the two lists sit in the same
   column and should run out at the same height. */
.plan-scroll {
  max-height: 20rem;
  overflow-y: auto;
  /* Room for the scrollbar, so it does not sit on top of the cards' borders. */
  padding-right: 0.25rem;
  /* Scrolling to the end of the list must not carry on into the page behind it. */
  overscroll-behavior: contain;
}

/* While an area is being drawn the pointer becomes a crosshair -- the same signal every
   drawing tool gives -- on the map AND on everything Leaflet puts inside it, because those
   set a cursor of their own. This class goes on the wrapper, NOT on the map element: Vue
   rewrites `class` wholesale, which would wipe the `leaflet-*` classes Leaflet needs.
   Leaflet's own drag is off, so `.leaflet-grab` is not asked about: the class is not on the
   map any more. */
.bench-drawing .bench-map,
.bench-drawing .bench-map .leaflet-interactive {
  cursor: crosshair;
}

/* Moving the view. The middle button pans in every mode, drawing included, so this has to be able
   to win over the crosshair above -- hence the class going on the map container itself, which
   makes the selector one part longer than `.bench-drawing .bench-map`, and hence the `!important`
   for the interactive layers, whose own `cursor: move`/`pointer` is set inline by the bench. */
.bench-map.bench-panning,
.bench-map.bench-panning .leaflet-interactive,
.bench-map.bench-panning .leaflet-interactive * {
  cursor: grabbing !important;
}

/* Adding points is a run of quick clicks, and a quick second click reads as a double-click --
   which starts a text selection. On the map there is no text worth selecting, but there is
   plenty to highlight: the attribution and the zoom buttons turned blue in the middle of
   drawing, and the drag then carried that highlight around. Nothing inside the map is
   selectable, so the highlight never starts. The hint and the name form sit in the same
   wrapper and are left alone -- the planner does need to select the name they typed. */
.bench-map,
.bench-map * {
  user-select: none;
}

/* The floor plan itself. Positioned from a geographic centre, so Leaflet's overlay pane
   moving with the map is all the pan handling it needs. */
:global(.bench-plan) {
  position: absolute;
  transform-origin: 50% 50%;
  pointer-events: none;
  user-select: none;
}

/* Corner handles: white squares with a coloured border, like a PowerPoint picture. */
.bench-handle {
  position: absolute;
  width: 14px;
  height: 14px;
  margin: -7px 0 0 -7px;
  background: #fff;
  border: 2px solid #0d6efd;
  border-radius: 2px;
  cursor: nwse-resize;
  touch-action: none;
  z-index: 800;
}

.bench-knob {
  position: absolute;
  width: 26px;
  height: 26px;
  margin: -13px 0 0 -13px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: grab;
  touch-action: none;
  z-index: 800;
}
.bench-knob:active {
  cursor: grabbing;
}
.bench-knob-dot {
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: #0d6efd;
  border: 2px solid #fff;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.4);
}

/* A draggable point of an area being adjusted. Leaflet builds this HTML outside Vue, so
   the rule has to be global. */
:global(.bench-vertex) {
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: #fff;
  border: 2px solid #fd7e14;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
  /* A bin: clicking a dot removes it (dragging still moves it) */
  cursor: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='20' height='20' viewBox='0 0 20 20'%3E%3Cpath d='M4 6h12M8 6V4h4v2M6 6l1 11h6l1-11' fill='white' stroke='black' stroke-width='1.6' stroke-linejoin='round'/%3E%3C/svg%3E") 10 10, pointer;
}

/* On an edge of the area being edited: a press adds a point there (see addPointOnEdge).
   !important because Leaflet puts the outline's own cursor inline. */
:global(.bench-edge-hover),
:global(.bench-edge-hover .leaflet-interactive) {
  cursor: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='20' height='20' viewBox='0 0 20 20'%3E%3Cpath d='M10 3v14M3 10h14' stroke='white' stroke-width='5'/%3E%3Cpath d='M10 3v14M3 10h14' stroke='black' stroke-width='2'/%3E%3C/svg%3E") 10 10, copy !important;
}

/* How full the canvas is, and how full it is allowed to get. `currentColor` means the SVG picks up
   the Bootstrap text colour on the same element, so the three states are three class names and no
   colour is written twice. */
.bench-ring {
  width: 34px;
  height: 34px;
  flex: 0 0 auto;
}

/* The strip along the top of the map -- the ONE place a refusal is said, while drawing and while
   adjusting alike. The name-and-type form takes the bottom-right while a ring is being closed. */
.bench-hint {
  position: absolute;
  top: 10px;
  left: 50%;
  /* Anchored at its TOP edge, not its middle. A message that wraps to two lines must grow down
     into the map, where it covers nothing that matters, rather than half off the top of it. */
  transform: translateX(-50%);
  z-index: 1000;
  padding: 0.25rem 0.75rem;
  background: #fff;
  border-radius: 0.5rem;
  font-size: 0.875rem;
  /* Wider than a status message needs: a refusal is a whole sentence, and cutting one in half
     with an ellipsis is how the planner ends up not knowing what to fix. Everything past two
     lines is elided rather than growing the strip down the map. */
  max-width: min(90%, 30rem);
  overflow: hidden;
  text-align: center;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
}

/* Somebody is being told no. The same red as the line or the outline the sentence is about, so the
   words and the thing they describe are obviously one thing. */
.bench-hint-bad {
  color: #b02a37;
  border: 1px solid #dc3545;
  background: #fdf2f3;
}

.bench-draft {
  position: absolute;
  right: 10px;
  bottom: 10px;
  z-index: 1000;
  width: 15rem;
  padding: 0.75rem;
  background: #fff;
  border-radius: 0.5rem;
}

/* Leaflet draws area labels outside Vue, so the rule has to be global. */
:global(.area-label) {
  background: rgba(255, 255, 255, 0.85);
  border: none;
  box-shadow: none;
  font-size: 0.75rem;
  padding: 0 0.25rem;
}
:global(.area-label::before) {
  display: none;
}

/* Presence chips are Leaflet's too, so these are global for the same reason.
   The wrapper is a zero-size point sitting exactly on the shape's centre (iconSize [0,0]) and the
   chip inside it is placed around that point. Neither takes a press: a chip is a label, and one
   that swallowed a press meant for the shape underneath would be worse than no chip at all. */
:global(.bench-chip-wrap) {
  width: 0;
  height: 0;
  pointer-events: none;
}
:global(.bench-chip) {
  position: absolute;
  left: 0;
  top: 0;
  display: flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.05rem 0.4rem;
  border-radius: 999px;
  border: 1px solid var(--chip);
  background: #fff;
  color: var(--chip);
  font-size: 0.7rem;
  font-weight: 600;
  line-height: 1.4;
  white-space: nowrap;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.15);
  pointer-events: none;
}
:global(.bench-chip-lock) {
  font-size: 0.65rem;
}
</style>
