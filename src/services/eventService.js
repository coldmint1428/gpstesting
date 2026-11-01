// eventService - the database calls for creating, listing and joining events.
// Pages and components call these instead of Supabase directly. Each one throws an Error
// with a readable message when something goes wrong.
import { supabase } from '../lib/supabase'

function db() {
  if (!supabase) throw new Error('The database is not set up (.env is missing)')
  return supabase
}

// A readable message for a failed call: no signal (common at a crowded venue) says so instead of "Failed to fetch"
function fail(error) {
  const msg = (error && error.message) || String(error)
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
    return new Error('No connection to the server. Check your internet and try again.')
  }
  return new Error(msg)
}

// A full email address, the shape the database checks too: something@something.something, no spaces
export function looksLikeEmail(value) {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(value || '').trim())
}

// Find the one account with exactly this email (068_find_person_by_email.sql): the wizard's step 2 and the People
// page. Nothing is suggested while typing and no list comes back -- the way email to someone outside your
// organisation works. Returns { id, display_name } or null (no such account, yourself, or not a full address).
export async function findPersonByEmail(email) {
  const clean = String(email || '').trim()
  if (!looksLikeEmail(clean)) return null
  const { data, error } = await db().rpc('find_person_by_email', { p_email: clean })
  if (error) throw fail(error)
  return data && data.length ? data[0] : null
}

// Step 4 of the wizard: save everything in ONE transaction (030_event_wizard.sql). Returns the event id.
// event   : { name, description, venue, starts_at, ends_at }   (ISO times)
// members : [{ user_id, role }]                                 (participant | planner | marshal)
// groups  : [{ name, colour, members: [{ user_id, is_admin, is_ic }] }]
export async function createEventWithSetup({ event, members, groups }) {
  const { data, error } = await db().rpc('create_event_with_setup', {
    p_event: event,
    p_members: members,
    p_groups: groups,
  })
  if (error) throw fail(error)
  return data
}

// Name-only event (the simulation events on the events page). Returns the event id.
export async function createQuickEvent(name, isSimulation = false) {
  const { data, error } = await db().rpc(isSimulation ? 'create_simulation_event' : 'create_event', {
    p_name: name,
  })
  if (error) throw fail(error)
  return data
}

// The events I am in, newest first:
// [{ id, name, created_at, isSimulation, startsAt, venue, roles: ['root', ...], isAdmin, isIC }]
export async function getMyEvents(userId) {
  // My role rows, each with its event (RLS only returns events I belong to), and my group flags (for the role badge)
  const [roles, flags] = await Promise.all([
    db().from('event_roles').select('role, events (id, name, created_at, is_simulation, starts_at, venue)').eq('user_id', userId),
    db().from('group_members').select('event_id, is_admin, is_ic').eq('user_id', userId),
  ])
  if (roles.error || flags.error) throw fail(roles.error || flags.error)
  const data = roles.data
  const flagsByEvent = Object.fromEntries(flags.data.map((f) => [f.event_id, f]))

  // One entry per event, with all my roles in it
  const byId = {}
  for (const row of data) {
    const ev = row.events
    if (!byId[ev.id]) {
      const f = flagsByEvent[ev.id] || {}
      byId[ev.id] = {
        id: ev.id,
        name: ev.name,
        created_at: ev.created_at,
        isSimulation: ev.is_simulation,
        startsAt: ev.starts_at,
        venue: ev.venue,
        roles: [],
        isAdmin: !!f.is_admin,
        isIC: !!f.is_ic,
      }
    }
    byId[ev.id].roles.push(row.role)
  }
  return Object.values(byId).sort((a, b) => b.created_at.localeCompare(a.created_at))
}

// Join with a 6-character code (as a participant). Returns the event id.
export async function joinEventByCode(code) {
  const { data, error } = await db().rpc('join_event', { p_code: code })
  if (error) throw fail(error)
  return data
}

// Phone app, My events: which of these events are live right now (a session that has started and not ended).
// Members may read their events' sessions (007_event_sessions.sql, "members see sessions").
export async function getLiveEventIds(eventIds) {
  if (!eventIds.length) return []
  const { data, error } = await db()
    .from('event_sessions')
    .select('event_id')
    .in('event_id', eventIds)
    .is('ended_at', null)
    .lte('starts_at', new Date().toISOString())
  if (error) throw fail(error)
  return data.map((r) => r.event_id)
}
