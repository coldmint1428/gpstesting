// Unit: the small helpers the People and Groups pages draw every row with.
//
// Nothing here is complicated, and that is the point of testing it: initials() is called for every person on the
// page, and escapeHtml() is the only thing standing between a display name somebody chose and the HTML that Leaflet
// puts into a map tooltip. A name is user input; a tooltip is markup.
import { describe, it, expect } from 'vitest'
import { initials, escapeHtml, timeAgo, freshness, groupRoleLabel, STALE_AFTER_MS, OFFLINE_AFTER_MS } from '../people'

describe('the helpers behind a person row', () => {
  it('draws initials, escapes a name before it becomes markup, and says how long ago a reading was', () => {
    // ---------- Initials (the circle beside every name) ----------
    expect(initials('Komin Chow')).toBe('KC')
    expect(initials('  hazel  tan ')).toBe('HT') // spaces are not a third word
    expect(initials('Bob')).toBe('BO')
    expect(initials('')).toBe('?') // the fallback is a placeholder, not an exception
    expect(initials(null)).toBe('?')

    // ---------- A name is data, not markup ----------
    // A display name can be anything ("<script>alert(1)</script>" is a legal name). Leaflet builds tooltips and
    // marker icons from HTML strings, so every character that could close a tag or start an attribute goes.
    expect(escapeHtml('<img src=x onerror="alert(1)">')).toBe('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;')
    expect(escapeHtml("O'Brien & Sons")).toBe('O&#39;Brien &amp; Sons')
    expect(escapeHtml('plain')).toBe('plain')
    expect(escapeHtml(42)).toBe('42') // nor does a non-string throw

    // ---------- How long ago ----------
    const now = Date.parse('2026-11-05T20:00:00Z')
    expect(timeAgo(new Date(now - 5_000), now)).toBe('just now')
    expect(timeAgo(new Date(now - 90_000), now)).toBe('2 min ago')
    expect(timeAgo(new Date(now - 2 * 3600_000), now)).toBe('2 h ago')
    expect(timeAgo(new Date(now + 60_000), now)).toBe('just now') // a phone clock ahead is not "in -1 min"

    // ---------- Live / stale / offline, the same thresholds the map fades a marker at ----------
    expect(freshness(now - 10_000, now)).toBe('live')
    expect(freshness(now - STALE_AFTER_MS - 1_000, now)).toBe('stale')
    expect(freshness(now - OFFLINE_AFTER_MS - 1_000, now)).toBe('offline')
    expect(freshness(now - OFFLINE_AFTER_MS - 1_000, now, 'stop')).toBe('stopped') // on purpose, not lost

    // ---------- The badge that says what a person is IN THEIR GROUP ----------
    // Roles are group-scoped, so the badge has to name the group or "Admin" means nothing on the People page.
    expect(groupRoleLabel('Gate Crew', true, true)).toBe('Gate Crew: Admin, IC')
    expect(groupRoleLabel('Gate Crew', false, true)).toBe('Gate Crew: IC')
    expect(groupRoleLabel('Gate Crew', false, false)).toBe('Gate Crew')
    expect(groupRoleLabel('', true, true)).toBe('') // nobody without a group has a group role
  })
})
