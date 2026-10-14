// useBenchLocks - who may change which shape, decided one object at a time.
//
// The database is the authority (016_object_locks.sql): a lock lives in public.layout_locks, keyed by an
// object and owned by a SESSION (see composables/benchSession.js -- the tag is a secret, and it is never
// the tag presence publishes). save_object() writes nothing for a shape the caller does not hold, so
// everything here is about two things: taking a lock at the moment a planner first changes something,
// and telling them the truth when they cannot.
//
// NOTHING HERE IS A GATE ON DATA. If this file got everything wrong, a planner's changes would simply
// not be stored: the database refuses a write with no lock, and the page puts the bench's own version
// back (see useBenchDoc). The locks exist so that the refusal arrives BEFORE the work instead of after
// it -- and so that a shape cannot be dragged out from under somebody.
//
// A LOCK IS KEPT WHILE ITS WORK IS UNSAVED, and that is the one part of this file that is not a
// straight answer to "who has it". A write happens when a change settles (the end of a gesture, or a
// moment after an edit -- see useBenchDoc), so a shape with a change still waiting to be written must
// not be let go of: the write that is still coming was granted under that lock, and a lock released
// first turns it into a refusal and the planner's work into nothing.
//
// WHAT IS UNSAVED IS THE DATA LAYER'S BUSINESS, NOT THIS FILE'S. It used to be tracked here as a pair of
// timestamps ("changed since the last save that landed"), which was the best a whole-document save
// allowed. Now the page tells this file, once, through watchBusy().
import { onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { benchSession } from './benchSession'
import { sendOnExit } from '../utils/exitBeacon'

const TICK_MS = 5 * 1000
// What the database gives a lock (016), kept here too so the page can reason about it without having to
// read the expiry back out of every reply.
const LOCK_MS = 45 * 1000
// Renewing with 20 to spare means one lost round trip, or one slow one, is not enough to lose a lock
// somebody is working inside of.
const RENEW_WITHIN_MS = 20 * 1000
// An object is held while it is being WORKED ON, not while it happens to be open. A planner who has not
// touched it in this long has stopped, and letting go costs them nothing: the next change takes it
// straight back. (`touched` is only moved by a change, never by a renewal, or this rule would never
// fire -- and never moved by a renewal of unsaved work, which is kept whatever the clock says.)
const IDLE_RELEASE_MS = 45 * 1000
// How long the sentence about a refusal stays on the screen. Long enough to read, short enough not to
// sit there contradicting a lock that has since been let go.
const REFUSAL_MS = 8 * 1000

// Fire and forget. A supabase-js call is LAZY -- the request only goes out when something awaits it or
// calls .then() -- so a bare `supabase.rpc('unlock_object', ...)` never reached the database at all, and
// every lock this page "let go of" was in fact left to lapse 45 s later, blocking everybody else.
function send(fn, args) {
  if (!supabase) return
  supabase.rpc(fn, args).then(
    () => {},
    () => {},
  )
}

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data
}

