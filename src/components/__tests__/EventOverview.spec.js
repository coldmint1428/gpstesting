// Component tests: the event's Overview (components/EventOverview.vue). It reads out what the event page gives it, shows
// the invite code only to the people who may hand it out, and lets the root edit the details only into a valid state.
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import EventOverview from '../EventOverview.vue'

// The QR on the invite panel is drawn by a canvas library jsdom does not have
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async () => 'data:image/png;base64,') } }))

const event = {
  id: 'ev1',
  name: 'Night Walk',
  description: '',
  venue: 'Padang',
  starts_at: '2026-11-05T11:00:00.000Z',
  ends_at: '2026-11-05T15:00:00.000Z',
  join_code: 'ABC123',
}
const groups = [
  { id: 'g1', name: 'Alpha' },
  { id: 'g2', name: 'Bravo' },
]
const members = [{ id: 'u1' }, { id: 'u2' }, { id: 'u3' }, { id: 'u4' }]

function mountOverview(props = {}) {
  return mount(EventOverview, { props: { event, members, groups, role: 'planner', ...props } })
}

describe('EventOverview', () => {
  it('reads out the status and the counts it was given, and shows the invite code to staff only', () => {
    const planner = mountOverview({ isLive: true })
    expect(planner.get('[data-testid="overview-status"]').text()).toBe('Live now')
    expect(planner.text()).toContain('4 in 2 groups')
    expect(planner.get('[data-testid="join-code-display"]').text()).toBe('ABC123')

    const scheduled = mountOverview({ scheduledStart: new Date('2026-11-05T11:00:00.000Z') })
    expect(scheduled.get('[data-testid="overview-status"]').text()).toMatch(/^Starts /)
    expect(mountOverview().get('[data-testid="overview-status"]').text()).toBe('Not live')

    const member = mountOverview({ role: 'member', myGroup: groups[0] })
    expect(member.find('[data-testid="join-code-display"]').exists()).toBe(false)
    expect(member.text()).not.toContain('4 in 2 groups') // a member has no count for the whole event
    expect(member.text()).toContain('Alpha')
  })

  it('will not save an end that is before the start, and saves nothing until something has changed', async () => {
    const wrapper = mountOverview({ role: 'root', mode: 'edit' })
    await wrapper.get('[data-testid="overview-edit-btn"]').trigger('click')
    const save = () => wrapper.get('[data-testid="overview-save"]')

    expect(save().attributes('disabled')).toBeDefined()
    await wrapper.get('[data-testid="overview-name"]').setValue('Night Walk 2026')
    expect(save().attributes('disabled')).toBeUndefined()

    const startsAt = '2026-11-05T19:00'
    await wrapper.get('[data-testid="overview-start"]').setValue(startsAt)
    await wrapper.get('[data-testid="overview-end"]').setValue('2026-11-05T18:00')
    await wrapper.get('[data-testid="overview-edit"]').trigger('submit')
    expect(wrapper.emitted('save-details')).toBeUndefined()
    expect(wrapper.text()).toContain('The end must be after the start')

    await wrapper.get('[data-testid="overview-end"]').setValue('2026-11-05T22:00')
    await wrapper.get('[data-testid="overview-edit"]').trigger('submit')
    expect(wrapper.emitted('save-details')).toHaveLength(1)
    expect(wrapper.emitted('save-details')[0][0]).toMatchObject({
      name: 'Night Walk 2026',
      startsAt: new Date(startsAt).toISOString(),
      endsAt: new Date('2026-11-05T22:00').toISOString(),
    })
  })
})
