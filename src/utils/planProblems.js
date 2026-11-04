// planProblems - what is wrong with a plan, in one list and one wording, and what may still be edited because of it.
// No map, no Vue, no Supabase: the board's Problems panel draws these, and its lock asks editAllowed().
//
// TWO LEVELS. An error is a walk the plan cannot have: too far for its steps (the board's own 25 m rule) or across a
// no-go area or obstacle (plan_check). It locks the plan until it is fixed. A warning can be dismissed and locks
// nothing.
//
// NO SPEED RULE. plan_check still says when a move is "faster than running", but a group may be on a bus, a boat or a
// float rather than on foot, so how fast a group moves is the planner's call: those rows are left out here, and the
// board shows no "moves too fast" warning and offers no time for it.
import { MAX_FRAME_GAP_M, metresBetween } from './planFrames'
import { formatDuration } from './time'

// How far inside the limit a suggested spot sits. A dragged badge lands a few metres off wherever it is aimed, so a spot
// right at the 25 m limit can be hit and still leave the error standing.
const SUGGEST_MARGIN = 0.85
const METRES_PER_DEGREE = 111320

const isPace = (row) => String(row.message || '').includes('faster than running')

/**
 * One list out of the board's gaps (annotate) and the database's rows (plan_check), errors first. A row naming the same
 * group and pair of frames as a gap is the same problem said twice, so only the gap is listed.
 */
