// Unit tests: a running timetable judged on the phone gives the database's answer (2 Nov, load fixes).
// The database's rule (session_status, 050): a mark wins; then off site -> not_required; then past -> late; else pending.
import { describe, it, expect } from 'vitest'
import { baseOf, marksOf, judge, lostAMark, formatInterval } from '../timetableLocal'

const T0 = Date.parse('2026-11-02T12:00:00Z')
const iso = (ms) => new Date(ms).toISOString()
const row = (t_s, group, extra = {}) => ({
  group_id: group, group_name: group, frame_id: 'f' + t_s, t_s, planned_at: iso(T0 + t_s * 1000),
  state: 'pending', lateness: null, marked_at: null, marked_by: null, note: '', plan_name: 'P', plan_rev: 3,
  place: null, lat: 1.29, lng: 103.85, ...extra,
})
const seconds = (text) => {
  if (text == null) return null
  const m = String(text).match(/^(-?)(\d+):(\d+):(\d+(?:\.\d+)?)$/)
  return (m[1] ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3]) * 60 + Number(m[4]))
}

describe('formatInterval', () => {
  it('writes intervals the way PostgREST sends them', () => {
    expect(formatInterval(192)).toBe('00:03:12')
    expect(formatInterval(-45)).toBe('-00:00:45')
    expect(formatInterval(93605.25)).toBe('26:00:05.25')
    expect(formatInterval(0)).toBe('00:00:00')
  })
})

describe('judge', () => {
  // As the database answered at T0 + 90 s: 0 s late, 60 s marked arrived 20 s late, 120 s off site, 180 s pending
  const answered = [
    row(0, 'A', { state: 'late', lateness: '00:01:30' }),
    row(60, 'A', { state: 'arrived', lateness: '00:00:20', marked_at: iso(T0 + 80000), marked_by: 'u1' }),
    row(120, 'A', { state: 'not_required' }),
    row(180, 'A'),
  ]
  const { base, marks, rev, t0 } = baseOf(answered)

  it('gives back exactly what the database said, at the database\'s time', () => {
    expect(judge(base, marks, T0 + 90000)).toEqual(answered)
    expect(rev).toBe(3)
    expect(t0).toBe(T0)
  })

  it('turns pending into late as the clock passes, with the lateness growing', () => {
    const later = judge(base, marks, T0 + 200000)
    expect(later[3].state).toBe('late')
    expect(seconds(later[3].lateness)).toBe(20)
    expect(seconds(later[0].lateness)).toBe(200)
    expect(later[2].state).toBe('not_required') // off site stays off site
    expect(later[1].state).toBe('arrived') // a mark keeps its own lateness
    expect(seconds(later[1].lateness)).toBe(20)
  })

  it('applies a mark that arrived later, early arrivals included', () => {
    const fresh = marksOf([
      { group_id: 'A', frame_id: 'f60', state: 'arrived', marked_at: iso(T0 + 80000), marked_by: 'u1' },
      { group_id: 'A', frame_id: 'f180', state: 'arrived', marked_at: iso(T0 + 150000), marked_by: null },
    ])
    const out = judge(base, fresh, T0 + 200000)
    expect(out[3]).toMatchObject({ state: 'arrived', marked_at: iso(T0 + 150000), marked_by: null })
    expect(seconds(out[3].lateness)).toBe(-30) // 30 s early
  })

  it('notices a mark that was taken back (only a whole read can say what the row is now)', () => {
    expect(lostAMark(base, marks)).toBe(false)
    expect(lostAMark(base, new Map())).toBe(true)
  })

  it('keeps every other field of the row as the database sent it', () => {
    const out = judge(base, marks, T0 + 200000)
    for (let i = 0; i < out.length; i++) {
      const { state, lateness, marked_at, marked_by, ...rest } = out[i]
      const { state: s, lateness: l, marked_at: ma, marked_by: mb, ...was } = answered[i]
      expect(rest).toEqual(was)
    }
  })
})
