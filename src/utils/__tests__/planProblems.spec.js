import { describe, expect, it } from 'vitest'
import { calmCase, editAllowed, problemWords, problemsOf, suggestedSpot } from '../planProblems'

const row = (over) => ({ severity: 'error', group_id: 'b', from_frame: 'f3', from_s: 100, to_frame: 'f4', to_s: 101, metres: 15, message: '', ...over })
const pace = row({ severity: 'warning', message: '15 m in +0:01 (from +1:25:25 to +1:25:26) -- 14.7 m/s is faster than running' })
// What a plan_check older than 091 says about a long hop. There is no distance rule any more.
const far = row({ group_id: 'a', from_frame: 'f1', from_s: 0, to_frame: 'f2', to_s: 60, metres: 120, message: '120 m in +1:00 (from +0:00 to +1:00) -- the limit is 25 m' })
const farSteps = row({ group_id: 'a', message: '120 m in +1:00 (from +0:00 to +1:00) -- 3 steps, so the limit is 75 m' })
const zone = row({ from_s: 30, message: '20 m in +1:00 (from +0:30 to +1:30) -- the straight line crosses the no-go area "Store"' })

describe('plan problems', () => {
  it('lists the no-go crossings, in time order', () => {
    const list = problemsOf([zone, row({ from_s: 5, message: '9 m -- the straight line crosses the obstacle "Stage"' })])
    expect(list.map((p) => [p.kind, p.level, p.fromS])).toEqual([['zone', 'error', 5], ['zone', 'error', 30]])
    expect(list[1].zone).toBe('the no-go area "Store"')
  })

  it('has no speed rule: a group may ride as well as walk', () => {
    expect(problemsOf([pace])).toEqual([])
    expect(problemsOf([{ ...pace, severity: 'error' }])).toEqual([])
  })

  it('has no distance rule: a long hop is not a problem', () => {
    expect(problemsOf([far])).toEqual([])
    expect(problemsOf([farSteps])).toEqual([])
    expect(problemsOf([far, pace, zone]).map((p) => p.kind)).toEqual(['zone'])
  })

  it('brings a dismissed problem back when the walk changes', () => {
    const before = problemsOf([zone])[0].id
    expect(problemsOf([{ ...zone, metres: 40 }])[0].id).not.toBe(before)
  })

  it('says what happened and how to fix it', () => {
    expect(problemWords(problemsOf([zone])[0], 'Monkey Party').title).toBe('Monkey Party crosses the no-go area "Store"')
  })

  describe('the suggested spot', () => {
    const from = { lat: 1.29, lng: 103.85 }
    const to = { lat: 1.29, lng: 103.85 + 89 / (111320 * Math.cos((1.29 * Math.PI) / 180)) } // 89 m due east

    it('suggests nothing for anything but a crossing, or a walk with an end missing', () => {
      expect(suggestedSpot({ kind: 'other', fromS: 0, toS: 2 }, from, to)).toBeNull()
      expect(suggestedSpot({ kind: 'zone', fromS: 0, toS: 2 }, from, null)).toBeNull()
    })
    // A square across the middle of the walk, 40 m wide and running 30 m either side of the line
    const box = (kind) => {
      const lng = (m) => to.lng * (m / 89) + from.lng * (1 - m / 89)
      const lat = (m) => from.lat + m / 111320
      return { kind, geojson: { type: 'Polygon', coordinates: [[[lng(25), lat(-30)], [lng(65), lat(-30)], [lng(65), lat(30)], [lng(25), lat(30)], [lng(25), lat(-30)]]] } }
    }

    it('goes around a no-go area, with both legs clear of it', () => {
      const zone = box('no_go')
      const spot = suggestedSpot({ kind: 'zone', fromS: 0, toS: 60 }, from, to, [zone])
      expect(spot).not.toBeNull()
      expect(Math.abs(spot.lat - from.lat) * 111320).toBeGreaterThan(30)
      expect(suggestedSpot({ kind: 'zone', fromS: 0, toS: 60 }, from, to, [box('stage')])).not.toBeNull()
    })

    it('says nothing when there is no way round', () => {
      const lat = (m) => from.lat + m / 111320
      const wall = { kind: 'no_go', geojson: { type: 'Polygon', coordinates: [[[from.lng - 1, lat(-900)], [from.lng + 1, lat(-900)], [from.lng + 1, lat(900)], [from.lng - 1, lat(900)], [from.lng - 1, lat(-900)]]] } }
      expect(suggestedSpot({ kind: 'zone', fromS: 0, toS: 60 }, from, to, [wall])).toBeNull()
    })
  })

  it('calms a place name without touching its codes', () => {
    expect(calmCase('CQ @ CLARKE QUAY, 3C RIVER VALLEY ROAD')).toBe('CQ @ Clarke Quay, 3C River Valley Road')
    expect(calmCase('EVERTON PARK, 5 EVERTON PARK')).toBe('Everton Park, 5 Everton Park')
    expect(calmCase('120 CANTONMENT RD')).toBe('120 Cantonment Rd')
    expect(calmCase('Main Gate')).toBe('Main Gate')
  })

  it('locks everything but what the errors name', () => {
    const errors = problemsOf([row({ group_id: 'a', from_s: 0, to_s: 60, message: '20 m -- the straight line crosses the no-go area "Store"' })])
    expect(editAllowed([], 500, ['z'])).toBe(true)
    expect(editAllowed(errors, 30)).toBe(true)
    expect(editAllowed(errors, 30, ['a'])).toBe(true)
    expect(editAllowed(errors, 30, ['a', 'z'])).toBe(false)
    expect(editAllowed(errors, 61)).toBe(false)
  })
})
