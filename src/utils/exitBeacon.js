// A request that must still go out while the page is closing (tab closed, reload, navigation away).
//
// supabase-js cannot do this: its requests are ordinary fetches, which the browser cancels as the page
// unloads, and it fetches the login token asynchronously -- there is no time for that in `pagehide`. So
// this keeps the current access token at hand (updated whenever the login changes) and sends a plain
// fetch with `keepalive: true`, which the browser completes after the page is gone. Used by the bench to
// release its locks and remove its presence row, so other planners are not blocked by a closed tab for
// the 45 s a lock otherwise takes to lapse.
import { supabase, supabaseUrl, supabaseAnonKey } from '../lib/supabase'

let token = ''

if (supabase) {
  supabase.auth.getSession().then(({ data }) => {
    token = (data && data.session && data.session.access_token) || ''
  })
  supabase.auth.onAuthStateChange((event, session) => {
    token = (session && session.access_token) || ''
  })
}

// path: what follows /rest/v1/, e.g. 'rpc/release_my_locks' or 'layout_presence?presence_id=eq.<id>'
export function sendOnExit(path, { method = 'POST', body } = {}) {
  if (!supabase || !token) return
  try {
    fetch(supabaseUrl + '/rest/v1/' + path, {
      method,
      keepalive: true,
      headers: {
        apikey: supabaseAnonKey,
        Authorization: 'Bearer ' + token,
        'Content-Type': 'application/json',
      },
      body: body ? JSON.stringify(body) : undefined,
    }).catch(() => {})
  } catch {
    // Nothing to do: the lock lapses by itself, and the presence row goes stale.
  }
}
