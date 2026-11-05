// Unit: does a shape cross itself?
//
// The bench refuses a point that would make an area's outline cross a line already drawn (an hourglass is not a
// shape anybody planned), and refuses to close a ring that would close across itself. Both answers come from
// areaShape.js, and the rule that makes it work is the one worth testing: TWO EDGES THAT MEET AT AN END DO NOT
// CROSS. Every neighbouring pair of a ring meets at an end, so if that rule were wrong every area on the map would
// be reported as broken -- and if it were applied too widely, a ring that really does pinch itself would be saved.
//
// Points are [lat, lng]. Nothing here is scaled by cos(lat) on purpose: scaling one axis is invertible and sends
// straight lines to straight lines, so it cannot create or destroy a crossing.
import { describe, it, expect } from 'vitest'
import { segmentsIntersect, edgesCross, pathCrossing, closingCrosses, ringCrossing } from '../areaShape'

// A square, drawn the way a planner clicks it. Nothing meets except at the corners.
const SQUARE = [
  [0, 0],
  [0, 1],
  [1, 1],
  [1, 0],
]

describe('an area outline that crosses itself', () => {
  it('calls a plain square legal, refuses a bow tie, and does not mistake a shared corner for a crossing', () => {
    // ---------- The legal shape ----------
    expect(pathCrossing(SQUARE)).toBe(null)
    expect(closingCrosses(SQUARE)).toBe(false)
    expect(ringCrossing(SQUARE)).toBe(null)

    // Two edges that meet at an end are neighbours, not a crossing: this is what makes a ring possible at all.
    expect(edgesCross([0, 0], [1, 1], [1, 1], [2, 0])).toBe(false)
    // ... and the same rule covers a corner drawn twice by accident, which is the whole reason it is tested by
    // coordinate rather than by position in the list.
    expect(pathCrossing([[0, 0], [0, 0], [1, 1]])).toBe(null)

    // ---------- A bow tie, closed ----------
    // 0 — 2 and 1 — 3 are the two wires: the first pair of edges that cross is (0, 2).
    const bowTie = [
      [0, 0],
      [1, 1],
      [1, 0],
      [0, 1],
    ]
    expect(ringCrossing(bowTie)).toEqual([0, 2])
    // While it is still being drawn, the same crossing is caught at the open path.
    expect(pathCrossing(bowTie)).toEqual([0, 2])

    // ---------- A vertex landing in the middle of an edge is a crossing too ----------
    // A ring that pinches itself is not a shape: the point touches a line it is not an end of.
    expect(segmentsIntersect([0, 0], [0, 2], [0, 1], [1, 1])).toBe(true) // c sits on a-b
    expect(edgesCross([0, 0], [0, 2], [0, 1], [1, 1])).toBe(true) // and it shares no end, so it IS a crossing
    expect(ringCrossing([[0, 0], [0, 2], [0, 1], [1, 1]])).not.toBe(null)

    // ---------- The half an open path cannot ask ----------
    // The closing edge does not exist until the planner closes the ring, so a path can be perfectly legal and still
    // close across itself. Here the path walks up the left, down a wall at lng 2, and stops to the right of it; the
    // line back to the start cuts the wall, which is edge 0-1.
    const closesAcrossTheRoom = [
      [0, 0], // start, left of the wall
      [2, 3], // the wall: lat 2, lng 3 down to -1
      [2, -1],
      [4, 0],
      [4, 2], // the end, right of the wall
    ]
    expect(pathCrossing(closesAcrossTheRoom)).toBe(null) // nothing drawn so far crosses
    expect(closingCrosses(closesAcrossTheRoom)).toBe(true) // but it cannot be closed
    expect(ringCrossing(closesAcrossTheRoom)).not.toBe(null) // a saved shape would be refused too

    // A ring of fewer than three points cannot cross anything: it has no edges to cross.
    expect(ringCrossing([[0, 0], [1, 1]])).toBe(null)
    expect(closingCrosses([[0, 0], [1, 1]])).toBe(false)
  })
})
