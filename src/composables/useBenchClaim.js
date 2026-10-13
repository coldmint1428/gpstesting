// useBenchClaim - the bench's document, and where this planner left the map.
//
// THE NAME IS A LEFTOVER: there is no claim any more. 008 replaced one-claim-for-the-whole-bench
// with a lock per object, which lives in composables/useBenchLocks.js. What is left here is the
// document itself -- reading it, saving it, and remembering this planner's camera.
//
// There is ONE bench, holding the whole canvas as a single JSON document. Saving it is a MERGE
// decided by the database (see save_bench in 008): an object this planner holds a lock on is taken
// from them, everything else keeps the stored version, and the ids of the objects where the STORED
// version won come back in the reply. So a save can succeed and still not have written everything
// it was sent -- which is why save() resolves to that list rather than to a plain "done".
//
// TWO RULES HOLD THIS TOGETHER, and both were learned the hard way:
//
// 1. ONE REQUEST AT A TIME. Opening and saving go through a single queue, in the order they were
//    asked for. Two saves in flight at once can land out of order, and then the older one wins.
//
// 2. THE BROWSER IS THE TRUTH WHILE YOU ARE WORKING. A save never copies the server's version back
//    over the local one. The reply describes what was sent a moment ago, and the planner has
//    probably kept working since; overwriting their newer edits with that older snapshot is what
//    made a dragged area jump back to where it started. When the server reports that it overruled
//    something, the PAGE decides what to do about it -- see mergeFromServer in PolygonTestView.
import { ref, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { LAYOUT_TOO_LARGE_MESSAGE, layoutBytes, MAX_LAYOUT_BYTES } from '../utils/layoutLimits'

// Where I left the map is a convenience, not a save: coalesce the reports a single pan produces
// into one write, and let the last one win.
const VIEW_SAVE_MS = 600

// The document always has this shape, whatever the database hands back.
function normalise(raw) {
  const doc = raw && typeof raw === 'object' ? raw : {}
  return {
    view: doc.view || null,
    floorPlans: Array.isArray(doc.floorPlans) ? doc.floorPlans : [],
    polygons: Array.isArray(doc.polygons) ? doc.polygons : [],
  }
}

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data
}

// A save is refused with 54000 (program_limit_exceeded) when the canvas is over 4 MB.
function isTooLarge(error) {
  if (!error) return false
  return error.code === '54000' || /too large/i.test(error.message || '')
}

// A save is refused with 22023 (invalid_parameter_value) when the canvas breaks one of the
// rules in area_ok()/floor_plan_ok(), and save_bench() raises that with one sentence for
// every rule: "The layout data is not valid". That tells the planner nothing.
function isInvalidData(error) {
  if (!error) return false
  return error.code === '22023' || /layout data is not valid/i.test(error.message || '')
}

// The canvas is one JSON document and the image lives inside it, so "how big is it" is
// measured on the text that is about to be sent -- the same string save() hands to
// supabase-js, serialised once. `undefined` means the caller built the payload itself and
// this has to do the serialising.
function measure(nextData, jsonText) {
  return jsonText === undefined ? layoutBytes(JSON.stringify(nextData)) : layoutBytes(jsonText)
}

