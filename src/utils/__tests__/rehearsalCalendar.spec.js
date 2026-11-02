import { describe, expect, it } from 'vitest'
import { dayKey, monthGrid, monthOf, monthTitle, shiftMonth } from '../rehearsalCalendar'

describe('rehearsal calendar', () => {
  it('puts a moment on the day it is in Singapore', () => {
    expect(dayKey('2026-11-01T17:00:00Z')).toBe('2026-11-02')
    expect(dayKey('2026-11-01T15:59:00Z')).toBe('2026-11-01')
    expect(monthOf('2026-11-30T16:00:00Z')).toEqual({ year: 2026, month: 12 })
  })

  it('moves between months across a year', () => {
    expect(shiftMonth({ year: 2026, month: 12 }, 1)).toEqual({ year: 2027, month: 1 })
    expect(shiftMonth({ year: 2026, month: 1 }, -1)).toEqual({ year: 2025, month: 12 })
  })

  it('names a month', () => {
    expect(monthTitle({ year: 2026, month: 11 })).toBe('November 2026')
  })

  it('lays a month out in whole weeks from Monday', () => {
    const weeks = monthGrid({ year: 2026, month: 11 }) // 1 Nov 2026 is a Sunday
    expect(weeks).toHaveLength(6)
    expect(weeks.every((week) => week.length === 7)).toBe(true)
    expect(weeks[0][0]).toEqual({ key: '2026-10-26', day: 26, inMonth: false })
    expect(weeks[0][6]).toEqual({ key: '2026-11-01', day: 1, inMonth: true })
    expect(weeks[5][0]).toEqual({ key: '2026-11-30', day: 30, inMonth: true })
    expect(weeks[5][6]).toEqual({ key: '2026-12-06', day: 6, inMonth: false })
  })

  it('does not add an empty week when a month ends on a Sunday', () => {
    const weeks = monthGrid({ year: 2026, month: 5 }) // 31 May 2026 is a Sunday
    expect(weeks[weeks.length - 1][6]).toEqual({ key: '2026-05-31', day: 31, inMonth: true })
  })
})
