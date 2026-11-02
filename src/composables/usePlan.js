// usePlan — the only place the plan board talks to the database.
//
// Everything here is a call to one of the 038 functions. Three rules run through the whole file:
//   1. A write is followed by a read. The list functions are `stable`, so a fresh snapshot is needed after a
//      change; the composable never patches a local copy and hopes.
//   2. A stale revision is a message, not an exception. The server answers PT409 when someone else saved
//      between my read and my write; that becomes "reload", and the board keeps everything else on screen.
//   3. Somebody else's write comes back the same way: as a read (step 19). One channel listens to this event's
//      plan rows, which every frame and position write touches (055), and a change that did not move the
//      revision is read back into `frames` -- so a second tab's drag appears without a reload. A change that
//      did move it is a publish, and the live strip owns that decision (steps 15 and 18).
import { computed, onScopeDispose, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { readTimetable as readTimetableShared, forgetTimetable, staleTimetables } from '../lib/timetableReader'
import { usePlanLocks } from './usePlanLocks'

const P409 = 'PT409'

/**
 * A refusal from the ownership doors: somebody else has this badge or this moment (081). HTTP 423 in the handler,
 * PT423 from the database, and the sentence is already written for a planner -- so a caller shows the words, and
 * decides WHERE (the board's strip rather than a toast, because a snap-back is not a success notice).
 */
export function isLockRefusal(error) {
  return !!error && (error.code === 'PT423' || error.status === 423)
}

/** Turn a PostgREST/Postgres error into something worth putting in front of a planner. */
export function planErrorMessage(error) {
  if (!error) return ''
  // The raised messages are already written for a human; drop the "P0001: " or "ERROR: " prefix.
  const text = String(error.message || error.error_description || error)
    .replace(/^(ERROR|P0001|[0-9A-Z]{5}):\s*/, '')
  if (error.code === P409) {
    // Every conflict the plan surface raises is a sentence about this plan -- a frame somebody else changed, a
    // revision somebody else published -- so the server's own words are the ones to show. The fallback is for a
    // conflict that arrives without a sentence of its own.
    return text && text !== P409 ? text : 'Someone else changed this a moment ago. Reopening the plan.'
  }
  return text
}

export function usePlan(eventId) {
  const plans = ref([])
  const plan = ref(null)
  const frames = ref([])
  const groups = ref([])
  const zones = ref([])
  const loading = ref(false)
  const busy = ref(false)
  const errorMsg = ref('')

  /**
   * One door, one error. `quiet` is for the calls whose failure is presented elsewhere or is not news: the ownership
   * doors (a refusal is the board's strip, or nothing at all for a lapsed heartbeat), and the presence read. A quiet
   * call neither writes `errorMsg` nor clears it, so a refusal on the strip is not said twice in the inspector.
   */
  async function call(fn, args, opts = {}) {
    const { data, error } = await supabase.rpc(fn, args)
    if (error) {
      if (!opts.quiet) errorMsg.value = planErrorMessage(error)
      throw error
    }
    if (!opts.quiet) errorMsg.value = ''
    return data
  }

  // Ownership of a badge while it is being written (081, 082). Everything it does is one of the plan_* doors.
  const locks = usePlanLocks(call)

  // Reads of the same rows are queued, one at a time, and each applies before the next starts. Overlapping reads do
  // not have to come back in the order they left: a save's own reload and a background one, or a plan switch against
  // a channel push, can land the older answer last and put yesterday's picture (or the previous plan's) on the screen.
  // A queue makes the last read started the last one applied, so the screen ends on the freshest answer, and a caller
  // that awaits a read never continues on top of an answer that was superseded.
  let planReads = Promise.resolve()
  let frameReads = Promise.resolve()

  /** Every plan of the event, newest first. */
  function loadPlans() {
    const run = planReads.then(() => call('plan_list', { p_event: eventId }))
    planReads = run.then(
      (rows) => {
        plans.value = rows || []
      },
      () => {}, // a failed read says so through `errorMsg`; the queue itself must stay alive
    )
    return run.then(() => plans.value)
  }

  async function loadGroups() {
    const { data } = await supabase
      .from('groups')
      .select('id, name, code, colour')
      .eq('event_id', eventId)
      .order('name')
    groups.value = data || []
  }

  /** The locked geography: polygons only, never editable from here. */
  async function loadZones() {
    zones.value = (await call('event_zones', { p_event: eventId })) || []
  }

  function loadFrames(opts = {}) {
    const id = plan.value ? plan.value.id : null
    if (!id) {
      frames.value = []
      return Promise.resolve([])
    }
    const run = frameReads.then(() => call('plan_frames_list', { p_plan: id }))
    frameReads = run.then(
      (rows) => {
        // The plan may have changed while this read was queued: another plan's frames are not this plan's answer.
        if (!plan.value || plan.value.id !== id) return
        // A background read must not re-bind the boxes under somebody's typing -- the caret's text is not committed
        // yet and a re-render can drop it. The answer is thrown away and asked for again once the field is let go.
        if (opts.quiet && typingOnBoard()) {
          liveAgain = true
          clearTimeout(liveTimer)
          liveTimer = setTimeout(runAdopt, 400)
          return
        }
        frames.value = (rows || []).map((row) => ({
          id: row.id,
          t_s: row.t_s,
          note: row.note,
          rev: row.rev,
          positions: row.positions || {},
        }))
      },
      () => {},
    )
    return run.then(() => frames.value)
  }

  /** Drop what is on screen without a read (the plan was deleted); a read already in flight must not put it back. */
  function clearFrames() {
    frames.value = []
  }

  async function openPlan(id) {
    loading.value = true
    try {
      plan.value = plans.value.find((p) => p.id === id) || null
      if (plan.value) await loadFrames()
    } finally {
      loading.value = false
    }
  }

  async function createPlan(name) {
    busy.value = true
    try {
      const row = await call('plan_save', { p_event: eventId, p_plan: { name: name || 'Untitled plan' } })
      await loadPlans()
      await openPlan(row.id)
      return row
    } finally {
      busy.value = false
    }
  }

  async function renamePlan(id, name) {
    busy.value = true
    try {
      const current = plans.value.find((p) => p.id === id)
      await call('plan_save', { p_event: eventId, p_plan: { id, name, rev: current ? current.rev : undefined } })
      await loadPlans()
      if (plan.value && plan.value.id === id) plan.value = plans.value.find((p) => p.id === id) || plan.value
    } finally {
      busy.value = false
    }
  }

  async function deletePlan(id) {
    busy.value = true
    try {
      await call('plan_delete', { p_plan: id })
      if (plan.value && plan.value.id === id) {
        plan.value = null
        clearFrames()
      }
      await loadPlans()
    } finally {
      busy.value = false
    }
  }

  /** Copy the plan, frames and positions included — the starting point for editing a running event. */
  async function forkPlan(id) {
    busy.value = true
    try {
      const row = await call('plan_fork', { p_plan: id })
      await loadPlans()
      await openPlan(row.id)
      return row
    } finally {
      busy.value = false
    }
  }

  /**
   * Publish the plan, naming the revision this screen is showing (step 18). The database refuses a stale one with
   * PT409: two planners cannot both announce a plan from the same picture, so the one who is behind is told so
   * instead of silently overruling the one who is not.
   */
  async function publishPlan(id, rev) {
    busy.value = true
    try {
      const row = await call('plan_publish', { p_plan: id, p_plan_rev: rev })
      await loadPlans()
      if (plan.value && plan.value.id === id) plan.value = plans.value.find((p) => p.id === id) || plan.value
      return row
    } finally {
      busy.value = false
    }
  }

  /**
   * Write one frame: its time and its note, and -- only when the frame does not exist yet -- its first badges.
   *
   * 082 split the write. A frame that is already in the plan refuses a `positions` payload outright, because the
   * payload was the bug: it carried every badge on the frame as the page had last read them, so one planner's drag
   * put everybody else's back. Badges of a frame that already stands are written by placeCells() below, one cell at
   * a time and against a hold on it. A frame this call creates still takes its first map, because a moment that did
   * not exist a statement ago cannot have somebody else's badge on it (that is also how plan_import() writes a
   * sheet, and how undo puts a deleted frame back).
   *
   * A frame this page can see also has its MOMENT held for the length of the write: the note and the time are one
   * resource, and two people editing the same moment are refused with a sentence rather than a stale-revision
   * error. A frame it cannot see is a restore (041) -- there is nothing to hold.
   */
  async function saveFrame(frame) {
    const payload = { t_s: frame.t_s }
    if (frame.id) payload.id = frame.id
    if (frame.rev != null) payload.rev = frame.rev
    if (frame.note !== undefined) payload.note = frame.note
    if (frame.positions !== undefined) payload.positions = frame.positions
    const known = Boolean(frame.id) && frames.value.some((f) => f.id === frame.id)
    busy.value = true
    try {
      const row = known
        ? await locks.withMoment(plan.value.id, frame.id, () =>
            call('frame_save', { p_plan: plan.value.id, p_frame: payload, p_session: locks.session() }),
          )
        : await call('frame_save', { p_plan: plan.value.id, p_frame: payload })
      await loadFrames()
      await loadPlans()
      return row
    } catch (error) {
      // A stale revision means my copy of the plan is out of date; pull the truth back in.
      if (error && error.code === P409) await loadFrames()
      throw error
    } finally {
      busy.value = false
    }
  }

  /**
   * Write badges at one frame: `map` is `groupId -> { lat, lng, state?, verify? }` -- the shape the board already
   * builds for a drag, a placement, an off-site toggle and a bulk state change.
   *
   * One call for the whole map because a gesture is one statement: a drag with three badges ticked writes all
   * three or none, and a refusal names whoever has the first one in the way. The rows in the payload are the only
   * rows touched (082), so a colleague's badge at the same moment is not carried along and cannot be lost.
   *
   * The hold is taken here rather than by the caller: a write that is not held is refused by the database, and
   * making the two a single call is what keeps them in step.
   */
  async function placeCells(frameId, map, options = {}) {
    if (!plan.value || !frameId) return 0
    const cells = Object.entries(map || {}).map(([group, at]) => ({
      frame: frameId,
      group,
      lat: at.lat,
      lng: at.lng,
      ...(at.state ? { state: at.state } : {}),
      ...(at.verify ? { verify: at.verify } : {}),
    }))
    if (!cells.length) return 0
    busy.value = true
    try {
      const written = await locks.place(plan.value.id, cells, options)
      await loadFrames()
      await loadPlans()
      return written
    } finally {
      busy.value = false
    }
  }

  /**
   * Hold badges for a gesture -- the length of a drag, not one write. `cells` is `[{ frame, group }]`: a hold is
   * about a cell's identity, and the lat/lng belongs to the write that comes later. Nothing is written here and no
   * frame is re-read: a refusal is the caller's to present, and a hold that is merely held changes nothing on screen.
   *
   * The heartbeat (2 s) belongs to the hold, so a caller that forgets to let go does not keep a badge for ever: the
   * page still stops refreshing it 12 s after it stops being true, and the idle release is the board's own rule.
   */
  async function holdCells(cells, options = {}) {
    if (!plan.value || !cells || !cells.length) return 0
    await locks.hold(plan.value.id, cells, options)
    return cells.length
  }

  /** Let go of badges held for a gesture. Best effort: a hold that is not let go of lapses on its own (081). */
  async function releaseCells(cells) {
    if (!plan.value || !cells || !cells.length) return
    await locks.letGo(plan.value.id, cells)
  }

  /** Who is editing what on the open plan (081's plan_lock_holders). Quiet: a presence read that fails says nothing. */
  async function lockHolders() {
    if (!plan.value) return []
    return locks.holders(plan.value.id)
  }

  /** Everything this page is holding on the open plan, given up at once -- on a hidden tab, a page unload, a plan switch. */
  async function releaseAllHolds() {
    await locks.releaseAll(plan.value ? plan.value.id : null)
  }

  /** Tell the page when a badge it believed it held is somebody else's (the heartbeat found out). */
  function onHoldLost(fn) {
    locks.onLost(fn)
  }

  /** Take badges off the plan -- the only way a position disappears (082), and a write like any other. */
  async function unplaceCells(frameId, groupIds) {
    if (!plan.value || !frameId) return 0
    const cells = (groupIds || []).map((group) => ({ frame: frameId, group }))
    if (!cells.length) return 0
    busy.value = true
    try {
      const removed = await locks.unplace(plan.value.id, cells)
      await loadFrames()
      await loadPlans()
      return removed
    } finally {
      busy.value = false
    }
  }

  async function moveFrame(id, t_s, rev) {
    busy.value = true
    try {
      await call('frame_move', { p_id: id, p_t_s: t_s, p_rev: rev })
      await loadFrames()
      await loadPlans()
    } catch (error) {
      if (error && error.code === P409) await loadFrames()
      throw error
    } finally {
      busy.value = false
    }
  }

  async function deleteFrame(id, rev) {
    busy.value = true
    try {
      await call('frame_delete', { p_id: id, p_rev: rev })
      await loadFrames()
      await loadPlans()
    } finally {
      busy.value = false
    }
  }

  /**
   * Push a stretch of frames later (or earlier) by `delta_s`, in one call whatever the number of frames. Name both
   * ends and only the frames between them move; pass `to_s` null and everything at or after `from_s` travels, which
   * is the "we are five minutes behind" move. The board always names both ends, because a selection is a stretch.
   */
  async function shiftFrom(from_s, delta_s, to_s = null) {
    busy.value = true
    try {
      const moved = await call('frame_shift', {
        p_plan: plan.value.id,
        p_from_s: from_s,
        p_delta_s: delta_s,
        p_to_s: to_s,
      })
      await loadFrames()
      await loadPlans()
      return moved
    } finally {
      busy.value = false
    }
  }

  /**
   * Space one impossible stretch out: the frames that split the distance between `fromId` and `toId` into legal
   * steps, for the named groups, are worked out and written by the database in one call (042). Doing this from
   * here would be one save per generated frame, each on a rev the one before it had bumped, and the seconds have
   * to be merged across groups -- which the database does for the groups it was given.
   */
  async function fillGap(fromId, toId, groupIds) {
    busy.value = true
    try {
      const rows = await call('frames_fill', {
        p_plan: plan.value.id,
        p_from: fromId,
        p_to: toId,
        p_groups: groupIds && groupIds.length ? groupIds : null,
      })
      await loadFrames()
      await loadPlans()
      return Array.isArray(rows) ? rows[0] : rows
    } finally {
      busy.value = false
    }
  }

  /**
   * Hold the named groups where they already stand, and say so again `seconds` later: the strip's "hold one group"
   * (045). One call for the whole set, and a partial write -- only those groups gain a row at the later moment, so a
   * frame that already states somebody else keeps them. No group list means everybody standing at this frame.
   */
  async function holdFrame(frameId, seconds, groupIds) {
    busy.value = true
    try {
      const rows = await call('frame_hold', {
        p_plan: plan.value.id,
        p_frame: frameId,
        p_seconds: seconds,
        p_groups: groupIds && groupIds.length ? groupIds : null,
      })
      await loadFrames()
      await loadPlans()
      return Array.isArray(rows) ? rows[0] : rows
    } finally {
      busy.value = false
    }
  }

  /**
   * Set the verification flag on positions that already exist, for a set of frames and groups, in ONE call (047).
   *
   * The batch is the point: the same edit through frame_save would be one save per frame, each followed by a reload,
   * each needing that frame's live revision. It patches rows only -- a frame that carries a group forward has no
   * position of its own to confirm -- and the answer counts what was left alone, so the board can say so instead of
   * pretending every frame was written.
   */
  async function setVerify(frameIds, groupIds, verify) {
    busy.value = true
    try {
      const rows = await call('frame_set_verify', {
        p_plan: plan.value.id,
        p_frames: frameIds,
        p_groups: groupIds && groupIds.length ? groupIds : null,
        p_verify: verify,
      })
      await loadFrames()
      await loadPlans()
      return (Array.isArray(rows) ? rows[0] : rows) || { frames_touched: 0, positions_set: 0, positions_skipped: 0 }
    } finally {
      busy.value = false
    }
  }

  /**
   * Replace every frame of a plan with a sheet, in ONE call and one transaction (059).
   *
   * A sheet is the whole plan, so this cannot be a loop of saveFrame: a refusal at the ninth frame would leave eight
   * frames of somebody else's plan on the screen. The database deletes and rewrites in one transaction, and answers
   * the two counts the board reports. It also refuses a plan that has already recorded what actually happened -- the
   * marks hang off the frames and would cascade away -- so a caller shows the server's sentence rather than guessing
   * at it (step 23's confirmation happens before the call, and the refusal can only arrive after it).
   */
  async function importFrames(planId, frameList) {
    busy.value = true
    try {
      const summary = await call('plan_import', { p_plan: planId, p_frames: frameList })
      await loadFrames()
      await loadPlans()
      return summary || { frames: 0, positions: 0 }
    } finally {
      busy.value = false
    }
  }

  /**
   * The plan as the database sees it: the 25 m rule, the locked polygons, and pace. The board derives its own 25 m
   * walk so a drag can go red before the write lands; only this call knows about the polygons, so a walk through a
   * no-go zone is only ever known here. A failed second opinion returns nothing rather than an error banner -- the
   * board's own red is still true, and the publish gate is still the authority.
   */
  async function check() {
    if (!plan.value) return []
    try {
      const { data, error } = await supabase.rpc('plan_check', { p_plan: plan.value.id })
      return error ? [] : data || []
    } catch {
      return []
    }
  }

  /**
   * The running timetable of one session, in one call (051): a row per group per frame with the plan's own clock
   * time, what the clock says about it, the frame's note and the plan's name, and the revision the session follows.
   * Deliberately quiet -- it is asked every half minute beside a plan somebody is drawing, or on a member's schedule,
   * and a failed read must not put an error over the screen. A caller that wants the failure gets the throw.
   *
   * `at` is the instant to judge by (050's p_at), and it is only passed when the screen is *not* speaking about now:
   * a closed show's timetable is read at its end time, so what is on screen is how the night closed. Null means now,
   * which is the database's own default.
   */
  // Through the shared reader since 2 Nov: the whole timetable once per published version, the marks between
  // (lib/timetableReader.js). The rows come back exactly as session_timetable answers them.
  async function readTimetable(sessionId, at = null) {
    return readTimetableShared(sessionId, at)
  }

  // ---------- the plan's log (step 22) ----------

  /**
   * The plan's messages and its timeline changes, newest first. Ops staff get the tally and who is still to ack;
   * everyone else gets only the rows addressed to them, with their own ack instant (the database decides that, not
   * this call). Deliberately quiet like the timetable read: it is asked beside a schedule and must not put an error
   * over the screen.
   */
  async function readLog(planId, limit = 10) {
    if (!planId) return []
    const { data, error } = await supabase.rpc('plan_log_list', { p_plan: planId, p_limit: limit })
    if (error) throw error
    return data || []
  }

  /** One tap: "I have it". Answers the instant the database wrote -- the first one, if it was already acked. */
  async function ackLog(logId) {
    const { data, error } = await supabase.rpc('plan_log_ack', { p_log: logId })
    if (error) throw error
    return data
  }

  /**
   * One press from the group's IC: "we are here" at this moment. `progress_mark` is the door (050), and since 064 it
   * refuses a moment another person already recorded -- unless the caller is the event's ops -- with a sentence
   * naming who and when. The refusal is thrown like any other: the screen shows its words and keeps them (a poll
   * does not get to wipe a write's error).
   */
  async function markProgress(sessionId, frameId, groupId, state = 'arrived') {
    if (!sessionId) return null
    const { data, error } = await supabase.rpc('progress_mark', {
      p_session: sessionId,
      p_frame: frameId,
      p_group: groupId,
      p_state: state,
    })
    forgetTimetable(sessionId) // the next read asks the database, so the press shows at once
    if (error) throw error
    return data
  }

  // ---------- live updates: another tab's change (step 19) ----------

  /**
   * Bumped by every read this file makes because of somebody else's write. A screen that draws from `frames` can
   * watch it to let go of what the read has taken away (an open frame somebody deleted) without reading anything
   * itself: the read has already happened here, and the answer is in the refs.
   */
  const changeTick = ref(0)

  const LIVE_DEBOUNCE_MS = 400
  let liveTimer = null
  let livePending = null // the burst's payload that names the plan on screen, if one did
  let liveRunning = false
  let liveAgain = false
  let livePaused = false // a pointer is down: the screen belongs to the gesture (see pauseLive)
  let livePauseTimer = null

  /**
   * Hold background reads while a gesture owns the board -- a badge being dragged, the bar being swept, a frame being
   * moved. A read that lands then replaces the frames and redraws the markers, and the gesture dies with the marker
   * under the hand. Nothing is dropped: the change is read as soon as the hand is up, and a pointer that never lifts
   * (a lost capture) releases after five seconds rather than silencing the screen for ever.
   */
  function pauseLive(on) {
    livePaused = !!on
    clearTimeout(livePauseTimer)
    if (on) {
      livePauseTimer = setTimeout(() => pauseLive(false), 5000)
      return
    }
    if (livePending || liveAgain) {
      clearTimeout(liveTimer)
      liveTimer = setTimeout(runAdopt, 0)
    }
  }

  /**
   * A field on the board has the caret. A background read re-binds the note and time boxes to the frame's own values,
   * so a reload under somebody's typing deletes what they have typed but not yet committed -- and the commit then
   * writes the old value. The read waits while the caret is there.
   */
  function typingOnBoard() {
    if (typeof document === 'undefined') return false
    const el = document.activeElement
    if (!el || !el.closest || !el.closest('.pv-board')) return false
    if (el.tagName === 'TEXTAREA') return true
    // A select or a tick box is not typing: the picker keeps the focus after a plan is chosen, and that must not stop
    // the screen from hearing about the plan it just opened.
    return el.tagName === 'INPUT' && /^(text|search|number|email|password|tel|url)$/i.test(el.type || 'text')
  }

  /**
   * Fold one `plans` change into what is on screen. Two facts travel on the same table (migration 055): the plan's
   * revision, and everything else about it. A revision that moved is a publish (or a rename, finding 58) and is the
   * live strip's decision to offer -- reloading the frames behind it would draw one revision's timetable under
   * another's number and silence the warning that says so (steps 15 and 18). Everything else is content, and content
   * is re-read: the plan list because a plan may have been created, archived or thrown away, the frames because that
   * is the timetable.
   *
   * `resync` is the reconnection case: no row to name the change, so the fresh plan decides whether the revision
   * moved while the connection was down.
   */
  async function adopt(payload, resync = false) {
    const row = payload ? payload.new || payload.old : null
    const openId = plan.value ? plan.value.id : null
    const deleted = !!payload && payload.eventType === 'DELETE'
    await loadPlans()
    // The page may have opened another plan while that read was in flight. This change is about a plan that is no
    // longer on screen; switching back to it would undo the planner's own click, so only the list is taken.
    if ((plan.value ? plan.value.id : null) !== openId) {
      changeTick.value++
      return
    }
    // A gesture owns the screen while it lasts: re-reading the frames under a hand that is moving a badge redraws the
    // markers and the drag dies with them. A write of our own is the same problem the other way round: its answer is
    // already on its way, and a read started now can overtake it and put the pre-write picture back. Both are read
    // again when the hand is up and the write has landed.
    if (livePaused || busy.value || typingOnBoard()) {
      liveAgain = true
      return
    }
    const fresh = openId ? plans.value.find((p) => p.id === openId) : null
    if (openId && !fresh) {
      // The plan on screen is gone: another tab threw it away. There is no picture left to keep.
      plan.value = null
      clearFrames()
      changeTick.value++
      return
    }
    // The revision to judge by is the one the read answered, not the one the payload carried. A publish can commit
    // between a frame write's payload and this read, and the payload then says "revision 1, content changed" about a
    // plan that is already at 2: adopting the read row here would move the strip's own number to 2 while the frames
    // on screen are still revision 1's, and the warning that exists for exactly that would never be shown.
    const seen = resync || (row && row.id === openId) ? fresh : null
    const moved = !!seen && !deleted && typeof seen.rev === 'number' && plan.value && seen.rev !== plan.value.rev
    if (moved) {
      // Leave the page on the revision it is drawing; the strip names the newer one and offers the catch-up.
      changeTick.value++
      return
    }
    if (fresh) plan.value = fresh
    if (openId && (resync || (row && row.id === openId))) await loadFrames({ quiet: true })
    changeTick.value++
  }

  /** Queue a read for the burst of rows one save writes, keeping the payload that names the plan on screen. */
  function onLiveChange(payload) {
    staleTimetables() // a plan changed: every timetable copy checks its version at its next read
    const row = payload ? payload.new || payload.old : null
    const openId = plan.value ? plan.value.id : null
    if (!livePending || !openId || (row && row.id === openId)) livePending = payload
    clearTimeout(liveTimer)
    liveTimer = setTimeout(runAdopt, LIVE_DEBOUNCE_MS)
  }

  function runAdopt() {
    clearTimeout(liveTimer)
    liveTimer = null
    // Our own write's echo: its save has already read the plan back, and reading again while it is still writing
    // would race that read for nothing. A gesture is the other reason to wait.
    if (busy.value || livePaused || typingOnBoard()) {
      liveTimer = setTimeout(runAdopt, 300)
      return
    }
    if (liveRunning) {
      // The read in flight started before this change committed; ask once more when it is done.
      liveAgain = true
      return
    }
    const payload = livePending
    livePending = null
    liveRunning = true
    adopt(payload, payload == null)
      .catch(() => {
        // A change that cannot be read back is not a change worth putting over the screen; the next one asks again.
      })
      .finally(() => {
        liveRunning = false
        if (liveAgain) {
          liveAgain = false
          liveTimer = setTimeout(runAdopt, 0)
        }
      })
  }

  // One table, one channel, one filter: this event's plans. The plan row is the change log (055), so a frame, a
  // position, a rename, a publish, a new plan and a deleted plan all arrive here and nowhere else.
  const liveChannel = supabase
    .channel('event-plans-' + eventId + '-' + Math.random().toString(36).slice(2)) // unique name (see useEventData.js)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'plans', filter: 'event_id=eq.' + eventId }, onLiveChange)
    .subscribe((status) => {
      // The first SUBSCRIBED cannot have missed anything; a reconnection can. Reading back once costs one list and,
      // if a plan is open, one frames read -- and it is the only way to learn what happened while the socket was down.
      if (status === 'SUBSCRIBED') onLiveChange(null)
    })

  // A page that is going away, or a tab that has been hidden, is not working on anything: its holds are given up
  // rather than waited out. `visibilitychange` fires first and reliably (a phone switching apps, a tab switch);
  // `pagehide` covers a close, a reload and a back navigation. Both are best effort -- every hold also expires on its
  // own after 12 s (081) -- and both are silent, because this is housekeeping rather than a change the planner made.
  function letEverythingGo() {
    locks.releaseAll(plan.value ? plan.value.id : null)
  }
  function onVisibility() {
    if (document.visibilityState === 'hidden') letEverythingGo()
  }
  if (typeof window !== 'undefined') {
    window.addEventListener('pagehide', letEverythingGo)
    document.addEventListener('visibilitychange', onVisibility)
  }

  onScopeDispose(() => {
    if (typeof window !== 'undefined') {
      window.removeEventListener('pagehide', letEverythingGo)
      document.removeEventListener('visibilitychange', onVisibility)
    }
    locks.dispose()
    clearTimeout(liveTimer)
    clearTimeout(livePauseTimer)
    supabase.removeChannel(liveChannel)
  })

  const livePlan = computed(() => plans.value.find((p) => p.status === 'live') || null)

  return {
    plans,
    plan,
    frames,
    groups,
    zones,
    loading,
    busy,
    errorMsg,
    livePlan,
    changeTick,
    pauseLive,
    loadPlans,
    loadGroups,
    loadZones,
    loadFrames,
    openPlan,
    createPlan,
    renamePlan,
    deletePlan,
    forkPlan,
    publishPlan,
    saveFrame,
    placeCells,
    unplaceCells,
    holdCells,
    releaseCells,
    lockHolders,
    releaseAllHolds,
    onHoldLost,
    moveFrame,
    deleteFrame,
    shiftFrom,
    fillGap,
    holdFrame,
    setVerify,
    importFrames,
    check,
    readTimetable,
    readLog,
    ackLog,
    markProgress,
  }
}

