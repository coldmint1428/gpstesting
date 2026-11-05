// Component: the People page, where the event's roster is managed.
//
// Every control on this page is drawn from a permission (utils/permissions.js), and the database checks each one
// again (033). What this file tests is the half only the page can get wrong: offering a role change to somebody who
// may not make it, or offering one on the row of a person who outranks them. A control that appears and is then
// refused teaches the user the wrong thing about their own role.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import PeoplePanel from '../PeoplePanel.vue'

const MEMBERS = [
  { id: 'u1', username: 'qa_member', display_name: 'QA Member', roles: ['participant'], groupId: 'g1' },
  { id: 'u2', username: 'qa_admin', display_name: 'QA Admin', roles: ['participant'], isAdmin: true, groupId: 'g1' },
  { id: 'u3', username: 'qa_root', display_name: 'QA Root', roles: ['root'], groupId: null },
  { id: 'u4', username: 'qa_ic1', display_name: 'QA Ic1', roles: ['participant'], isIC: true, groupId: 'g1' },
]
const GROUPS = [
  { id: 'g1', name: 'Gate Crew' },
  { id: 'g2', name: 'Stage' },
]
const ROOT = { id: 'p1', roles: ['root'], isAdmin: false, groupId: null }

const mountPanel = (props = {}) =>
  mount(PeoplePanel, {
    props: { eventId: 'e1', members: MEMBERS, groups: GROUPS, me: ROOT, mode: 'edit', ...props },
    // The page links to the Groups page (where IC is set); the link itself is the router's business, not this file's.
    global: { stubs: { RouterLink: { template: '<a><slot /></a>' } } },
  })

describe('the People page', () => {
  it('offers a role change only on the rows this role may change, and only the roles somebody actually has', () => {
    const root = mountPanel()

    // A root may change a member's and a group admin's role...
    expect(root.find('[data-testid="person-role-select-qa_member"]').exists()).toBe(true)
    expect(root.find('[data-testid="person-role-select-qa_admin"]').exists()).toBe(true)
    // ... but not another root's: nobody manages their equal, or their better.
    expect(root.find('[data-testid="person-role-select-qa_root"]').exists()).toBe(false)
    // IC is a duty, not a rank, so it is a badge here and switched on the Groups page.
    expect(root.find('[data-testid="person-ic-qa_ic1"]').exists()).toBe(true)
    expect(root.find('[data-testid="person-role-select-qa_ic1"]').exists()).toBe(true) // still a member, role-wise

    // The filter buttons only offer roles that somebody has: a "Planner (0)" button is a dead end.
    expect(root.find('[data-testid="people-role-all"]').exists()).toBe(true)
    expect(root.find('[data-testid="people-role-root"]').exists()).toBe(true)
    expect(root.find('[data-testid="people-role-admin"]').exists()).toBe(true)
    expect(root.find('[data-testid="people-role-planner"]').exists()).toBe(false)
    expect(root.find('[data-testid="people-role-member"]').exists()).toBe(true)
    expect(root.find('[data-testid="people-role-ic"]').exists()).toBe(true)

    // The page says where IC is set, rather than hiding it and leaving a planner to hunt for it.
    expect(root.get('[data-testid="people-scope"]').text()).toContain('ICs are set on the Groups page')

    // A member is not a manager: no role select, and no way to add anybody.
    const member = mountPanel({ me: { id: 'u1', roles: ['participant'], isAdmin: false, groupId: 'g1' }, mode: 'edit' })
    expect(member.find('[data-testid="person-role-select-qa_admin"]').exists()).toBe(false)
    expect(member.find('[data-testid="add-person-btn"]').exists()).toBe(false)

    // Read-only (an IC or member opening the page at all): nothing is offered, because nothing is allowed.
    const reader = mountPanel({ mode: 'view' })
    expect(reader.find('[data-testid="person-role-select-qa_member"]').exists()).toBe(false)
    expect(reader.get('[data-testid="people-scope"]').text()).toContain('You can see everyone in this event')
  })
})
