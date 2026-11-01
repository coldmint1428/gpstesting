// Unit tests: the position map a frame write sends. Placing a group (1 Nov) is one frame_save, and frame_save replaces
// the frame's positions wholesale -- so the payload must restate everyone already there, or placing Bravo deletes Alpha.
import { describe, it, expect } from 'vitest'
import { restatedPositions, snap, formatOffset, parseOffset } from '../planFrames'

const frame = {
  id: 'f1',
  t_s: 0,
  positions: {
    alpha: { lat: 1.2931, lng: 103.8558, state: 'on_site', verify: 'manual' },
  },
}

describe('restatedPositions', () => {
  it('keeps every group the frame already states when one more is placed', () => {
    const out = restatedPositions(frame, { bravo: { lat: 1.2925, lng: 103.8537, state: 'on_site', verify: 'auto' } })
    expect(Object.keys(out).sort()).toEqual(['alpha', 'bravo'])
    expect(out.alpha).toEqual({ lat: 1.2931, lng: 103.8558, state: 'on_site', verify: 'manual' })
  })

  it('lets a change replace a group that is already there (a drag)', () => {
    const out = restatedPositions(frame, { alpha: { lat: 1.3, lng: 103.9, state: 'on_site', verify: 'manual' } })
    expect(out.alpha.lat).toBe(1.3)
    expect(Object.keys(out)).toEqual(['alpha'])
  })

  it('only ever writes the two states and the two confidences the database accepts', () => {
    const out = restatedPositions({ positions: { x: { lat: 1, lng: 2, state: 'weird', verify: 'maybe' } } })
    expect(out.x.state).toBe('on_site')
    expect(out.x.verify).toBe('auto')
  })

  it('returns an empty map for a frame with nothing on it', () => {
    expect(restatedPositions({ positions: {} })).toEqual({})
    expect(restatedPositions(null)).toEqual({})
  })
})

describe('the time grid', () => {
  it('snaps a dragged time to the 5-second grid', () => {
    expect(snap(62)).toBe(60)
    expect(snap(63)).toBe(65)
  })

  it('writes and reads back an offset from T+0', () => {
    expect(formatOffset(90)).toBe('+1:30')
    expect(parseOffset('+1:30')).toBe(90)
    expect(parseOffset('90s')).toBe(90)
  })
})
