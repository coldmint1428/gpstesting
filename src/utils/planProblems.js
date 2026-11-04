// planProblems - what is wrong with a plan, in one list and one wording, and what may still be edited because of it.
// No map, no Vue, no Supabase: the board's Problems panel draws these, and its lock asks editAllowed().
//
// WHAT IS CHECKED. Only walks across a no-go area or obstacle (plan_check). Such a walk is an error: it locks the plan
// until it is fixed, and Publish refuses it.
//
// NO DISTANCE OR SPEED RULE (091). A group may walk, ride a bus, take a boat or follow a float, so how far and how fast it
// moves between two frames is the planner's call. There is no 25 m limit, no "jumps too far", no "moves too fast", and
// nothing that adds frames or time to satisfy one. An older database whose plan_check still sends those rows is ignored.

const METRES_PER_DEGREE = 111320

// Rows from a plan_check older than 091: the 25 m budget and the speed warning. Neither is a rule any more.
const isRetiredRule = (row) => /faster than running|the limit is \d+ m/.test(String(row.message || ''))

/** One list out of the database's rows (plan_check), in time order. */
export function problemsOf(rows = []) {
  const list = []
  for (const row of rows) {
    if (isRetiredRule(row) || row.severity !== 'error') continue
    const crossing = String(row.message || '').match(/crosses (.+)$/)
    list.push({
      // The distance is in the id so a dismissed problem comes back if the walk changes
      id: `zone|${row.group_id}|${row.from_frame}|${row.to_frame}|${row.metres}`,
      level: 'error',
      kind: crossing ? 'zone' : 'other',
      groupId: row.group_id,
      fromFrame: row.from_frame,
      fromS: row.from_s,
      toFrame: row.to_frame,
      toS: row.to_s,
      metres: row.metres,
      zone: crossing ? crossing[1] : '',
      message: row.message,
    })
  }
  const rank = (p) => (p.level === 'error' ? 0 : 1)
  return list.sort((a, b) => rank(a) - rank(b) || a.fromS - b.fromS)
}

/**
 * OneMap answers in capitals, and "EVERTON PARK, 5 EVERTON PARK" reads as a shout in a list of them. A word with a digit
 * ("3C") or no vowel ("CQ") is a code and keeps its capitals, apart from the road words that only look like one.
 */
export function calmCase(text) {
  if (text !== text.toUpperCase()) return text
  return text.replace(/[^\s,()/-]+/g, (word) => {
    if (/\d/.test(word) || (/^[A-Z]+$/.test(word) && !/[AEIOUY]/.test(word) && !['ST', 'RD', 'DR', 'LN', 'BLK', 'JLN'].includes(word))) return word
    return word.charAt(0) + word.slice(1).toLowerCase()
  })
}

/** The words for one problem: what is wrong, the numbers behind it, and anything the buttons do not already say. */
export function problemWords(problem, groupName) {
  const seconds = problem.toS - problem.fromS
  if (problem.kind === 'zone') {
    return {
      title: `${groupName} crosses ${problem.zone}`,
      detail: '',
      fix: seconds < 2 ? 'No room for a frame between: add time first.' : 'Add a frame between, then drag them to the suggested spot.',
    }
  }
  return { title: `${groupName} cannot do this walk`, detail: problem.message, fix: 'Change these positions or times.' }
}

/**
 * While there are errors, may this be edited? Only what they name: a moment inside an error's stretch of time, and when
 * groups are named, each of them must be in an error covering that moment. No errors, no lock.
 */
export function editAllowed(errors, t_s, groupIds = []) {
  if (!errors.length) return true
  const covering = errors.filter((e) => e.fromS <= t_s && t_s <= e.toS)
  if (!covering.length) return false
  return groupIds.every((id) => covering.some((e) => e.groupId === id))
}

// ---------- where to go instead ----------

/** Flat metres around a point: close enough over a venue, and the same planar sum plan_check uses. */
function flatten(origin) {
  const across = METRES_PER_DEGREE * Math.cos((origin.lat * Math.PI) / 180)
  return {
    toXY: (lat, lng) => ({ x: (lng - origin.lng) * across, y: (lat - origin.lat) * METRES_PER_DEGREE }),
    toLatLng: ({ x, y }) => ({ lat: origin.lat + y / METRES_PER_DEGREE, lng: origin.lng + x / across }),
  }
}

function crosses(a, b, c, d) {
  const side = (p, q, r) => (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
  return side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0
}

function inside(point, ring) {
  let hit = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]
    const b = ring[j]
    if (a.y > point.y !== b.y > point.y && point.x < ((b.x - a.x) * (point.y - a.y)) / (b.y - a.y) + a.x) hit = !hit
  }
  return hit
}

/** The outer rings of a zone's GeoJSON, in flat metres. */
function ringsOf(geojson, flat) {
  if (!geojson) return []
  const polygons = geojson.type === 'Polygon' ? [geojson.coordinates] : geojson.type === 'MultiPolygon' ? geojson.coordinates : []
  return polygons.map((polygon) => polygon[0].map(([lng, lat]) => flat.toXY(lat, lng)))
}

function legIsClear(a, b, rings) {
  return rings.every((ring) => {
    if (inside(a, ring) || inside(b, ring)) return false
    return ring.every((point, i) => i === 0 || !crosses(a, b, ring[i - 1], point))
  })
}

/**
 * Where to send the group instead, or null when there is no answer worth drawing: the nearest place to one side of
 * the line's middle from which both legs miss every no-go area and obstacle. It is a suggestion to drag to, never a write: only the planner
 * knows the ground, and the hop after it may then need moving too.
 */
export function suggestedSpot(problem, from, to, zones = []) {
  if (!from || !to) return null
  const flat = flatten(from)
  const a = flat.toXY(from.lat, from.lng)
  const b = flat.toXY(to.lat, to.lng)
  const length = Math.hypot(b.x - a.x, b.y - a.y)
  if (!length) return null
  if (problem.kind !== 'zone') return null
  const rings = zones.filter((z) => z.kind === 'no_go' || z.kind === 'obstacle').flatMap((z) => ringsOf(z.geojson, flat))
  const middle = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
  const across = { x: -(b.y - a.y) / length, y: (b.x - a.x) / length }
  for (let d = 10; d <= 500; d += 10) {
    for (const sign of [1, -1]) {
      const spot = { x: middle.x + across.x * d * sign, y: middle.y + across.y * d * sign }
      if (legIsClear(a, spot, rings) && legIsClear(spot, b, rings)) return flat.toLatLng(spot)
    }
  }
  return null
}
