// Playback: turns saved readings into per-person tracks and answers "where was everyone at
// time t?". Used for both sources of a replay:
//   - the database (location_history, root / planners, kept 7 days after the day a session ends)
//   - a CSV file the planner downloaded earlier (read in the browser, never uploaded)
import { STALE_AFTER_MS, OFFLINE_AFTER_MS, freshness } from './people'
import { sgtIso } from './time'
import { saveFile } from '../lib/saveFile'
import { GROUP_PALETTE } from './groupColours'

// Two readings further apart than this are a GAP (tunnel, battery saver, phone off):
// the marker does not slide between them, and trails draw that part dashed
export const GAP_MS = STALE_AFTER_MS // 2 min (phones send every 30 s)
export const TRAIL_MS = 10 * 60 * 1000 // "Show trails" = everyone's last 10 min

const FALLBACK_COLOURS = GROUP_PALETTE

// ---------- Building a recording ----------

// rows   : [{ id?, t (ms), userId, groupId, lat, lng, accuracy, source }]
// people : { userId: { name, username } }
// groups : [{ id, name, colour }]
// Returns { from, to, tracks: [{ userId, name, username, groupId, points }], groups, maxId }
export function buildRecording({ rows, people, groups, from, to }) {
  const byUser = new Map()
  let maxId = 0
  for (const r of rows) {
    if (!byUser.has(r.userId)) byUser.set(r.userId, [])
    byUser.get(r.userId).push(r)
    if (r.id && r.id > maxId) maxId = r.id
  }
  const tracks = []
  for (const [userId, points] of byUser) {
    points.sort((a, b) => a.t - b.t)
    const person = people[userId] || {}
    tracks.push({
      userId,
      name: person.name || person.username || 'Unknown',
      username: person.username || '',
      groupId: points[points.length - 1].groupId,
      points,
    })
  }
  tracks.sort((a, b) => a.name.localeCompare(b.name))

  let first = Infinity
  let last = -Infinity
  for (const r of rows) {
    if (r.t < first) first = r.t
    if (r.t > last) last = r.t
  }
  return {
    from: from ?? (rows.length ? first : Date.now()),
    to: to ?? (rows.length ? last : Date.now()),
    tracks,
    groups,
    maxId,
  }
}

// Live rewind: add newly uploaded readings to an existing recording
// (people = { userId: { name, username } } for anyone who started sharing after the first load)
export function addRows(recording, rows, people = {}) {
  for (const r of rows) {
    let track = recording.tracks.find((x) => x.userId === r.userId)
    if (!track) {
      const person = people[r.userId] || {}
      track = { userId: r.userId, name: person.name || 'Unknown', username: person.username || '', groupId: r.groupId, points: [] }
      recording.tracks.push(track)
    }
    track.points.push(r)
    track.points.sort((a, b) => a.t - b.t)
    track.groupId = r.groupId
    if (r.id && r.id > recording.maxId) recording.maxId = r.id
  }
}

// Database rows ([id, user_id, group_id, lat, lng, accuracy, source, epoch_ms]) -> row objects
export function rowsFromDatabase(compactRows) {
  return compactRows.map((r) => ({
    id: r[0],
    userId: r[1],
    groupId: r[2],
    lat: r[3],
    lng: r[4],
    accuracy: r[5],
    source: r[6],
    t: r[7],
  }))
}

// ---------- Where was someone at time t? ----------

