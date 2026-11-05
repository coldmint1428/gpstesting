// Component: the Groups page, which is where "who is in which group, and who is its IC" is read.
//
// An IC and a member do not get a list of every group: 073 gives them their own, and this page is opened already
// narrowed to it (onlyGroupId). That narrowing is what this test is about -- a member who can scroll through the
// whole event's group structure has been shown the organisation of an event they cannot see. The other half is the
// same rule as the People page: the controls follow the role, and the database checks them again.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import MembersPanel from '../MembersPanel.vue'

const GROUPS = [
  { id: 'g1', name: 'Gate Crew', colour: '#0072B2' },
  { id: 'g2', name: 'Stage', colour: '#009E73' },
]
const MEMBERS = [
  { id: 'u1', username: 'qa_ic1', display_name: 'QA Ic1', roles: ['participant'], isIC: true, groupId: 'g1' },
  { id: 'u2', username: 'qa_member', display_name: 'QA Member', roles: ['participant'], groupId: 'g1' },
  { id: 'u3', username: 'qa_planner', display_name: 'QA Planner', roles: ['planner'], groupId: null },
]

async function mountPanel(props = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/events/:id/:page', name: 'event', component: { template: '<div />' } }],
  })
  await router.push('/events/e1/groups')
  await router.isReady()
  return mount(MembersPanel, {
    props: {
      eventId: 'e1',
      members: MEMBERS,
      groups: GROUPS,
      me: { id: 'u1', groupId: 'g1', roles: ['participant'], isIC: true },
      isRoot: false,
      canManage: false,
      onlyGroupId: 'g1',
      ...props,
    },
    global: { plugins: [router] },
  })
}

describe('the Groups page', () => {
  it('opens on my own group and only that one, with no controls for a member who may not change it', async () => {
    const ic = await mountPanel()

    // Straight into the group, not a list of every group in the event.
    expect(ic.find('[data-testid="group-view-Gate Crew"]').exists()).toBe(true)
    expect(ic.find('[data-testid="group-view-Stage"]').exists()).toBe(false)
    expect(ic.find('[data-testid="group-card-Stage"]').exists()).toBe(false)
    // ... and there is no "back to all groups" to press, because there is nothing behind it for this person.
    expect(ic.find('[data-testid="group-back"]').exists()).toBe(false)

    // The rows are the group's own people; somebody in another group (or in none) is not on this page at all.
    expect(ic.find('[data-testid="member-qa_member"]').exists()).toBe(true)
    expect(ic.find('[data-testid="member-qa_planner"]').exists()).toBe(false)

    // "Mine" is marked, so a member opening the app knows which card they are looking at.
    expect(ic.find('[data-testid="group-mine-chip"]').exists()).toBe(true)

    // A member may not rename, delete, create, or switch anybody's IC on.
    expect(ic.find('[data-testid="group-edit-btn"]').exists()).toBe(false)
    expect(ic.find('[data-testid="group-delete-btn"]').exists()).toBe(false)
    expect(ic.find('[data-testid="create-group-btn"]').exists()).toBe(false)
    expect(ic.find('[data-testid="group-ic-toggle-qa_member"]').exists()).toBe(false)

    // A planner arriving at the same page keeps every control, including the IC switch the People page sends them
    // here for.
    const planner = await mountPanel({ me: { id: 'p1', groupId: null, roles: ['planner'] }, canManage: true, isRoot: true, onlyGroupId: 'g1' })
    expect(planner.find('[data-testid="group-edit-btn"]').exists()).toBe(true)
    expect(planner.find('[data-testid="group-delete-btn"]').exists()).toBe(true)
    expect(planner.find('[data-testid="group-ic-toggle-qa_member"]').exists()).toBe(true)
  })
})
