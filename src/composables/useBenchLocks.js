// useBenchLocks - who may change which shape, decided one object at a time.
//
// The database is the authority (008_object_locks.sql): a lock lives in public.layout_locks, keyed
// by an object and owned by a SESSION, and save_bench() only takes an object from a planner who
// holds its lock. Everything here is therefore about two things -- taking a lock at the moment a
// planner first changes something, and telling them the truth when they cannot.
//
// THE SESSION IS A SECOND, SECRET TAG. The page already has a presence tag (useBenchPresence),
// which is published to every other planner through Realtime. The session id must never be
// published, because it is what the database authorises with. So they are two different values
// with two different storage keys, and the rule from 007 is what keeps them apart: the id you
// publish is not the id you are authorised by.
//
// NOTHING HERE IS A GATE ON DATA. If this file were to get everything wrong, a planner's changes
// would simply not be saved: the merge in save_bench() keeps the stored version of every object
// nobody holds and names it in the reply. The locks exist so that the refusal arrives BEFORE the
// work instead of after it -- and so that a shape cannot be dragged out from under somebody.
import { computed, onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'
import { uuid4 } from '../utils/uuid'

const TICK_MS = 5 * 1000
// What the database gives a lock (008), kept here too so the page can reason about it without
// having to read the expiry back out of every reply.
const LOCK_MS = 45 * 1000
// Renewing with 20 to spare means one lost round trip, or one slow one, is not enough to lose a
// lock somebody is working inside of.
const RENEW_WITHIN_MS = 20 * 1000
// An object is held while it is being WORKED ON, not while it happens to be open. A planner who
// has not touched it in this long has stopped, and letting go costs them nothing: the next change
// takes it straight back. (`touched` is only moved by a change, never by a renewal, or this rule
// would never fire.)
const IDLE_RELEASE_MS = 45 * 1000
// How long the sentence about a refusal stays on the screen. Long enough to read, short enough not
// to sit there contradicting a lock that has since been let go.
const REFUSAL_MS = 8 * 1000

function tabSession(userId) {
  const key = 'bench.session.' + userId
  try {
    const saved = sessionStorage.getItem(key)
    if (saved) return saved
    const tag = uuid4()
    sessionStorage.setItem(key, tag)
    return tag
  } catch {
    // Storage blocked (private mode): a fresh session per page load is still correct. It only
    // means any lock this tab held is left to expire rather than being let go by name.
    return uuid4()
  }
}

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data
}

export function useBenchLocks() {
  const auth = useAuthStore()

  const session = ref('') // this tab's secret, as a uuid
  const held = ref({}) // object id -> when my lock lapses (ms since the epoch)
  // The last refusal: { objectId, name, mine, idleSeconds }. Read by the bench's one strip of text.
  const refused = ref(null)

  let pending = {} // object id -> the acquisition already in flight
  let touched = {} // object id -> when I last CHANGED it
  let timer = null
  let refusalTimer = null

  const myUserId = computed(() => (auth.user ? auth.user.id : ''))

  function holds(objectId) {
    return Boolean(objectId && session.value && held.value[objectId])
  }

  function remember(objectId) {
    held.value = { ...held.value, [objectId]: Date.now() + LOCK_MS }
    touched[objectId] = Date.now()
  }

  function forget(objectId) {
    const next = { ...held.value }
    delete next[objectId]
    held.value = next
    delete touched[objectId]
  }

  function refuse(objectId, row) {
    refused.value = {
      objectId,
      name: row.held_by || 'Someone else',
      mine: Boolean(row.mine_elsewhere),
      idleSeconds: Number(row.idle_seconds || 0),
    }
    if (refusalTimer) clearTimeout(refusalTimer)
    refusalTimer = setTimeout(() => (refused.value = null), REFUSAL_MS)
  }

  // ---------- Taking one ----------
  // One round trip per object, however many changes arrive while it is in flight: a drag emits on
  // every pointer move, and none of them should be a separate request.
  async function ask(objectId, fn, retry = true) {
    if (!supabase || !objectId) return false
    if (!session.value) session.value = tabSession(myUserId.value)

    const { data, error } = await supabase.rpc(fn, { p_object: objectId, p_session: session.value })
    const row = firstRow(data)

    if (error || !row) {
      // A missing session is the one hard refusal left in the database; say so rather than
      // swallowing it, because it means this page cannot save anything at all.
      if (error) refused.value = { objectId, name: '', mine: false, idleSeconds: 0, error: error.message }
      return false
    }

    if (!row.granted) {
      // Nobody is named: the lock expired between the two statements inside the function, so there
      // is nothing to report and the honest answer is to look again. Once only.
      if (retry && !row.held_by && !row.expires_at) return ask(objectId, fn, false)
      refuse(objectId, row)
      return false
    }

    remember(objectId)
    if (refused.value && refused.value.objectId === objectId) refused.value = null
    return true
  }

  // May I change this object -- taking it if I do not hold it yet? Every write goes through here.
  function ensure(objectId) {
    if (!objectId || !supabase) return Promise.resolve(false)
    if (holds(objectId)) {
      touched[objectId] = Date.now()
      return Promise.resolve(true)
    }
    if (pending[objectId]) return pending[objectId]

    const flight = ask(objectId, 'lock_object').finally(() => delete pending[objectId])
    pending[objectId] = flight
    return flight
  }

  // It is my own other window, or whoever has it has gone quiet. Offered by the strip.
  function takeOver(objectId) {
    return ask(objectId, 'take_over_object')
  }

  // ---------- Letting go ----------
  // Called when a planner puts a shape down, and when a drag or an edit is over for good.
  function end(objectId) {
    if (!objectId) return
    const mine = holds(objectId)
    forget(objectId)
    if (mine && supabase) supabase.rpc('unlock_object', { p_object: objectId, p_session: session.value })
  }

  function releaseAll() {
    const had = Object.keys(held.value).length > 0
    held.value = {}
    touched = {}
    if (had && supabase && session.value) {
      supabase.rpc('release_my_locks', { p_session: session.value })
    }
  }

  // ---------- Keeping them ----------
  function tick() {
    // A hidden tab is not working on anything, so it holds nothing and renews nothing.
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return

    const now = Date.now()
    for (const objectId of Object.keys(held.value)) {
      if (now - (touched[objectId] || 0) > IDLE_RELEASE_MS) {
        end(objectId)
        continue
      }
      if (held.value[objectId] - now < RENEW_WITHIN_MS) ask(objectId, 'lock_object')
    }
  }

  function onVisibilityChange() {
    // Going away puts everything down: another planner should not have to wait out a lock held by
    // a tab nobody is looking at. Coming back needs nothing -- the next change takes it again.
    if (document.visibilityState === 'hidden') releaseAll()
  }

  function start() {
    if (!supabase || session.value) return
    session.value = tabSession(myUserId.value)
    timer = setInterval(tick, TICK_MS)
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange)
  }

  onUnmounted(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
    if (timer) clearInterval(timer)
    if (refusalTimer) clearTimeout(refusalTimer)
    releaseAll()
  })

  return {
    session,
    held,
    refused,
    holds,
    ensure,
    end,
    releaseAll,
    takeOver,
    start,
  }
}
