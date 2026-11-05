// Unit: what the camera's QR code is allowed to mean.
//
// In QR mode the IC's screen shows a code that changes every 5 seconds ("PLANOVA-ATT|<roll call id>|<token>"), and a
// member's phone reads it with the camera. The phone sends whatever text it read, and this is the one place that
// decides whether that text is a check-in at all: a poster on the wall, a QR from another app, or a code from a
// previous roll call must be refused before anything is asked of the database (037_attendance.sql checks the token).
import { describe, it, expect } from 'vitest'
import { parseAttendanceQr } from '../useAttendance'

describe('reading a roll call QR code', () => {
  it('accepts exactly what the IC screen shows, and refuses anything else without guessing', () => {
    // What a correct read looks like.
    expect(parseAttendanceQr('PLANOVA-ATT|9f2c-rollcall|a1b2c3')).toEqual({ rollcallId: '9f2c-rollcall', token: 'a1b2c3' })

    // The token is the part that expires; the id is only a hint, so both are handed on and the database decides.
    expect(parseAttendanceQr('PLANOVA-ATT|0|0')).toEqual({ rollcallId: '0', token: '0' })

    // A QR from anything else at the venue (a poster, a menu, another app's code) is simply not a check-in.
    expect(parseAttendanceQr('https://example.com/menu')).toBe(null)
    expect(parseAttendanceQr('PLANOVA-ATT|only-two-parts')).toBe(null)
    expect(parseAttendanceQr('PLANOVA-ATT|a|b|extra')).toBe(null) // three separators is not three parts
    expect(parseAttendanceQr('PLANOVA-ATT|a|b ').token).toBe('b ') // never trimmed: the token is compared exactly

    // The prefix is matched as drawn, not case-insensitively: a lower-cased code is a different string, not a
    // near-miss to helpfully repair.
    expect(parseAttendanceQr('planova-att|a|b')).toBe(null)
    expect(parseAttendanceQr('PLANOVA-ATT' + '|a|b').rollcallId).toBe('a')

    // No camera reading at all (permission refused, cancelled) must not throw on the way to the page.
    expect(parseAttendanceQr('')).toBe(null)
    expect(parseAttendanceQr(null)).toBe(null)
    expect(parseAttendanceQr(undefined)).toBe(null)
  })
})
