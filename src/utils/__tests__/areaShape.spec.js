// Unit test: does a shape cross itself? (utils/areaShape.js). Two edges that meet at an end do not cross.
import { describe, it, expect } from 'vitest'
import { pathCrossing, closingCrosses, ringCrossing, edgesCross } from '../areaShape'

const SQUARE = [
  [0, 0],
  [0, 1],
  [1, 1],
  [1, 0],
]
const BOW_TIE = [
  [0, 0],
  [1, 1],
  [1, 0],
  [0, 1],
]

describe('areaShape', () => {
  it('calls a plain square legal, refuses a bow tie, and does not mistake a shared corner for a crossing', () => {
    expect(pathCrossing(SQUARE)).toBe(null)
    expect(closingCrosses(SQUARE)).toBe(false)
    expect(ringCrossing(SQUARE)).toBe(null)
    expect(edgesCross([0, 0], [1, 1], [1, 1], [2, 0])).toBe(false)

    // The bow tie: legal as far as it is drawn edge by edge, until it is closed
    expect(ringCrossing(BOW_TIE)).toEqual([0, 2])
    expect(pathCrossing(BOW_TIE)).toEqual([0, 2])
    expect(closingCrosses([[0, 0], [0, 1], [1, 0], [1, 1]])).toBe(true)
    expect(edgesCross([0, 0], [1, 1], [0, 1], [1, 0])).toBe(true)
  })
})
