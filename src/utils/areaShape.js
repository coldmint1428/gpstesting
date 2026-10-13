// Does a shape cross itself?
//
// The bench refuses a point that would make an area's outline cross a line already drawn -- an
// hourglass is not a shape anybody planned -- and refuses an edit that would leave an outline
// crossing itself. Both answers come from here.
//
// TWO EDGES THAT MEET AT AN END DO NOT CROSS. That is the whole trick. Every pair of
// neighbouring edges of a ring meets at an end, and so does a pair that shares a point by
// accident (the same point drawn twice, or two points that landed on the same spot), and none
// of those is a crossing. Testing it by COORDINATE rather than by position in the list means one
// rule covers both, with no "skip the neighbours" special case left to get wrong.
//
// Everything else that meets IS a crossing, including a vertex landing in the middle of another
// edge -- a ring that pinches itself is not a shape either. The threshold for "the same point"
// is tiny (EPS is about a tenth of a micrometre), so an ordinary click can never land close
// enough to be read as one.
//
// All of it is plane geometry on [lat, lng] pairs, with NO scaling of longitude by cos(lat).
// That is deliberate and it is exact, not an approximation: scaling one axis by a positive
// factor is an invertible map that sends straight lines to straight lines, so it cannot create
// or destroy a crossing. The only thing it would change is the angles, and nothing here
// measures angles.

const EPS = 1e-12

// Twice the signed area of the triangle a, b, c. Positive and negative are the two sides of
// the line through a and b; zero is on it. Only the sign is ever used.
function orient(a, b, c) {
  return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
}

// Is p inside the box the segment a-b spans? Only asked when p is already known to be on the
// line through a and b, which is what makes the box the whole question.
function withinBox(a, b, p) {
  return (
    Math.min(a[0], b[0]) - EPS <= p[0] &&
    p[0] <= Math.max(a[0], b[0]) + EPS &&
    Math.min(a[1], b[1]) - EPS <= p[1] &&
    p[1] <= Math.max(a[1], b[1]) + EPS
  )
}

// Do the segments a-b and c-d meet, at all? True for a proper crossing and for every touching
// case: an endpoint on the other segment, or the two overlapping.
export function segmentsIntersect(a, b, c, d) {
  const d1 = orient(a, b, c)
  const d2 = orient(a, b, d)
  const d3 = orient(c, d, a)
  const d4 = orient(c, d, b)

  // Each segment straddles the other's line -- the ordinary crossing.
  const straddle1 = (d1 > EPS && d2 < -EPS) || (d1 < -EPS && d2 > EPS)
  const straddle2 = (d3 > EPS && d4 < -EPS) || (d3 < -EPS && d4 > EPS)
  if (straddle1 && straddle2) return true

  // Otherwise the only way to meet is on a line: one of the four endpoints sits on the other
  // segment (which covers the fully-overlapping case too).
  if (Math.abs(d1) <= EPS && withinBox(a, b, c)) return true
  if (Math.abs(d2) <= EPS && withinBox(a, b, d)) return true
  if (Math.abs(d3) <= EPS && withinBox(c, d, a)) return true
  if (Math.abs(d4) <= EPS && withinBox(c, d, b)) return true
  return false
}

function samePlace(a, b) {
  return Math.abs(a[0] - b[0]) <= EPS && Math.abs(a[1] - b[1]) <= EPS
}

function sharesEnd(a, b, c, d) {
  return samePlace(a, c) || samePlace(a, d) || samePlace(b, c) || samePlace(b, d)
}

// Do the edges a-b and c-d cross? Meeting at an end is not crossing -- see the note at the top.
export function edgesCross(a, b, c, d) {
  return !sharesEnd(a, b, c, d) && segmentsIntersect(a, b, c, d)
}

// The first pair of edges of an OPEN path that cross, as [i, j], or null. Edge i joins
// nodes[i] and nodes[i+1].
//
// This is the check that runs while the planner is drawing, on the path as far as the point
// they are about to add. It cannot refuse a legal shape: the edges of a ring that does not
// cross itself are a subset of that ring's edges, so no part of drawing one can cross either.
export function pathCrossing(nodes) {
  const edges = nodes.length - 1
  for (let i = 0; i < edges; i += 1) {
    for (let j = i + 1; j < edges; j += 1) {
      if (edgesCross(nodes[i], nodes[i + 1], nodes[j], nodes[j + 1])) return [i, j]
    }
  }
  return null
}

// Would the line that closes the ring -- last point back to the first -- cross the shape?
//
// This is the half of the question an open path cannot ask while it is being drawn: the closing
// edge does not exist until the planner closes it. A ring can be perfectly legal as far as the
// drawn path goes and still close across itself, which is why the bench asks here as well as at
// every point. Every edge of the path is compared, including the two that neighbour the closing
// edge: those share an end with it, so they cannot cross it.
export function closingCrosses(nodes) {
  const n = nodes.length
  if (n < 3) return false
  const last = nodes[n - 1]
  const first = nodes[0]
  for (let j = 0; j <= n - 2; j += 1) {
    if (edgesCross(last, first, nodes[j], nodes[j + 1])) return true
  }
  return false
}

// The first pair of edges of a CLOSED ring that cross, as [i, j], or null. Edge i joins
// nodes[i] and nodes[(i + 1) % n] -- the ring, not a path. Used on shapes that already exist:
// an area on the map, and the shape a dragged vertex would make.
export function ringCrossing(nodes) {
  const n = nodes.length
  if (n < 3) return null // three edges can only ever meet at their ends
  for (let i = 0; i < n; i += 1) {
    for (let j = i + 1; j < n; j += 1) {
      if (edgesCross(nodes[i], nodes[(i + 1) % n], nodes[j], nodes[(j + 1) % n])) return [i, j]
    }
  }
  return null
}
