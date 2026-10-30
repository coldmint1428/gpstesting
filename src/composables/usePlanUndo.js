// usePlanUndo — Ctrl+Z for the plan: an inverse-command stack.
//
// WHAT IS ON THE STACK. One command per edit a planner made on purpose, recorded AFTER that edit has been written:
// moving a badge (one group or several), a frame's time, a frame's note, taking a group off site, confirming a
// position, pushing a stretch, holding a group, filling a stretch, adding or pasting a frame, deleting a frame,
// and renaming the plan. Nothing else: a selection, a group tick, a zoom and a reload change the screen, not the
// plan, and Ctrl+Z must not spend itself on them.
//
// A COMMAND IS DATA, NOT A CLOSURE. Every command is a small object -- `{ kind, label, ... }` -- holding the values
// that have to be written back, and one `apply()` knows how to write each kind in either direction ('back' for
// undo, 'again' for redo). Two consequences, and both are the point of the step:
//
//   * A command holds NO revision. The inverse re-reads the frame's rev from the plan on screen when it runs, so
//     undoing is a write under exactly the rules every other write follows: if somebody else got there first the
//     answer is still PT409 and "reopen the plan", never a silent overwrite of their edit. A command also holds no
//     frame *object* -- only its id and the values -- for the same reason: the frame the inverse writes to is the
//     one the plan has now.
//
//   * Being data, the stack survives a reload inside the tab (sessionStorage, one key per plan). That is what
//     makes the Done-when literal: drag 40 m, Ctrl+Z, reload, Ctrl+Y puts the 40 m back. It survives a reload and
//     nothing else -- not a publish, not a plan switch, and not a new tab, because a redo must never be able to
//     resurrect a pre-publish edit inside a published plan.
//
// AN UNDO IS NOT AN EDIT. Stepping back moves the command from the undo stack to the redo stack and touches
// nothing else, so an undo that is itself undone cannot push the same command twice; any NEW edit drops the redo
// stack, exactly as every editor does. Both stacks are cleared at a publish boundary and when the open plan
// changes, since a command that names another plan's frames means nothing here.
//
// A FAILED INVERSE KEEPS ITS COMMAND. The stack pops only after the write has landed. An undo refused for a
// collision ("There is already a frame at +2:00.") therefore leaves the planner exactly where they were, with the
// sentence saying why, and the key works again once the frame is out of the way -- rather than quietly swallowing
// the one thing that could have put the plan back.
import { computed, ref, watch } from 'vue'
import { planErrorMessage } from './usePlan'
import { toast } from './useNotify'

/**
 * How many edits one plan remembers. A drag is one command, so forty is a working session; the stack is a way back
 * from a slip, not a document history (step 18's versions are the history).
 */
export const UNDO_LIMIT = 40

const STORE_PREFIX = 'planUndo:'

