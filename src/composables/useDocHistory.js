// One undo stack for the WHOLE canvas.
//
// An earlier version kept a stack per thing being edited -- one for the ring being drawn, one
// for the shape of the area whose dots were being dragged -- and reset each of them whenever
// the planner looked somewhere else. That read as "undo only works while I am holding the
// thing", which is not how any drawing tool behaves: click away and back, and the steps taken
// were gone. This replaces all of it with one timeline of the whole document, so Undo reaches
// the last thing that happened whatever it was, and wherever the planner has since clicked.
// Adding an area, deleting a floor plan, dragging a dot, moving or turning a plan, renaming and
// retyping are all steps on the same stack.
//
// HOW A STEP IS STORED. Snapshot, not diff. The document is small once the images are shared:
// the floor plans and the areas are held by reference, and those objects are never mutated (the
// page rebuilds the array on every change, see PolygonTestView), so a hundred steps cost a
// hundred small arrays and ONE copy of each image.
//
// THE MODEL. `past` is the timeline: states the document has been in, oldest first. Recording a
// change pushes the state being LEFT, because that is the state Undo has to bring back. Undo
// therefore swaps the top of `past` with the current state, and redo swaps it back.
//
// ONE GESTURE IS ONE STEP. A dragged dot reports a change on every mousemove, and without
// coalescing, taking back a single drag would be a hundred presses of Undo. A run of changes is
// held open and only becomes a step when the pointer comes up (`endRun`) or the changes stop
// coming for COALESCE_MS. The state pushed is the one the run STARTED from.
//
// IN MEMORY ONLY, deliberately. Persisting the canvas to the browser would mean writing every
// floor plan image a second time (up to 4 MB, and the localStorage quota is about 5 MB in
// total) to reproduce a history whose every step is already on the server after the next lock.
// So the stack lives as long as the tab and is thrown away on reload. "Local" means it never
// leaves the browser: nothing here is written to the database, and no other planner sees it.
import { computed, ref } from 'vue'

// How long a run of changes has to go quiet before it counts as finished. Short enough that an
// ordinary click is its own step well before the planner can reach for Undo; long enough that
// the gaps between mousemoves never split one drag into several steps.
const COALESCE_MS = 150

// Deep enough for a long session, bounded so a forgotten tab cannot grow forever.
export const HISTORY_LIMIT = 100

// The content signature described above: the fields a planner would call a change, minus the
// map view. One string per document, no image bytes.
//
// A shape's POINTS are represented by their count plus the centre of the ring, not by the
// coordinates themselves. That is the balance that makes this work: a drag must register as a
// change -- otherwise a dragged dot would leave no step and Undo would refuse to take it back --
// but a signature containing all 200 coordinates of every area would be built on every mousemove.
// The ring's centre moves for any real edit (moving one dot, adding one, removing one), and it
// moves by a distance the reader can see, which is exactly the resolution the signature needs.
function signatureOf(snapshot) {
  const plans = snapshot.floorPlans.map((p) =>
    [
      p.id,
      p.name,
      Number(p.centre && p.centre[0]).toFixed(6),
      Number(p.centre && p.centre[1]).toFixed(6),
      Number(p.angleDeg) || 0,
      Number(p.opacity),
      p.visible === false ? 0 : 1,
    ].join('\u0001'),
  )
  const areas = snapshot.polygons.map((a) => {
    const points = Array.isArray(a.points) ? a.points : []
    let lat = 0
    let lng = 0
    for (const point of points) {
      lat += Number(point[0]) || 0
      lng += Number(point[1]) || 0
    }
    const n = points.length || 1
    return [a.id, a.name, a.kind, points.length, (lat / n).toFixed(6), (lng / n).toFixed(6)].join('\u0001')
  })
  return [plans.join('\u0002'), areas.join('\u0002')].join('\u0003')
}

// One snapshot of the document as it stands. The arrays are the live ones, which is safe
// because nothing in the app mutates them or the objects inside them -- every change replaces
// them, so every snapshot keeps exactly the state it was taken in. The map view is copied
// because the page hands out a fresh object for it on every pan anyway.
export function snapshotOf(doc) {
  const source = doc || {}
  return {
    view: source.view ? { ...source.view } : null,
    floorPlans: Array.isArray(source.floorPlans) ? source.floorPlans : [],
    polygons: Array.isArray(source.polygons) ? source.polygons : [],
  }
}

