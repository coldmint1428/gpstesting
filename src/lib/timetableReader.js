// timetableReader -- the one way the app reads a running timetable (`session_timetable`), shared by every screen.
//
// WHY. 2 Nov load test: each phone read the whole timetable every 30 s and again at every planned moment -- 436 rows
// for a member, 8,720 for a planner on the NDP plan -- and those reads were about 95 % of the database's work; 35
// simulated phones made the app slow for everyone. Between two publishes only the marks and the clock change, so:
//
//   * The whole timetable is read once per published version (and again at least every FULL_MS as a safety net).
//   * In between, the small `session_marks` read (076) brings the marks, the database's clock, and what the timetable
//     is about (plan, revision, T+0). When any of those differs from the copy, the whole timetable is read again --
//     so a publish reaches the phone even when its live connection missed the notice.
//   * Each row's state is then worked out here, at the database's clock (utils/timetableLocal.js, its exact rule).
//   * A screen that asks again within FRESH_MS gets the copy judged at the new time, with no request at all: the wake
//     at each planned moment, a focus, a second screen on the same session.
//   * After a new version, each phone waits a random 0-SPREAD_MS before reading it, so a publish is not every phone
//     reading 436 rows in the same second.
//
// A database without `session_marks` (before 076) still works: every ask past FRESH_MS is a whole read, as before.
// A timetable judged at a fixed time (a closed session, `at`) never changes and is read once.
import { supabase } from './supabase'
import { baseOf, marksOf, lostAMark, judge } from '../utils/timetableLocal'

const FRESH_MS = 20000 // asked the database less than this long ago: answer from the copy
const FULL_MS = 10 * 60 * 1000 // read the whole timetable at least this often, whatever the marks say
const SPREAD_MS = 8000 // a new version: wait up to this long, at random, before reading it

const copies = new Map() // `${user}|${session}|${at}` -> copy
let marksMissing = false // this database has no session_marks (before 076): whole reads only

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function whoAmI() {
  const { data } = await supabase.auth.getSession()
  return (data && data.session && data.session.user && data.session.user.id) || 'anon'
}

async function readWhole(sessionId, at) {
  const args = { p_session: sessionId }
  if (at) args.p_at = at
  const asked = Date.now()
  const { data, error } = await supabase.rpc('session_timetable', args)
  if (error) throw error
  const rows = data || []
  const copy = { ...baseOf(rows), meta: null, wholeAt: Date.now(), askedAt: Date.now(), offset: 0, rows }
  // The database's clock, when the rows tell it: a late, unmarked row's lateness is (its now - planned_at)
  const late = rows.find((r) => r.state === 'late' && !r.marked_at && r.lateness)
  if (late) {
    const seconds = secondsOf(late.lateness)
    if (seconds != null) copy.offset = new Date(late.planned_at).getTime() + seconds * 1000 - (asked + copy.askedAt) / 2
  }
  return copy
}

// Postgres interval text -> seconds (the same reading PlanSchedule does)
function secondsOf(text) {
  const m = String(text).match(/^\s*(-?)(?:(\d+)\s+days?\s+)?(\d+):(\d+):(\d+(?:\.\d+)?)\s*$/)
  if (!m) return null
  const value = Number(m[2] || 0) * 86400 + Number(m[3]) * 3600 + Number(m[4]) * 60 + Number(m[5])
  return m[1] ? -value : value
}

const sameT0 = (a, b) => (a == null && b == null) || (a != null && b != null && Math.abs(a - b) < 1000)

/**
 * Bring a copy up to date: the marks and the database's clock, or the whole timetable again when what it is about has
 * changed. Returns the copy to use.
 */
async function refresh(key, sessionId, copy) {
  if (marksMissing || !copy || Date.now() - copy.wholeAt > FULL_MS) return readWhole(sessionId, null)
  const asked = Date.now()
  const { data, error } = await supabase.rpc('session_marks', { p_session: sessionId })
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') {
      marksMissing = true
      return readWhole(sessionId, null)
    }
    throw error
  }
  const back = Date.now()
  // What the timetable is about, now. The first time, it is checked against the rows themselves (an empty read has
  // nothing to check, so it is taken as it is); after that, against what the last ask said.
  const meta = {
    plan: data.plan_id,
    rev: data.plan_rev,
    t0: data.t0_at ? new Date(data.t0_at).getTime() : null,
    ended: data.ended_at || null,
  }
  const moved = copy.meta
    ? meta.plan !== copy.meta.plan || meta.rev !== copy.meta.rev || !sameT0(meta.t0, copy.meta.t0) || meta.ended !== copy.meta.ended
    : copy.base.length > 0 && (meta.rev !== copy.rev || !sameT0(meta.t0, copy.t0))
  const marks = marksOf(data.marks)
  if (moved || lostAMark(copy.base, marks)) {
    // A new version (or T+0, or a mark taken back): read it all, after a random wait so phones do not ask together
    await sleep(Math.random() * SPREAD_MS)
    return readWhole(sessionId, null)
  }
  return { ...copy, meta, marks, askedAt: back, offset: new Date(data.now).getTime() - (asked + back) / 2 }
}

/**
 * The timetable of one session, as `session_timetable` answers it. `at` (a Date or ISO text) judges it at that time
 * instead of now: a closed session, read once.
 */
export async function readTimetable(sessionId, at = null) {
  if (!sessionId) return []
  const atText = at ? (at instanceof Date ? at.toISOString() : at) : null
  const key = (await whoAmI()) + '|' + sessionId + '|' + (atText || '')
  let entry = copies.get(key)
  if (!entry) {
    entry = { copy: null, inflight: null }
    copies.set(key, entry)
  }

  if (atText) {
    if (!entry.copy || Date.now() - entry.copy.wholeAt > FULL_MS) {
      if (!entry.inflight) entry.inflight = readWhole(sessionId, atText).finally(() => (entry.inflight = null))
      entry.copy = await entry.inflight
    }
    return entry.copy.rows
  }

  if (!entry.copy || Date.now() - entry.copy.askedAt >= FRESH_MS) {
    if (!entry.inflight) {
      entry.inflight = refresh(key, sessionId, entry.copy).finally(() => (entry.inflight = null))
    }
    entry.copy = await entry.inflight
  }
  const copy = entry.copy
  return judge(copy.base, copy.marks, Date.now() + copy.offset)
}

/** Something was just written to this session (a mark): the next ask goes to the database. */
export function forgetTimetable(sessionId) {
  for (const [key, entry] of copies) {
    if (key.split('|')[1] === sessionId && entry.copy) entry.copy = { ...entry.copy, askedAt: 0 }
  }
}

/** A plan changed somewhere (the live notice): every copy checks with the database at its next ask. */
export function staleTimetables() {
  for (const entry of copies.values()) if (entry.copy) entry.copy = { ...entry.copy, askedAt: 0 }
}

/** Signed out: nothing kept. */
export function clearTimetables() {
  copies.clear()
}