export function usePlanUndo({ plan, frames, api }) {
  const past = ref([])
  const future = ref([])

  const canUndo = computed(() => past.value.length > 0)
  const canRedo = computed(() => future.value.length > 0)

  // ---------- where the stack lives ----------

  function storeKey(id) {
    return `${STORE_PREFIX}${id}`
  }

  function read(id) {
    if (!id) return { past: [], future: [] }
    try {
      const saved = JSON.parse(sessionStorage.getItem(storeKey(id)) || 'null')
      return {
        past: Array.isArray(saved?.past) ? saved.past : [],
        future: Array.isArray(saved?.future) ? saved.future : [],
      }
    } catch {
      return { past: [], future: [] }
    }
  }

  function persist() {
    const id = plan.value ? plan.value.id : null
    if (!id) return
    try {
      if (!past.value.length && !future.value.length) sessionStorage.removeItem(storeKey(id))
      else sessionStorage.setItem(storeKey(id), JSON.stringify({ past: past.value, future: future.value }))
    } catch {
      // A full or disabled store costs the planner the stack across a reload and nothing more: the stack in memory
      // is still the one the keys act on, so undo keeps working in this tab.
    }
  }

  // One stack per plan: opening another plan opens its own memory, and the plan this board was showing keeps its
  // own. (A command names plan frames by id, so it is only ever safe to run against the plan it came from.)
  watch(
    () => (plan.value ? plan.value.id : null),
    (id) => {
      const saved = read(id)
      past.value = saved.past
      future.value = saved.future
    },
    { immediate: true },
  )

  // ---------- recording ----------

  function record(command) {
    past.value = [...past.value, command].slice(-UNDO_LIMIT)
    future.value = []
    persist()
  }

  /**
   * Drop everything. A publish boundary, a deleted plan, or a fork that put a different plan on screen. `id` is for
   * the caller that has just deleted the plan -- the plan itself is not readable any more, and the stored copy of the
   * stack must go with the commands it describes.
   */
  function clear(id = plan.value ? plan.value.id : null) {
    past.value = []
    future.value = []
    if (id) {
      try {
        sessionStorage.removeItem(storeKey(id))
      } catch {
        // nothing to undo about a store that is not there
      }
    }
  }

  // ---------- the writes an inverse is allowed to make ----------
  // All of them are the same calls the forward edit made. That is deliberate: undo is not a second write path with
  // its own rules, it is the same path with the other set of values.

  function liveFrame(id) {
    return (frames.value || []).find((f) => f.id === id) || null
  }

  function missing() {
    return new Error('That frame is no longer in the plan, so there is nothing to put back.')
  }

  async function writePositions(frameId, positions) {
    const frame = liveFrame(frameId)
    if (!frame) throw missing()
    await api.saveFrame({ id: frame.id, t_s: frame.t_s, rev: frame.rev, positions: positions || {} })
  }

  async function writeNote(frameId, note) {
    const frame = liveFrame(frameId)
    if (!frame) throw missing()
    await api.saveFrame({ id: frame.id, t_s: frame.t_s, rev: frame.rev, note })
  }

  async function moveFrameTo(frameId, t_s) {
    const frame = liveFrame(frameId)
    if (!frame) throw missing()
    if (frame.t_s === t_s) return
    await api.moveFrame(frame.id, t_s, frame.rev)
  }

  async function removeFrame(id) {
    const frame = liveFrame(id)
    if (!frame) return // already gone: there is nothing to take away
    await api.deleteFrame(frame.id, frame.rev)
  }

  async function removeFrames(list) {
    // Latest first, so a strip being emptied one frame at a time never has to skip over a neighbour.
    for (const copy of [...list].sort((a, b) => b.t_s - a.t_s)) await removeFrame(copy.id)
  }

  async function restoreFrames(list) {
    // 041's rule, and the reason the id is on the command: a restored frame is the SAME frame to everything that
    // points at it (progress in step 14, fork origins in step 17), not a new frame that happens to stand at the
    // same moment. The server refuses an id owned by another plan, so this can never move one between plans.
    for (const copy of [...list].sort((a, b) => a.t_s - b.t_s)) {
      const payload = { id: copy.id, t_s: copy.t_s }
      if (copy.note) payload.note = copy.note
      const positions = copy.positions || {}
      // No `positions` key at all when the frame had none: sending `{}` would say "this frame states nobody", which
      // is a statement, and on a frame that already exists it deletes rows.
      if (Object.keys(positions).length) payload.positions = positions
      await api.saveFrame(payload)
    }
  }

  /**
   * Put the confirmation flags back exactly as they were. `pairs` is a list of `{frameId, groupId, verify}` -- one
   * per position the edit touched -- because the function that writes a flag sets ONE value for a grid of frames and
   * groups, while the values being restored may differ per frame and per group.
   *
   * So the pairs are batched by (value, the set of groups it belongs to): a stretch confirmed by hand is one call,
   * and a frame holding two confidences is two. Within one batch the grid is exactly the pairs, so no position is
   * given a value it did not have.
   */
  async function writeVerify(pairs) {
    if (!pairs || !pairs.length) return
    const perFrame = new Map()
    for (const pair of pairs) {
      if (!perFrame.has(pair.frameId)) perFrame.set(pair.frameId, new Map())
      const byValue = perFrame.get(pair.frameId)
      if (!byValue.has(pair.verify)) byValue.set(pair.verify, new Set())
      byValue.get(pair.verify).add(pair.groupId)
    }
    const batches = new Map()
    for (const [frameId, byValue] of perFrame) {
      for (const [value, groupIds] of byValue) {
        const groups = [...groupIds].sort()
        const key = `${value}|${groups.join(',')}`
        if (!batches.has(key)) batches.set(key, { value, groupIds: groups, frameIds: [] })
        batches.get(key).frameIds.push(frameId)
      }
    }
    for (const batch of batches.values()) await api.setVerify(batch.frameIds, batch.groupIds, batch.value)
  }

  /**
   * Put a pushed stretch back. One call when the moved range still holds exactly the frames the push moved -- the
   * shape of the strip comes back whole, in one write.
   *
   * It may not: 044 allows a chunk to be pushed *past* a frame that stays put, and after such a push that staying
   * frame can sit inside the range the chunk now occupies. Shifting that range back would drag the newcomer as well,
   * so in that case every frame goes home by its own id and its own time, oldest first (latest first when the push
   * went backwards), which is the same thing without the guesswork.
   */
  async function shiftBack(command) {
    const before = command.frames || []
    if (!before.length) return
    const now = frames.value || []
    const moved = before.map((row) => now.find((f) => f.id === row.id)).filter(Boolean)
    if (!moved.length) return
    const lo = command.from_s + command.delta
    const hi = command.to_s + command.delta
    const inRange = now.filter((f) => f.t_s >= lo && f.t_s <= hi)
    const exact = inRange.length === moved.length && moved.every((frame) => inRange.some((f) => f.id === frame.id))
    if (exact) {
      await api.shiftFrom(lo, -command.delta, hi)
      return
    }
    const order = [...before].sort((a, b) => (command.delta > 0 ? a.t_s - b.t_s : b.t_s - a.t_s))
    for (const row of order) {
      // Re-checked each time: every move reloads the plan, so the next frame's rev and time are the fresh ones.
      if ((frames.value || []).some((f) => f.id === row.id)) await moveFrameTo(row.id, row.t_s)
    }
  }

  async function shiftAgain(command) {
    await api.shiftFrom(command.from_s, command.delta, command.to_s)
  }

  async function renamePlan(name) {
    if (!plan.value) return
    await api.renamePlan(plan.value.id, name)
  }

  /** One command, in one direction. The single place that knows how to write each kind back. */
  async function apply(command, direction) {
    const back = direction === 'back'
    switch (command.kind) {
      case 'positions':
        return writePositions(command.frameId, back ? command.before : command.after)
      case 'note':
        return writeNote(command.frameId, back ? command.before : command.after)
      case 'time':
        return moveFrameTo(command.frameId, back ? command.before_s : command.after_s)
      case 'verify':
        return writeVerify(back ? command.before : command.after)
      case 'shift':
        return back ? shiftBack(command) : shiftAgain(command)
      case 'create':
        return back ? removeFrame(command.frame.id) : restoreFrames([command.frame])
      case 'delete':
        return back ? restoreFrames([command.frame]) : removeFrame(command.frame.id)
      case 'hold':
        // A hold either added a frame (undo = take it away again) or wrote rows into one that already stood
        // (undo = put that frame's own map back). Both directions use the frame the hold named.
        if (back) return command.added ? removeFrame(command.frame.id) : writePositions(command.frameId, command.before)
        return command.added ? restoreFrames([command.frame]) : writePositions(command.frameId, command.after)
      case 'fill':
        return back ? removeFrames(command.added) : restoreFrames(command.added)
      case 'planName':
        return renamePlan(back ? command.before : command.after)
      default:
        throw new Error(`There is no way to write "${command.kind}" back.`)
    }
  }

  // ---------- stepping ----------

  async function undo() {
    const command = past.value[past.value.length - 1]
    if (!command) {
      toast('Nothing to undo.', 'warning', 2600)
      return null
    }
    try {
      await apply(command, 'back')
    } catch (error) {
      toast(planErrorMessage(error), 'danger', 6000)
      return null
    }
    past.value = past.value.slice(0, -1)
    future.value = [...future.value, command]
    persist()
    toast(`Undid — ${command.label}.`, 'success', 3200)
    return command
  }

  async function redo() {
    const command = future.value[future.value.length - 1]
    if (!command) {
      toast('Nothing to redo.', 'warning', 2600)
      return null
    }
    try {
      await apply(command, 'again')
    } catch (error) {
      toast(planErrorMessage(error), 'danger', 6000)
      return null
    }
    future.value = future.value.slice(0, -1)
    past.value = [...past.value, command].slice(-UNDO_LIMIT)
    persist()
    toast(`Redid — ${command.label}.`, 'success', 3200)
    return command
  }

  /** The frame an undo or a redo left the planner looking at, so the board can open it (or let it go). */
  function focusOf(command) {
    if (!command) return null
    if (command.frame && command.frame.id) return command.frame.id
    if (command.frameId) return command.frameId
    if (command.added && command.added.length) return command.added[0].id
    return null
  }

  // ---------- what the board records ----------
  // Each of these is one line, and the board calls it after the write has landed. The labels are sentences' worth of
  // context, because "Undid — moved Gate Crew at +1:00." has to say what happened in terms the planner recognises.

  /** A badge drag, an off-site toggle, a bulk state change: one frame's whole position map, before and after. */
  function positions(frameId, before, after, label) {
    record({ kind: 'positions', frameId, before, after, label })
  }

  function note(frameId, before, after, label) {
    record({ kind: 'note', frameId, before, after, label })
  }

  function time(frameId, before_s, after_s, label) {
    record({ kind: 'time', frameId, before_s, after_s, label })
  }

  /** `pairs` is `[{frameId, groupId, verify}]`: the confidences the edit was applied to, as they stood before it. */
  function verify(pairs, after, label) {
    record({ kind: 'verify', before: pairs, after, label })
  }

  function shift({ from_s, to_s, delta, frames: moved }, label) {
    record({ kind: 'shift', from_s, to_s, delta, frames: moved, label })
  }

  function created(copy, label) {
    record({ kind: 'create', frame: copy, label })
  }

  function deleted(copy, label) {
    record({ kind: 'delete', frame: copy, label })
  }

  function held({ frameId, added, before, after, frame }, label) {
    record({ kind: 'hold', frameId, added, before, after, frame, label })
  }

  function filled(added, label) {
    record({ kind: 'fill', added, label })
  }

  function planName(before, after, label) {
    record({ kind: 'planName', before, after, label })
  }

  return {
    canUndo,
    canRedo,
    undo,
    redo,
    clear,
    focusOf,
    positions,
    note,
    time,
    verify,
    shift,
    created,
    deleted,
    held,
    filled,
    planName,
  }
}
