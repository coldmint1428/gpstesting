// planWalk — the plan's walk out of a timetable's rows: the line a group's statements make, and which two statements
// the clock is between. No map, no Vue, no Supabase: this is the part that can be proved without a browser
// (tools/plan_walk_test.mjs), and the screens are the part that has to be seen.
//
// WHAT A ROW IS. One row per group per frame of the plan, as `session_timetable` (065) answers it: `planned_at` (the
// moment on the plan's clock), `state` ('pending' / 'late' / 'arrived' / 'missed' / 'not_required'), and the moment's
// own point (`lat`, `lng`) when it states one. The rows arrive in the plan's clock order, a group's rows together, and
// this file does not re-sort them: the order is the plan's, and a screen that re-sorted would disagree with the engine's
// own idea of "which moment is next".
//
// WHERE THE SCOPE IS. Nowhere here. `session_status` applies 040's scope inside the engine (052), so staff are handed
// every group's rows and a member their own; this file draws whatever arrived and never filters by group. A filter here
// would look the same in a browser and be a second place for the rule to drift (step 16's finding 48).
//
// THREE RULES, AND WHO THEY BELONG TO.
//   - An off-site statement is not a place on the map, so the walk BREAKS there rather than bridging the group across
//     ground it is not on (step 9's rule for the board, step 29's for the follower's map). The engine answers
//     `not_required` for every moment between an off-site statement and the next on-site one, so the break is the
//     engine's own carrying of that statement forward, not a guess made here.
//   - A moment that only CARRIES the group forward states no point of its own and does not break the walk: the line
//     continues from the last point the group actually stated.
//   - A single stated point is a mark, not a line. A run of one draws nothing, because there is no second point to join
//     it to, and inventing one would be inventing a place nobody wrote (the same refusal as step 30's "no interpolated
//     dot").
//
// WHY THE LEG IS TWO ROWS AND NOT TWO POINTS. `legNow` answers the two statements the clock falls between, so a caller
// can say WHICH moments they are ("+0:00 → +5:00") as well as where they are; a plain pair of coordinates would throw
// away the only thing that makes the bold leg checkable against the timetable's own row.

/** The clock time of a row, in milliseconds. */
function at(row) {
  return new Date(row.planned_at).getTime()
}

/**
 * The drawable stretches of one group's walk: one array of [lat, lng] per stretch, in the plan's order. A stretch is
 * broken by an off-site statement (see the third rule above) and is never joined across one.
 */
export function runsOf(rows) {
  const runs = []
  let run = []
  for (const row of rows) {
    if (row.state === 'not_required') {
      if (run.length) runs.push(run)
      run = []
    } else if (row.lat != null) {
      run.push([row.lat, row.lng])
    }
  }
  if (run.length) runs.push(run)
  return runs
}

/**
 * The walk of every group the rows mention, keyed by group id and in the order the read first named each group: the
 * rows it was built from, the rows that state a point, and the runs to draw. The group's colour is the caller's (the
 * event's palette), because a colour is a screen's business and this file has no screen.
 */
export function walksOf(rows) {
  const walks = new Map()
  for (const row of rows) {
    let walk = walks.get(row.group_id)
    if (!walk) {
      walk = { id: row.group_id, name: row.group_name, rows: [], points: [], runs: [] }
      walks.set(row.group_id, walk)
    }
    walk.rows.push(row) // the rows arrive in the plan's clock order
  }
  for (const walk of walks.values()) {
    walk.points = walk.rows.filter((row) => row.lat != null)
    walk.runs = runsOf(walk.rows)
  }
  return walks
}

/**
 * Where the plan has one group at an instant: the row of the last point it stated by then. A moment that only carries
 * the group keeps it at that point. Null before its first point and while it is off site.
 */
export function whereAt(rows, clockMs) {
  let found = null
  for (const row of rows) {
    if (at(row) > clockMs) break
    if (row.state === 'not_required') found = null
    else if (row.lat != null) found = row
  }
  return found
}

