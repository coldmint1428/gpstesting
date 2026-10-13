// useBenchClaim - the "receipt" for the polygon bench.
//
// There is ONE bench and only one person may edit it at a time. The database decides who:
// claim_bench() returns a TOKEN, every save must present it, and a save with a stale token
// is refused rather than obeyed. So nobody has to trust anyone's browser.
//
// The claim lapses after 5 minutes of silence. This composable keeps it alive with a
// heartbeat -- but only while the tab is VISIBLE, so a forgotten background tab releases
// the bench instead of holding it hostage. On the way back in it re-claims, which either
// renews the claim or reports that somebody else has it now.
//
// TWO RULES HOLD THIS TOGETHER, and both were learned the hard way:
//
// 1. ONE REQUEST AT A TIME. Claiming, saving and releasing all go through a single queue,
//    in the order they were asked for. Firing two at once is exactly how a late release
//    cancels the claim that replaced it (so the next save is refused and the page announces
//    that "somebody took the bench over" -- when it was you), and how two saves can land
//    out of order so the older one wins.
//
// 2. THE BROWSER IS THE TRUTH WHILE YOU ARE WORKING. A save never copies the server's
//    version back over the local one. The reply describes what was sent a moment ago, and
//    the planner has probably kept working since; overwriting their newer edits with that
//    older snapshot is what made a dragged area jump back to where it started.
import { ref, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { LAYOUT_TOO_LARGE_MESSAGE, layoutBytes, MAX_LAYOUT_BYTES } from '../utils/layoutLimits'

const RENEW_MS = 60 * 1000

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

// A save is refused with PT409 (HTTP 409) when the token is no longer good.
function isLostClaim(error) {
  if (!error) return false
  return error.code === 'PT409' || /claim expired/i.test(error.message || '')
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

  const editing = ref(false) // do I hold a live claim?
  const claiming = ref(false)
  const saving = ref(false)
  const lostClaim = ref(false) // I was editing and the claim was taken from me
  const heldBy = ref('') // display name of whoever else is editing
  const claimExpiresAt = ref(null)

  // The bench's id, and where THIS planner left the map. Both are per-session server state the
  // page needs: the id is what presence is filed under (see useBenchPresence.js), and the view is
  // now a planner's own rather than a field of the shared canvas (see 007_presence_and_views.sql).
  const layoutId = ref('')
  const myView = ref(null)

  let token = null
  let renewTimer = null
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

  function stopRenewing() {
    if (renewTimer) {
      clearInterval(renewTimer)
      renewTimer = null
    }
  }

  function applyRefusal(row) {
    token = null
    editing.value = false
    heldBy.value = (row && row.held_by) || ''
    claimExpiresAt.value = row && row.expires_at ? new Date(row.expires_at) : null
    stopRenewing()
  }

  // ---------- Open ----------
  // Load (or create) the bench and find out who is editing it.
  async function doOpen() {
    loading.value = true
    errorMsg.value = ''
    lostClaim.value = false

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
    heldBy.value = row.held_by || ''
    claimExpiresAt.value = row.claim_expires_at ? new Date(row.claim_expires_at) : null
    // LAST, and not a moment earlier. The page draws the map as soon as `loading` is false, and the
    // map takes the view it is given at that instant and never looks again -- so reading my own
    // view above is what makes the bench open where I left it rather than at the home view.
    loading.value = false
    return data.value
  }

  function open() {
    return enqueue(doOpen)
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

  // ---------- Claim ----------
  // Ask to edit. Returns true if the bench is mine now.
  async function doClaim() {
    // Already mine. Asking again would be harmless, but a second answer arriving out of
    // order is not, so don't ask.
    if (editing.value && token) return true

    if (!supabase) {
      errorMsg.value = 'Supabase is not set up, so the bench cannot be edited.'
      return false
    }

    claiming.value = true
    errorMsg.value = ''
    const { data: rows, error } = await supabase.rpc('claim_bench')
    claiming.value = false

    if (error) {
      errorMsg.value = error.message
      return false
    }

    const row = firstRow(rows)
    if (!row || !row.granted) {
      applyRefusal(row)
      return false
    }

    token = row.token
    editing.value = true
    lostClaim.value = false
    heldBy.value = ''
    claimExpiresAt.value = row.expires_at ? new Date(row.expires_at) : null
    startRenewing()
    return true
  }

  function startEditing() {
    return enqueue(doClaim)
  }

  // ---------- Release ----------
  // Let go deliberately, so the next person does not have to wait out the 5 minutes. The
  // state is only dropped HERE, in the queue, so a save that was asked for first still has
  // a claim to present.
  async function doRelease() {
    stopRenewing()
    const mine = token
    token = null
    editing.value = false
    heldBy.value = ''
    claimExpiresAt.value = null

    if (mine && supabase) await supabase.rpc('release_bench', { p_token: mine })
  }

  function stopEditing() {
    return enqueue(doRelease)
  }

  // ---------- Save ----------
  // `opts.jsonText` is optional: pass it when the caller already serialised the payload, so
  // the document is not turned into a string twice on every lock.
  //
  // `opts.diagnose(nextData)` is optional too: it returns a sentence when the CLIENT can
  // already see why the canvas would be refused, or null when it cannot. It is only asked
  // after the database has refused, and only so the planner gets a reason instead of
  // "The layout data is not valid". It is a backstop, not a guard -- anything routinely
  // reachable should be refused at the point the planner tries to do it.
  async function doSave(nextData, opts) {
    const mine = token
    if (!editing.value || !mine || !supabase) return false

    const size = measure(nextData, opts && opts.jsonText)

    // Refuse an over-large canvas BEFORE the round trip. The database would give the same
    // answer, only later and less usefully: by then the planner has already locked the thing
    // they were working on. Refusing here keeps their work on screen and says what to do.
    // Deleting a floor plan always shrinks the document, so the way out of this state is
    // itself a save -- there is no dead end.
    if (size > MAX_LAYOUT_BYTES) {
      errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
      return false
    }

    saving.value = true
    const { error } = await supabase.rpc('save_bench', { p_token: mine, p_data: nextData })
    saving.value = false

    // We let go, or claimed again, while that was in flight. The answer is about a claim we
    // no longer hold, so it says nothing about the bench -- in particular it must not be
    // read as "somebody took it over".
    if (mine !== token) return false

    if (!error) {
      // Deliberately NOT `data.value = nextData` -- see rule 2 at the top of the file.
      updatedAt.value = new Date()
      bytes.value = size
      errorMsg.value = '' // a failed save left its reason here; it no longer applies
      return true
    }

    if (isLostClaim(error)) {
      // Somebody else really did take the bench while we were quiet. Go read-only and say
      // so rather than silently dropping the planner's work.
      applyRefusal({ held_by: heldBy.value })
      lostClaim.value = true
      return false
    }

    // Over the cap even though we measured first: the row is bigger than this browser thinks
    // it is, most likely because an older client wrote it.
    if (isTooLarge(error)) {
      errorMsg.value = LAYOUT_TOO_LARGE_MESSAGE
      return false
    }

    errorMsg.value =
      (isInvalidData(error) ? await explain(nextData, opts) : '') ||
      error.message ||
      'The bench could not be saved.'
    return false
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

  // ---------- Heartbeat ----------
  async function doRenew() {
    const mine = token
    if (!editing.value || !mine || !supabase) return

    const { data: rows, error } = await supabase.rpc('claim_bench')
    if (error) return // a blip: the claim is still ours until it actually expires
    if (!editing.value || token !== mine) return // stopped or re-claimed meanwhile

    const row = firstRow(rows)
    if (!row) return

    if (!row.granted) {
      applyRefusal(row)
      lostClaim.value = true
      return
    }

    token = row.token
    claimExpiresAt.value = row.expires_at ? new Date(row.expires_at) : null
  }

  function renew() {
    return enqueue(doRenew)
  }

  function startRenewing() {
    stopRenewing()
    renewTimer = setInterval(() => {
      // A hidden tab is not editing, so it earns no renewal: walking away for five
      // minutes hands the bench to whoever wants it next.
      if (document.visibilityState === 'visible') renew()
    }, RENEW_MS)
  }

  function onVisibilityChange() {
    // Back in view: re-claim straight away, so being away never leaves a stale token.
    if (document.visibilityState === 'visible' && editing.value) renew()
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange)
  }

  onUnmounted(() => {
    stopRenewing()
    // A pan that has not been written yet is still worth writing: leaving the page is exactly the
    // moment "where I was looking" should be remembered, so the debounce is flushed rather than
    // dropped.
    flushView()
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }

    // Best-effort release, queued behind whatever is still in flight. beforeunload is
    // deliberately NOT used: it is unreliable, and the 5-minute expiry is the backstop.
    const mine = token
    token = null
    editing.value = false
    if (mine && supabase) enqueue(() => supabase.rpc('release_bench', { p_token: mine }))
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
    // claim
    open,
    startEditing,
    stopEditing,
    editing,
    claiming,
    lostClaim,
    heldBy,
    claimExpiresAt,
    // Per-session state that is not the claim: the bench's id, and my own camera.
    layoutId,
    myView,
    saveView,
  }
}
