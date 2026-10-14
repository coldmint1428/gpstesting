// The tab's session: the one secret the bench's database authorises with.
//
// public.layout_locks is keyed by an object and owned by a SESSION, not by a planner -- because the
// user id cannot do that job: the database already uses it to recognise "this is my own renewal", so
// it cannot also be what tells two of my tabs apart. Two tabs of one account are two editors here,
// which was the bench's oldest bug, and the count of that fix lives in this value and nowhere else.
//
// IT MUST NEVER BE PUBLISHED, and that is the rule 015 set from the other side: the id a page
// PUBLISHES (its presence tag, see useBenchPresence) is not the id it is AUTHORISED by. So this tag is
// stored under a key of its own, is never put in a presence row and never in a broadcast frame, and is
// sent only to the functions that decide who may write what.
//
// One value per tab per account, because a login that changes inside one tab must not inherit the
// previous planner's locks (the same reasoning as the presence tag).
import { ref } from 'vue'
import { useAuthStore } from '../stores/auth'
import { uuid4 } from '../utils/uuid'

const session = ref('')

function tabSession(userId) {
  const key = 'bench.session.' + userId
  try {
    const saved = sessionStorage.getItem(key)
    if (saved) return saved
    const tag = uuid4()
    sessionStorage.setItem(key, tag)
    return tag
  } catch {
    // Storage blocked (private mode): a fresh session per page load is still correct. It only means
    // any lock this tab held is left to expire rather than being let go by name.
    return uuid4()
  }
}

// This tab's session id, minted on first use. Called from a composable during setup, which is where
// the auth store is available.
export function benchSession() {
  if (!session.value) {
    const auth = useAuthStore()
    session.value = tabSession(auth.user ? auth.user.id : '')
  }
  return session.value
}
