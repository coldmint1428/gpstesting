// Where does a new point go when the planner presses "Add point"?
//
// Appending it to the end of the ring -- which is what the bench used to do -- looks harmless and
// is not. A point at the end is joined to TWO neighbours: the dot that was last, and the dot that
// was first, because the ring closes. So the new dot has to sit somewhere the last-to-new edge and
// the new-to-first edge both miss everything else, and for a three-point ring that is often
// nowhere at all. A right-angled triangle with its last dot due south of its first had no legal
// landing spot within 13 m to the east: the closing edge ran straight through it, the guard
// refused, and there was no way to add a point to a triangle at all.
//
// Splitting an edge instead has no such problem. A new node that lies exactly on an existing edge
// divides that edge in two and leaves every other edge untouched, so a ring that did not cross
// itself still does not -- there is nothing to find, because the union of the split edges is
// exactly the segment that was already there.
//
// So: try the end of the ring first, because that is the dot the planner was last looking at and
// a new point belongs next to it; if that is refused, split the longest edge instead. A ring that
// already crosses itself gets neither, because a point added to a broken ring is a bigger broken
// ring.
//
// This is plane geometry on [lat, lng] pairs with no scaling of longitude by cos(lat), for the
// same reason utils/areaShape.js does not scale: a positive scale on one axis is an invertible map
// that sends straight lines to straight lines, so it cannot create or destroy a crossing. "Longest"
// is therefore longest on the page as well as longest in metres.

import { ringCrossing } from './areaShape.js'

// The threshold areaShape.js uses for "the same place" (about a tenth of a micrometre).
const EPS = 1e-12

// How far a point that splits an edge sits off the line of that edge, as a MULTIPLE of the base
// offset below. It only has to break the tie between "on the line" (a node three edges meet at,
// which areaShape.js reads as a crossing) and "beside it" (a plain corner) -- but it has to break
// it in a way the arithmetic can still SEE, and a ring whose dots are collinear to within a
// micrometre can need a bigger nudge than an ordinary one before the tie is broken.
//
// Two parts in the base offset, because either alone fails at one end of the range. The
// proportional part keeps the offset a fixed tiny SHARE of the edge, so it is invisible on the map
// at every scale. The flat part keeps it above the noise of double precision (about 1e-16
// relative) for a short edge: 1e-9 degrees is about a tenth of a millimetre.
//
// The fallbacks are for rings that are already degenerate: three dots within a micrometre of a
// straight line are not a triangle anybody can see, but they are a triangle the browser can hold,
// and refusing to add a point to one is the bug this whole module exists to fix. A millimetre is
// still nothing on a map.
const TOUCH_DEG = 1e-9
const TOUCH_SHARE = 1e-4
const OFFSETS = [1, 1e3, 1e4, 1e5]

// How far the parked dot sits from the ring, in degrees of latitude: about 13 m, which is a clear
// step away at the zooms this bench is used at. It is only a starting position -- the next thing
// the planner does is drag it -- so it wants to be visible more than it wants to be precise.
const STEP_DEG = 0.00012

// Adds one point to a ring, or reports that there is nowhere legal to put it (`insertedAt: null`,
// with the ring unchanged).
export function growRing(points) {
  const ring = Array.isArray(points) ? points.map((p) => [p[0], p[1]]) : []
  const n = ring.length
  if (n < 3) return { points: ring, insertedAt: null }

  // A ring that already crosses itself has no legal place to put anything -- every candidate is
  // judged by the same detector that says the ring is broken, and a new node on top of a broken
  // ring is a bigger broken ring, not a repaired one. Refusing is the honest answer, and the panel
  // already says what to do about it: drag a dot until the lines come apart.
  if (ringCrossing(ring)) return { points: ring, insertedAt: null }

  const last = ring[n - 1]
  const first = ring[0]

  // End of the ring: a step from the last dot, at right angles to the edge that arrives there --
  // the two sides of that edge, so the first candidate is the side the ring is NOT already on.
  const arrived = ring[n - 2]
  let dy = last[0] - arrived[0]
  let dx = last[1] - arrived[1]
  if (dy === 0 && dx === 0) {
    // The last two dots are in the same place (only reachable by hand: every path that adds a
    // point refuses a duplicate). Fall back to the edge that LEAVES the last dot instead.
    dy = first[0] - last[0]
    dx = first[1] - last[1]
  }
  const length = Math.hypot(dy, dx)
  if (length > 0) {
    const outward = [-dx / length, dy / length] // [dLat, dLng], a quarter turn from the edge
    for (const step of [STEP_DEG, -STEP_DEG]) {
      const candidate = [last[0] + outward[0] * step, last[1] + outward[1] * step]
      if (!ringCrossing([...ring, candidate])) {
        return { points: [...ring, candidate], insertedAt: n }
      }
    }
  }

  // Nothing at the end works, so an edge is split instead. A new node that lies ON an edge divides
  // it in two and leaves every other edge alone, so a ring that did not cross itself still does
  // not: the two halves are pieces of a line that was already there.
  //
  // It is placed a hair off the line rather than exactly on it, which is the difference between a
  // new corner and a broken ring. Exactly on the line means a node with three edges meeting at it,
  // and the rule in areaShape.js is that anything meeting anywhere but at an end is a crossing --
  // so the "safe" placement is the one that fails. For a ring whose dots are already collinear it
  // is worse than that: the split makes the closing edge run back along the edge it just split,
  // and the two overlap. A hair off the line is a plain corner on either side.
  //
  // Longest edge first, but not only the longest: a dot can already sit where an edge's middle is,
  // and splitting there would leave a zero-length edge behind, so each edge is tried and skipped.
  const order = []
  for (let i = 0; i < n; i += 1) {
    const a = ring[i]
    const b = ring[(i + 1) % n]
    order.push({ i, span: (b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]) })
  }
  order.sort((p, q) => q.span - p.span)

  for (const { i, span } of order) {
    if (span <= 0) continue // every dot in one place: there is no edge to split
    const a = ring[i]
    const b = ring[(i + 1) % n]
    const middle = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
    const edge = Math.sqrt(span)
    const across = [(b[1] - a[1]) / edge, -(b[0] - a[0]) / edge] // a quarter turn from the edge
    for (const distance of OFFSETS) {
      const touch = (TOUCH_SHARE * edge + TOUCH_DEG) * distance
      for (const side of [1, -1]) {
        const candidate = [
          middle[0] + across[0] * touch * side,
          middle[1] + across[1] * touch * side,
        ]
        const sitsOnADot = ring.some(
          (p) => Math.abs(p[0] - candidate[0]) <= EPS && Math.abs(p[1] - candidate[1]) <= EPS,
        )
        if (sitsOnADot) continue
        const split = [...ring.slice(0, i + 1), candidate, ...ring.slice(i + 1)]
        if (ringCrossing(split)) continue
        return { points: split, insertedAt: i + 1 }
      }
    }
  }

  // Genuinely nowhere to put it: every dot in one place, or a ring that already crosses itself.
  return { points: ring, insertedAt: null }
}
