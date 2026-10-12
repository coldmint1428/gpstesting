// Date / time text for sessions and playback. Everything is shown in Singapore time,
// whatever time zone the viewer's computer is set to.
const TZ = 'Asia/Singapore'

// "6:42 pm"
export function formatTime(date) {
  return new Date(date).toLocaleTimeString('en-SG', { timeZone: TZ, hour: 'numeric', minute: '2-digit' })
}

// "6:42:15 pm"
export function formatTimeSeconds(date) {
  return new Date(date).toLocaleTimeString('en-SG', {
    timeZone: TZ,
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
  })
}

// "Sat 9 Aug"
export function formatDay(date) {
  return new Date(date).toLocaleDateString('en-SG', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'short' })
}

// "Sat 9 Aug, 6:42 pm"
export function formatDayTime(date) {
  return formatDay(date) + ', ' + formatTime(date)
}

// "4 h 30 min", "9 min", "45 s"
export function formatDuration(ms) {
  const seconds = Math.round(ms / 1000)
  if (seconds < 60) return seconds + ' s'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + ' min'
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return hours + ' h' + (rest ? ' ' + rest + ' min' : '')
}

// The same moment as Singapore wall-clock parts (for file names and CSV text)
export function sgtParts(date) {
  const shifted = new Date(new Date(date).getTime() + 8 * 3600 * 1000) // SGT = UTC+8, no daylight saving
  const iso = shifted.toISOString() // "2026-08-09T09:00:05.000Z" but already shifted to SGT
  return { date: iso.slice(0, 10), time: iso.slice(11, 19) }
}

// "2026-08-09T17:00:05+08:00" - stays text when the CSV is opened in Excel
export function sgtIso(date) {
  const p = sgtParts(date)
  return p.date + 'T' + p.time + '+08:00'
}

// Value for <input type="datetime-local"> (uses the viewer's own clock)
export function toDateTimeLocal(date) {
  const d = new Date(date)
  const pad = (n) => String(n).padStart(2, '0')
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes())
}
