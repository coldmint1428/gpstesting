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
  // Everything changed up to this moment has been saved. A lock is not let go of while its change is
  // NEWER than this, because the save that carries that change is the thing the lock is for: release
  // it early and the database keeps its own version of the shape instead, which is the planner's work
  // thrown away with no error anywhere. Measured, not imagined -- see tools/bench_harness.mjs.
  let savedAt = 0
  let timer = null
  let refusalTimer = null

  const myUserId = computed(() => (auth.user ? auth.user.id : ''))

  function holds(objectId) {
    return Boolean(objectId && session.value && held.value[objectId])
  }

  // Has this object been changed since the last save that landed? An object nobody has touched is
  // clean, so a lock taken and never used can always be let go of at once.
  function unsaved(objectId) {
    return Boolean(objectId) && (touched[objectId] || 0) > savedAt
  }

  // A save landed, and its payload was taken at `since`. Everything changed before that moment is
  // committed -- and everything changed after it (while the save was in flight, which on a bench this
  // size is twenty seconds of opportunity) is not, and keeps its lock.
  function saved(since) {
    const stamp = Number(since) || 0
    if (stamp > savedAt) savedAt = stamp
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

  // A refusal the page can ALREADY see, without asking anybody: presence says this shape is held, and
  // by whom. It goes through the same `refused` a refusal from the database does -- so the sentence
  // in the bench's strip has one source and one timer -- and it decides nothing at all: the shape
  // does not move either way, and only the lock can actually refuse a change. Without this, a press
  // on a shape somebody else is holding was refused in silence: the planner saw nothing happen and
  // was told nothing, which is indistinguishable from a broken page.
  function refuseHere(objectId, name, mine) {
    refuse(objectId, { held_by: name, mine_elsewhere: mine, idle_seconds: 0 })
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
  //
  // THE CHANGE GOES FIRST, THE LOCK AFTER. A lock whose object has been changed and not yet saved is
  // KEPT -- this page forgets about it locally (so it stops being renewed and expires on its own) but
  // does not tell the database to drop it, because the save that is still coming needs it. That one
  // line is the difference between an edit being stored and an edit being silently overruled: the
  // merge in save_bench() takes an object from this page only while this page holds its lock, and it
  // cannot tell "I have not saved that yet" from "I have stopped caring about that".
  function end(objectId) {
    if (!objectId) return
    const mine = holds(objectId)
    const keep = mine && unsaved(objectId)
    forget(objectId)
    if (mine && !keep && supabase) {
      supabase.rpc('unlock_object', { p_object: objectId, p_session: session.value })
    }
  }

  // Everything at once: the tab is being hidden or is going away. `force` is for the second case --
  // a page that is unloading cannot save anything any more, so holding a lock only delays whoever
  // comes next until it expires.
  function releaseAll(force = false) {
    const ids = Object.keys(held.value)
    const clean = ids.filter((id) => force || !unsaved(id))
    held.value = {}
    touched = {}

    if (!ids.length || !supabase || !session.value) return

    // One round trip for the ordinary case; per object only when something unsaved has to be kept.
    if (clean.length === ids.length) {
      supabase.rpc('release_my_locks', { p_session: session.value })
      return
    }
    for (const id of clean) {
      supabase.rpc('unlock_object', { p_object: id, p_session: session.value })
    }
  }

  // ---------- Keeping them ----------
  function tick() {
    // A hidden tab is not working on anything, so it holds nothing and renews nothing.
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return

    const now = Date.now()
    for (const objectId of Object.keys(held.value)) {
      // Quiet means the planner has stopped working on it -- unless the work is not SAVED yet. Then
      // the lock is what protects it, and letting go now would hand the shape to somebody else and
      // throw this planner's change away the next time they save. A lock like that keeps being
      // renewed; what releases it is a save (see `saved`), the tab going away, or a takeover.
      if (unsaved(objectId)) {
        if (held.value[objectId] - now < RENEW_WITHIN_MS) ask(objectId, 'lock_object')
        continue
      }
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
    releaseAll(true)
  })

  return {
    session,
    held,
    refused,
    holds,
    unsaved,
    ensure,
    end,
    saved,
    releaseAll,
    takeOver,
    refuseHere,
    start,
  }
}