/**
 * One group's rows as the stops a person walks between, in the plan's order. A stop is a point and every moment spent at
 * it: the statement, the moments that carry it, and a further statement of the same point (a different name at the same
 * point is a different stop, because a planner wrote it). Points in the same clock minute are one stop too, at the first
 * of them: seconds apart they would be rows and pins all saying the same time. Off-site moments make one 'off' entry, and moments before the
 * first point make one 'none' entry; neither takes a number, so the numbers are the pins on the map. A stop lasts until
 * the next entry starts (`endsAt`), and the last one has no end the plan can state.
 */
export function stopsOf(rows) {
  const stops = []
  let number = 0
  let stop = null
  const open = (kind, row) => {
    const place = kind === 'place'
    stop = {
      kind,
      number: place ? (number += 1) : null,
      point: place ? row : null,
      name: '',
      rows: [],
      startsAt: row.planned_at,
      endsAt: null,
    }
    if (stops.length) stops[stops.length - 1].endsAt = row.planned_at
    stops.push(stop)
  }
  for (const row of rows) {
    if (row.state === 'not_required') {
      if (!stop || stop.kind !== 'off') open('off', row)
    } else if (row.lat != null) {
      const same = stop && stop.kind === 'place' && (
        Math.floor(at(row) / 60000) === Math.floor(at(stop.point) / 60000)
        || (stop.point.lat === row.lat && stop.point.lng === row.lng && (!row.place || !stop.name || row.place === stop.name))
      )
      if (!same) open('place', row)
      if (!stop.name && row.place) stop.name = row.place
    } else if (!stop) {
      open('none', row)
    }
    stop.rows.push(row)
  }
  return keepRealStops(stops)
}

/**
 * A walk traced frame by frame puts a new point every few metres, and each one would be a numbered stop: a list and a
 * map full of corners. A point is a stop only when the planner named it or the group stays there (a later moment of the
 * stop keeps it on that point); the first and last points, and a point next to an off-site stretch, always are. Any other
 * point is one the group walks through: its rows join the stop it is walking on from (as `via`), and the numbers close up.
 */
function keepRealStops(stops) {
  const places = stops.filter((s) => s.kind === 'place')
  const first = places[0]
  const last = places[places.length - 1]
  const held = (s) => s.rows.some((r) => r !== s.point && (r.lat == null || (r.lat === s.point.lat && r.lng === s.point.lng)))
  const out = []
  stops.forEach((stop, index) => {
    stop.via = []
    const prev = out[out.length - 1]
    const after = stops[index + 1]
    const passing = stop.kind === 'place' && stop !== first && stop !== last && !stop.name && !held(stop) &&
      prev && prev.kind === 'place' && after && after.kind === 'place'
    if (!passing) {
      out.push(stop)
      return
    }
    prev.rows.push(...stop.rows)
    prev.via.push(...stop.rows)
    prev.endsAt = stop.endsAt
  })
  let number = 0
  for (const stop of out) if (stop.kind === 'place') stop.number = number += 1
  return out
}

/**
 * The leg the clock is on: the statement the clock has reached and the one after it, or null when there is no such pair
 * to draw. Null is the honest answer in four of the five places a clock can be (see the test): before the first
 * statement, on a moment that states no point (a carried or off-site one — the plan says the group is still where it
 * last was, not that it is walking), after the last one, and anywhere in a walk that is not a line at all.
 *
 * A statement counts as reached AT its own time (`<=`), not after it: at +5:00 the group is at the +5:00 point and the
 * leg it is due to walk is the one that leaves it. The whole of a leg's points belong to the caller; this answers rows.
 */
export function legNow(rows, clockMs) {
  let reached = -1
  for (let k = 0; k < rows.length; k += 1) {
    if (at(rows[k]) <= clockMs) reached = k
  }
  if (reached < 0 || reached + 1 >= rows.length) return null
  const from = rows[reached]
  const to = rows[reached + 1]
  // `not_required` rows answer no point, so the point check covers them too; it is stated as well because a caller's
  // rows are only promised to be the engine's shape, not to keep its habit of never giving an off-site row a point.
  if (from.state === 'not_required' || to.state === 'not_required') return null
  if (from.lat == null || to.lat == null) return null
  return [from, to]
}
