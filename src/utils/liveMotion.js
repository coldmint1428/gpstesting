// Smooth live markers: draw everyone where they were a few seconds ago, sliding along the
// line between two REAL readings (the technique ride-hailing maps and online games use).
//
// Why a delay: phones send a reading every ~10 s, and after a tunnel, battery saver or a
// paused browser tab several readings arrive at once, sometimes out of order. Drawing "the
// newest reading" makes markers jump and then crawl; drawing a moment slightly in the past
// means there is almost always a reading before AND after it, so the marker follows the real
// path and late readings simply slot into place.
//
// Each person has a track (readings sorted by time, t in ms) and a playhead (the time the
// marker is drawn at). Every frame the playhead moves forward with the clock. When it runs
// out of readings it waits at the newest one; when readings arrive late (tunnel, battery saver)
// it fast-forwards along the real path until it is back on time, so the
// marker never jumps. Only when the map itself was not on screen (tab hidden) does it jump
// straight to the present instead of replaying what you did not watch.
// Readings are cleaned on the way in: GPS wobble while standing still is flattened, one bad
// fix and impossible jumps are skipped.

export const LAG_MS = 12000 // draw people 12 s in the past (phones send every ~10 s)
export const GAP_MS = 2 * 60 * 1000 // longer than this without readings = a real gap (dashed, no sliding)
export const KEEP_MS = 10 * 60 * 1000 // history kept per person (the selected person keeps the whole session)
export const SNAP_MS = 30 * 1000 // map was off screen and is this far behind: jump instead of replaying
const RESUME_MS = 15000 // after the map was off screen, readings fetched in this window may cause a jump
const CATCH_UP_MS = 5000 // how quickly a late playhead catches up (bigger = gentler)
const MAX_RATE = 20 // fast-forward limit: a 5 min dead zone replays in ~20 s

// Movements smaller than this (metres) are GPS noise: half the accuracy, 4–15 m
export function wobbleThreshold(accuracy) {
  return Math.min(Math.max((accuracy || 0) * 0.5, 4), 15)
}

// Distance in metres between two { lat, lng } (good enough for city distances)
export function metres(a, b) {
  const toRad = Math.PI / 180
  const dLat = (b.lat - a.lat) * toRad
  const dLng = (b.lng - a.lng) * toRad * Math.cos(((a.lat + b.lat) / 2) * toRad)
  return Math.sqrt(dLat * dLat + dLng * dLng) * 6371000
}

export function newTrack() {
  return { points: [], keepAll: false, at: null, delays: [], resumedAt: 0 }
}

// Two readings the marker may slide between (close in time, no Stop in between)
function joined(a, b) {
  return a.source !== 'stop' && b.source !== 'stop' && b.t - a.t <= GAP_MS
}

// Add one reading { t, lat, lng, accuracy, source }. Returns true if the track changed.
export function addReading(track, r) {
  const pts = track.points
  // Where it goes (usually at the end; late readings land in the middle)
  let i = pts.length
  while (i > 0 && pts[i - 1].t > r.t) i--
  const prev = pts[i - 1]
  if (prev && prev.t === r.t) return false // already have it

  if (prev && joined(prev, r)) {
    // One bad fix (reflections off buildings): much worse than the reading before it
    if (r.accuracy > 100 && prev.accuracy > 0 && prev.accuracy <= 50) return false
    // Impossible jump (faster than 70 m/s ≈ 250 km/h): skip it
    const seconds = (r.t - prev.t) / 1000
    if (seconds > 0 && seconds < 30 && metres(prev, r) / seconds > 70) return false
    // Standing still: keep the earlier position so the marker doesn't wobble
    if (metres(prev, r) <= wobbleThreshold(r.accuracy)) r = { ...r, lat: prev.lat, lng: prev.lng }
  }
  pts.splice(i, 0, { t: r.t, lat: r.lat, lng: r.lng, accuracy: r.accuracy, source: r.source })
  return true
}

// Drop old readings (always keeps the newest one so the person stays on the map)
export function prune(track, now) {
  if (track.keepAll) return
  const cut = Math.min(now, track.at ?? now) - KEEP_MS
  let n = 0
  while (n < track.points.length - 1 && track.points[n].t < cut) n++
  if (n) track.points.splice(0, n)
}

// How late this person's readings reach us (phone clock vs ours + upload time).
// The smallest of the last 20 live deliveries; readings caught up in a batch don't count.
export function noteDelay(track, delayMs) {
  if (delayMs > 30000) return // a queued reading uploaded after a dead zone, not the normal delay
  track.delays.push(delayMs)
  if (track.delays.length > 20) track.delays.shift()
}
function delayOf(track) {
  if (!track.delays.length) return 1500
  return Math.min(Math.max(Math.min(...track.delays), -60000), 60000)
}

// Move the playhead forward by `elapsed` ms of real time (time since the last frame; a
// big value means the map was off screen). Returns the playhead time.
export function advance(track, now, elapsed) {
  const pts = track.points
  if (!pts.length) return null
  const wanted = now - delayOf(track) - LAG_MS
  if (elapsed > 5000) track.resumedAt = now
  if (track.at === null || track.at > wanted + SNAP_MS) {
    track.at = wanted // first time, or our clock moved back
  } else if (track.at < wanted) {
    const behind = wanted - track.at
    if (behind > SNAP_MS && now - track.resumedAt < RESUME_MS) {
      track.at = wanted // back on the map after a while: show the present, don't replay
    } else {
      // A little late (readings arrived late): speed up gently until on time again
      const rate = Math.min(1 + behind / CATCH_UP_MS, MAX_RATE)
      track.at = Math.min(track.at + elapsed * rate, wanted)
    }
  }
  // Never past the newest reading: wait there for the next one
  const newest = pts[pts.length - 1].t
  if (track.at > newest) track.at = newest
  return track.at
}

// Index of the last reading at or before t (-1 if none)
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

// Where to draw the person at time t: { lat, lng, index } (index = last reading passed).
// Between two joined readings: slide between them. Across a real gap: show the newer reading
// straight away (there is nothing to slide along).
export function positionAt(track, t) {
  const pts = track.points
  if (!pts.length) return null
  const i = lastIndexAt(pts, t)
  if (i === -1) return { lat: pts[0].lat, lng: pts[0].lng, index: 0 }
  const p = pts[i]
  const next = pts[i + 1]
  if (!next) return { lat: p.lat, lng: p.lng, index: i }
  if (!joined(p, next)) return { lat: next.lat, lng: next.lng, index: i + 1 }
  const k = (t - p.t) / (next.t - p.t)
  return { lat: p.lat + (next.lat - p.lat) * k, lng: p.lng + (next.lng - p.lng) * k, index: i }
}

// Trail from time `from` up to reading `index`: solid parts, plus dashed lines over real gaps
// (> GAP_MS without readings, or after Stop). The piece from reading `index` to the marker is
// drawn separately every frame.
export function trailUpTo(track, from, index) {
  const solid = []
  const dashed = []
  let line = []
  let prev = null
  for (let i = 0; i <= index && i < track.points.length; i++) {
    const p = track.points[i]
    if (p.t < from) continue
    if (prev && !joined(prev, p)) {
      if (line.length > 1) solid.push(line)
      dashed.push([[prev.lat, prev.lng], [p.lat, p.lng]])
      line = []
    }
    line.push([p.lat, p.lng])
    prev = p
  }
  if (line.length > 1) solid.push(line)
  return { solid, dashed }
}
