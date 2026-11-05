// Unit test: reading the attendance QR (composables/useAttendance.js). The IC's screen shows
// "PLANOVA-ATT|<roll call id>|<token>"; anything else the camera sees is not a check-in, and is refused as it is.
import { describe, it, expect, vi } from 'vitest'
import { parseAttendanceQr } from '../useAttendance'

vi.mock('../../lib/supabase', () => ({ supabase: null }))

describe('parseAttendanceQr', () => {
  it('accepts exactly what the IC screen shows, and refuses anything else without guessing', () => {
    expect(parseAttendanceQr('PLANOVA-ATT|9f2c-rollcall|a1b2c3')).toEqual({ rollcallId: '9f2c-rollcall', token: 'a1b2c3' })
    expect(parseAttendanceQr('PLANOVA-ATT|0|0')).toEqual({ rollcallId: '0', token: '0' })
    expect(parseAttendanceQr('https://example.com/menu')).toBe(null)
    expect(parseAttendanceQr('PLANOVA-ATT|only-two-parts')).toBe(null)
    expect(parseAttendanceQr('PLANOVA-ATT|a|b|c')).toBe(null) // one bar too many is not trimmed to fit
    expect(parseAttendanceQr('planova-att|a|b')).toBe(null) // nor is the prefix read in another case
    expect(parseAttendanceQr('')).toBe(null)
    expect(parseAttendanceQr(null)).toBe(null)
  })
})