// Index of the last point at or before t (-1 if none yet)
function lastIndexAt(points, t) {
  let lo = 0
  let hi = points.length - 1
  let found = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (points[mid].t <= t) {
      found = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  return found
}

// Returns { lat, lng, accuracy, readingTime, state, index } or null (not sharing yet at t).
// Between two normal readings the marker slides smoothly; across a gap it stays at the
// last reading and turns stale / "lost contact" like on the live map.
export function positionAt(track, t) {
  const points = track.points
  const i = lastIndexAt(points, t)
  if (i === -1) return null
  const p = points[i]
  const next = points[i + 1]

  let lat = p.lat
  let lng = p.lng
  let state = freshness(p.t, t, p.source)
  if (p.source !== 'stop' && next && next.source !== 'stop' && next.t - p.t <= GAP_MS) {
    const k = (t - p.t) / (next.t - p.t)
    lat = p.lat + (next.lat - p.lat) * k
    lng = p.lng + (next.lng - p.lng) * k
    state = 'live' // still between two readings that arrived on time
  }
  return { lat, lng, accuracy: p.accuracy, readingTime: p.t, state, index: i }
}

// Trail between fromT and t, split into solid parts and dashed gap parts.
// current = positionAt(track, t), so the line ends exactly at the marker.
export function trailAt(track, fromT, t, current) {
  const points = track.points
  const solid = []
  const dashed = []
  let line = []
  let prev = null
  const end = current ? current.index : -1
  for (let i = 0; i <= end; i++) {
    const p = points[i]
    if (p.t < fromT) continue
    if (prev && (p.t - prev.t > GAP_MS || prev.source === 'stop')) {
      if (line.length > 1) solid.push(line)
      dashed.push([
        [prev.lat, prev.lng],
        [p.lat, p.lng],
      ])
      line = []
    }
    line.push([p.lat, p.lng])
    prev = p
  }
  if (current && current.state === 'live' && line.length) line.push([current.lat, current.lng])
  if (line.length > 1) solid.push(line)
  return { solid, dashed }
}

// Marks under the timeline: when people started sharing (first reading, or first after a
// stop / 10+ min gap) and when they pressed Stop
export function timelineMarks(recording, limit = 300) {
  const marks = []
  for (const track of recording.tracks) {
    let prev = null
    for (const p of track.points) {
      if (p.source === 'stop') {
        marks.push({ t: p.t, kind: 'stop', name: track.name })
      } else if (!prev || prev.source === 'stop' || p.t - prev.t > OFFLINE_AFTER_MS) {
        marks.push({ t: p.t, kind: 'start', name: track.name })
      }
      prev = p
    }
  }
  marks.sort((a, b) => a.t - b.t)
  return marks.slice(0, limit)
}

// ---------- CSV (download, and replay after the 7 days) ----------

export const CSV_TITLE = '# Event Tracker playback'
export const CSV_COLUMNS = ['time_sgt', 'name', 'username', 'group', 'group_colour', 'lat', 'lng', 'accuracy_m', 'source', 'user_id', 'group_id']

function csvCell(value) {
  const text = value === null || value === undefined ? '' : String(value)
  return /[",\r\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text
}

// One row per reading, oldest first. Times are text in Singapore time with +08:00, so Excel
// keeps them as text (it would round real Excel dates to the minute).
export function recordingToCsv(recording, eventName) {
  const groupById = new Map(recording.groups.map((g) => [g.id, g]))
  const lines = [
    [CSV_TITLE, 'v1', eventName || '', sgtIso(recording.from), sgtIso(recording.to)].map(csvCell).join(','),
    CSV_COLUMNS.join(','),
  ]
  const rows = []
  for (const track of recording.tracks) for (const p of track.points) rows.push({ track, p })
  rows.sort((a, b) => a.p.t - b.p.t)
  for (const { track, p } of rows) {
    const g = groupById.get(p.groupId) || {}
    lines.push(
      [
        sgtIso(p.t),
        track.name,
        track.username,
        g.name || '',
        g.colour || '',
        p.lat.toFixed(6),
        p.lng.toFixed(6),
        p.accuracy === null || p.accuracy === undefined ? '' : Math.round(p.accuracy * 10) / 10,
        p.source,
        track.userId,
        p.groupId,
      ]
        .map(csvCell)
        .join(','),
    )
  }
  return '﻿' + lines.join('\r\n') + '\r\n' // BOM so Excel reads names with accents correctly
}

// Splits CSV text into rows of cells (handles quotes, "" inside quotes, CRLF, ; or , separators)
function splitCsv(text) {
  text = text.replace(/^﻿/, '')
  const firstLine = text.slice(0, text.indexOf('\n') === -1 ? text.length : text.indexOf('\n'))
  const sep = (firstLine.match(/;/g) || []).length > (firstLine.match(/,/g) || []).length ? ';' : ','
  const rows = []
  let row = []
  let cell = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        cell += '"'
        i++
      } else if (c === '"') {
        quoted = false
      } else {
        cell += c
      }
    } else if (c === '"') {
      quoted = true
    } else if (c === sep) {
      row.push(cell)
      cell = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      row.push(cell)
      rows.push(row)
      row = []
      cell = ''
    } else {
      cell += c
    }
  }
  if (cell !== '' || row.length) {
    row.push(cell)
    rows.push(row)
  }
  return rows
}

