// useReverseGeocode - turns coordinates into a place name ("Blk 81 Victoria St").
// Calls our Supabase Edge Function "reverse-geocode", which calls the OneMap API
// (OneMap needs a login token, which must stay on the server, never in the browser).
// Results are cached by position rounded to ~11 m, so hovering again costs nothing
// and we stay well inside OneMap's free limits.
import { supabase } from '../lib/supabase'

const cache = new Map() // shared by every map on the page: "lat,lng" -> name (or null)

export async function placeName(lat, lng) {
  const key = lat.toFixed(4) + ',' + lng.toFixed(4)
  if (cache.has(key)) return cache.get(key)

  try {
    const { data, error } = await supabase.functions.invoke('reverse-geocode', { body: { lat, lng } })
    if (error || !data) return null // failed: don't cache, so we try again next time
    cache.set(key, data.name) // only remember answers that worked (name, or null = nothing nearby)
    return data.name
  } catch {
    return null // network error: show "unavailable" instead of breaking the map
  }
}
