// Component test: the Groups page (components/MembersPanel.vue) as an IC sees it. ICs and members go straight to their
// own group (073), with no list of the other groups to wander into and no switches they are not allowed to use.
import { describe, it, expect } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import MembersPanel from '../MembersPanel.vue'

const groups = [
  { id: 'g-gate', name: 'Gate Crew', colour: '#0072B2' },
  { id: 'g-stage', name: 'Stage', colour: '#009E73' },
]
const person = (id, username, groupId, extra = {}) => ({ id, username, display_name: username, roles: [], groupId, isAdmin: false, isIC: false, ...extra })
const me = person('u-ic', 'qa_ic1', 'g-gate', { isIC: true })
const members = [me, person('u-m', 'qa_member', 'g-gate'), person('u-s', 'qa_stage', 'g-stage')]

async function mountAs(props) {
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div />' } }] })
  router.push('/events/ev1/groups')
  await router.isReady()
  const wrapper = mount(MembersPanel, { props: { eventId: 'ev1', members, groups, ...props }, global: { plugins: [router] } })
  await flushPromises()
  return wrapper
}

describe('MembersPanel', () => {
  it('opens on my own group and only that one, with no controls for a member who may not change it', async () => {
    const ic = await mountAs({ me, onlyGroupId: 'g-gate' })
    expect(ic.find('[data-testid="group-view-Gate Crew"]').exists()).toBe(true)
    expect(ic.find('[data-testid="group-view-Stage"]').exists()).toBe(false)
    expect(ic.find('[data-testid="group-card-Stage"]').exists()).toBe(false)
    expect(ic.find('[data-testid="group-back"]').exists()).toBe(false)

    expect(ic.find('[data-testid="member-qa_member"]').exists()).toBe(true)
    expect(ic.find('[data-testid="member-qa_stage"]').exists()).toBe(false)
    for (const control of ['group-ic-toggle-qa_member', 'group-select-qa_member', 'group-remove-qa_member', 'group-edit-btn', 'group-delete-btn']) {
      expect(ic.find(`[data-testid="${control}"]`).exists(), control).toBe(false)
    }
  })
})
