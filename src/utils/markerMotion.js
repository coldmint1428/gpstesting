// Smooth marker movement for the live map (website and phone app).
//
// Readings arrive every ~10 s (phone app). Instead of jumping - or sliding for 1 s and then
// standing still until the next reading - a marker moves at a STEADY speed across the whole
// time between two readings, so it is always gliding, like a taxi on a ride-hailing map.
// It reaches each reading roughly when the next one arrives, so what you see is at most one
// interval (~10 s) behind.
//
// - GPS wobble: a reading closer than about half its accuracy to where the marker is going
//   counts as noise and is ignored (standing still stays still).
// - Very big moves (>1 km, train / car after a tunnel) or long gaps (>2 min) jump instead of
//   "flying" through buildings.
// - One bad fix (accuracy >100 m right after good readings) is skipped, see isBadFix().

export const MIN_GLIDE_MS = 1000
export const MAX_GLIDE_MS = 12000 // longer gaps: glide 12 s, then wait for the next reading
export const JUMP_METRES = 1000
export const JUMP_GAP_MS = 2 * 60 * 1000

// Movements smaller than this (metres) are GPS noise: half the reading's accuracy, 4-15 m.
// (Still phones moved 3 m median / 9 m 90% in our tests; walkers ~14 m per 10 s.)
export function wobbleThreshold(accuracy) {
  return Math.min(Math.max((accuracy || 0) * 0.5, 4), 15)
}

// A reading much worse than the last good one, soon after it, is usually a bad fix
// (reflection off buildings) - skip it; real gaps (tunnels) are longer than 2 min.
export function isBadFix(accuracy, previousAccuracy, gapMs) {
  return accuracy > 100 && previousAccuracy > 0 && previousAccuracy <= 50 && gapMs < JUMP_GAP_MS
}

// Move a Leaflet marker towards `target` (L.LatLng).
//   accuracy : accuracy of the new reading (metres)
//   gapMs    : time between this reading and the marker's previous one (glide length)
//   onStep   : called with each position while gliding (e.g. follow mode pans the map)
// Returns true if the marker moves, false if the change was ignored as wobble.
export function moveMarker(marker, target, { accuracy = 0, gapMs = 0, onStep = null } = {}) {
  const goal = marker.goalLatLng || marker.getLatLng()
  const distance = goal.distanceTo(target)
  if (distance === 0 || distance <= wobbleThreshold(accuracy)) return false

  marker.goalLatLng = target
  if (marker.glideFrame) cancelAnimationFrame(marker.glideFrame)

  const from = marker.getLatLng() // where it is shown now (may be mid-glide)
  if (from.distanceTo(target) > JUMP_METRES || gapMs > JUMP_GAP_MS || document.hidden) {
    marker.setLatLng(target)
    if (onStep) onStep(target)
    return true
  }

  // Glide across (almost) the whole gap between readings, at a steady speed
  const duration = Math.min(Math.max(gapMs * 0.9, MIN_GLIDE_MS), MAX_GLIDE_MS)
  const startTime = performance.now()
  function step(timeNow) {
    const t = Math.min((timeNow - startTime) / duration, 1)
    const here = [from.lat + (target.lat - from.lat) * t, from.lng + (target.lng - from.lng) * t]
    marker.setLatLng(here)
    if (onStep) onStep(marker.getLatLng())
    marker.glideFrame = t < 1 ? requestAnimationFrame(step) : null
  }
  marker.glideFrame = requestAnimationFrame(step)
  return true
}
