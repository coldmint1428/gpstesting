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

const RENEW_MS = 60 * 1000

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

export function useBenchClaim() {
  const data = ref(normalise(null)) // the saved canvas
  const updatedAt = ref(null)
  const loading = ref(true)
  const errorMsg = ref('')

  const editing = ref(false) // do I hold a live claim?
  const claiming = ref(false)
  const saving = ref(false)
  const lostClaim = ref(false) // I was editing and the claim was taken from me
  const heldBy = ref('') // display name of whoever else is editing
  const claimExpiresAt = ref(null)

  let token = null
  let renewTimer = null

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
    loading.value = false
    if (error) {
      errorMsg.value = error.message
      return null
    }

    const row = firstRow(rows)
    if (!row) {
      errorMsg.value = 'The bench could not be opened.'
      return null
    }

    data.value = normalise(row.data)
    updatedAt.value = row.updated_at ? new Date(row.updated_at) : null
    heldBy.value = row.held_by || ''
    claimExpiresAt.value = row.claim_expires_at ? new Date(row.claim_expires_at) : null
    return data.value
  }

  function open() {
    return enqueue(doOpen)
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
  async function doSave(nextData) {
    const mine = token
    if (!editing.value || !mine || !supabase) return false

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
      return true
    }

    if (isLostClaim(error)) {
      // Somebody else really did take the bench while we were quiet. Go read-only and say
      // so rather than silently dropping the planner's work.
      applyRefusal({ held_by: heldBy.value })
      lostClaim.value = true
      return false
    }

    errorMsg.value = error.message
    return false
  }

  // Save the whole canvas. The token travels with it.
  function save(nextData) {
    return enqueue(() => doSave(nextData))
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
    // claim
    open,
    startEditing,
    stopEditing,
    editing,
    claiming,
    lostClaim,
    heldBy,
    claimExpiresAt,
  }
}
