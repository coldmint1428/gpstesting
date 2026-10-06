// Small helpers for showing people.

// "Komin Chow" -> "KC", "Bob" -> "BO"
export function initials(name) {
  const words = (name || '?').trim().split(/\s+/)
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase()
  return words[0].slice(0, 2).toUpperCase()
}

// Names are typed by users, so escape them before putting them inside HTML
// (Leaflet tooltips/icons use HTML strings) - prevents script injection (XSS).
export function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

// "just now", "3 min ago", "2 h ago"
export function timeAgo(date, now) {
  const seconds = Math.max(0, Math.round((now - date) / 1000))
  if (seconds < 60) return 'just now'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + ' min ago'
  return Math.round(minutes / 60) + ' h ago'
}

// Live / stale / offline (lost contact), based on how long since the last reading
export const STALE_AFTER_MS = 2 * 60 * 1000 // 2 min
export const OFFLINE_AFTER_MS = 10 * 60 * 1000 // 10 min

// source = 'stop' means the person pressed Stop sharing (on purpose)
export function freshness(date, now, source) {
  if (source === 'stop') return 'stopped'
  const age = now - date
  if (age < STALE_AFTER_MS) return 'live'
  if (age < OFFLINE_AFTER_MS) return 'stale'
  return 'offline'
}
