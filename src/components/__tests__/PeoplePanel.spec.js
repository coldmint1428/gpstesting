// Component test: the People page (components/PeoplePanel.vue). Controls appear only where my role may act
// (utils/permissions.js), and the role filter offers only the roles somebody in the event actually has.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import PeoplePanel from '../PeoplePanel.vue'

const groups = [{ id: 'g1', name: 'Alpha', colour: '#0072B2' }]
const person = (id, username, extra = {}) => ({ id, username, display_name: username, roles: [], groupId: 'g1', isAdmin: false, isIC: false, toleranceM: 30, ...extra })
const rootMe = person('u-root', 'qa_root', { roles: ['root'], groupId: null })
const members = [
  rootMe,
  person('u-admin', 'qa_admin', { isAdmin: true }),
  person('u-ic1', 'qa_ic1', { isIC: true }),
  person('u-m', 'qa_member'),
]

function mountAs(me, mode = 'edit') {
  return mount(PeoplePanel, {
    props: { eventId: 'ev1', members, groups, me, mode },
    global: { stubs: { RouterLink: { template: '<a><slot /></a>' } } },
  })
}

describe('PeoplePanel', () => {
  it('offers a role change only on the rows this role may change, and only the roles somebody actually has', async () => {
    const root = mountAs(rootMe)
    expect(root.find('[data-testid="person-role-select-qa_member"]').exists()).toBe(true)
    expect(root.find('[data-testid="person-role-select-qa_admin"]').exists()).toBe(true)
    expect(root.find('[data-testid="person-role-select-qa_root"]').exists()).toBe(false)
    expect(root.find('[data-testid="person-ic-qa_ic1"]').exists()).toBe(true)

    // Root, Group Admin, Member and IC are in this event; nobody is a planner, so there is no Planner filter
    const filters = root.findAll('[data-testid^="people-role-"]').map((b) => b.attributes('data-testid'))
    expect(filters).toEqual(expect.arrayContaining(['people-role-all', 'people-role-root', 'people-role-admin', 'people-role-member', 'people-role-ic']))
    expect(root.find('[data-testid="people-role-planner"]').exists()).toBe(false)

    // A group admin changes nobody's role here, and a reader nothing at all
    const admin = mountAs(members[1])
    expect(admin.find('[data-testid^="person-role-select-"]').exists()).toBe(false)
    expect(admin.find('[data-testid="person-menu-qa_root"]').exists()).toBe(false)
    await admin.get('[data-testid="person-menu-qa_member"]').trigger('click')
    expect(admin.find('[data-testid="person-remove-qa_member"]').exists()).toBe(true)
    const reader = mountAs(rootMe, 'view')
    expect(reader.find('[data-testid^="person-role-select-"]').exists()).toBe(false)
  })
})
