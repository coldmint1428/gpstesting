// What a live frame may say, and what may be done with one.
//
// A live frame is how one planner watches another drag a shape: the browser that is moving it
// publishes the geometry it is moving, about twenty times a second, straight to the other browsers
// (Realtime broadcast -- see composables/useBenchFrames.js). It never reaches the database, and the
// database is the only thing that decides who may change what, so a frame is a hint in the
// strongest sense: any signed-in page can publish one, and the page that receives it still has to
// draw it. Everything in this file exists because of that.
//
// TWO RULES MAKE AN UNTRUSTWORTHY STREAM SAFE TO DRAW.
//
// 1. A FRAME MAY ONLY CHANGE WHAT A DRAG CHANGES. The field list is per kind, and it deliberately
//    holds no `id`, no `image` and no `view`: a frame can never invent a shape, rename one, hand a
//    floor plan a new picture, or carry a picture through the socket at all. The same list filters
//    what is sent and what is applied, so the two sides cannot drift apart -- and a field that is
//    present but unusable (points that are not points) takes the whole frame down with it, rather
//    than half-applying a shape.
//
// 2. A FRAME MAY NEVER MAKE THE CANVAS UNSAVEABLE. What a receiver draws is part of the document it
//    holds, and that document is what the next write of each shape sends -- so geometry the database
//    would refuse has no business being drawn on the strength of a message from another browser: the
//    planner's own next write of that shape would be refused with a sentence about a shape they did not
//    move. So a frame whose geometry leaves that box is dropped, and the shape on this screen stays
//    where it was until the planner who owns it writes their own change.
//
// The box below is public.point_in_sg() in 005_layouts.sql, which is where it is enforced for real.
// A crossing outline is deliberately NOT checked: the database has no such rule (refusing a
// crossing ring is the bench's own courtesy while a dot is being dragged), so a crossing frame is
// perfectly saveable and there is nothing here that needs to care about it.
import {
  AREA_KINDS,
  AREA_MAX_POINTS,
  AREA_MIN_POINTS,
  isValidAreaName,
} from './areaKinds'
import { MAX_SIZE_M, isValidPlanName } from './floorPlan'

const SG = { minLat: 1.1, maxLat: 1.5, minLng: 103.5, maxLng: 104.2 }

// Per kind, and nothing else may travel. `points` and `centre` are what the drags change on every
// frame; the rest are the ordinary edits (a rename, a retype, a hide) that a planner would expect
// to appear on the other screen too.
const AREA_FIELDS = ['points', 'name', 'kind']
const PLAN_FIELDS = ['centre', 'angleDeg', 'widthM', 'heightM', 'opacity', 'visible', 'name']

function isNumber(value) {
  return typeof value === 'number' && Number.isFinite(value)
}

// Exactly two finite numbers inside Singapore -- the same four tests point_in_sg() makes, including
// "exactly two members": a third would be a value the database refuses.
export function inSingapore(point) {
  if (!Array.isArray(point) || point.length !== 2) return false
  if (!isNumber(point[0]) || !isNumber(point[1])) return false
  return (
    point[0] >= SG.minLat &&
    point[0] <= SG.maxLat &&
    point[1] >= SG.minLng &&
    point[1] <= SG.maxLng
  )
}

function ringInSingapore(points) {
  if (!Array.isArray(points)) return false
  if (points.length < AREA_MIN_POINTS || points.length > AREA_MAX_POINTS) return false
  return points.every(inSingapore)
}

// One field of a frame, cleaned: copied (never aliased to the sender's array), reduced to the
// members this app stores, and checked against the rule it has to satisfy. `undefined` means "this
// frame cannot be used", which is not the same as "this field was absent" -- absent fields are
// skipped before they get here, and are how a frame says nothing about them.
function cleanField(kind, field, value) {
  if (field === 'points') {
    if (!ringInSingapore(value)) return undefined
    return value.map((point) => [point[0], point[1]])
  }
  if (field === 'name') {
    const valid = kind === 'plan' ? isValidPlanName(value) : isValidAreaName(value)
    return valid ? value : undefined
  }
  if (field === 'kind') {
    return AREA_KINDS.some((entry) => entry.value === value) ? value : undefined
  }
  if (field === 'centre') {
    return inSingapore(value) ? [value[0], value[1]] : undefined
  }
  if (field === 'angleDeg') {
    return isNumber(value) ? value : undefined
  }
  if (field === 'widthM' || field === 'heightM') {
    // Matches floor_plan_ok(): positive, and no longer than 20 km a side.
    return isNumber(value) && value > 0 && value <= MAX_SIZE_M ? value : undefined
  }
  if (field === 'opacity') {
    return isNumber(value) && value >= 0 && value <= 1 ? value : undefined
  }
  if (field === 'visible') {
    return typeof value === 'boolean' ? value : undefined
  }
  return undefined
}

// A frame's patch, cleaned, or null when the frame says nothing this app can use. Used on the way
// OUT as well as on the way in: one list of fields for both directions is what stops a future patch
// (a floor plan's image, say) from quietly turning every drag into a megabyte on the wire.
export function framePatch(kind, patch) {
  if (!patch || typeof patch !== 'object') return null
  const fields = kind === 'plan' ? PLAN_FIELDS : AREA_FIELDS
  const out = {}
  let used = false

  for (const field of fields) {
    if (!Object.prototype.hasOwnProperty.call(patch, field)) continue
    const value = cleanField(kind, field, patch[field])
    if (value === undefined) return null
    out[field] = value
    used = true
  }

  return used ? out : null
}

// One frame applied to one area: a NEW object, or null when the result would not be a shape the
// database would store. Nothing in this app is mutated in place -- the page replaces the object on
// every change -- so this hands back a replacement and leaves the original alone.
export function applyAreaFrame(area, patch) {
  if (!area) return null
  const clean = framePatch('area', patch)
  if (!clean) return null

  const next = { ...area, ...clean }
  // The rules public.area_ok() has that a patch could break, re-checked on the MERGED object: a
  // frame is only ever allowed to leave a shape that could be saved.
  if (!isValidAreaName(next.name)) return null
  if (!AREA_KINDS.some((entry) => entry.value === next.kind)) return null
  if (!ringInSingapore(next.points)) return null
  return next
}

// The same for a floor plan. `image` is never in a patch, so it is never a question here; what a
// frame can break is the placement, and that is what is checked.
export function applyPlanFrame(plan, patch) {
  if (!plan) return null
  const clean = framePatch('plan', patch)
  if (!clean) return null

  const next = { ...plan, ...clean }
  if (!inSingapore(next.centre)) return null
  if (!isNumber(next.widthM) || next.widthM <= 0 || next.widthM > MAX_SIZE_M) return null
  if (!isNumber(next.heightM) || next.heightM <= 0 || next.heightM > MAX_SIZE_M) return null
  if (!isNumber(next.angleDeg)) return null
  if (!isNumber(next.opacity) || next.opacity < 0 || next.opacity > 1) return null
  if (typeof next.visible !== 'boolean') return null
  if (!isValidPlanName(next.name)) return null
  return next
}
