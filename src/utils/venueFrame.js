// What a map opens on. Every map in the event (Live, Timeline, Route, Playback) zooms to the drawn zones: that is
// where the event happens. People, plan positions and recorded readings only widen the view when they are near the
// zones -- one phone that sent a fix from home, or a group parked across the island, used to zoom the whole map out
// until the venue was a dot. With no zones drawn, the points are all there is, so the view fits all of them.

/** Metres around the zones that still count as "at the venue". */
export const VENUE_REACH_M = 300

const M_PER_DEG_LAT = 111320

/**
 * @param {{south:number, west:number, north:number, east:number} | null} zones  the zones' box, or null
 * @param {Array<[number, number]>} points  [lat, lng] pairs
 * @returns {{south:number, west:number, north:number, east:number} | null}  the box to frame, or null for nothing
 */
export function venueBox(zones, points = [], reachM = VENUE_REACH_M) {
  const list = points.filter((p) => p && Number.isFinite(p[0]) && Number.isFinite(p[1]))
  if (!zones) {
    if (!list.length) return null
    const box = { south: Infinity, west: Infinity, north: -Infinity, east: -Infinity }
    for (const [lat, lng] of list) grow(box, lat, lng)
    return box
  }
  const midLat = (zones.south + zones.north) / 2
  const dLat = reachM / M_PER_DEG_LAT
  const dLng = reachM / (M_PER_DEG_LAT * Math.max(0.1, Math.cos((midLat * Math.PI) / 180)))
  const box = { ...zones }
  for (const [lat, lng] of list) {
    const near =
      lat >= zones.south - dLat && lat <= zones.north + dLat && lng >= zones.west - dLng && lng <= zones.east + dLng
    if (near) grow(box, lat, lng)
  }
  return box
}

function grow(box, lat, lng) {
  if (lat < box.south) box.south = lat
  if (lat > box.north) box.north = lat
  if (lng < box.west) box.west = lng
  if (lng > box.east) box.east = lng
}

/** The same, for Leaflet: zone bounds (or null) and points in, LatLngBounds (or null) out. */
export function venueBounds(L, zoneBounds, points = [], reachM = VENUE_REACH_M) {
  const zones =
    zoneBounds && zoneBounds.isValid()
      ? { south: zoneBounds.getSouth(), west: zoneBounds.getWest(), north: zoneBounds.getNorth(), east: zoneBounds.getEast() }
      : null
  const box = venueBox(zones, points, reachM)
  return box ? L.latLngBounds([box.south, box.west], [box.north, box.east]) : null
}
