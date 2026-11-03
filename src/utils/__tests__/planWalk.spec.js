import { describe, expect, it } from 'vitest'
import { stopsOf } from '../planWalk'

const row = (t, lat, extra = {}) => ({
  group_id: 'A',
  frame_id: 'f' + t,
  t_s: t,
  planned_at: new Date(1800000000000 + t * 1000).toISOString(),
  state: 'pending',
  lat,
  lng: lat == null ? null : 103.8,
  place: null,
  ...extra,
})

describe('stopsOf', () => {
  it('folds the points a group only walks through into the stop it walks on from', () => {
    const rows = [
      row(0, 1.29, { place: 'Gate' }),
      row(120, 1.291), // walked through
      row(240, 1.292), // walked through
      row(360, 1.293, { place: 'Hall' }),
      row(480, 1.294),
    ]
    const stops = stopsOf(rows)
    expect(stops.map((s) => s.name || s.number)).toEqual(['Gate', 'Hall', 3])
    expect(stops[0].rows.map((r) => r.t_s)).toEqual([0, 120, 240])
    expect(stops[0].via.map((r) => r.t_s)).toEqual([120, 240])
    expect(stops[0].endsAt).toBe(rows[3].planned_at)
  })

  it('keeps an unnamed point where the group stays', () => {
    const rows = [row(0, 1.29), row(120, 1.291), row(240, null), row(360, 1.292)]
    expect(stopsOf(rows).map((s) => s.number)).toEqual([1, 2, 3])
  })

  it('keeps the point a group leaves the site from', () => {
    const rows = [row(0, 1.29), row(120, 1.291), row(240, null, { state: 'not_required' }), row(360, 1.292)]
    expect(stopsOf(rows).map((s) => s.kind + (s.number || ''))).toEqual(['place1', 'place2', 'off', 'place3'])
  })
})
