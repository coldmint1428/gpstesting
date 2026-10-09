// Floor-plan placement maths.
//
// A floor plan is stored as FOUR numbers -- centre (lat/lng), width, height and an angle
// -- rather than as two corners. That is what lets it rotate rigidly (slide + resize +
// turn, no skew) the way a PowerPoint picture does.
//
// Everything here is in "metres east / metres north" relative to the plan's centre, which
// keeps the trigonometry readable. Over the size of a venue the conversion between metres
// and degrees is accurate enough to ignore the curvature of the earth.

// Metres per degree of latitude. Longitude shrinks by cos(latitude).
const METRES_PER_DEGREE = 111320

// Matches the limits enforced by public.floor_plan_ok() in 005_layouts.sql.
export const MIN_SIZE_M = 0.5
export const MAX_SIZE_M = 20000
export const PLAN_NAME_MAX = 50

function toRadians(deg) {
  return (deg * Math.PI) / 180
}

export function normaliseAngle(deg) {
  const wrapped = Number(deg) % 360
  return wrapped < 0 ? wrapped + 360 : wrapped
}

function latOf(point) {
  return Array.isArray(point) ? point[0] : point.lat
}

function lngOf(point) {
  return Array.isArray(point) ? point[1] : point.lng
}

// How many metres one screen pixel covers at this latitude and zoom.
// 156543.03392 = the circumference of the earth at the equator / 256 px tiles.
export function metresPerPixel(lat, zoom) {
  return (156543.03392 * Math.cos(toRadians(lat))) / Math.pow(2, zoom)
}

// Offset of `point` from `centre`, in metres east (+) and north (+).
export function latLngToMetres(centre, point) {
  const lat0 = latOf(centre)
  const lng0 = lngOf(centre)
  return {
    x: (lngOf(point) - lng0) * METRES_PER_DEGREE * Math.cos(toRadians(lat0)),
    y: (latOf(point) - lat0) * METRES_PER_DEGREE,
  }
}

// The inverse: metres east/north from the centre back to a [lat, lng].
export function metresToLatLng(centre, x, y) {
  const lat0 = latOf(centre)
  const lng0 = lngOf(centre)
  return [
    lat0 + y / METRES_PER_DEGREE,
    lng0 + x / (METRES_PER_DEGREE * Math.cos(toRadians(lat0))),
  ]
}

// World (metres east/north) -> the plan's own frame, which is axis-aligned with the
// picture. Used when a mouse drag has to become a width/height change.
export function toLocal(x, y, angleDeg) {
  const a = toRadians(angleDeg)
  const cos = Math.cos(a)
  const sin = Math.sin(a)
  return { x: x * cos - y * sin, y: x * sin + y * cos }
}

// The plan's own frame -> world. A positive angle turns the picture clockwise on screen.
export function toWorld(x, y, angleDeg) {
  const a = toRadians(angleDeg)
  const cos = Math.cos(a)
  const sin = Math.sin(a)
  return { x: x * cos + y * sin, y: -x * sin + y * cos }
}

// The four corners as [lat, lng] pairs, going clockwise from the bottom-left of the
// picture's own frame. Handles are placed on these.
export function cornersOf(plan) {
  const centre = plan.centre
  const halfW = plan.widthM / 2
  const halfH = plan.heightM / 2
  const angle = plan.angleDeg || 0

  const local = [
    { x: -halfW, y: -halfH }, // bottom-left
    { x: halfW, y: -halfH }, // bottom-right
    { x: halfW, y: halfH }, // top-right
    { x: -halfW, y: halfH }, // top-left
  ]

  return local.map((p) => {
    const world = toWorld(p.x, p.y, angle)
    return metresToLatLng(centre, world.x, world.y)
  })
}

// Where the rotate knob sits: just outside the middle of the top edge.
export const KNOB_OFFSET_M = 18

export function knobLatLng(plan) {
  const world = toWorld(0, plan.heightM / 2 + KNOB_OFFSET_M, plan.angleDeg || 0)
  return metresToLatLng(plan.centre, world.x, world.y)
}

// The angle that makes the picture's "up" point from the centre towards the cursor.
// The picture's up vector at angle t is (sin t, cos t), so t = atan2(east, north).
export function angleFromPoints(centre, cursor) {
  const { x, y } = latLngToMetres(centre, cursor)
  return normaliseAngle((Math.atan2(x, y) * 180) / Math.PI)
}

// Drag a corner: turn the cursor's position into a new width and height, measured in the
// picture's own frame so the shape stays rectangular while it turns.
export function sizeFromCorner(plan, cursor) {
  const { x, y } = latLngToMetres(plan.centre, cursor)
  const local = toLocal(x, y, plan.angleDeg || 0)
  return {
    widthM: clampSize(Math.abs(local.x) * 2),
    heightM: clampSize(Math.abs(local.y) * 2),
  }
}

export function clampSize(metres) {
  if (!Number.isFinite(metres)) return MIN_SIZE_M
  return Math.min(MAX_SIZE_M, Math.max(MIN_SIZE_M, metres))
}

// A brand-new plan, centred on the current view: roughly a quarter of the screen wide,
// with the height taken from the image's own aspect ratio.
export function defaultPlan({ centre, zoom, image, imageAspect, id, name }) {
  const metresAcross = Math.max(5, 0.25 * 1000 * metresPerPixel(latOf(centre), zoom))
  const aspect = Number.isFinite(imageAspect) && imageAspect > 0 ? imageAspect : 1
  return {
    id,
    name: String(name == null ? '' : name).trim().slice(0, PLAN_NAME_MAX) || 'Floor plan',
    centre: [latOf(centre), lngOf(centre)],
    widthM: clampSize(metresAcross),
    heightM: clampSize(metresAcross / aspect),
    angleDeg: 0,
    opacity: 0.5,
    visible: true,
    image,
  }
}

// What to call a plan in the list. Names were added after the first version, so a plan
// saved without one still has to show something: its position in the list.
export function planLabel(plan, index) {
  const name = plan && typeof plan.name === 'string' ? plan.name.trim() : ''
  return name || 'Floor plan ' + (Number(index) + 1)
}

export function isValidPlanName(name) {
  const trimmed = String(name == null ? '' : name).trim()
  return trimmed.length >= 1 && trimmed.length <= PLAN_NAME_MAX
}

// Leaflet needs a zoom to compute the same metres-per-pixel; this keeps the call sites
// honest about which latitude and zoom they used.
export function pixelSize(plan, lat, zoom) {
  const mpp = metresPerPixel(lat, zoom)
  return { wPx: plan.widthM / mpp, hPx: plan.heightM / mpp }
}
