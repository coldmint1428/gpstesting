// eventService - the database calls for creating, listing and joining events.
// Pages and components call these instead of Supabase directly. Each one throws an Error
// with a readable message when something goes wrong.
import { supabase } from '../lib/supabase'

function db() {
  if (!supabase) throw new Error('The database is not set up (.env is missing)')
  return supabase
}

// Characters that would break the search, and the "@" people type in front of usernames
function cleanSearchTerm(term) {
  return String(term || '')
    .replace(/[,()%*]/g, '')
    .trim()
    .replace(/^@/, '')
}

// Step 2 of the wizard: find accounts by username, display name or a whole email address.
// Returns [{ id, username, display_name }] (at most 10; never the caller; [] for under 2 characters)
export async function searchPeople(term) {
  const clean = cleanSearchTerm(term)
  if (clean.length < 2) return []
  const { data, error } = await db().rpc('search_people', { p_term: clean })
  if (error) throw new Error(error.message)
  return data
}

// Step 4 of the wizard: save everything in ONE transaction (023_event_wizard.sql). Returns the event id.
// event   : { name, description, venue, starts_at, ends_at }   (ISO times)
// members : [{ user_id, role }]                                 (participant | planner | marshal)
// groups  : [{ name, colour, members: [{ user_id, is_admin, is_ic }] }]
export async function createEventWithSetup({ event, members, groups }) {
  const { data, error } = await db().rpc('create_event_with_setup', {
    p_event: event,
    p_members: members,
    p_groups: groups,
  })
  if (error) throw new Error(error.message)
  return data
}

// Name-only event (the simulation events on the events page). Returns the event id.
export async function createQuickEvent(name, isSimulation = false) {
  const { data, error } = await db().rpc(isSimulation ? 'create_simulation_event' : 'create_event', {
    p_name: name,
  })
  if (error) throw new Error(error.message)
  return data
}

// The events I am in, newest first: [{ id, name, created_at, isSimulation, roles: ['root', ...] }]
export async function getMyEvents(userId) {
  // My role rows, each with its event (RLS only returns events I belong to)
  const { data, error } = await db()
    .from('event_roles')
    .select('role, events (id, name, created_at, is_simulation)')
    .eq('user_id', userId)
  if (error) throw new Error(error.message)

  // One entry per event, with all my roles in it
  const byId = {}
  for (const row of data) {
    const ev = row.events
    if (!byId[ev.id]) byId[ev.id] = { id: ev.id, name: ev.name, created_at: ev.created_at, isSimulation: ev.is_simulation, roles: [] }
    byId[ev.id].roles.push(row.role)
  }
  return Object.values(byId).sort((a, b) => b.created_at.localeCompare(a.created_at))
}

// Join with a 6-character code (as a participant). Returns the event id.
export async function joinEventByCode(code) {
  const { data, error } = await db().rpc('join_event', { p_code: code })
  if (error) throw new Error(error.message)
  return data
}