// Reads a time written by us ("2026-08-09T17:00:05+08:00") or re-saved by Excel
// ("9/8/2026 17:00", "2026-08-09 17:00:05", "9/8/2026 5:00:05 PM"). No zone = Singapore time.
export function parseCsvTime(text) {
  const s = String(text || '').trim()
  if (!s) return null
  if (/^\d{4}-\d{2}-\d{2}T.*(Z|[+-]\d{2}:?\d{2})$/.test(s)) {
    const ms = Date.parse(s)
    return Number.isNaN(ms) ? null : ms
  }
  let y, mo, d, rest
  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](.*)$/)
  if (m) {
    ;[, y, mo, d, rest] = m
  } else {
    m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})\s+(.*)$/)
    if (!m) return null
    let [, a, b] = m
    y = m[3].length === 2 ? '20' + m[3] : m[3]
    rest = m[4]
    // Singapore Excel writes day/month; if the second number can't be a month, it was month/day
    if (Number(b) > 12) [a, b] = [b, a]
    d = a
    mo = b
  }
  const tm = rest.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*([AaPp][Mm])?$/)
  if (!tm) return null
  let hour = Number(tm[1])
  if (tm[4]) {
    const pm = tm[4].toLowerCase() === 'pm'
    if (hour === 12) hour = pm ? 12 : 0
    else if (pm) hour += 12
  }
  const ms = Date.UTC(Number(y), Number(mo) - 1, Number(d), hour - 8, Number(tm[2]), Number(tm[3] || 0)) // SGT -> UTC
  return Number.isNaN(ms) ? null : ms
}

// CSV text -> { recording, eventName, skipped } or throws Error with a plain-words message
export function csvToRecording(text) {
  const rows = splitCsv(text)
  let eventName = ''
  let from = null
  let to = null
  let headerIndex = -1
  for (let i = 0; i < Math.min(rows.length, 10); i++) {
    const first = (rows[i][0] || '').trim()
    if (first.startsWith(CSV_TITLE)) {
      eventName = rows[i][2] || ''
      from = parseCsvTime(rows[i][3])
      to = parseCsvTime(rows[i][4])
    } else if (rows[i].some((c) => c.trim().toLowerCase() === 'time_sgt')) {
      headerIndex = i
      break
    }
  }
  if (headerIndex === -1) throw new Error("This doesn't look like a playback file (no time_sgt column).")

  const header = rows[headerIndex].map((c) => c.trim().toLowerCase())
  const col = (name) => header.indexOf(name)
  for (const required of ['time_sgt', 'name', 'lat', 'lng']) {
    if (col(required) === -1) throw new Error("This doesn't look like a playback file (missing the " + required + ' column).')
  }

  const people = {}
  const groupsByKey = new Map()
  const out = []
  let skipped = 0
  for (let i = headerIndex + 1; i < rows.length; i++) {
    const r = rows[i]
    if (r.length === 1 && r[0].trim() === '') continue // blank line
    const get = (name) => (col(name) === -1 ? '' : (r[col(name)] || '').trim())
    const t = parseCsvTime(get('time_sgt'))
    const lat = Number(get('lat'))
    const lng = Number(get('lng'))
    const name = get('name')
    if (t === null || !name || !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      skipped++
      continue
    }
    const userId = get('user_id') || get('username') || name
    if (!people[userId]) people[userId] = { name, username: get('username') }

    const groupName = get('group') || 'No group'
    const groupKey = get('group_id') || groupName
    if (!groupsByKey.has(groupKey)) {
      const colour = /^#[0-9a-fA-F]{6}$/.test(get('group_colour'))
        ? get('group_colour')
        : FALLBACK_COLOURS[groupsByKey.size % FALLBACK_COLOURS.length]
      groupsByKey.set(groupKey, { id: groupKey, name: groupName, colour })
    }
    const accuracy = get('accuracy_m') === '' ? null : Number(get('accuracy_m'))
    out.push({
      t,
      userId,
      groupId: groupKey,
      lat,
      lng,
      accuracy: Number.isFinite(accuracy) ? accuracy : null,
      source: get('source') === 'stop' ? 'stop' : 'gps',
    })
  }
  if (out.length === 0) throw new Error('No readings could be read from this file.')

  const recording = buildRecording({ rows: out, people, groups: [...groupsByKey.values()] })
  // Use the session times from the file if they still make sense
  if (from !== null && from <= recording.from) recording.from = from
  if (to !== null && to >= recording.to) recording.to = to
  return { recording, eventName, skipped }
}

// "NDP-Rehearsal_2026-08-09_1700-2130.csv"
export function csvFileName(eventName, from, to) {
  const slug = (eventName || 'event').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'event'
  const a = sgtIso(from)
  const b = sgtIso(to)
  return slug + '_' + a.slice(0, 10) + '_' + a.slice(11, 16).replace(':', '') + '-' + b.slice(11, 16).replace(':', '') + '.csv'
}

// Save text as a file in the browser
// A browser download, or in the phone app Android's "Save to..." screen (a download link does nothing there)
export function downloadText(text, fileName, type = 'text/csv;charset=utf-8') {
  return saveFile(new TextEncoder().encode(text), fileName, type)
}
