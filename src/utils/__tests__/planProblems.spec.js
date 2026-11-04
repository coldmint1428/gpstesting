import { describe, expect, it } from 'vitest'
import { calmCase, editAllowed, problemWords, problemsOf, suggestedSpot, walkFixPlan, walkFixWords } from '../planProblems'
import { metresBetween, resolveTracks } from '../planFrames'

const gap = { groupId: 'a', from: { frameId: 'f1', t_s: 0 }, to: { frameId: 'f2', t_s: 60 }, metres: 120.4, steps: 1, budget: 25 }
const row = (over) => ({ severity: 'error', group_id: 'b', from_frame: 'f3', from_s: 100, to_frame: 'f4', to_s: 101, metres: 15, message: '', ...over })
const pace = row({ severity: 'warning', message: '15 m in +0:01 (from +1:25:25 to +1:25:26) -- 14.7 m/s is faster than running' })
const zone = row({ from_s: 30, message: '20 m in +1:00 (from +0:30 to +1:30) -- the straight line crosses the no-go area "Store"' })

describe('plan problems', () => {
  it('lists the errors, in time order', () => {
    const list = problemsOf([gap], [zone])
    expect(list.map((p) => [p.kind, p.level])).toEqual([['far', 'error'], ['zone', 'error']])
    expect(list[1].zone).toBe('the no-go area "Store"')
  })

  it('has no speed rule: a group may ride as well as walk', () => {
    expect(problemsOf([], [pace])).toEqual([])
    expect(problemsOf([], [{ ...pace, severity: 'error' }])).toEqual([])
    expect(problemsOf([gap], [pace, zone]).map((p) => p.kind)).toEqual(['far', 'zone'])
  })

  it('says one problem once', () => {
    const same = row({ group_id: 'a', from_frame: 'f1', to_frame: 'f2', message: '120 m -- the limit is 25 m' })
    expect(problemsOf([gap], [same])).toHaveLength(1)
  })

  it('brings a dismissed problem back when the walk changes', () => {
    const before = problemsOf([], [zone])[0].id
    expect(problemsOf([], [{ ...zone, metres: 40 }])[0].id).not.toBe(before)
  })

  it('says what happened and how to fix it', () => {
    expect(problemWords(problemsOf([], [zone])[0], 'Monkey Party').title).toBe('Monkey Party crosses the no-go area "Store"')
    const far = problemWords(problemsOf([gap], [])[0], 'Monkey Party')
    expect(far.title).toBe('Monkey Party jumps too far')
    expect(far.detail).toBe('120 m in one step. The limit is 25 m.')
  })

  describe('the suggested spot', () => {
    const metres = (a, b) => Math.hypot((b.lat - a.lat) * 111320, (b.lng - a.lng) * 111320 * Math.cos((a.lat * Math.PI) / 180))
    const from = { lat: 1.29, lng: 103.85 }
    const to = { lat: 1.29, lng: 103.85 + 89 / (111320 * Math.cos((1.29 * Math.PI) / 180)) } // 89 m due east

    it('stays on the line, just inside the limit', () => {
      const spot = suggestedSpot({ kind: 'far', budget: 25, fromS: 0, toS: 2 }, from, to)
      expect(metres(from, spot)).toBeCloseTo(21.25, 1)
      expect(metres(spot, to)).toBeCloseTo(67.75, 1)
    })

    it('leaves room for a drop that lands off centre', () => {
      const spot = suggestedSpot({ kind: 'far', budget: 25, fromS: 0, toS: 2 }, from, to)
      expect(25 - metres(from, spot)).toBeGreaterThan(3)
    })

    it('suggests nothing when the walk is already inside it', () => {
      expect(suggestedSpot({ kind: 'far', budget: 500, fromS: 0, toS: 2 }, from, to)).toBeNull()
      expect(suggestedSpot({ kind: 'far', budget: 25, fromS: 0, toS: 2 }, from, null)).toBeNull()
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

  describe('fixing a whole walk', () => {
    const north = (m) => 1.29 + m / 111320
    // Frames 2 s apart, 2 m a hop, with one jump of `jump` metres between frames `at` and `at + 1`
    const walk = (jump, at = 2, count = 10) => {
      let m = 0
      return Array.from({ length: count }, (_, i) => {
        if (i) m += i === at + 1 ? jump : 2
        return { id: 'f' + i, t_s: 100 + i * 60, positions: { a: { lat: north(m), lng: 103.85 } } }
      })
    }
    const planOf = (frames, clickedAt = 0, rows = []) => {
      const points = resolveTracks(frames).get('a')
      const gaps = []
      const stated = points.filter((p) => p.defined)
      for (let i = 1; i < stated.length; i += 1) {
        const metres = metresBetween(stated[i - 1], stated[i])
        const steps = stated[i].index - stated[i - 1].index
        if (metres > 25 * steps) gaps.push({ groupId: 'a', from: stated[i - 1], to: stated[i], metres, steps, budget: 25 * steps })
      }
      const problems = problemsOf(gaps, rows)
      return { plan: walkFixPlan(problems[clickedAt], problems, points), points, problems }
    }
    it('fills a jump with no room using only the seconds that make room, not the time to walk it', () => {
      const quick = walk(97).map((f, i) => ({ ...f, t_s: 100 + i * 2 }))
      const { plan } = planOf(quick)
      expect(plan.blocked).toBe('')
      expect(plan.times).toEqual([{ frameId: 'f3', from_s: 106, seconds: 3 }]) // 5 steps need 5 s, and it has 2
      expect(plan.fills[0].spots).toHaveLength(4)
      expect(plan.newFrames).toBe(4)
    })

    it('uses the room a jump already has, and adds no time', () => {
      const { plan } = planOf(walk(97))
      expect(plan.times).toEqual([])
      expect(plan.totalSeconds).toBe(0)
      expect(plan.fills[0].spots).toHaveLength(4)
    })

    it('adds only as many frames as the limit needs', () => {
      const { plan } = planOf(walk(2500, 2, 10))
      expect(plan.newFrames).toBe(Math.ceil(2500 / 24) - 1)
    })

    it('places the new frames evenly on the line, each step inside the limit', () => {
      const frames = walk(97)
      const { plan, points } = planOf(frames)
      const a = points[2]
      const b = points[3]
      const line = [a, ...plan.fills[0].spots, b]
      for (let i = 1; i < line.length; i += 1) expect(metresBetween(line[i - 1], line[i])).toBeLessThanOrEqual(25)
      expect(plan.fills[0].spots.every((spot) => spot.lng === 103.85)).toBe(true)
    })

    it('takes in only its own walk: a too-fast row is no problem at all', () => {
      const row = (a, b) => ({ severity: 'warning', group_id: 'a', from_frame: a, from_s: 0, to_frame: b, to_s: 1, metres: 2, message: 'faster than running' })
      const quick = walk(97).map((f, i) => ({ ...f, t_s: 100 + i * 2 }))
      const mixed = planOf(quick, 0, [row('f1', 'f2')])
      expect(mixed.problems.map((p) => p.kind)).toEqual(['far'])
      expect(mixed.plan.kind).toBe('far')
      expect(mixed.plan.run).toHaveLength(1)
    })

    it('works right up to the end of the plan', () => {
      const { plan } = planOf(walk(97, 8))
      expect(plan.blocked).toBe('')
      expect(plan.newFrames).toBe(4)
    })

    it('does not count a frame that is already there as new', () => {
      const frames = walk(97)
      frames.splice(3, 0, { id: 'carried', t_s: frames[2].t_s + 12, positions: {} }) // on one of the four times it wants
      const { plan } = planOf(frames)
      expect(plan.fills[0].spots).toHaveLength(4)
      expect(plan.newFrames).toBe(3)
    })

    it('refuses, and says why, when the group goes off site during the walk', () => {
      const frames = walk(97)
      frames.splice(3, 0, { id: 'away', t_s: frames[2].t_s + 5, positions: { a: { lat: north(0), lng: 103.85, state: 'off_site' } } })
      const points = resolveTracks(frames).get('a')
      const onSite = points.filter((p) => p.defined && p.state !== 'off_site')
      const gaps = [{ groupId: 'a', from: onSite[2], to: onSite[3], metres: 97, steps: 2, budget: 50 }]
      const problems = problemsOf(gaps, [])
      expect(walkFixPlan(problems[0], problems, points).blocked).toContain('off site')
    })

    it('says exactly what will change', () => {
      const { plan } = planOf(walk(97))
      const words = walkFixWords(plan, 'hii', (id) => Number(id.slice(1)) + 1)
      expect(words.wrong[0]).toBe('Frames 3 → 4: 97 m in one step. The limit is 25 m.')
      expect(words.changes[0]).toBe('Adds 4 new frames between frames 3 and 4 for hii, so each step is about 19 m. Later frames are renumbered.')
      expect(words.changes[1]).toBe('No time is added.')
      expect(words.changes[2]).toBe('hii keeps the same route: no existing frame moves.')
      expect(words.note).toBe('')
    })

    it('says nothing about speed when a filled walk is still quick: a group may ride', () => {
      const quick = walk(97).map((f, i) => ({ ...f, t_s: 100 + i * 2 }))
      const words = walkFixWords(planOf(quick).plan, 'hii', (id) => Number(id.slice(1)) + 1)
      expect(words.changes[1]).toContain('to make room')
      expect(words.note).not.toMatch(/speed|fast/i)
    })
  })

  it('locks everything but what the errors name', () => {
    const errors = problemsOf([gap], [])
    expect(editAllowed([], 500, ['z'])).toBe(true)
    expect(editAllowed(errors, 30)).toBe(true)
    expect(editAllowed(errors, 30, ['a'])).toBe(true)
    expect(editAllowed(errors, 30, ['a', 'z'])).toBe(false)
    expect(editAllowed(errors, 61)).toBe(false)
  })
})