export function problemsOf(gaps = [], rows = []) {
  const told = new Set(gaps.map((g) => `${g.groupId}|${g.from.frameId}|${g.to.frameId}`))
  const list = gaps.map((gap) => ({
    id: `far|${gap.groupId}|${gap.from.frameId}|${gap.to.frameId}`,
    level: 'error',
    kind: 'far',
    groupId: gap.groupId,
    fromFrame: gap.from.frameId,
    fromS: gap.from.t_s,
    toFrame: gap.to.frameId,
    toS: gap.to.t_s,
    metres: Math.round(gap.metres),
    steps: gap.steps,
    budget: Math.round(gap.budget),
    gap,
  }))
  for (const row of rows) {
    if (told.has(`${row.group_id}|${row.from_frame}|${row.to_frame}`)) continue
    // Speed is not a rule (see the top of this file)
    if (isPace(row) || row.severity !== 'error') continue
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
  if (problem.kind === 'far') {
    const over = problem.steps === 1 ? 'in one step' : `over ${problem.steps} steps`
    return {
      title: `${groupName} jumps too far`,
      detail: `${problem.metres} m ${over}. The limit is ${problem.budget} m.`,
      fix: '',
    }
  }
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
 * Where to send the group instead, or null when there is no answer worth drawing. Too far: the place along
 * the same line that is just inside the limit. Across an area: the nearest place to one side of the line's middle from
 * which both legs miss every no-go area and obstacle. It is a suggestion to drag to, never a write: only the planner
 * knows the ground, and the hop after it may then need moving too.
 */
export function suggestedSpot(problem, from, to, zones = []) {
  if (!from || !to) return null
  const flat = flatten(from)
  const a = flat.toXY(from.lat, from.lng)
  const b = flat.toXY(to.lat, to.lng)
  const length = Math.hypot(b.x - a.x, b.y - a.y)
  if (!length) return null
  if (problem.kind === 'far') {
    const reach = problem.budget * SUGGEST_MARGIN
    if (reach >= length) return null
    return flat.toLatLng({ x: a.x + ((b.x - a.x) * reach) / length, y: a.y + ((b.y - a.y) * reach) / length })
  }
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

// ---------- fixing a whole walk ----------
// Fill is for the 25 m limit: it adds frames, and only the seconds those frames need to sit on (whole seconds each).

// frames_fill's own step (042): 24 m, not the 25 m limit, so that rounding cannot tip a step over it
const FILL_STEP_M = 24

/** The problems of the same kind joined end to end with this one: one group's frames, each ending where the next begins. */
function walkOf(clicked, problems) {
  const same = problems.filter((p) => p.groupId === clicked.groupId && p.kind === clicked.kind)
  const run = [clicked]
  for (;;) {
    const before = same.find((p) => p.toFrame === run[0].fromFrame && !run.includes(p))
    if (!before) break
    run.unshift(before)
  }
  for (;;) {
    const after = same.find((p) => p.fromFrame === run[run.length - 1].toFrame && !run.includes(p))
    if (!after) break
    run.push(after)
  }
  return run
}

/**
 * What a fix would do, worked out and not written. `points` is the group's track (resolveTracks). Nobody's position
 * changes, so the route stays the one the planner drew.
 *
 * Too far: new frames along the hop's line (frames_fill, 042), the fewest that bring each step inside the limit, at the
 * times and places frames_fill works out, so what the preview promises is what is written. Frames sit on whole seconds,
 * so a hop too short to hold them gets just the seconds that make room, and no more.
 */
export function walkFixPlan(clicked, problems, points, zones = []) {
  const run = walkOf(clicked, problems)
  const base = { problemId: clicked.id, groupId: clicked.groupId, kind: clicked.kind, run, fills: [], newFrames: 0, times: [], totalSeconds: 0, route: [], frameIds: [], crosses: false, blocked: '' }
  const stops = points.filter((p) => p.defined && p.state !== 'off_site')
  const pairs = []
  for (const problem of run) {
    const a = stops.findIndex((s) => s.frameId === problem.fromFrame)
    const b = stops.findIndex((s) => s.frameId === problem.toFrame)
    if (a < 0 || b !== a + 1) return { ...base, blocked: 'This walk has changed. Open it again on the map.' }
    pairs.push([stops[a], stops[b]])
  }

  const times = []
  const fills = []
  for (const [a, b] of pairs) {
    if (points.some((p) => p.state === 'off_site' && p.index > a.index && p.index < b.index)) {
      return { ...base, blocked: 'This group goes off site during this walk, so it cannot be filled in. Drag these positions closer on the map instead.' }
    }
    const metres = metresBetween(a, b)
    let seconds = b.t_s - a.t_s
    const steps = Math.ceil(metres / FILL_STEP_M)
    if (seconds < steps) {
      times.push({ frameId: b.frameId, from_s: b.t_s, seconds: steps - seconds })
      seconds = steps
    }
    const taken = new Set(points.filter((p) => p.index > a.index && p.index < b.index).map((p) => p.t_s))
    const at = new Set()
    const spots = []
    for (let n = 1; n < steps; n += 1) {
      const t = a.t_s + Math.round((seconds * n) / steps)
      if (t <= a.t_s || t >= a.t_s + seconds || at.has(t)) continue
      at.add(t)
      const share = (t - a.t_s) / seconds
      spots.push({ lat: a.lat + (b.lat - a.lat) * share, lng: a.lng + (b.lng - a.lng) * share })
    }
    fills.push({
      fromFrame: a.frameId,
      fromS: a.t_s,
      toFrame: b.frameId,
      spots,
      newFrames: [...at].filter((t) => !taken.has(t)).length,
      hop: Math.round(metres / (spots.length + 1)),
    })
  }

  const route = [pairs[0][0], ...pairs.map(([, b]) => b)]
  const flat = flatten(route[0])
  const rings = zones.filter((z) => z.kind === 'no_go' || z.kind === 'obstacle').flatMap((z) => ringsOf(z.geojson, flat))
  const crosses = route.some((stop, i) => i > 0 && !legIsClear(flat.toXY(route[i - 1].lat, route[i - 1].lng), flat.toXY(stop.lat, stop.lng), rings))
  return {
    ...base,
    fills,
    newFrames: fills.reduce((sum, fill) => sum + fill.newFrames, 0),
    times,
    totalSeconds: times.reduce((sum, row) => sum + row.seconds, 0),
    route: route.map((stop) => ({ lat: stop.lat, lng: stop.lng })),
    frameIds: route.map((stop) => stop.frameId),
    crosses,
  }
}

/** A fix in words, before it is applied: what is wrong, and exactly what will change. */
export function walkFixWords(plan, groupName, frameNumber) {
  const wrong = plan.run.slice(0, 4).map((p) => {
    const words = problemWords(p, groupName)
    return `Frames ${frameNumber(p.fromFrame)} → ${frameNumber(p.toFrame)}: ${words.detail}`
  })
  if (plan.run.length > 4) wrong.push(`and ${plan.run.length - 4} more on this walk.`)
  const changes = []
  const notes = []
  const first = plan.times.length ? Math.min(...plan.times.map((t) => frameNumber(t.frameId))) : 0
  const added = formatDuration(plan.totalSeconds * 1000)
  {
    const count = plan.newFrames === 1 ? '1 new frame' : plan.newFrames + ' new frames'
    const fill = plan.fills[0]
    const where = plan.fills.length === 1 ? `between frames ${frameNumber(fill.fromFrame)} and ${frameNumber(fill.toFrame)}` : 'along this walk'
    const hop = Math.max(...plan.fills.map((f) => f.hop))
    changes.push(`Adds ${count} ${where} for ${groupName}, so each step is about ${hop} m. Later frames are renumbered.`)
    changes.push(plan.times.length
      ? `Adds ${added} to make room: frames sit on whole seconds. Every group's frames from ${first} onward run that much later.`
      : 'No time is added.')
  }
  changes.push(`${groupName} keeps the same route: no existing frame moves.`)
  if (plan.crosses) notes.push('This route crosses a no-go area or obstacle, so that error will appear next.')
  return { wrong, changes, note: notes.join(' ') }
}
