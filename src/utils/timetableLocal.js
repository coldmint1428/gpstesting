// timetableLocal -- a running timetable judged on the phone, exactly as the database judges it (session_status, 050).
//
// Between two publishes a timetable's rows only change in two ways: a mark arrives (tapped, or detected from GPS) and
// the clock moves. So the app keeps the rows of one full read, keeps the marks up to date with the small
// `session_marks` read (076), and works out each row's state here, every time a screen asks (src/lib/timetableReader.js).
//
// The database's rule, copied exactly:
//   a mark                      -> the mark's state; lateness = marked_at - planned_at
//   off site at that moment     -> 'not_required', no lateness
//   planned_at already passed   -> 'late'; lateness = now - planned_at
//   otherwise                   -> 'pending', no lateness
// Lateness is written the way PostgREST sends a Postgres interval ("00:03:12.5", "-00:00:45"), so every screen reads
// it with the parser it already has. Tested against the database's own answers (__tests__/timetableLocal.spec.js).

const keyOf = (frameId, groupId) => frameId + '|' + groupId

/** Seconds -> Postgres interval text ("-00:00:45", "26:00:05.25"). Hours are not folded into days. */
export function formatInterval(seconds) {
  if (seconds == null || Number.isNaN(seconds)) return null
  const sign = seconds < 0 ? '-' : ''
  let rest = Math.abs(seconds)
  const h = Math.floor(rest / 3600)
  rest -= h * 3600
  const m = Math.floor(rest / 60)
  rest -= m * 60
  const s = Math.round(rest * 1e6) / 1e6
  const whole = Math.floor(s)
  const frac = s - whole
  const ss = String(whole).padStart(2, '0') + (frac > 0 ? String(Number(frac.toFixed(6))).slice(1) : '')
  return sign + String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + ss
}

/**
 * Split one full read into what stays (the rows, and whether each row is off site) and what moves (the marks).
 * A row the database answered as 'not_required' with no mark is off site; a marked row hides that fact, which is why
 * the reader reads everything again when a mark disappears.
 */
export function baseOf(rows) {
  const base = []
  const marks = new Map()
  for (const row of rows || []) {
    const planned = row.planned_at ? new Date(row.planned_at).getTime() : null
    base.push({ row, planned, offSite: row.state === 'not_required' && !row.marked_at })
    if (row.marked_at) {
      marks.set(keyOf(row.frame_id, row.group_id), {
        state: row.state, marked_at: row.marked_at, marked_by: row.marked_by,
      })
    }
  }
  const first = rows && rows.length ? rows[0] : null
  return {
    base,
    marks,
    rev: first ? first.plan_rev : null,
    // T+0 as the rows say it: planned_at = t0 + t_s
    t0: first && first.planned_at != null ? new Date(first.planned_at).getTime() - first.t_s * 1000 : null,
  }
}

/** The marks from a `session_marks` answer, keyed the way baseOf keys them. */
export function marksOf(list) {
  const marks = new Map()
  for (const m of list || []) {
    marks.set(keyOf(m.frame_id, m.group_id), { state: m.state, marked_at: m.marked_at, marked_by: m.marked_by })
  }
  return marks
}

/** True when a row the copy had marked is no longer marked (only a full read can say what it is now). */
export function lostAMark(base, marks) {
  for (const b of base) {
    if (b.row.marked_at && !marks.has(keyOf(b.row.frame_id, b.row.group_id))) return true
  }
  return false
}

/** The rows as the database would answer them at `nowMs` (its clock), with `marks` applied. */
export function judge(base, marks, nowMs) {
  return base.map(({ row, planned, offSite }) => {
    const mark = marks.get(keyOf(row.frame_id, row.group_id))
    let state
    let lateness = null
    if (mark) {
      state = mark.state
      lateness = planned == null ? null : formatInterval((new Date(mark.marked_at).getTime() - planned) / 1000)
    } else if (offSite) {
      state = 'not_required'
    } else if (planned != null && planned < nowMs) {
      state = 'late'
      lateness = formatInterval((nowMs - planned) / 1000)
    } else {
      state = 'pending'
    }
    return {
      ...row,
      state,
      lateness,
      marked_at: mark ? mark.marked_at : null,
      marked_by: mark ? mark.marked_by : null,
    }
  })
}
