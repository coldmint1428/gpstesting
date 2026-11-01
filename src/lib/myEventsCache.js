// myEventsCache - the last list of my events (and which were live), kept while the app is open.
//
// Home and My events both show this list. Without a copy, every move between them through the top bar showed the
// loading skeleton again for a list that was on screen a second ago. With it, the page opens with the list it had and
// reads a fresh one quietly; the skeleton is only for the very first load. Keyed by the signed-in user, so another
// account on the same device never sees it.
let saved = null // { userId, events, liveIds }

export function cachedMyEvents(userId) {
  return saved && userId && saved.userId === userId ? saved : null
}

export function saveMyEvents(userId, events, liveIds) {
  if (userId) saved = { userId, events, liveIds }
}
