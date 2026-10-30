// Who may see and do what in an event. The database decides (033_people_and_roles.sql); these mirror its rules so
// the pages only show what the server would allow. Keep every list here, so it is one file to change.
//
// Top role (one per person, highest first): root > planner > admin (group admin) > member.
// Marshal and IC are duties on top of that, not ranks: a marshal (event_roles row) sees every group and the plan's
// ops board; an IC (group flag) shares GPS. "View role" 'marshal' / 'ic' is a member with that duty.

export const ROLE_RANK = { root: 4, planner: 3, admin: 2, member: 1 }
export const ROLE_LABEL = { root: 'Root', planner: 'Planner', marshal: 'Marshal', admin: 'Group admin', member: 'Member', ic: 'IC' }

// A member of useEventData ({ roles: ['planner', ...], isAdmin, isIC }) -> 'root' | 'planner' | 'admin' | 'member'
export function topRole(member) {
  if (!member) return null
  const roles = member.roles || []
  for (const r of ['root', 'planner']) if (roles.includes(r)) return r
  return member.isAdmin ? 'admin' : 'member'
}

export const isMarshal = (member) => !!member && (member.roles || []).includes('marshal')

// The role the pages are built for: a member who is marshal gets the marshal view, one who is IC the IC view
export function viewRole(membership) {
  if (!membership) return null
  if (membership.role !== 'member') return membership.role
  if (membership.is_marshal) return 'marshal'
  return membership.is_ic ? 'ic' : 'member'
}

// ---------- People page (managing people) ----------
export function canManage(actorRole, targetRole) {
  return (actorRole === 'root' || actorRole === 'planner') && ROLE_RANK[actorRole] > ROLE_RANK[targetRole]
}

export function assignableRoles(actorRole) {
  if (actorRole !== 'root' && actorRole !== 'planner') return []
  return ['planner', 'admin', 'member'].filter((r) => ROLE_RANK[r] < ROLE_RANK[actorRole])
}

// Marshal duty on / off: root / planners, for people below them
export function canSetMarshal(actor, target) {
  if (!actor || !target || actor.id === target.id) return false
  return canManage(topRole(actor), topRole(target))
}

// IC: root / planners in any group (themselves too); a group admin for themselves and members of their own group
export function canSetIC(actor, target) {
  if (!actor || !target || !target.groupId) return false
  const role = topRole(actor)
  if (role === 'root' || role === 'planner') return true
  if (!actor.isAdmin || actor.groupId !== target.groupId) return false
  return target.id === actor.id || topRole(target) === 'member'
}

// Remove from the event (never yourself: that is "Leave event")
export function canRemove(actor, target) {
  if (!actor || !target || actor.id === target.id) return false
  const role = topRole(actor)
  if (role === 'root' || role === 'planner') return ROLE_RANK[role] > ROLE_RANK[topRole(target)]
  return actor.isAdmin && !!actor.groupId && actor.groupId === target.groupId && topRole(target) === 'member'
}

// ---------- Event pages ----------
// Page keys are the URL: /events/:id/<page>
export const PAGES = ['overview', 'timeline', 'map', 'people', 'groups', 'live', 'playback', 'simulator']
export const PAGE_LABEL = {
  overview: 'Overview',
  timeline: 'Timeline',
  map: 'Map',
  groups: 'Groups',
  people: 'People',
  live: 'Live',
  playback: 'Playback',
  simulator: 'Simulator',
}

const EVERYONE = ['root', 'planner', 'marshal', 'admin', 'ic', 'member']
export const PAGE_ACCESS = {
  overview: EVERYONE,
  timeline: EVERYONE,
  map: EVERYONE,
  groups: EVERYONE,
  people: EVERYONE,
  live: EVERYONE,
  playback: ['root', 'planner'],
  simulator: ['root'], // and only in a simulation event
}

export const EDIT_ACCESS = {
  overview: ['root'], // event details, delete event
  timeline: ['root', 'planner'],
  map: ['root', 'planner'],
  groups: ['root', 'planner', 'admin'], // admin: own group only
  people: ['root', 'planner', 'admin'], // admin: IC and removing, own group only
}

// Not pages, but shown by role the same way
export const FEATURE_ACCESS = {
  invite: ['root', 'planner'], // the invite code / QR on the overview
  wholeEvent: ['root', 'planner', 'marshal'], // see every group (the ops board, the map)
}

export const canView = (page, role) => PAGE_ACCESS[page]?.includes(role) ?? false
export const canEdit = (page, role) => EDIT_ACCESS[page]?.includes(role) ?? false
export const can = (feature, role) => FEATURE_ACCESS[feature]?.includes(role) ?? false
export const pageMode = (page, role) => (canEdit(page, role) ? 'edit' : 'view')

// Where an event opens: the plan board for root / planners, groups for admins, the live view for marshals, ICs and
// members while the event is on. Out of a live event a marshal opens the timetable (they read every group's moments)
// and members and ICs the overview.
export function defaultPage(role, isLive) {
  if (role === 'root' || role === 'planner') return 'timeline'
  if (role === 'admin') return 'groups'
  if (isLive) return 'live'
  if (role === 'marshal') return 'timeline'
  return 'overview'
}
