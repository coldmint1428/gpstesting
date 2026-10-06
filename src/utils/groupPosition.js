// Group position = accuracy-weighted midpoint of the group's ICs.
//
// weight = 1 / accuracy^2  -> a reading accurate to 10 m counts 100x more than one at 100 m,
// so one faulty phone can't drag the whole group away.
// Readings that are stale (too old) or very inaccurate are ignored completely.
// (Averaging lat/lng directly is fine for the short distances inside one event.)

export const MAX_AGE_MS = 2 * 60 * 1000 // ignore readings older than 2 min
export const MAX_ACCURACY_M = 100 // ignore readings worse than 100 m

// readings: [{ lat, lng, accuracy, time: Date }]
// returns { lat, lng, used } or null if no usable reading
export function weightedMidpoint(readings, now = Date.now()) {
  let sumWeight = 0
  let sumLat = 0
  let sumLng = 0
  let used = 0

  for (const r of readings) {
    if (now - r.time > MAX_AGE_MS) continue // stale
    if (!(r.accuracy > 0) || r.accuracy > MAX_ACCURACY_M) continue // missing or too inaccurate

    const weight = 1 / (r.accuracy * r.accuracy)
    sumWeight += weight
    sumLat += r.lat * weight
    sumLng += r.lng * weight
    used++
  }

  if (used === 0) return null
  return { lat: sumLat / sumWeight, lng: sumLng / sumWeight, used }
}
