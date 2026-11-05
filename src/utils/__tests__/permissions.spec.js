// Unit test: who may see and do what (utils/permissions.js). The database decides (033, 073); this table is what the
// pages promise, role by role, so a change to one list shows up here as the row it changed.
import { describe, it, expect } from 'vitest'
import { can, canView, canEdit } from '../permissions'

//                 role       whole  map    people plan
const TABLE = [
  { role: 'root', whole: true, map: true, people: true, plan: true },
  { role: 'planner', whole: true, map: true, people: true, plan: true },
  { role: 'admin', whole: false, map: false, people: true, plan: false },
  { role: 'ic', whole: false, map: false, people: false, plan: false },
  { role: 'member', whole: false, map: false, people: false, plan: false },
]

describe('permissions', () => {
  it('gives the whole event to the root and the planners, and everyone else their own group', () => {
    for (const row of TABLE) {
      const at = (what) => `${row.role}: ${what}`
      expect(can('wholeEvent', row.role), at('wholeEvent')).toBe(row.whole)
      expect(canView('map', row.role), at('map')).toBe(row.map)
      expect(canView('people', row.role), at('people')).toBe(row.people)
      expect(canEdit('timeline', row.role), at('edit the plan')).toBe(row.plan)
      // everyone opens their own group's timeline and groups
      expect(canView('timeline', row.role), at('timeline')).toBe(true)
      expect(canView('groups', row.role), at('groups')).toBe(true)
    }
  })
})
