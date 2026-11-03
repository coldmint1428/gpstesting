// usePlanLocks -- taking a hold on the badges a change is about, keeping it while the hand is on them, and letting go.
//
// The database is the authority (081_plan_locks.sql, 082_frame_place.sql). A hold lives in public.plan_cell_locks,
// keyed by one cell -- (frame, group) -- and owned by a SESSION, not by a planner (see pageSession.js: two tabs of
// one account are two editors). frame_place() writes nothing for a cell the caller does not hold, so everything
// here is about two things: holding a badge while it is being changed, and telling the planner the truth when
// somebody else has it.
//
// NOTHING HERE IS A GATE ON DATA. If this file got everything wrong, a planner's change would simply not be
// stored: the door refuses a write with no hold. The hold exists so that the refusal arrives BEFORE the work
// instead of after it -- and so that two planners cannot write the same badge in the same instant.
//
// A HOLD IS RENEWED WHILE THIS PAGE MEANS TO KEEP IT. Every HEARTBEAT_MS plan_renew() moves last_seen on every
// badge this page holds. The server's blocking rule is "quiet for 7 s" (plus a 12 s outer expiry), so a page that
// says "still here" every two seconds cannot be mistaken for one that has walked away. The answer also says, per
// row, whether the hold is still mine: a row that is not has been taken over or has expired, and it is dropped
// from this page's list and reported to the board (onLost) rather than kept in the page's imagination. That is the
// one thing the heartbeat is for -- a page that only renews is a page that can go on feeling confident about a
// badge somebody else now has.
//
// WHEN A GESTURE ENDS, THE BADGE IS LET GO. Holding across a pointer gesture (down to up), the 5 s idle release
// and the silent re-acquire are the BOARD's rules, because a gesture is a board idea; this file offers the two
// halves they are built from (hold, release) plus the heartbeat that keeps them alive. A write inside a gesture
// only takes a second reference (see `depth`), so the write's own release cannot let go of the badge the hand is
// still holding.
//
// WHY A WRITE NEEDS THE HOLD AND NOT MERELY THE REFUSAL. Two page-loads that both find no hold and both write would
// both be "allowed"; the hold is the one row that decides which of them wins, because taking it is a single
// statement on a primary key. plan_lock_cells() is that statement, and a hold it gives is a hold the write can be
// checked against.
import { pageSession } from './pageSession'

/** How often a held badge says "still here". Must be comfortably under the server's 7 s steal (081). */
export const HEARTBEAT_MS = 2000

/** The key prefixes: a cell and a moment are different resources and never share a hold (081). */
const CELL = 'c:'
const MOMENT = 'f:'

