// Who may see and do what in an event. The database decides (033_people_and_roles.sql); these mirror its rules so
// the pages only show what the server would allow. Keep every list here, so it is one file to change.
//
// Top role (one per person, highest first): root > planner > admin (group admin) > member.
// IC is a duty on top of that, not a rank: an IC (group flag) shares GPS. "View role" 'ic' is a member with that duty.

export const ROLE_RANK = { root: 4, planner: 3, admin: 2, member: 1 }
export const ROLE_LABEL = { root: 'Root', planner: 'Planner', admin: 'Group admin', member: 'Member', ic: 'IC' }

// A member of useEventData ({ roles: ['planner', ...], isAdmin, isIC }) -> 'root' | 'planner' | 'admin' | 'member'
export function topRole(member) {
  if (!member) return null
  const roles = member.roles || []
  for (const r of ['root', 'planner']) if (roles.includes(r)) return r
  return member.isAdmin ? 'admin' : 'member'
}

// The role the pages are built for: a member who is IC gets the IC view
export function viewRole(membership) {
  if (!membership) return null
  if (membership.role !== 'member') return membership.role
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
// Page keys are the URL: /events/:id/<page>. In the order of the side menu: what everyone uses first, planning
// pages next, then people, then the planners' tools.
export const PAGES = ['overview', 'live', 'timeline', 'rehearsals', 'map', 'groups', 'people', 'attendance', 'playback']
export const PAGE_LABEL = {
  overview: 'Overview',
  timeline: 'Timeline',
  rehearsals: 'Rehearsals',
  map: 'Map',
  groups: 'Groups',
  people: 'People',
  attendance: 'Attendance',
  live: 'Live',
  playback: 'Playback',
}

const EVERYONE = ['root', 'planner', 'admin', 'ic', 'member']
// Everyone opens Timeline and Map: members, ICs and admins see their own group's timetable and map (the planning
// stage, 040 and later); only root and planners edit them (EDIT_ACCESS).
export const PAGE_ACCESS = {
  overview: EVERYONE,
  timeline: EVERYONE,
  rehearsals: EVERYONE, // a calendar; only root and planners schedule them (EDIT_ACCESS, 079)
  map: EVERYONE,
  groups: EVERYONE, // ICs and members: their own group only
  people: ['root', 'planner', 'admin'], // ICs and members cannot see everyone in the event (073)
  attendance: EVERYONE, // checking in; ICs, admins and planners also run roll calls (071)
  live: EVERYONE,
  playback: ['root', 'planner'],
}

export const EDIT_ACCESS = {
  overview: ['root'], // event details, delete event
  timeline: ['root', 'planner'],
  rehearsals: ['root', 'planner'],
  map: ['root', 'planner'],
  groups: ['root', 'planner', 'admin'], // admin: own group only
  people: ['root', 'planner', 'admin'], // admin: IC and removing, own group only
}

// Not pages, but shown by role the same way
export const FEATURE_ACCESS = {
  invite: ['root', 'planner'], // the invite code / QR on the overview
  wholeEvent: ['root', 'planner'], // see every group (the ops board, the map)
}

export const canView = (page, role) => PAGE_ACCESS[page]?.includes(role) ?? false
export const canEdit = (page, role) => EDIT_ACCESS[page]?.includes(role) ?? false
export const can = (feature, role) => FEATURE_ACCESS[feature]?.includes(role) ?? false
export const pageMode = (page, role) => (canEdit(page, role) ? 'edit' : 'view')

// Where an event opens: the plan board for root / planners, groups for admins, the live view for ICs and members while
// the event is on, and the overview when it is not.
export function defaultPage(role, isLive) {
  if (role === 'root' || role === 'planner') return 'timeline'
  if (role === 'admin') return 'groups'
  if (isLive) return 'live'
  return 'overview'
}
