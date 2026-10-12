// Loads saved readings for playback from the database (root / planners only:
// location_history in 008_playback.sql). The database sends pages of 10 000 readings.
import { supabase } from '../lib/supabase'
import { buildRecording, rowsFromDatabase } from '../utils/playback'

async function fetchPage(eventId, from, to, afterId) {
  const { data, error } = await supabase.rpc('location_history', {
    p_event_id: eventId,
    p_from: new Date(from).toISOString(),
    p_to: new Date(to).toISOString(),
    p_after_id: afterId,
  })
  if (error) throw new Error(error.message)
  return data
}

// Whole recording between from and to. onProgress(readingsLoaded) after each page.
export async function loadRecording(eventId, from, to, onProgress = () => {}) {
  const first = await fetchPage(eventId, from, to, 0)
  const rows = rowsFromDatabase(first.rows)
  onProgress(rows.length)
  let next = first.next_after_id
  while (next !== null && next !== undefined) {
    const page = await fetchPage(eventId, from, to, next)
    rows.push(...rowsFromDatabase(page.rows))
    onProgress(rows.length)
    next = page.next_after_id
  }

  const people = {}
  for (const p of first.people) people[p.id] = { name: p.display_name, username: p.username }
  return buildRecording({ rows, people, groups: first.groups, from: new Date(from).getTime(), to: new Date(to).getTime() })
}

// Live rewind: readings uploaded since the last load (ids are increasing)
export async function loadNewRows(eventId, from, to, afterId) {
  const rows = []
  let next = afterId
  do {
    const page = await fetchPage(eventId, from, to, next)
    rows.push(...rowsFromDatabase(page.rows))
    next = page.next_after_id
  } while (next !== null && next !== undefined)
  return rows
}
