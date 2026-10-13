// A bounded undo/redo stack of snapshots.
//
// The bench keeps two: the ring being drawn, and the shape of the area whose dots are being
// dragged. They are separate stacks because the two are never open at once (the mode picks
// one) and a snapshot of one means nothing to the other.
//
// Snapshots are whole VALUES, not diffs. A ring is at most 200 points, so copying one costs
// nothing next to the map work around it, and it removes the entire class of bug where an
// inverse operation does not quite undo its forward one.
//
// Nothing here is persisted anywhere: the history lives as long as the tab does. It is a
// drawing aid, not a document history -- what the planner keeps is what the database holds,
// and that is written on every lock.
import { computed, ref } from 'vue'

export function useHistory(limit = 50) {
  const past = ref([])
  const future = ref([])

  const canUndo = computed(() => past.value.length > 0)
  const canRedo = computed(() => future.value.length > 0)

  // Remember the state as it is BEFORE a change. Recording drops the redo stack: once the
  // planner has drawn something new, the states they had stepped back past are no longer on
  // the way to anywhere.
  function record(snapshot) {
    past.value.push(snapshot)
    // Oldest out first. The limit is what stops a long session holding every ring it ever had.
    while (past.value.length > limit) past.value.shift()
    future.value = []
  }

  // Step back one state. `current` is the state now, and becomes the redo step. Returns the
  // state to restore, or null when there is nothing to go back to.
  function undo(current) {
    if (past.value.length === 0) return null
    future.value.push(current)
    return past.value.pop()
  }

  // Step forward again, undoing an undo. Returns the state to restore, or null.
  function redo(current) {
    if (future.value.length === 0) return null
    past.value.push(current)
    while (past.value.length > limit) past.value.shift()
    return future.value.pop()
  }

  // Everything forgotten. Used when the thing being edited changes, because a different shape
  // has no history on this stack.
  function reset() {
    past.value = []
    future.value = []
  }

  return { canUndo, canRedo, record, undo, redo, reset }
}
