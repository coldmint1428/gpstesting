// Event membership and role changes (033_people_and_roles.sql). Each call returns an error message, or '' on success;
// the database checks every rule again and its messages are written to be shown as they are.
import { supabase } from '../lib/supabase'

async function call(fn, params) {
  const { error } = await supabase.rpc(fn, params)
  if (error) return error.message
  forgetMembership(params.p_event_id)
  return ''
}

// Beyond the course (CLAUDE.md asks for Axios + an Express REST API): this project's backend is Supabase, so these
// call its database functions with supabase.rpc. Each still returns '' or the error's message, as the course's
// try...catch examples show it.
// An existing account, picked from searchPeople (034); groupId null = no group yet (group admins: their own group only)
export const addEventMember = (eventId, userId, groupId) =>
  call('add_event_member', { p_event_id: eventId, p_user_id: userId, p_group_id: groupId })

// 'planner' | 'admin' | 'member'
export const setMemberRole = (eventId, userId, role) =>
  call('set_member_role', { p_event_id: eventId, p_user_id: userId, p_new_role: role })

export const setMarshal = (eventId, userId, isMarshal) =>
  call('set_marshal', { p_event_id: eventId, p_user_id: userId, p_is_marshal: isMarshal })

export const setGroupIC = (groupId, userId, isIC) => call('set_group_ic', { p_group_id: groupId, p_user_id: userId, p_is_ic: isIC })

export const removeEventMember = (eventId, userId) => call('remove_event_member', { p_event_id: eventId, p_user_id: userId })

// Leaving yourself
export const leaveEvent = (eventId, myUserId) => call('remove_member', { p_event_id: eventId, p_user_id: myUserId })

// { name, description, venue, startsAt, endsAt } (times: Date or ISO text, or both null) - 035_event_details.sql
export const updateEventDetails = (eventId, d) =>
  call('update_event_details', {
    p_event_id: eventId,
    p_name: d.name,
    p_description: d.description,
    p_venue: d.venue,
    p_starts_at: d.startsAt,
    p_ends_at: d.endsAt,
  })

export const deleteEvent = (eventId) => call('delete_event', { p_event_id: eventId })

// ---------- My membership of an event (the router guard and the event page) ----------
// { role, group_id, is_admin, is_ic, is_simulation, live } or null when I am not in the event.
// Kept per event so moving between the event's pages needs no round trip; the event page refreshes it
// whenever its member list reloads (rememberMembership).
const memberships = new Map()

export async function fetchMembership(eventId, { fresh = false } = {}) {
  if (!fresh && memberships.has(eventId)) return memberships.get(eventId)
  const { data, error } = await supabase.rpc('my_event_membership', { p_event_id: eventId })
  if (error) throw error
  memberships.set(eventId, data)
  return data
}

export function rememberMembership(eventId, membership) {
  memberships.set(eventId, membership)
}

export function forgetMembership(eventId) {
  if (eventId) memberships.delete(eventId)
  else memberships.clear()
}
