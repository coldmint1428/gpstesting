// The tab's session: the one secret a lock authorises with.
//
// Used by the bench (016_object_locks.sql) and by the plan board (081_plan_locks.sql), because both need the same
// thing and for the same reason: a lock is owned by a SESSION, not by a planner -- the user id cannot do that job,
// because the database already uses it to recognise "this is my own renewal", so it cannot also be what tells two
// of my tabs apart. Two tabs of one account are two editors, which was the bench's oldest bug, and the count of
// that fix lives in this value and nowhere else.
//
// IT MUST NEVER BE PUBLISHED, and that is the rule 015 set from the other side: the id a page PUBLISHES (its
// presence tag, its broadcast `from`) is not the id it is AUTHORISED by. So this tag is never put in a presence
// row and never in a broadcast frame, and is sent only to the functions that decide who may write what.
//
// ONE VALUE PER PAGE LOAD, per account. It used to live in sessionStorage so a reload kept its locks -- but the
// browser COPIES sessionStorage into a duplicated tab ("Duplicate tab", and some "open in new tab" paths), and the
// copy then held the same session: two windows, one editor, both allowed to write the same shape. A fresh value
// per load cannot be shared. What a reload used to keep is handed back instead: the page releases its locks as it
// unloads (see useBenchLocks and usePlanLocks), so the reloaded page simply takes them again.
//
// Per account, because a login that changes inside one tab must not inherit the previous planner's locks.
import { useAuthStore } from '../stores/auth'
import { uuid4 } from '../utils/uuid'

const sessions = new Map() // user id -> this page load's session for that account

// This tab's session id, minted on first use. Called from a composable during setup, which is where
// the auth store is available.
export function pageSession() {
  const auth = useAuthStore()
  const userId = auth.user ? auth.user.id : ''
  if (!sessions.has(userId)) sessions.set(userId, uuid4())
  return sessions.get(userId)
}
