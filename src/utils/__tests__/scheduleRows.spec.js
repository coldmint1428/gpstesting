import { describe, expect, it } from 'vitest'
import { scheduleOf } from '../scheduleRows'

// A separate little area for each moment: consecutive stops outside any area share one "On the move" row
const zones = [0, 120, 300, 480].map((t) => {
  const lat = 1.29 + t / 100000
  const a = lat - 0.0001
  const b = lat + 0.0001
  return { id: 'z' + t, name: 'Z' + t, kind: 'zone', geojson: { type: 'Polygon', coordinates: [[[103.79, a], [103.81, a], [103.81, b], [103.79, b], [103.79, a]]] } }
})
const row = (group, frame, t) => ({
  group_id: group,
  group_name: group,
  frame_id: frame,
  t_s: t,
  planned_at: new Date(1800000000000 + t * 1000).toISOString(),
  state: 'pending',
  lat: 1.29 + t / 100000,
  lng: 103.8,
})

describe('scheduleOf', () => {
  it('lists every group in the order of the plan, and numbers the pins the same way', () => {
    const rows = [row('A', 'f1', 0), row('A', 'f3', 300), row('B', 'f2', 120), row('B', 'f4', 480)]
    const schedule = scheduleOf(rows, zones)
    expect(schedule.map((r) => r.startS)).toEqual([0, 120, 300, 480])
    expect(schedule.map((r) => r.number)).toEqual([1, 2, 3, 4])
  })

  it('goes by the clock even when the rows arrive out of order', () => {
    const schedule = scheduleOf([row('A', 'f2', 300), row('A', 'f1', 0)], zones)
    expect(schedule.map((r) => r.startS)).toEqual([0, 300])
    expect(schedule.map((r) => r.number)).toEqual([1, 2])
  })
})
