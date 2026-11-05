// Unit: the one rule that decides who the operations dashboard is for.
//
// The dashboard is the screen a planner watches during a run -- every group, every IC, at once. That is a permission
// question before it is a screen question, and `can('wholeEvent', role)` is the answer the pages ask. The database
// decides again (033_people_and_roles.sql): these lists only hide what the server would already refuse, so a page
// that shows the wrong person a control argues with the database in front of the user. This pins the whole matrix
// down in one place, because every role's version of "the dashboard" is drawn from it.
import { describe, it, expect } from 'vitest'
import { ROLE_LABEL, topRole, viewRole, canManage, canRemove, canView, canEdit, can, pageMode, defaultPage } from '../permissions'

/** What each role is allowed to see of the whole event. One row per role, written out as a claim to check. */
const DASHBOARD = [
  // role,       whole event, the zones map, the people page, editing the plan, opens on
  { role: 'root', whole: true, map: true, people: true, plan: true, opens: 'timeline' },
  { role: 'planner', whole: true, map: true, people: true, plan: true, opens: 'timeline' },
  { role: 'admin', whole: false, map: false, people: true, plan: false, opens: 'groups' },
  { role: 'ic', whole: false, map: false, people: false, plan: false, opens: 'overview' },
  { role: 'member', whole: false, map: false, people: false, plan: false, opens: 'overview' },
]

describe('who the operations dashboard is for', () => {
  it('gives the whole event to the root and the planners, and everyone else their own group', () => {
    for (const row of DASHBOARD) {
      const at = (what) => `${what} for ${row.role}`
      expect(can('wholeEvent', row.role), at('wholeEvent')).toBe(row.whole)
      expect(canView('map', row.role), at('map')).toBe(row.map)
      expect(canView('people', row.role), at('people')).toBe(row.people)
      expect(canEdit('timeline', row.role), at('edit the plan')).toBe(row.plan)
      // The dashboard is a reading screen for everyone, planners included: the buttons that change the run live
      // beside the status (EventStatus), not on the board.
      expect(pageMode('live', row.role), at('pageMode live')).toBe('view')
      // Where an event opens for this role, before anybody has navigated.
      expect(defaultPage(row.role, false), at('defaultPage')).toBe(row.opens)
    }

    // An IC is a duty on top of being a member, not a rank: the IC view is a different page set, never more access.
    expect(viewRole({ role: 'member', is_ic: true })).toBe('ic')
    expect(viewRole({ role: 'planner', is_ic: false })).toBe('planner')
    expect(viewRole(null)).toBe(null)
    expect(can('invite', 'ic')).toBe(false) // the code is for the people who run the event
    expect(can('wholeEvent', 'ic')).toBe(false)

    // Ranks: nobody manages their equal or their better, and nobody removes themselves (that is "Leave event").
    expect(canManage('root', 'planner')).toBe(true)
    expect(canManage('planner', 'root')).toBe(false)
    expect(canManage('admin', 'member')).toBe(false) // a group admin is not event staff
    expect(canRemove({ id: 'me', roles: ['root'] }, { id: 'me', roles: ['root'] })).toBe(false)
    expect(topRole({ roles: ['root', 'planner'] })).toBe('root') // the highest wins
    expect(ROLE_LABEL.ic).toBe('IC') // ... but the raw role still has a name to show
  })
})
