// Component: the event's dashboard, which is where "live operations" is actually read.
//
// EventOverview is the page a planner opens between two tasks: what the event is, whether it is live, how many people
// are in how many groups, and -- for the two roles that run it -- the code to bring more people in. Two things are
// worth testing here, and they are the two the component is built for: that the numbers and the status agree with
// what it was given, and that the controls it shows are the ones the person's role may actually use. The second is
// the one that goes wrong quietly: a member who can see the invite code is a member who can invite anyone in.
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import EventOverview from '../EventOverview.vue'

// The invite panel draws a QR code on a <canvas>, which jsdom does not have. The code itself is not what this file
// is about (see InvitePanel.spec.js), so it answers with a picture.
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async () => 'data:image/png;base64,AAAA') } }))

const EVENT = {
  id: 'e1',
  name: 'Night Walk',
  description: 'Along the river',
  venue: 'The Padang',
  starts_at: '2026-11-05T11:00:00Z',
  ends_at: '2026-11-05T15:00:00Z',
  join_code: 'ABC123',
}
const MEMBERS = [{ id: 'u1' }, { id: 'u2' }, { id: 'u3' }, { id: 'u4' }]
const GROUPS = [{ id: 'g1', name: 'Gate Crew' }, { id: 'g2', name: 'Stage' }]

function mountOverview(overrides = {}) {
  return mount(EventOverview, {
    props: {
      event: EVENT,
      members: MEMBERS,
      groups: GROUPS,
      role: 'planner',
      mode: 'view',
      isLive: true,
      myGroup: null,
      planName: '',
      ...overrides,
    },
  })
}

describe('the event dashboard', () => {
  it('reads out the status and the counts it was given, and shows the invite code to staff only', () => {
    const planner = mountOverview()
    expect(planner.get('[data-testid="overview-status"]').text()).toBe('Live now')
    expect(planner.text()).toContain('4 in 2 groups')
    expect(planner.get('[data-testid="join-code-display"]').text()).toBe('ABC123')

    // Not live, but with a start time: the status says when, rather than a bare "not live" that makes a planner
    // wonder whether anything is scheduled at all.
    const scheduled = mountOverview({
      isLive: false,
      scheduledStart: new Date('2026-11-05T13:00:00Z'),
    })
    expect(scheduled.get('[data-testid="overview-status"]').text()).toMatch(/^Starts /)

    // A member: no invite code (the database would refuse the read), their own group named, and no count of the
    // event they cannot see -- 073 gives a member their own group and nothing else.
    const member = mountOverview({ role: 'member', isLive: false, myGroup: GROUPS[0] })
    expect(member.find('[data-testid="join-code-display"]').exists()).toBe(false)
    expect(member.text()).toContain('Gate Crew')
    expect(member.text()).not.toContain('in 2 groups')
    expect(member.get('[data-testid="leave-event"]').exists()).toBe(true) // everyone else may leave
    expect(member.find('[data-testid="delete-event"]').exists()).toBe(false)

    // The root, in edit mode, is the only role offered "Delete event", and it is an emit -- the page decides, and
    // asks for the word first.
    const root = mountOverview({ role: 'root', mode: 'edit' })
    expect(root.get('[data-testid="delete-event"]').exists()).toBe(true)
  })

  it('will not save an end that is before the start, and saves nothing until something has changed', async () => {
    const wrapper = mountOverview({ role: 'root', mode: 'edit' })
    await wrapper.get('[data-testid="overview-edit-btn"]').trigger('click')

    // The form opens as a copy of the event, so nothing is "changed" and Save is not offered yet.
    const save = () => wrapper.get('[data-testid="overview-save"]')
    expect(save().attributes('disabled')).toBeDefined()

    await wrapper.get('[data-testid="overview-name"]').setValue('Night Walk 2026')
    expect(save().attributes('disabled')).toBeUndefined()

    // The wizard's rule, quoted in full: the end must be after the start.
    const startsAt = '2026-11-05T19:00'
    const endsAt = '2026-11-05T23:00'
    await wrapper.get('[data-testid="overview-start"]').setValue(startsAt)
    await wrapper.get('[data-testid="overview-end"]').setValue('2026-11-05T18:00')
    await wrapper.get('form').trigger('submit')
    expect(wrapper.text()).toContain('The end must be after the start')
    expect(wrapper.emitted('save-details')).toBeUndefined() // nothing was sent

    await wrapper.get('[data-testid="overview-end"]').setValue(endsAt)
    await wrapper.get('form').trigger('submit')
    expect(wrapper.text()).not.toContain('The end must be after the start')
    // datetime-local is the browser's local time; the database takes UTC, and the page does the conversion.
    expect(wrapper.emitted('save-details')).toEqual([
      [
        {
          name: 'Night Walk 2026',
          description: 'Along the river',
          venue: 'The Padang',
          startsAt: new Date(startsAt).toISOString(),
          endsAt: new Date(endsAt).toISOString(),
        },
      ],
    ])
  })
})
