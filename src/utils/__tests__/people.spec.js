// Unit test: the small helpers for showing people (utils/people.js).
import { describe, it, expect } from 'vitest'
import { initials, escapeHtml, timeAgo } from '../people'

describe('people', () => {
  it('draws initials, escapes a name before it becomes markup, and says how long ago a reading was', () => {
    expect(initials('Komin Chow')).toBe('KC')
    expect(initials('  hazel  tan ')).toBe('HT') // spaces are not a third word
    expect(initials('Bob')).toBe('BO')
    expect(initials('')).toBe('?') // the fallback is a placeholder, not an exception
    expect(initials(null)).toBe('?')

    expect(escapeHtml('<img src=x onerror="alert(1)">')).toBe('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;')
    expect(escapeHtml("Ern Qi's & Co")).toBe('Ern Qi&#39;s &amp; Co')

    const now = new Date('2026-11-05T12:00:00Z').getTime()
    expect(timeAgo(now - 20_000, now)).toBe('just now')
    expect(timeAgo(now - 3 * 60_000, now)).toBe('3 min ago')
    expect(timeAgo(now - 2 * 3600_000, now)).toBe('2 h ago')
    expect(timeAgo(now + 5000, now)).toBe('just now') // a clock a little ahead is not "-1 min ago"
  })
})