export function useBenchClaim() {
  const data = ref(normalise(null)) // the saved canvas
  const updatedAt = ref(null)
  const loading = ref(true)
  const errorMsg = ref('')
  // Size of the canvas as it stands, in the same bytes save_bench() counts, so the page can
  // tell the planner how close to the 4 MB cap they are before they find out the hard way.
  const bytes = ref(0)

  const saving = ref(false)

  // The bench's id, and where THIS planner left the map. Both are per-session server state the
  // page needs: the id is what presence is filed under (see useBenchPresence.js), and the view is
  // a planner's own rather than a field of the shared canvas (see 007_presence_and_views.sql).
  const layoutId = ref('')
  const myView = ref(null)

  let viewTimer = null // pending write of where I left the map (see saveView)
  let pendingView = null

  // See rule 1 at the top of the file.
  let chain = Promise.resolve()
  function enqueue(work) {
    const next = chain.then(work, work)
    chain = next.then(
      () => {},
      () => {},
    )
    return next
  }

  // ---------- Open ----------
  // Load (or create) the bench and find out who is editing it.
  async function doOpen() {
    loading.value = true
    errorMsg.value = ''

    if (!supabase) {
      loading.value = false
      errorMsg.value = 'Supabase is not set up, so the bench cannot be loaded.'
      return null
    }

    const { data: rows, error } = await supabase.rpc('open_bench')
    if (error) {
      loading.value = false
      errorMsg.value = error.message
      return null
    }

    const row = firstRow(rows)
    if (!row) {
      loading.value = false
      errorMsg.value = 'The bench could not be opened.'
      return null
    }

    data.value = normalise(row.data)
    updatedAt.value = row.updated_at ? new Date(row.updated_at) : null
    bytes.value = layoutBytes(JSON.stringify(data.value))
    layoutId.value = row.id || ''
    myView.value = await loadMyView()
    // LAST, and not a moment earlier. The page draws the map as soon as `loading` is false, and the
    // map takes the view it is given at that instant and never looks again -- so reading my own
    // view above is what makes the bench open where I left it rather than at the home view.
    loading.value = false
    return data.value
  }

  function open() {
    return enqueue(doOpen)
  }

  // Read the bench as it is NOW, without touching the local document. The page needs this when the
  // server overrules part of a save: it has to take the bench's version of what it was not entitled
  // to say while keeping its own version of what it holds, and only the page knows which is which
  // (see mergeById in PolygonTestView).
  async function doReload() {
    if (!supabase) return null
    const { data: rows, error } = await supabase.rpc('open_bench')
    if (error) return null
    const row = firstRow(rows)
    return row ? normalise(row.data) : null
  }

  function reload() {
    return enqueue(doReload)
  }

  // ---------- Where I left the map ----------
  // A planner's camera is their own. It used to be a field of the shared canvas, so one planner
  // panning moved the next planner's map -- odd while one person edits at a time, wrong the
  // moment two do (see 007_presence_and_views.sql). The stored copy inside the document is now
  // only a fallback for a planner who has never panned: it is what stops the first planner after
  // this change from being thrown at a default location.
  async function loadMyView() {
    if (!supabase) return null
    // No filter: RLS shows a planner their own row and nobody else's, and there is one bench.
    const { data: row, error } = await supabase
      .from('layout_views')
      .select('lat, lng, zoom')
      .maybeSingle()

    if (error || !row) return null
    return { lat: row.lat, lng: row.lng, zoom: row.zoom }
  }

  // The map reports on every settle, so the write is debounced: one round trip for a drag of the
  // map rather than one for every intermediate moveend.
  function saveView(view) {
    if (!view || !supabase) return
    pendingView = { lat: view.lat, lng: view.lng, zoom: view.zoom }
    if (viewTimer) return
    viewTimer = setTimeout(flushView, VIEW_SAVE_MS)
  }

  async function flushView() {
    if (viewTimer) {
      clearTimeout(viewTimer)
      viewTimer = null
    }

    const next = pendingView
    pendingView = null
    if (!next || !layoutId.value || !supabase) return

    // Best effort, deliberately. The one way this fails is a view outside the box the bench draws
    // in (the map can be panned past Singapore), and "I could not remember where you were looking"
    // is not worth an error message in the middle of somebody's work.
    const { error } = await supabase
      .from('layout_views')
      .upsert({ layout_id: layoutId.value, ...next }, { onConflict: 'layout_id,user_id' })

    if (error) return
    myView.value = next
  }

  // ---------- Save ----------
  // `opts.jsonText` is optional: pass it when the caller already serialised the payload, so
  // the document is not turned into a string twice on every save.
  //
  // `opts.session` is the tab's lock session (see useBenchLocks). It is not optional: without it
  // the database refuses the save outright, because a page that holds nothing has nothing it is
  // entitled to write.
  //
  // `opts.diagnose(nextData)` is optional too: it returns a sentence when the CLIENT can
  // already see why the canvas would be refused, or null when it cannot. It is only asked
  // after the database has refused, and only so the planner gets a reason instead of
  // "The layout data is not valid". It is a backstop, not a guard -- anything routinely
  // reachable should be refused at the point the planner tries to do it.
  //
  // Resolves to the list of object ids the server OVERRULED -- where the stored version won over
  // the one sent -- or null when the save did not happen at all. An empty list is the ordinary
  // case: everything sent was mine to say.
  async function doSave(nextData, opts) {
    if (!opts || !opts.session || !supabase) return null

    const size = measure(nextData, opts && opts.jsonText)

    // Refuse an over-large canvas BEFORE the round trip. The database would give the same
    // answer, only later and less usefully: by then the planner has already done the work.
    // Deleting a floor plan always shrinks the document, so the way out of this state is
    // itself a save -- there is no dead end.
    if (size > MAX_LAYOUT_BYTES) {
      errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
      return null
    }

    saving.value = true
    const { data, error } = await supabase.rpc('save_bench', {
      p_data: nextData,
      p_session: opts.session,
    })
    saving.value = false

    if (error) {
      // Over the cap even though we measured first: the row is bigger than this browser thinks it
      // is, most likely because another planner has added something since this page loaded.
      if (isTooLarge(error)) {
        errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
        return null
      }

      errorMsg.value =
        (isInvalidData(error) ? await explain(nextData, opts) : '') ||
        error.message ||
        'The bench could not be saved.'
      return null
    }

    // Deliberately NOT `data.value = nextData` -- see rule 2 at the top of the file. What the
    // server actually stored is the page's business, and the overruled list is how it finds out.
    updatedAt.value = new Date()
    bytes.value = size
    errorMsg.value = '' // a failed save left its reason here; it no longer applies
    return Array.isArray(data) ? data : []
  }

  // The database said no; find out what it objected to. Three answers, best first:
  //
  //   1. the client's own diagnosis, which NAMES the thing to fix (see opts.diagnose);
  //   2. layout_problem(), which asks the database the same question -- it knows about floor
  //      plans, and it is the only side that can see the row as it is actually stored;
  //   3. nothing. A generic sentence is still better than silence.
  async function explain(nextData, opts) {
    if (opts && typeof opts.diagnose === 'function') {
      try {
        const mine = opts.diagnose(nextData)
        if (mine) return mine
      } catch {
        // A broken diagnosis must not replace the failure it was meant to describe.
      }
    }

    try {
      const { data, error } = await supabase.rpc('layout_problem', { p_data: nextData })
      if (error) return ''
      // A scalar function arrives as the value itself; be forgiving about an array wrapper.
      const reason = Array.isArray(data) ? data[0] : data
      return typeof reason === 'string' ? reason : ''
    } catch {
      return ''
    }
  }

  // Save the whole canvas. The token travels with it.
  function save(nextData, jsonText) {
    const opts = typeof jsonText === 'string' ? { jsonText } : jsonText || {}
    return enqueue(() => doSave(nextData, opts))
  }

  onUnmounted(() => {
    // A pan that has not been written yet is still worth writing: leaving the page is exactly the
    // moment "where I was looking" should be remembered, so the debounce is flushed rather than
    // dropped.
    //
    // There is nothing else to let go of here. The claim is gone (008), and the locks this page
    // holds are released by useBenchLocks, which owns them.
    flushView()
  })

  return {
    // data
    data,
    updatedAt,
    loading,
    errorMsg,
    save,
    saving,
    bytes,
    open,
    reload,
    // Per-session state that is not the document: the bench's id, and my own camera.
    layoutId,
    myView,
    saveView,
  }
}
