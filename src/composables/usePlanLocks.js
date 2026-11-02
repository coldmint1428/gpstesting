// usePlanLocks -- taking a hold on the badges a write is about, and letting go.
//
// The database is the authority (081_plan_locks.sql, 082_frame_place.sql). A hold lives in public.plan_cell_locks,
// keyed by one cell -- (frame, group) -- and owned by a SESSION, not by a planner (see pageSession.js: two tabs of
// one account are two editors). frame_place() writes nothing for a cell the caller does not hold, so everything
// here is about two things: holding a badge for the moment a change is written, and telling the planner the truth
// when somebody else has it.
//
// NOTHING HERE IS A GATE ON DATA. If this file got everything wrong, a planner's change would simply not be
// stored: the door refuses a write with no hold. The hold exists so that the refusal arrives BEFORE the work
// instead of after it -- and so that two planners cannot write the same badge in the same instant.
//
// THIS PHASE HOLDS FOR THE LENGTH OF ONE WRITE, and nothing longer. Take it, write, put it down -- so the write is
// exclusive without a badge staying "in use" for twelve seconds after the planner has stopped. Holding it across a
// whole gesture (pointer down to pointer up), the 2 s heartbeat and the 5 s idle release are phase 3, and they
// build on exactly these calls: plan_renew, plan_release_all and plan_take_over are already in 081.
//
// WHY A WRITE NEEDS THE HOLD AND NOT MERELY THE REFUSAL. Two page-loads that both find no hold and both write would
// both be "allowed"; the hold is the one row that decides which of them wins, because taking it is a single
// statement on a primary key. plan_lock_cells() is that statement, and a hold it gives is a hold the write can be
// checked against.
import { pageSession } from './pageSession'

/** How many of this page's writes are inside a hold, so that two overlapping writes cannot let go of each other. */
const CELL = 'c:'
const MOMENT = 'f:'

export function usePlanLocks(call) {
  const depth = new Map() // cell key (or frame key) -> how many writes are inside it

  function session() {
    return pageSession()
  }

  function cellKey(cell) {
    return CELL + cell.frame + ':' + cell.group
  }

  function pickUp(key) {
    depth.set(key, (depth.get(key) || 0) + 1)
  }

  /** Returns true when this was the last write inside the hold, i.e. when the database should be told. */
  function putDown(key) {
    const left = (depth.get(key) || 0) - 1
    if (left > 0) {
      depth.set(key, left)
      return false
    }
    depth.delete(key)
    return true
  }

  /**
   * Take the hold on every cell, or none. A refusal (PT423) throws with the server's sentence -- "Priya is editing
   * Gate Crew at +1:00" -- and leaves the caller with nothing to write, which is the all-or-nothing half of the
   * gesture. `plan_lock_cells` is given the cells as they are: it reads `frame` and `group` and ignores the rest.
   */
  async function hold(planId, cells) {
    for (const cell of cells) pickUp(cellKey(cell))
    try {
      await call('plan_lock_cells', { p_plan: planId, p_cells: cells, p_session: session() })
    } catch (error) {
      for (const cell of cells) putDown(cellKey(cell)) // it never happened
      throw error
    }
  }

  /** Put the cells down. Best effort: a hold that is not let go of lapses on its own after 12 s (081). */
  async function letGo(planId, cells) {
    const free = cells.filter((cell) => putDown(cellKey(cell)))
    if (!free.length) return
    try {
      await call('plan_unlock_cells', { p_plan: planId, p_cells: free, p_session: session() })
    } catch {
      // Losing a release costs twelve seconds of a hold nobody is using, and nothing else.
    }
  }

  /**
   * Write one badge, or one gesture's badges, against the hold. `cells` is
   * `[{ frame, group, lat, lng, state?, verify? }]` -- 082's list, the same shape the hold takes.
   */
  async function place(planId, cells) {
    if (!cells || !cells.length) return 0
    await hold(planId, cells)
    try {
      return await call('frame_place_many', { p_plan: planId, p_cells: cells, p_session: session() })
    } finally {
      await letGo(planId, cells)
    }
  }

  /** Take badges off the plan. The only way a position disappears (082). */
  async function unplace(planId, cells) {
    if (!cells || !cells.length) return 0
    await hold(planId, cells)
    try {
      return await call('frame_unplace_many', { p_plan: planId, p_cells: cells, p_session: session() })
    } finally {
      await letGo(planId, cells)
    }
  }

  /**
   * Hold one moment for the length of `fn` -- the note is written and then the moment is let go. The frame id is
   * the same credential as a cell's, so a colleague retiming the same moment is refused rather than beaten to the
   * write.
   */
  async function withMoment(planId, frameId, fn) {
    const key = MOMENT + frameId
    pickUp(key)
    try {
      await call('plan_lock_frame', { p_plan: planId, p_frame: frameId, p_session: session() })
    } catch (error) {
      putDown(key)
      throw error
    }
    try {
      return await fn()
    } finally {
      if (putDown(key)) {
        try {
          await call('plan_unlock_frame', { p_frame: frameId, p_session: session() })
        } catch {
          // as above: it lapses by itself
        }
      }
    }
  }

  return { session, place, unplace, withMoment }
}
