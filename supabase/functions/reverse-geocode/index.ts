// Supabase Edge Function: reverse-geocode
// Turns { lat, lng } into a Singapore place name using the OneMap Reverse Geocode API
// (https://www.onemap.gov.sg/apidocs/). OneMap needs a login token made from an account
// email + password; those are stored as Supabase secrets ONEMAP_EMAIL / ONEMAP_PASSWORD
// so they never reach the browser. Only logged-in app users can call this (JWT checked).

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// OneMap tokens last 3 days: keep one in memory while this function instance is warm
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

// OneMap writes "NIL" for empty fields
function clean(value: unknown): string {
  const text = String(value ?? '').trim()
  return text === '' || text.toUpperCase() === 'NIL' ? '' : text
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS })

  try {
    const { lat, lng } = await req.json()
    // Only accept numbers inside (roughly) Singapore
    if (typeof lat !== 'number' || typeof lng !== 'number' || lat < 1.1 || lat > 1.5 || lng < 103.5 || lng > 104.2) {
      return json({ error: 'lat/lng must be numbers inside Singapore' }, 400)
    }

    const url =
      'https://www.onemap.gov.sg/api/public/revgeocode?location=' + lat + ',' + lng +
      '&buffer=50&addressType=All&otherFeatures=N'
    const res = await fetch(url, { headers: { Authorization: await getOneMapToken() } })
    if (!res.ok) {
      console.error('OneMap revgeocode error', res.status, await res.text())
      return json({ error: 'OneMap error (' + res.status + ')' }, 502)
    }

    const data = await res.json()
    const info = data.GeocodeInfo && data.GeocodeInfo[0]
    if (!info) return json({ name: null }) // nothing within 50 m

    // e.g. "Li Ka Shing Library, 70 Stamford Rd"
    const building = clean(info.BUILDINGNAME)
    const street = [clean(info.BLOCK), clean(info.ROAD)].filter(Boolean).join(' ')
    const name = [building, street].filter(Boolean).join(', ') || null
    return json({ name })
  } catch (err) {
    const message = String(err instanceof Error ? err.message : err)
    console.error('reverse-geocode failed:', message) // shows in Supabase -> Edge Functions -> Logs
    return json({ error: message }, 500)
  }
})