// `read` returns the document as the page holds it. The composable asks for it whenever it needs
// to know the state of things, so there is no chance of a stale copy being handed in at the
// wrong moment -- which is exactly how "the state before the change" gets recorded as the state
// after it.
export function useDocHistory(read) {
  const past = ref([]) // states left behind, most recent last
  const future = ref([]) // states stepped back past, most recent last

  let last = null // the document as it stands, as a snapshot
  let base = null // where the open run started, waiting to become a step
  let baseSig = ''
  let timer = null
  // Has a change been reported since the last time the stack was settled? Only a run that
  // actually reported one may push a step. Without this, `undo` -- which closes the run that is
  // open -- would find a difference between its own snapshot and the document it has just been
  // handed and mistake that for a change, clearing the redo branch it was about to use.
  let recorded = false

  const canUndo = computed(() => past.value.length > 0)
  const canRedo = computed(() => future.value.length > 0)
  const steps = computed(() => past.value.length)

  function now() {
    const doc = typeof read === 'function' ? read() : read
    return doc ? snapshotOf(doc) : null
  }

  // Forget everything and take the current document as the starting point. Called when an
  // editing session begins or ends: a stack carried over would let a planner undo past the
  // moment they took the bench, or past somebody else's saved version.
  function reset() {
    if (timer) clearTimeout(timer)
    timer = null
    base = null
    baseSig = ''
    recorded = false
    past.value = []
    future.value = []
    last = now()
  }

  // A change is about to be made. Called once per change, including once per mousemove of a
  // drag: the first call of a run captures the state the run started from, and the later calls
  // of the same run only move the current state along.
  function record() {
    const before = now()
    if (!before) return
    if (!base) {
      base = before
      baseSig = signatureOf(before)
    }
    recorded = true
    if (timer) clearTimeout(timer)
    timer = setTimeout(endRun, COALESCE_MS)
  }

  // The run is over: the state it started from becomes a step. Called on pointerup, which is the
  // one moment that is reliably the end of a drag, and by the quiet timer as a backstop.
  //
  // A run that changed nothing -- a refused edit, a re-render, or a drag that ended where it
  // began -- leaves no step, which is what keeps "nothing to undo" honest.
  function endRun() {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
    const from = base
    const fromSig = baseSig
    const changed = recorded
    base = null
    baseSig = ''
    recorded = false
    if (!from || !changed) return
    // The state the run started from and the state it ended in have to differ, or there is
    // nothing to take back.
    const current = now()
    const nowSig = current ? signatureOf(current) : ''
    if (fromSig === nowSig) return
    last = current
    past.value.push(from)
    while (past.value.length > HISTORY_LIMIT) past.value.shift()
    // A new step means the states that were stepped back past are no longer on the way to
    // anywhere -- the same rule a text editor uses.
    future.value = []
  }

  // The step to put back, or null when there is none. The caller is the one that writes it,
  // because the caller owns the document.
  function undo() {
    const at = last
    endRun() // a change a moment ago is still a step, and it is the one to take back
    if (past.value.length === 0) return null
    if (at) future.value.push(at)
    last = past.value.pop()
    return last
  }

  // Redo deliberately does NOT call endRun first: endRun clears the redo stack, which is the one
  // thing a redo must not do. A change still in progress is not a state anyone redoes into, so
  // there is nothing here that needed closing.
  function redo() {
    if (future.value.length === 0) return null
    if (last) {
      past.value.push(last)
      while (past.value.length > HISTORY_LIMIT) past.value.shift()
    }
    last = future.value.pop()
    return last
  }

  // The caller has written a step back into its document. `last` has to say so, or the next
  // change would be recorded against a state that is no longer on screen -- but the stacks are
  // NOT touched: the very point of a redo stack is that the states ahead stay reachable. (This
  // is why a restore is not a reset; resetting here would clear redo every time undo ran.)
  function settle(snapshot) {
    last = snapshot ? snapshotOf(snapshot) : null
  }

  return { canUndo, canRedo, steps, reset, record, endRun, undo, redo, settle }
}
