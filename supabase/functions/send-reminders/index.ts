// Supabase Edge Function: send-reminders
// Sends "Event started - tap to share your location" pushes to ICs who haven't started sharing
// in a live session, through Firebase Cloud Messaging (FCM HTTP v1). Works when the app is closed.
//
// Who may call it (deployed with verify_jwt = false; this file checks callers itself):
//   - pg_cron every minute while a session is live, with header x-cron-secret (random secret in
//     Supabase Vault, see 009_push_reminders.sql) -> reminds every live event
//   - a root / planner pressing "Remind ICs" (their login token + { eventId }) -> that event only
//   - the same, right after "Start event now" ({ eventId, start: true }): the normal "Event started"
//     push goes out at once instead of at the next cron minute
// Which ICs, and how often, is decided by the database function claim_push_reminders().
//
// Since merger Stage 8 (028_ic_moves.sql) it also sends the queued pushes: pg_cron / the movements tick call it
// with the cron secret and { queue: true }; claim_push_queue() hands out "Get ready", "Leave now", "Running
// late", planners' messages and No-Go warnings (already worded, one per person and movement). These are normal
// notifications (Android draws them, also when the app is closed); a tap opens the event at the group's next move.
//
// Secret: FCM_SERVICE_ACCOUNT = the JSON key of the Firebase project's service account
// (Firebase console -> Project settings -> Service accounts -> Generate new private key).
import { createClient } from 'npm:@supabase/supabase-js@2.117.2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } })
}

// ---------- Google login for FCM (service account -> 1 h access token) ----------
type ServiceAccount = { project_id: string; client_email: string; private_key: string }

function base64url(bytes: Uint8Array): string {
  let text = ''
  for (const b of bytes) text += String.fromCharCode(b)
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

let googleToken = ''
let googleTokenExpiresAt = 0 // ms

async function getGoogleToken(sa: ServiceAccount): Promise<string> {
  if (googleToken && Date.now() < googleTokenExpiresAt - 60000) return googleToken

  const now = Math.floor(Date.now() / 1000)
  const encode = (o: unknown) => base64url(new TextEncoder().encode(JSON.stringify(o)))
  const unsigned =
    encode({ alg: 'RS256', typ: 'JWT' }) +
    '.' +
    encode({
      iss: sa.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    })

  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const signature = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)))

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: unsigned + '.' + base64url(signature),
    }),
  })
  if (!res.ok) throw new Error('Google login failed (' + res.status + '): ' + (await res.text()))
  const data = await res.json()
  googleToken = data.access_token
  googleTokenExpiresAt = Date.now() + data.expires_in * 1000
  return googleToken
}

// ---------- One push ----------
type Reminder = { token: string; event_id: string; event_name: string; reminder_no: number; forced: boolean }

function messageFor(r: Reminder) {
  const title = r.forced
    ? 'A planner asked you to share your location'
    : r.reminder_no === 1
      ? 'Event started: ' + r.event_name
      : 'Reminder: ' + r.event_name + ' is live'
  const body = r.forced
    ? r.event_name + ' is live. Tap Start sharing to share your location.'
    : r.reminder_no === 1
      ? 'Tap Start sharing to share your location with the planners.'
      : "You're not sharing your location yet. Tap Start sharing."
  return {
    message: {
      token: r.token,
      // Android: a DATA message, drawn by the app itself (ReminderMessagingService.java) so it can
      // have a "Start sharing" button - works when the app is closed. HIGH = delivered right away.
      data: { kind: 'event-start', eventId: r.event_id, title, body },
      android: { priority: 'HIGH', ttl: '900s' }, // drop it if the phone is offline for 15+ min
      // iPhone: a normal alert (needs APNs set up in Firebase)
      apns: { payload: { aps: { alert: { title, body }, sound: 'default' } } },
    },
  }
}

// ---------- A queued push (Stage 8) ----------
type Queued = { id: number; token: string; kind: string; title: string; body: string; data: Record<string, unknown> }

