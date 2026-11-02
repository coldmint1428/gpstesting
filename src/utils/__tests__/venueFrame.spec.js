import { describe, it, expect } from 'vitest'
import { venueBox } from '../venueFrame'

const zones = { south: 1.29, west: 103.85, north: 1.292, east: 103.852 }

describe('venueBox', () => {
  it('frames the zones when there are no points', () => {
    expect(venueBox(zones, [])).toEqual(zones)
  })

  it('widens for a point just outside the zones', () => {
    const box = venueBox(zones, [[1.2925, 103.851]]) // about 55 m north
    expect(box.north).toBeCloseTo(1.2925)
  })

  it('ignores a point far from the zones', () => {
    expect(venueBox(zones, [[1.35, 103.95]])).toEqual(zones) // a phone at home, kilometres away
  })

  it('fits every point when no zones are drawn', () => {
    expect(venueBox(null, [[1.3, 103.8], [1.31, 103.82]])).toEqual({ south: 1.3, west: 103.8, north: 1.31, east: 103.82 })
  })

  it('has nothing to frame with no zones and no points', () => {
    expect(venueBox(null, [])).toBeNull()
  })
})
