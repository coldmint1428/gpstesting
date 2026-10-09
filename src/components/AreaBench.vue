<script setup>
// AreaBench - the drawing bench itself: the map, the floor plans on it, the areas drawn on
// top, and the controls that operate them.
//
// Three things are deliberate and worth knowing before changing anything:
//
// 1. ONE THING IS UNLOCKED AT A TIME. `mode` is null | 'map' | 'floorplan:<id>' |
//    'polygons' | 'area:<id>'. Picking one locks the others, because two unlocked things
//    is not a state the value can express. Locking the map means disabling every Leaflet
//    handler.
//
// 2. BECAUSE THE MAP IS LOCKED WHILE A FLOOR PLAN IS EDITED, the corner handles and the
//    rotate knob are positioned once, from the frozen view, and never have to chase
//    anything. That is the whole reason this stays simple.
//
// 3. THE PAGE OWNS THE DATA. This component only draws it and reports what the planner
//    did (emit), so there is exactly one place that saves.
//
// Libraries: Leaflet (BSD-2-Clause) - https://leafletjs.com
//            OneMap basemap tiles (c) Singapore Land Authority - https://www.onemap.gov.sg
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { createSingaporeMap } from '../utils/onemap'
import { escapeHtml } from '../utils/people'
import {
  AREA_KINDS,
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
import { shrinkToUnder } from '../utils/imageShrink'

const props = defineProps({
  plans: { type: Array, default: () => [] },
  areas: { type: Array, default: () => [] },
  view: { type: Object, default: null }, // where the map was left
  // False while the planner is only looking. Looking allows panning and zooming; editing
  // is what starts locked, so the very first choice is what to work on.
  canEdit: { type: Boolean, default: false },
})

const emit = defineEmits([
  'plan-added',
  'plan-updated',
  'plan-deleted',
  'area-added',
  'area-updated',
  'view-changed',
])

// null | 'map' | 'floorplan:<id>' | 'polygons' | 'area:<id>'
const mode = defineModel('mode', { default: null })

const mapEl = ref(null)
const fileInput = ref(null)
const nameInput = ref(null)
const errorMsg = ref('')
const busy = ref(false)

// Leaflet objects are plain variables, never reactive: they are not Vue's to manage.
let map = null
const planLayers = {} // plan id -> { img, plan, place, add, remove }
const areaLayers = {} // area id -> L.polygon

// Drawing state
const draftPoints = ref([])
const draftClosed = ref(false)
const draftName = ref('')
const draftKind = ref('zone')
// True while the cursor is close enough to the first point that clicking would close the
// ring. Drives both the rubber band and the look of the first dot.
const snapActive = ref(false)
let cursorLatLng = null
let draftVertexMarkers = []
let draftLine = null
let draftFill = null

// Handle positions, in pixels inside the map container
const handlePoints = ref([])
const knobPoint = ref(null)
let dragState = null
let areaDrag = null

// Vertices of the area whose shape is being adjusted
let areaVertexMarkers = []
let zoomAnimating = false

const MAP_HANDLERS = ['dragging', 'scrollWheelZoom', 'touchZoom', 'boxZoom', 'doubleClickZoom', 'keyboard']

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

// How near the cursor has to come to the first point before the ring snaps shut, in screen
// pixels. Generous on purpose: closing a shape should not be a test of aim, and a fingertip
// covers far more than a mouse pointer does.
const SNAP_PX = 15

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

// Floor plans and drawn areas may be clicked on the map only when the map's own pointer is
// not wanted: in the locked state (to pick something) and while that kind of thing is
// already being worked on. In map and drawing modes every click belongs to the map, so the
// pictures and the polygons step out of the way.
const plansClickable = computed(
  () => props.canEdit && (mode.value === null || String(mode.value).startsWith('floorplan:')),
)

const areasClickable = computed(
  () => props.canEdit && (mode.value === null || String(mode.value).startsWith('area:')),
)

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

      // A picture that accepts pointer events swallows the map's own drags and taps, so it
      // only does so when the map is not the thing being used.
      const grabbable = plansClickable.value
      img.style.pointerEvents = grabbable ? 'auto' : 'none'
      img.style.touchAction = grabbable ? 'none' : ''
      img.style.cursor = grabbable ? (mine ? 'move' : 'pointer') : ''
      // The one being worked on sits above its neighbours. The overlay pane is its own
      // stacking context, so these numbers can never lift a plan over the map's controls.
      img.style.zIndex = mine ? '0' : '-1'
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
// chosen and then moved without letting go in between.
function onPlanPointerDown(layer, event) {
  if (!plansClickable.value) return
  const myMode = 'floorplan:' + layer.plan.id
  if (mode.value !== myMode) mode.value = myMode
  startDrag('move', event)
}

function areaKey(area) {
  return JSON.stringify([area.kind, area.name, area.points])
}

// Move an area's outline, and its label with it.
//
// A permanent Leaflet tooltip works out its own position ONCE, when it opens, and never
// looks again -- so moving the polygon leaves the name behind. Setting the label's latlng to
// the polygon's new centre is what puts it back on top of the shape.
function applyAreaPoints(layer, points) {
  if (!layer) return
  layer.setLatLngs(points)

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

  // Areas. They only take pointer events when clicking one is meant to select it; an
  // interactive polygon otherwise swallows the drags and taps meant for the map underneath.
  const clickable = areasClickable.value
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
      layer.benchClickable = clickable
      areaLayers[area.id] = layer
      if (clickable) {
        // A native pointer event, not Leaflet's `mousedown`: pointer events cover mouse,
        // finger and stylus with one path, and Leaflet's own touch events would never reach
        // this handler. The map is locked in every mode where this is attached, so the
        // polygon taking the press costs the map nothing.
        const el = layer.getElement()
        if (el) {
          el.style.cursor = 'move'
          el.addEventListener('pointerdown', (event) => onAreaPointerDown(area.id, event))
        }      }
    } else {
      // Shape and look are compared separately: dragging an area rewrites its points many
      // times a second, and there is no reason to rewrite the colour and the label too.
      const styleKey = area.kind + '\u0000' + area.name
      if (layer.benchKey !== key) {
        applyAreaPoints(layer, area.points)
        layer.benchKey = key
      }
      if (layer.benchStyleKey !== styleKey) {
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
}

// ---------- Map lock ----------
// Looking is free -- anybody may pan around. Working is not: once a planner holds the
// claim, everything starts locked and they unlock one thing at a time.
function applyMapLock() {
  if (!map) return
  const unlocked = !props.canEdit || mode.value === 'map'
  for (const name of MAP_HANDLERS) {
    const handler = map[name]
    if (!handler) continue
    if (unlocked) handler.enable()
    else handler.disable()
  }
}

function emitView() {
  if (!map || mode.value !== 'map') return
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

function startDrag(kind, event, index) {
  if (!props.canEdit) return
  const plan = editingPlan.value
  if (!plan || !map) return
  event.preventDefault()
  event.stopPropagation()
  dragState = { kind, index }
  if (kind === 'move') {
    // Recorded once, in geography: every move is then measured from here, so the picture
    // follows the pointer exactly instead of accumulating rounding at every step.
    dragState.from = map.containerPointToLatLng(map.mouseEventToContainerPoint(event))
    dragState.centre = [plan.centre[0], plan.centre[1]]
  }
  window.addEventListener('pointermove', onDragMove)
  window.addEventListener('pointerup', endDrag)
  window.addEventListener('pointercancel', endDrag)
}

function onDragMove(event) {
  const plan = editingPlan.value
  if (!dragState || !plan || !map) return

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
function updateSnap() {
  if (draftClosed.value || draftPoints.value.length < AREA_MIN_POINTS || !cursorLatLng || !map) {
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
    color: snapActive.value ? '#198754' : '#0d6efd',
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
    points.forEach((point, index) => areaVertexMarkers[index].setLatLng(point))
    return
  }

  clearAreaVertices()

  points.forEach((point, index) => {
    const marker = L.marker(point, {
      draggable: true,
      keyboard: false,
      icon: L.divIcon({
        className: '',
        html: '<div class="bench-vertex"></div>',
        iconSize: [16, 16],
        iconAnchor: [8, 8],
      }),
    }).addTo(map)

    marker.on('drag', () => {
      const at = marker.getLatLng()
      const next = currentAreaPoints()
      next[index] = [at.lat, at.lng]
      // Move the outline with the dot as it goes. Waiting for the drop meant the shape
      // only caught up once the planner let go, which made placing a point a guessing game.
      applyAreaPoints(areaLayers[area.id], next)
    })

    marker.on('dragend', () => {
      const at = marker.getLatLng()
      const next = currentAreaPoints()
      next[index] = [at.lat, at.lng]
      emit('area-updated', { id: area.id, patch: { points: next } })
    })

    marker.on('click', (event) => {
      L.DomEvent.stopPropagation(event)
      const next = currentAreaPoints()
      if (next.length <= AREA_MIN_POINTS) {
        errorMsg.value = 'An area needs at least ' + AREA_MIN_POINTS + ' points.'
        return
      }
      emit('area-updated', {
        id: area.id,
        patch: { points: next.filter((_, i) => i !== index) },
      })
    })

    areaVertexMarkers.push(marker)
  })

  areaVertexMarkers.benchArea = area.id
}

// A new point has to go somewhere: park it a short step east of the last one, then the
// planner drags it into place.
function addAreaPoint() {
  const area = editingArea.value
  if (!area) return
  const last = area.points[area.points.length - 1]
  const next = [last[0], last[1] + 0.00012] // ~13 m at this latitude
  emit('area-updated', { id: area.id, patch: { points: [...area.points, next] } })
}

// ---------- Selecting and moving areas ----------
// Pressing an area selects it -- the list row highlights and its dots appear -- and dragging
// carries the whole shape along, exactly the way a floor plan moves. A plain press with no
// movement is therefore just a selection.
function onAreaPointerDown(id, event) {
  if (!areasClickable.value || !map) return
  const area = props.areas.find((a) => a.id === id)
  if (!area) return

  // The browser must not start a text selection or a page scroll instead of a drag.
  if (event.preventDefault) event.preventDefault()

  if (mode.value !== 'area:' + id) mode.value = 'area:' + id

  areaDrag = {
    id,
    from: map.mouseEventToContainerPoint(event),
    points: area.points.map((p) => [p[0], p[1]]),
  }
  window.addEventListener('pointermove', onAreaDragMove)
  window.addEventListener('pointerup', endAreaDrag)
  window.addEventListener('pointercancel', endAreaDrag)
}

function onAreaDragMove(event) {
  if (!areaDrag || !map) return
  const from = map.containerPointToLatLng(areaDrag.from)
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
}

// ---------- Drawing ----------
function onMapClick(event) {
  const native = event.originalEvent
  const target = native && native.target
  // A click that landed on a floor plan picture or on a drawn area already belongs to that
  // thing, so it is not a click on the map.
  if (target && target.closest && target.closest('.leaflet-overlay-pane')) return
  if (!props.canEdit) return

  if (mode.value === 'polygons') {
    addDraftPoint(event)
    return
  }

  // Clicking away from whatever is being worked on puts it down. Putting it down is a lock,
  // and a lock is the save -- so this keeps what was done, it does not throw it away.
  if (mode.value !== null && mode.value !== 'map') mode.value = null
}

function addDraftPoint(event) {
  if (draftClosed.value) return

  const points = draftPoints.value
  if (points.length >= AREA_MIN_POINTS) {
    // Same tolerance as the snap, so "it looked closed" and "it closed" are the same thing.
    // The panel's Finish button closes it too, for anyone who would rather not aim at all.
    const first = map.latLngToContainerPoint(L.latLng(points[0][0], points[0][1]))
    const here = map.latLngToContainerPoint(event.latlng)
    if (here.distanceTo(first) <= SNAP_PX) {
      closeDraft()
      return
    }
  }

  points.push([event.latlng.lat, event.latlng.lng])
  cursorLatLng = event.latlng
  updateSnap()
  redrawDraft()
}

function onMapMove(event) {
  if (!props.canEdit || mode.value !== 'polygons' || draftClosed.value) return
  cursorLatLng = event.latlng
  updateSnap()
  applySnapLook()
  drawDraftLine()
}

function closeDraft() {
  if (draftPoints.value.length < AREA_MIN_POINTS) return
  draftClosed.value = true
  snapActive.value = false
  redrawDraft()
  nextTick(() => {
    if (nameInput.value) nameInput.value.focus()
  })
}

function finishDraft() {
  errorMsg.value = ''
  if (!isValidAreaName(draftName.value)) {
    errorMsg.value = 'Give the area a name (1 to 50 characters).'
    return
  }
  emit('area-added', {
    id: newId(),
    name: draftName.value.trim(),
    kind: draftKind.value,
    points: draftPoints.value.map((p) => [p[0], p[1]]),
  })
  resetDraft()
  mode.value = null // locking is the save
}

function resetDraft() {
  clearDraftLayers()
  draftPoints.value = []
  draftClosed.value = false
  draftName.value = ''
  draftKind.value = 'zone'
  snapActive.value = false
  cursorLatLng = null
}

function undoPoint() {
  if (draftClosed.value) {
    draftClosed.value = false
  }
  draftPoints.value.pop()
  redrawDraft()
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
    emit('plan-added', plan)
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

function deletePlan(plan) {
  if (!confirm('Delete this floor plan? The areas you have drawn stay.')) return
  if (mode.value === 'floorplan:' + plan.id) mode.value = null
  emit('plan-deleted', plan.id)
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

// Escape backs out of whatever is going on: first a half-drawn ring, then the mode. Both
// steps land on a lock, so both save.
function onKeyDown(event) {
  if (event.key !== 'Escape') return

  // A field comes first: leaving it commits what was typed, and a second Escape then backs
  // out. Otherwise pressing Escape mid-rename would quietly drop the new name.
  const el = event.target
  const tag = el && el.tagName
  if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') {
    if (el.blur) el.blur()
    return
  }

  if (draftPoints.value.length > 0) {
    resetDraft()
    return
  }
  if (mode.value !== null) mode.value = null
}

// Clicking anywhere that is not part of the bench puts down whatever is being worked on:
// the page background, the header, the navbar, or the empty space of a card.
//
// Things that OPERATE the bench are exempt, because reaching for one must not end the edit
// you are in the middle of -- the opacity slider would vanish under your finger, and a
// rename would be cut short. The map is exempt because it handles its own clicks and has to
// be able to ADD a point while drawing.
const KEEPS_EDITING = '.bench-wrap, .area-row, input, select, textarea, button, a, label'

function onDocumentPointerDown(event) {
  if (!props.canEdit || mode.value === null) return
  const target = event.target
  if (!target || !target.closest) return
  if (target.closest(KEEPS_EDITING)) return
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

  map.on('click', onMapClick)
  map.on('mousemove', onMapMove)
  map.on('zoom zoomend viewreset moveend', onMapMoved)
  map.on('moveend zoomend', emitView)
  map.on('zoomstart', onZoomStart)
  map.on('zoomanim', onZoomAnim)

  applyMapLock()
  render()
  renderHandles()
  window.addEventListener('resize', onWindowResize)
  window.addEventListener('keydown', onKeyDown)
  document.addEventListener('pointerdown', onDocumentPointerDown)
})

onUnmounted(() => {
  window.removeEventListener('resize', onWindowResize)
  window.removeEventListener('keydown', onKeyDown)
  document.removeEventListener('pointerdown', onDocumentPointerDown)
  endDrag()
  endAreaDrag()
  clearDraftLayers()
  clearAreaVertices()
  if (map) {
    map.remove()
    map = null
  }
})

// Redraw what the props now say. Leaving a floor-plan edit, or finishing a polygon, locks
// the map again -- which is also the page's cue to save.
watch(mode, (value) => {
  applyMapLock()
  if (value !== 'polygons') resetDraft()
  render()
  renderHandles()
  drawAreaVertices()
})

watch(() => props.plans, () => {
  render()
  renderHandles()
}, { deep: true })

watch(() => props.areas, render, { deep: true })

// Whether a floor plan or an area accepts a click is decided by the mode, and that is baked
// into the Leaflet layers when they are built -- so it needs its own repaint.
watch(plansClickable, render)
watch(areasClickable, render)

watch(editingPlan, renderHandles)

// Gaining or losing the claim changes whether the map may move at all -- and whether the
// floor plans may be picked up, which is a style on the pictures rather than a Leaflet
// handler, so it needs a repaint too.
watch(() => props.canEdit, () => {
  applyMapLock()
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
    <div class="col-12 col-lg-8">
      <div
        class="bench-wrap position-relative"
        :class="{ 'bench-drawing': mode === 'polygons' }"
      >
        <div ref="mapEl" class="bench-map rounded border" data-testid="bench-map"></div>

        <!-- Floor-plan handles. They only exist while the map is locked, so they never
             have to be re-anchored: they are placed once, from a frozen view. -->
        <template v-if="editingPlan">
          <div
            v-for="(point, index) in handlePoints"
            :key="index"
            class="bench-handle"
            :style="{ left: point.x + 'px', top: point.y + 'px' }"
            :data-testid="'corner-' + index"
            @pointerdown="startDrag('corner', $event, index)"
          ></div>
          <div
            v-if="knobPoint"
            class="bench-knob"
            :style="{ left: knobPoint.x + 'px', top: knobPoint.y + 'px' }"
            data-testid="rotate-knob"
            title="Drag to turn the floor plan"
            @pointerdown="startDrag('knob', $event)"
          >
            <span class="bench-knob-dot"></span>
          </div>
        </template>

        <!-- Drawing hint -->
        <div v-if="mode === 'polygons'" class="bench-hint shadow-sm" data-testid="draft-hint">
          <template v-if="draftClosed">Ring closed. Name it, then save.</template>
          <template v-else-if="draftPoints.length === 0">Click the map to add the first point.</template>
          <template v-else-if="draftPoints.length < 3">
            Click to add point ({{ draftPoints.length }} of 3 minimum).
          </template>
          <template v-else>Click to add a point, or click the first dot to close the shape.</template>
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
            <button class="btn btn-sm btn-outline-secondary" data-testid="area-cancel" @click="resetDraft">
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- ============ Controls ============ -->
    <div class="col-12 col-lg-4">
      <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="bench-error">
        {{ errorMsg }}
      </div>

      <!-- Looking, not editing: the map moves, nothing else does. -->
      <div v-if="!canEdit" class="card">
        <div class="card-body">
          <h2 class="h6 card-title">Looking, not editing</h2>
          <p class="small text-muted mb-0">
            Press <strong>Start editing</strong> to change anything.
          </p>
        </div>
      </div>

      <template v-else>
      <!-- Map -->
      <div class="card mb-3">
        <div class="card-body">
          <h2 class="h6 card-title">Map</h2>
          <button
            v-if="mode === 'map'"
            class="btn btn-primary w-100"
            data-testid="lock-map"
            @click="mode = null"
          >
            Lock the map
          </button>
          <button
            v-else
            class="btn btn-outline-primary w-100"
            :disabled="mode === 'polygons' && draftPoints.length > 0"
            data-testid="unlock-map"
            @click="mode = 'map'"
          >
            Unlock the map
          </button>
        </div>
      </div>

      <!-- Floor plans. One card each, because each one has its own name, its own show/hide
           and its own placement. -->
      <div class="card mb-3">
        <div class="card-body">
          <h2 class="h6 card-title">Floor plans</h2>

          <input
            ref="fileInput"
            type="file"
            accept="image/*"
            class="d-none"
            data-testid="floorplan-file"
            @change="onFileChosen"
          />
          <button
            class="btn btn-outline-secondary w-100 mb-3"
            :disabled="busy || mode === 'map'"
            data-testid="add-floorplan"
            @click="fileInput.click()"
          >
            {{ busy ? 'Shrinking...' : 'Add a floor plan' }}
          </button>

          <p v-if="plans.length === 0" class="small text-muted mb-0" data-testid="no-plans">
            No floor plans yet.
          </p>
          <div v-else data-testid="plan-list">
            <div
              v-for="(plan, index) in plans"
              :key="plan.id"
              class="card mb-2"
              :class="{ 'border-primary': mode === 'floorplan:' + plan.id }"
              :data-testid="'plan-' + index"
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
                  <button
                    class="btn btn-sm"
                    :class="mode === 'floorplan:' + plan.id ? 'btn-primary' : 'btn-outline-primary'"
                    :data-testid="'plan-edit-' + index"
                    @click="mode = mode === 'floorplan:' + plan.id ? null : 'floorplan:' + plan.id"
                  >
                    {{ mode === 'floorplan:' + plan.id ? 'Done' : 'Edit' }}
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

      <!-- Drawing -->
      <div class="card">
        <div class="card-body">
          <h2 class="h6 card-title">Areas</h2>

          <template v-if="mode === 'polygons'">
            <div class="d-flex flex-wrap gap-2">
              <button
                class="btn btn-sm btn-outline-secondary"
                :disabled="draftPoints.length === 0"
                data-testid="area-undo"
                @click="undoPoint"
              >
                Undo point
              </button>
              <button
                class="btn btn-sm btn-outline-secondary"
                :disabled="draftPoints.length < 3 || draftClosed"
                data-testid="area-finish"
                @click="closeDraft"
              >
                Finish
              </button>
              <button
                class="btn btn-sm btn-outline-danger"
                :disabled="draftPoints.length === 0"
                data-testid="area-clear"
                @click="resetDraft"
              >
                Clear
              </button>
              <button class="btn btn-sm btn-outline-secondary" data-testid="area-done" @click="mode = null">
                Done
              </button>
            </div>
          </template>

          <template v-else-if="editingArea">
            <p class="small mb-2">Drag a dot to move it, click a dot to remove it.</p>
            <div class="d-flex flex-wrap gap-2">
              <button
                class="btn btn-sm btn-outline-secondary"
                data-testid="area-add-point"
                @click="addAreaPoint"
              >
                Add point
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

          <button
            v-else
            class="btn btn-success w-100"
            :disabled="mode === 'map'"
            data-testid="draw-areas"
            @click="mode = 'polygons'"
          >
            Draw areas
          </button>
        </div>
      </div>
      </template>

      <!-- The page drops the list of areas in here, so it lines up with the controls. -->
      <slot />
    </div>
  </div>
</template>

<style scoped>
.bench-map {
  height: 70vh;
  min-height: 360px;
}

/* While an area is being drawn the pointer becomes a crosshair -- the same signal every
   drawing tool gives -- on the map AND on everything Leaflet puts inside it, because those
   set a cursor of their own. This class goes on the wrapper, NOT on the map element: Vue
   rewrites `class` wholesale, which would wipe the `leaflet-*` classes Leaflet needs. */
.bench-drawing .bench-map,
.bench-drawing .bench-map .leaflet-grab,
.bench-drawing .bench-map .leaflet-interactive {
  cursor: crosshair;
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
  cursor: move;
}

.bench-hint {
  position: absolute;
  top: 10px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 1000;
  padding: 0.25rem 0.75rem;
  background: #fff;
  border-radius: 999px;
  font-size: 0.875rem;
  max-width: calc(100% - 100px);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
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
</style>