function queuedMessage(q: Queued) {
  // FCM data values must be strings
  const data: Record<string, string> = { title: q.title, body: q.body }
  for (const [k, v] of Object.entries(q.data || {})) if (v !== null && v !== undefined) data[k] = String(v)
  return {
    message: {
      token: q.token,
      notification: { title: q.title, body: q.body },
      data,
      android: {
        priority: 'HIGH',
        ttl: '600s', // a "Leave now" more than 10 min late is no help
        // same tag = replaces the group's previous push (Get ready -> Leave now -> Running late)
        notification: { channel_id: 'moves', tag: data.tag || q.kind, default_sound: true, notification_priority: 'PRIORITY_HIGH' },
      },
      apns: { headers: { 'apns-priority': '10' }, payload: { aps: { alert: { title: q.title, body: q.body }, sound: 'default' } } },
    },
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS })
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  })

  // ---------- Who is calling? ----------
  let eventId: string | null = null
  let forced = false
  let queue = false
  const cronSecret = req.headers.get('x-cron-secret')
  if (cronSecret) {
    const { data: ok } = await admin.rpc('check_push_cron_secret', { p_secret: cronSecret })
    if (!ok) return json({ error: 'Not allowed' }, 401)
    const body = await req.json().catch(() => ({}))
    queue = body.queue === true
  } else {
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '')
    const { data: userData } = await admin.auth.getUser(jwt)
    // A token can still look valid after its login was ended (e.g. logged out everywhere): the
    // database accepts it until it expires, but the Auth server no longer knows the session.
    if (!userData || !userData.user) return json({ error: 'Your login has ended. Log out and sign in again.' }, 401)
    const body = await req.json().catch(() => ({}))
    eventId = typeof body.eventId === 'string' ? body.eventId : null
    if (!eventId) return json({ error: 'eventId missing' }, 400)
    const { data: roles } = await admin
      .from('event_roles')
      .select('role')
      .eq('event_id', eventId)
      .eq('user_id', userData.user.id)
      .in('role', ['root', 'planner'])
    if (!roles || roles.length === 0) return json({ error: 'Only the root or a planner can send reminders' }, 403)
    forced = body.start !== true // Start event now: the normal first reminder, not "a planner asked you"
  }

  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT')
  if (!raw) return json({ error: 'FCM_SERVICE_ACCOUNT secret is not set' }, 500)
  const sa = JSON.parse(raw) as ServiceAccount

  async function forgetIfGone(token: string, status: number, text: string) {
    // App uninstalled / token replaced: forget this phone
    if (status === 404 || text.includes('UNREGISTERED') || text.includes('registration token is not a valid')) {
      await admin.rpc('delete_push_token', { p_token: token })
    }
  }

  // ---------- Queued pushes (Stage 8): already worded and de-duplicated by the database ----------
  if (queue) {
    const { data: rows, error: qError } = await admin.rpc('claim_push_queue', { p_limit: 200 })
    if (qError) return json({ error: qError.message }, 500)
    if (!rows || rows.length === 0) return json({ sent: 0, failed: 0 })
    const accessToken = await getGoogleToken(sa)
    let sent = 0
    let failed = 0
    const list = rows as Queued[]
    for (let i = 0; i < list.length; i += 20) {
      await Promise.all(
        list.slice(i, i + 20).map(async (q) => {
          const res = await fetch('https://fcm.googleapis.com/v1/projects/' + sa.project_id + '/messages:send', {
            method: 'POST',
            headers: { Authorization: 'Bearer ' + accessToken, 'Content-Type': 'application/json' },
            body: JSON.stringify(queuedMessage(q)),
          })
          if (res.ok) {
            sent++
          } else {
            failed++
            const text = await res.text()
            console.error('[send-reminders] queued', q.kind, res.status, text)
            await forgetIfGone(q.token, res.status, text)
          }
        }),
      )
    }
    return json({ sent, failed })
  }

  // ---------- Who needs a reminder (the database also records it, so no double sends) ----------
  const { data: due, error } = await admin.rpc('claim_push_reminders', { p_event_id: eventId, p_force: forced })
  if (error) return json({ error: error.message }, 500)
  if (!due || due.length === 0) return json({ sent: 0, failed: 0 })

  const accessToken = await getGoogleToken(sa)
  let sent = 0
  let failed = 0
  async function sendOne(r: Reminder) {
    const res = await fetch('https://fcm.googleapis.com/v1/projects/' + sa.project_id + '/messages:send', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + accessToken, 'Content-Type': 'application/json' },
      body: JSON.stringify(messageFor(r)),
    })
    if (res.ok) {
      sent++
    } else {
      failed++
      const text = await res.text()
      console.error('[send-reminders] FCM', res.status, text)
      await forgetIfGone(r.token, res.status, text)
    }
  }
  // 20 at a time: one by one, an NDP-sized event (hundreds of ICs) took over half a minute to reach the last phone
  const list = due as Reminder[]
  for (let i = 0; i < list.length; i += 20) await Promise.all(list.slice(i, i + 20).map(sendOne))
  return json({ sent, failed })
})
