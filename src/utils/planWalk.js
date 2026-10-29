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