export function usePlanLocks(call, opts = {}) {
  const beatMs = typeof opts.heartbeatMs === 'number' ? opts.heartbeatMs : HEARTBEAT_MS
  // Everything this page is holding for a write or a gesture: cell key -> { frame, group, refs, plan }.
  const held = new Map()
  // Moments held for the length of one note-and-time write: frame id -> how many writes are inside it.
  const moments = new Map()
  let beat = null
  let touched = false // has this page ever asked for a hold? (release-all after a failed release still has to try)
  let lost = null // the board's callback when a held row is no longer mine

  function session() {
    return pageSession()
  }

  function cellKey(cell) {
    return CELL + cell.frame + ':' + cell.group
  }

  function pickUp(key, cell, planId) {
    const entry = held.get(key)
    if (entry) {
      entry.refs += 1
      return false
    }
    held.set(key, { frame: cell.frame, group: cell.group, refs: 1, plan: planId })
    return true
  }

  /** Returns the entry when this was the last reference, i.e. when the database should be told. */
  function putDown(key) {
    const entry = held.get(key)
    if (!entry) return null
    if (entry.refs > 1) {
      entry.refs -= 1
      return null
    }
    held.delete(key)
    return entry
  }

  function startBeat() {
    if (beat || !held.size) return
    beat = setInterval(renew, beatMs)
  }

  function stopBeat() {
    if (!beat) return
    clearInterval(beat)
    beat = null
  }

  /**
   * Say "still here" for every badge this page holds, and learn whether that is still true. A row that comes back
   * not mine is dropped from the list and handed to the board: from that moment the page must not believe it holds
   * the badge, because the very next write will be refused.
   */
  async function renew() {
    if (!held.size) {
      stopBeat()
      return
    }
    // One call per plan (a page normally touches one). The cells are read now, so a release that lands while the
    // call is out is not resurrected by the answer.
    const byPlan = new Map()
    for (const entry of held.values()) {
      const list = byPlan.get(entry.plan)
      if (list) list.push({ frame: entry.frame, group: entry.group })
      else byPlan.set(entry.plan, [{ frame: entry.frame, group: entry.group }])
    }
    for (const [planId, cells] of byPlan) {
      let rows = null
      try {
        rows = await call('plan_renew', { p_plan: planId, p_cells: cells, p_frames: [], p_session: session() }, { quiet: true })
      } catch {
        // A heartbeat that fails is not news: the hold simply lapses and the next write says so. Telling the planner
        // about a failed refresh while they are still dragging would be an error message about nothing they did.
        continue
      }
      const gone = []
      for (const row of rows || []) {
        if (row.kind !== 'badge' || row.held !== false) continue
        const key = cellKey({ frame: row.frame_id, group: row.group_id })
        if (held.delete(key)) gone.push({ frame: row.frame_id, group: row.group_id })
      }
      if (gone.length && lost) lost(gone)
    }
  }

  /**
   * Take the hold on every badge, or none. A refusal (PT423) throws with the server's sentence -- "Priya is editing
   * Gate Crew at +1:00" -- and leaves the caller with nothing to hold, which is the all-or-nothing half of the
   * gesture. Only the badges not already held are asked for: a write inside a gesture is a second reference, not a
   * second grab, and a take-over only ever applies to a badge this page did not have.
   */
  async function hold(planId, cells, options = {}) {
    if (!cells || !cells.length) return
    const fresh = []
    for (const cell of cells) {
      if (pickUp(cellKey(cell), cell, planId)) fresh.push(cell)
    }
    if (fresh.length) {
      try {
        await call(
          'plan_lock_cells',
          { p_plan: planId, p_cells: fresh, p_session: session(), p_take_over: !!options.takeOver },
          { quiet: true },
        )
      } catch (error) {
        for (const cell of cells) putDown(cellKey(cell)) // it never happened
        if (!held.size) stopBeat()
        throw error
      }
    }
    touched = true
    // The heartbeat starts with the first hold and stops with the last: one timer per page, not one per badge.
    startBeat()
  }

  /** Put the badges down. Best effort: a hold that is not let go of lapses on its own after 12 s (081). */
  async function letGo(planId, cells) {
    if (!cells || !cells.length) return
    const free = []
    for (const cell of cells) {
      const gone = putDown(cellKey(cell))
      if (gone) free.push({ frame: gone.frame, group: gone.group })
    }
    if (!held.size) stopBeat()
    if (!free.length) return
    try {
      await call('plan_unlock_cells', { p_plan: planId, p_cells: free, p_session: session() }, { quiet: true })
    } catch {
      // Losing a release costs twelve seconds of a hold nobody is using, and nothing else.
    }
  }

  /**
   * Write several badges against ONE held breath: `cells` `[{ frame, group, lat, lng, state?, verify? }]` are placed,
   * `gone` `[{ frame, group }]` are taken away (082's two doors, the shapes they take).
   *
   * The hold is asked for ONCE, for every cell of both directions, before anything is written. That is the whole
   * point of doing it this way: a refusal is all-or-nothing (081), so a badge somebody else is holding stops the work
   * before the first row rather than half-way through it -- which is what an undo needs, because a command that could
   * not happen must not happen in part. The placements go first: an interrupted call has the badge back where it
   * belongs and one row too many, which is nearer the truth than the other order.
   */
  async function rewrite(planId, cells, gone, options = {}) {
    const placing = cells || []
    const lifting = gone || []
    const all = [...placing, ...lifting]
    if (!all.length) return { placed: 0, removed: 0 }
    await hold(planId, all, options)
    try {
      const placed = placing.length
        ? await call('frame_place_many', { p_plan: planId, p_cells: placing, p_session: session() }, { quiet: true })
        : 0
      const removed = lifting.length
        ? await call('frame_unplace_many', { p_plan: planId, p_cells: lifting, p_session: session() }, { quiet: true })
        : 0
      return { placed: placed || 0, removed: removed || 0 }
    } finally {
      await letGo(planId, all)
    }
  }

  /**
   * Write one badge, or one gesture's badges, against the hold. `cells` is
   * `[{ frame, group, lat, lng, state?, verify? }]` -- 082's list, the same shape the hold takes.
   */
  async function place(planId, cells, options = {}) {
    if (!cells || !cells.length) return 0
    const written = await rewrite(planId, cells, [], options)
    return written.placed
  }

  /** Take badges off the plan. The only way a position disappears (082). */
  async function unplace(planId, cells) {
    if (!cells || !cells.length) return 0
    const written = await rewrite(planId, [], cells)
    return written.removed
  }

  /**
   * Who is editing what on this plan, as the database sees it: live badge holds and live moment holds, with the
   * planner's name and whether it is a session of this user. Quiet by design -- it is asked every few seconds beside
   * a board somebody is drawing, and a failed presence read is not worth a word on the screen.
   */
  async function holders(planId) {
    if (!planId) return []
    try {
      return (await call('plan_lock_holders', { p_plan: planId }, { quiet: true })) || []
    } catch {
      return []
    }
  }

  /**
   * Everything this page was holding, at once (081). A page that is going away cannot be trusted to walk its own
   * list, and a hidden tab is not working on anything -- so this is what pagehide and a hidden tab call, and what a
   * plan switch calls. After it, this page believes it holds nothing, because it does not.
   */
  async function releaseAll(planId = null) {
    const any = touched || held.size > 0 || moments.size > 0
    held.clear()
    moments.clear()
    stopBeat()
    touched = false
    if (!any) return
    try {
      await call('plan_release_all', { p_session: session(), p_plan: planId }, { quiet: true })
    } catch {
      // Best effort, as above: an unload cannot wait for an answer, and the rows expire anyway.
    }
  }

  /**
   * Hold one moment for the length of `fn` -- the note is written and then the moment is let go. The frame id is
   * the same credential as a cell's, so a colleague retiming the same moment is refused rather than beaten to the
   * write. No heartbeat: a moment is held for one write, and that write is what keeps it alive.
   */
  async function withMoment(planId, frameId, fn) {
    const key = MOMENT + frameId
    moments.set(key, (moments.get(key) || 0) + 1)
    try {
      await call(
        'plan_lock_frame',
        { p_plan: planId, p_frame: frameId, p_session: session() },
        { quiet: true },
      )
    } catch (error) {
      const left = (moments.get(key) || 1) - 1
      if (left > 0) moments.set(key, left)
      else moments.delete(key)
      throw error
    }
    try {
      return await fn()
    } finally {
      const left = (moments.get(key) || 1) - 1
      if (left > 0) {
        moments.set(key, left)
      } else {
        moments.delete(key)
        try {
          await call('plan_unlock_frame', { p_frame: frameId, p_session: session() }, { quiet: true })
        } catch {
          // as above: it lapses by itself
        }
      }
    }
  }

  /** The board's callback for a hold this page believes in and no longer has. */
  function onLost(fn) {
    lost = fn
  }

  /** What this page is holding, for the strip and for a page that wants to say so. */
  function heldCells() {
    return [...held.values()].map((entry) => ({ frame: entry.frame, group: entry.group, refs: entry.refs }))
  }

  /** Stop the clock without asking the database (the page is going away and the caller has already released). */
  function dispose() {
    stopBeat()
    held.clear()
    moments.clear()
  }

  return { session, hold, letGo, place, unplace, rewrite, holders, releaseAll, withMoment, onLost, heldCells, dispose }
}
