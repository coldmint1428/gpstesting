// Supabase Edge Function: route-eta (merger Stage 7)
// Fetches OneMap walking / driving routes for groups on their way to a zone, so the movements engine
// (027_movements.sql, move_step) can measure the distance still to go along the real path instead of a
// straight line x 1.3. The database decides which routes are needed (route_claim: active movements of groups
// over 80 m away, no route yet, over 2 min old, or the group strayed > 50 m from it) and stores the answer
// (route_save). Nothing here is shown to anyone directly.
//
// Who may call it (deployed with verify_jwt = false; this file checks callers itself):
//   - pg_cron every 30 s while a route is due, with header x-cron-secret (the random secret in Supabase Vault
//     from 009_push_reminders.sql, checked by check_push_cron_secret)
// OneMap needs a login token made from an account email + password: the same Supabase secrets as
// reverse-geocode (ONEMAP_EMAIL / ONEMAP_PASSWORD), so they never reach the browser.
import { createClient } from 'npm:@supabase/supabase-js@2.117.2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } })
}

// ---------- OneMap login (tokens last 3 days: one is kept while this instance is warm) ----------
let token = ''
let tokenExpiresAt = 0 // seconds since 1970

async function getOneMapToken(): Promise<string> {
  const nowSeconds = Date.now() / 1000
  if (token && nowSeconds < tokenExpiresAt - 300) return token
  const email = Deno.env.get('ONEMAP_EMAIL')
  const password = Deno.env.get('ONEMAP_PASSWORD')
  if (!email || !password) throw new Error('OneMap secrets ONEMAP_EMAIL / ONEMAP_PASSWORD are not set')
  const res = await fetch('https://www.onemap.gov.sg/api/auth/post/getToken', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  if (!res.ok) throw new Error('OneMap login failed (' + res.status + ')')
  const data = await res.json()
  token = data.access_token
  tokenExpiresAt = Number(data.expiry_timestamp) || nowSeconds + 3600
  return token
}

// ---------- Encoded polyline (Google format) -> [[lat, lng], ...] ----------
export function decodePolyline(text: string, precision = 5): number[][] {
  const factor = Math.pow(10, precision)
  const points: number[][] = []
  let index = 0
  let lat = 0
  let lng = 0
  while (index < text.length) {
    for (const which of [0, 1]) {
      let shift = 0
      let result = 0
      let byte = 0
      do {
        byte = text.charCodeAt(index++) - 63
        result |= (byte & 0x1f) << shift
        shift += 5
      } while (byte >= 0x20 && index < text.length)
      const delta = result & 1 ? ~(result >> 1) : result >> 1
      if (which === 0) lat += delta
      else lng += delta
    }
    points.push([lat / factor, lng / factor])
  }
  return points
}

const inSingapore = (p: number[]) => p[0] > 1.1 && p[0] < 1.5 && p[1] > 103.5 && p[1] < 104.2

type Wanted = {
  session_id: string
  movement_id: string
  group_id: string
  mode: 'walk' | 'drive'
  from_lat: number
  from_lng: number
  to_lat: number
  to_lng: number
}

async function fetchRoute(w: Wanted) {
  const url =
    'https://www.onemap.gov.sg/api/public/routingsvc/route?start=' + w.from_lat + ',' + w.from_lng +
    '&end=' + w.to_lat + ',' + w.to_lng + '&routeType=' + w.mode
  const res = await fetch(url, { headers: { Authorization: await getOneMapToken() } })
  if (!res.ok) throw new Error('OneMap routing error (' + res.status + ')')
  const data = await res.json()
  const summary = data.route_summary || {}
  const geometry = typeof data.route_geometry === 'string' ? data.route_geometry : ''
  if (!geometry) throw new Error(String(data.status_message || data.error || 'OneMap found no route'))
  // OneMap's walk / drive routes use precision 5; a few answers have used 6 - the one that lands in Singapore wins
  let points = decodePolyline(geometry, 5)
  if (!points.length || !points.every(inSingapore)) points = decodePolyline(geometry, 6)
  if (points.length < 2 || !points.every(inSingapore)) throw new Error('OneMap route could not be read')
  return { points, distance: Number(summary.total_distance) || null, duration: Number(summary.total_time) || null }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS })

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  })

  const cronSecret = req.headers.get('x-cron-secret')
  if (!cronSecret) return json({ error: 'Not allowed' }, 401)
  const { data: ok } = await admin.rpc('check_push_cron_secret', { p_secret: cronSecret })
  if (!ok) return json({ error: 'Not allowed' }, 401)

  const { data: wanted, error } = await admin.rpc('route_claim', { p_limit: 20 })
  if (error) {
    console.error('route_claim failed:', error.message)
    return json({ error: error.message }, 500)
  }

  let saved = 0
  let failed = 0
  // A few at a time: OneMap allows about 250 calls a minute
  const queue = [...((wanted || []) as Wanted[])]
  async function worker() {
    for (let w = queue.shift(); w; w = queue.shift()) {
      let points: number[][] | null = null
      let distance: number | null = null
      let duration: number | null = null
      let problem: string | null = null
      try {
        const route = await fetchRoute(w)
        points = route.points
        distance = route.distance
        duration = route.duration
      } catch (err) {
        problem = String(err instanceof Error ? err.message : err)
      }
      const { error: saveError } = await admin.rpc('route_save', {
        p_session: w.session_id,
        p_movement: w.movement_id,
        p_group: w.group_id,
        p_points: points,
        p_distance_m: distance,
        p_duration_s: duration,
        p_from_lat: w.from_lat,
        p_from_lng: w.from_lng,
        p_to_lat: w.to_lat,
        p_to_lng: w.to_lng,
        p_error: problem,
      })
      if (saveError || problem) {
        failed++
        console.error('route-eta', w.group_id, problem || saveError?.message) // Supabase -> Edge Functions -> Logs
      } else {
        saved++
      }
    }
  }
  await Promise.all([worker(), worker(), worker(), worker()])
  return json({ wanted: (wanted || []).length, saved, failed })
})
