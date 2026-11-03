// scheduleRows — the Schedule page's rows out of the timetable it already read: which area of the Map page each of a
// group's stops is in, with consecutive stops in one area merged into one row. No map, no Vue, no Supabase.
import { stopsOf, walksOf } from './planWalk'

export function inRing(lat, lng, ring) {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]
    const [xj, yj] = ring[j]
    if (yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) inside = !inside
  }
  return inside
}

function inPolygon(lat, lng, rings) {
  return inRing(lat, lng, rings[0]) && !rings.slice(1).some((hole) => inRing(lat, lng, hole))
}

function polygonsOf(geojson) {
  if (!geojson) return []
  if (geojson.type === 'Feature') return polygonsOf(geojson.geometry)
  if (geojson.type === 'FeatureCollection') return geojson.features.flatMap((feature) => polygonsOf(feature.geometry))
  if (geojson.type === 'Polygon') return [geojson.coordinates]
  if (geojson.type === 'MultiPolygon') return geojson.coordinates
  return []
}

/** The first area that contains the point, or null. */
export function areaAt(lat, lng, zones) {
  return zones.find((zone) => polygonsOf(zone.geojson).some((rings) => inPolygon(lat, lng, rings))) || null
}

/**
 * One group's rows for the list, in the plan's order. `number` is the pin the row's places carry on the map (none for
 * off site); `point` is what a click on the row shows; `endS` is the next row's start, null for the last.
 */
export function scheduleRowsOf(rows, zones) {
  const out = []
  let number = 0
  for (const stop of stopsOf(rows)) {
    const area = stop.kind === 'place' ? areaAt(stop.point.lat, stop.point.lng, zones) : null
    const key = stop.kind === 'off' ? 'off' : area ? area.id : 'move'
    const last = out[out.length - 1]
    if (last && last.key === key) {
      last.stops.push(stop)
      last.rows.push(...stop.rows)
      last.endsAt = stop.endsAt
      continue
    }
    if (last) last.endS = stop.rows[0].t_s
    const placed = stop.kind === 'place'
    out.push({
      key,
      name: stop.kind === 'off' ? 'Off site' : area ? area.name : 'On the move',
      kind: stop.kind === 'off' ? 'off' : area ? area.kind : 'move',
      number: placed ? (number += 1) : null,
      point: stop.point,
      stops: [stop],
      rows: [...stop.rows],
      startsAt: stop.startsAt,
      endsAt: stop.endsAt,
      startS: stop.rows[0].t_s,
      endS: null,
    })
  }
  return out
}

/**
 * Every group's rows in the timetable, in the order of the plan's clock. The numbers run in that same order, so the
 * pins on the map and the list read alike.
 */
export function scheduleOf(rows, zones) {
  const list = [...walksOf(rows).values()]
    .flatMap((walk) => scheduleRowsOf([...walk.rows].sort((a, b) => a.t_s - b.t_s), zones))
    .sort((a, b) => a.startS - b.startS)
  let number = 0
  for (const row of list) if (row.number) row.number = number += 1
  return list
}
