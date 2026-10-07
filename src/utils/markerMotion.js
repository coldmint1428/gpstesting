// Smooth marker movement for the live map (used by the website and the phone app).
//
// 1. Glide: instead of jumping to each new reading (about every 30 s), a marker slides to
//    the new spot over ANIMATION_MS. Big jumps (train/bus, or after a long gap such as a
//    tunnel) still jump, so a marker never "flies" through buildings for kilometres.
// 2. Ignore GPS wobble: a phone lying still reports positions a few metres apart (noise).
//    If a new reading is closer than the wobble threshold to where the marker is shown,
//    the marker stays put. Slow real movement still adds up and moves it once it exceeds
//    the threshold, because we compare with the SHOWN position, not the last reading.
//
// Thresholds come from our outing test: when still, readings moved 3 m (median) / 9 m (90%)
// with ~16 m accuracy; walking moved ~26 m per update; train/bus 300-1200 m.

export const ANIMATION_MS = 1000 // how long a glide takes
export const MAX_GLIDE_METRES = 500 // bigger jumps (vehicles) are not animated
export const MAX_GLIDE_GAP_MS = 90 * 1000 // after a gap longer than this (e.g. tunnel): jump

// Movements smaller than this (metres) count as GPS noise: the reading's accuracy,
// but at least 5 m and at most 25 m (so a slow walker still moves on the map)
export function wobbleThreshold(accuracy) {
  return Math.min(Math.max(accuracy || 0, 5), 25)
}

// Ease in and out: start slow, speed up, slow down at the end
function ease(t) {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2
}

// Move a Leaflet marker towards `target` (L.LatLng).
//   accuracy : accuracy of the new reading in metres (for the wobble check)
//   gapMs    : time since the previous reading of this marker
// Returns true if the marker moved, false if the change was ignored as wobble.
export function moveMarker(marker, target, { accuracy = 0, gapMs = 0 } = {}) {
  const shown = marker.shownLatLng || marker.getLatLng()
  const distance = shown.distanceTo(target) // metres (Leaflet helper)

  // Within the wobble threshold = GPS noise: keep the marker where it is (even after a gap)
  if (distance === 0 || distance <= wobbleThreshold(accuracy)) return false

  marker.shownLatLng = target
  if (marker.glideFrame) cancelAnimationFrame(marker.glideFrame)

  // Jump instead of gliding: vehicles, after long gaps, or when the tab isn't visible
  if (distance > MAX_GLIDE_METRES || gapMs > MAX_GLIDE_GAP_MS || document.hidden) {
    marker.setLatLng(target)
    return true
  }

  const start = marker.getLatLng() // may be part-way through a previous glide
  const startTime = performance.now()
  function step(timeNow) {
    const t = Math.min((timeNow - startTime) / ANIMATION_MS, 1)
    const k = ease(t)
    marker.setLatLng([start.lat + (target.lat - start.lat) * k, start.lng + (target.lng - start.lng) * k])
    marker.glideFrame = t < 1 ? requestAnimationFrame(step) : null
  }
  marker.glideFrame = requestAnimationFrame(step)
  return true
}