export function useBenchLocks() {
  const held = ref({}) // object id -> when my lock lapses (ms since the epoch)
  // The last refusal: { objectId, name, mine, idleSeconds, problem }. Read by the bench's one strip of
  // text, whichever way the refusal arrived.
  const refused = ref(null)

  let pending = {} // object id -> the acquisition already in flight
  let touched = {} // object id -> when I last CHANGED it
  // Locks this page has put DOWN but still needs on the server, because the change they protect is not
  // written yet (a save in flight, or one waiting to be retried). They are not `held` -- the planner has
  // moved on, so the page does not treat the shape as being edited -- but they are renewed until the
  // write lands and then let go of at once, instead of being left to lapse 45 s later.
  const keeping = new Set()
  const keptAt = {} // object id -> when the server last renewed it
  let timer = null
  let refusalTimer = null
  let isBusy = () => false
  let layoutId = '' // which bench a lock is asked on (020: one bench per event)
  let onLost = () => {} // the page's "catch up": a shape I stopped holding may have changed meanwhile

  // Is this shape held by this tab? `held` carries when the lock lapses, and a claim that has lapsed is
  // not a claim -- the page stops trusting it at the same moment the database would.
  function holds(objectId) {
    const until = objectId ? held.value[objectId] : 0
    return Boolean(until) && until > Date.now()
  }

  // The page hands in "has this shape got a change that has not been written yet" (see the note at the
  // top). It is asked in three places and nowhere else: letting go of a shape, releasing everything,
  // and the idle sweep.
  function watchBusy(read) {
    if (typeof read === 'function') isBusy = read
  }

  // Called when a lock this page believed it held turns out to be somebody else's. While it was "mine"
  // the page ignored every change to it from Realtime, so those have to be fetched now.
  function whenLost(fn) {
    if (typeof fn === 'function') onLost = fn
  }

  function unsaved(objectId) {
    return Boolean(objectId) && isBusy(objectId)
  }

  function remember(objectId) {
    held.value = { ...held.value, [objectId]: Date.now() + LOCK_MS }
    touched[objectId] = Date.now()
    keeping.delete(objectId)
  }

  function forget(objectId) {
    const next = { ...held.value }
    delete next[objectId]
    held.value = next
    delete touched[objectId]
  }

  // A refusal the page can ALREADY see, without asking anybody: presence says this shape is held, and by
  // whom. It goes through the same `refused` a refusal from the database does, and it decides nothing at
  // all: the shape does not move either way, and only the lock can actually refuse a change. Without
  // this, a press on a shape somebody else is holding was refused in silence: the planner saw nothing
  // happen and was told nothing, which is indistinguishable from a broken page.
  function refuseHere(objectId, name, mine) {
    refuse(objectId, { held_by: name, mine_elsewhere: mine, idle_seconds: 0 })
  }

  // ---------- Taking one ----------
  // One round trip per object, however many changes arrive while it is in flight: a drag emits on every
  // pointer move, and none of them should be a separate request.

  // A refusal that is not about a lock at all: the database will not store this shape, and said why.
  // It goes through the same `refused` as a lock refusal does, so the bench's strip has one source and
  // one timer for every way a change can be turned down.
  // A refusal that is not about a lock at all: the database will not store this shape, and said why.
  // It goes through the same `refused` as a lock refusal does, so the bench's strip has one source and
  // one timer for every way a change can be turned down.
  function say(objectId, sentence) {
    refused.value = { objectId, name: '', mine: false, idleSeconds: 0, problem: sentence }
    if (refusalTimer) clearTimeout(refusalTimer)
    refusalTimer = setTimeout(() => (refused.value = null), REFUSAL_MS)
  }

  function refuse(objectId, row) {
    refused.value = {
      objectId,
      name: row.held_by || 'Someone else',
      mine: Boolean(row.mine_elsewhere),
      idleSeconds: Number(row.idle_seconds || 0),
      problem: row.problem || '',
    }
    if (refusalTimer) clearTimeout(refusalTimer)
    refusalTimer = setTimeout(() => (refused.value = null), REFUSAL_MS)
  }

  // A refusal the page can ALREADY see, without asking anybody: presence says this shape is held, and by
  // whom. It goes through the same `refused` a refusal from the database does, and it decides nothing at
  // all: the shape does not move either way, and only the lock can actually refuse a change. Without
  // this, a press on a shape somebody else is holding was refused in silence: the planner saw nothing
  // happen and was told nothing, which is indistinguishable from a broken page.
  //
  // ---------- Taking one ----------
  // One round trip per object, however many changes arrive while it is in flight: a drag emits on every
  // pointer move, and none of them should be a separate request.
  async function ask(objectId, fn, retry = true) {
    if (!supabase || !objectId) return false

    const { data, error } = await supabase.rpc(fn, { p_object: objectId, p_session: benchSession(), p_layout: layoutId || null })
    const row = firstRow(data)

    if (error || !row) {
      // A missing session is the one hard refusal left in the database; say so rather than swallowing
      // it, because it means this page cannot save anything at all.
      if (error) refused.value = { objectId, name: '', mine: false, idleSeconds: 0, error: error.message }
      return false
    }

    if (!row.granted) {
      // Nobody is named: the lock expired between the two statements inside the function, so there is
      // nothing to report and the honest answer is to look again. Once only.
      if (retry && !row.held_by && !row.expires_at) return ask(objectId, fn, false)
      // If this was a RENEWAL, somebody has taken the shape over (a quiet lock, or my own other window).
      // It is not mine any more: stop holding it, so the new holder's changes reach this screen and this
      // page stops writing a shape the database will refuse.
      const wasMine = Boolean(held.value[objectId])
      if (wasMine) forget(objectId)
      keeping.delete(objectId)
      refuse(objectId, row)
      if (wasMine) onLost(objectId)
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
  // Called when a planner puts a shape down. THE CHANGE GOES FIRST, THE LOCK AFTER: a lock whose shape
  // has been changed and not yet written is KEPT -- this page forgets about it locally (so it stops
  // being renewed and expires on its own) but does not tell the database to drop it, because the write
  // that is still coming needs it. That one rule is the difference between an edit being stored and an
  // edit being silently refused.
  function end(objectId) {
    if (!objectId) return
    const mine = holds(objectId)
    const keepIt = mine && unsaved(objectId)
    forget(objectId)
    if (keepIt) {
      // Kept on the server until its write lands (see `keeping`), then let go of by the tick.
      keeping.add(objectId)
      keptAt[objectId] = Date.now()
    } else if (mine && supabase) {
      send('unlock_object', { p_object: objectId, p_session: benchSession() })
    }
  }

  // Make sure the server still has this shape's lock for this tab before an unsaved change is written
  // again (a retry after a failed save). A lapsed lock nobody else took is simply taken back; one that
  // somebody else has is not, and the write that follows is refused and put back as usual.
  async function keep(objectId) {
    if (!objectId || !supabase) return false
    if (holds(objectId)) return true
    const { data, error } = await supabase.rpc('lock_object', {
      p_object: objectId,
      p_session: benchSession(),
      p_layout: layoutId || null,
    })
    const row = firstRow(data)
    if (error || !row) return false
    if (!row.granted) {
      keeping.delete(objectId)
      return false
    }
    if (!held.value[objectId]) {
      keeping.add(objectId)
      keptAt[objectId] = Date.now()
    }
    return true
  }

  // Everything at once: the tab is being hidden or is going away. `force` is for the second case -- a
  // page that is unloading cannot write anything any more, so holding a lock only delays whoever comes
  // next until it expires.
  function releaseAll(force = false) {
    const ids = Object.keys(held.value)
    const clean = ids.filter((id) => force || !unsaved(id))
    held.value = {}
    touched = {}
    // Unsaved work keeps its lock until it is written (see `keeping`); a page going away keeps nothing.
    for (const id of ids) {
      if (!clean.includes(id)) {
        keeping.add(id)
        keptAt[id] = Date.now()
      }
    }
    if (force) keeping.clear()

    if (!ids.length || !supabase) return

    // One round trip for the ordinary case; per object only when something unsaved has to be kept.
    if (clean.length === ids.length) {
      send('release_my_locks', { p_session: benchSession() })
      return
    }
    for (const id of clean) {
      send('unlock_object', { p_object: id, p_session: benchSession() })
    }
  }

  // ---------- Keeping them ----------
  function tick() {
    const now = Date.now()

    // Locks kept for a write that has not landed: let go the moment it has, renew them until then. This
    // runs even in a hidden tab, because a write can still be on its way from one.
    for (const objectId of [...keeping]) {
      if (holds(objectId)) {
        keeping.delete(objectId)
        continue
      }
      if (!unsaved(objectId)) {
        keeping.delete(objectId)
        if (supabase) send('unlock_object', { p_object: objectId, p_session: benchSession() })
        continue
      }
      if (now - (keptAt[objectId] || 0) > LOCK_MS - RENEW_WITHIN_MS) {
        keptAt[objectId] = now
        keep(objectId)
      }
    }

    // A hidden tab is not working on anything, so it holds nothing and renews nothing.
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return

    for (const objectId of Object.keys(held.value)) {
      // Quiet means the planner has stopped working on it -- unless the work is not written yet. Then
      // the lock is what protects it, and letting go now would hand the shape to somebody else and turn
      // this planner's change into a refusal. A lock like that keeps being renewed; what releases it is
      // the write (see useBenchDoc), the tab going away, or a takeover.
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
    // Going away puts everything down: another planner should not have to wait out a lock held by a tab
    // nobody is looking at. Coming back needs nothing -- the next change takes it again.
    if (document.visibilityState === 'hidden') releaseAll()
  }

  // The bench this page has open (set once it is known, see PolygonTestView).
  function setLayout(id) {
    layoutId = id || ''
  }

  function start() {
    if (!supabase || timer) return
    benchSession()
    timer = setInterval(tick, TICK_MS)
  }

  // The page is closing (tab closed, reload, navigating away): nothing it holds can be written any more,
  // so every lock goes at once -- with a request the browser finishes after the page is gone, because an
  // ordinary one is cancelled. Without this a closed tab blocked other planners for 45 s.
  function onPageHide() {
    held.value = {}
    touched = {}
    keeping.clear()
    sendOnExit('rpc/release_my_locks', { body: { p_session: benchSession() } })
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange)
    window.addEventListener('pagehide', onPageHide)
  }

  onUnmounted(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange)
      window.removeEventListener('pagehide', onPageHide)
    }
    if (timer) clearInterval(timer)
    if (refusalTimer) clearTimeout(refusalTimer)
    releaseAll(true)
  })

  return {
    held,
    refused,
    holds,
    ensure,
    keep,
    end,
    releaseAll,
    takeOver,
    refuseHere,
    refuse,
    say,
    watchBusy,
    whenLost,
    setLayout,
    start,
  }
}
