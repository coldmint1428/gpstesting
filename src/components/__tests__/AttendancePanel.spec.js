// Component: taking a roll call, by hand and by QR.
//
// Attendance has two modes and the component has to behave differently in each without letting the modes blur: by
// hand, the IC ticks people; by QR, the people scan the IC's screen and only the planners may still mark somebody by
// hand (which is the whole reason QR mode exists -- it is used when the ICs are not trusted with the register). The
// screen also has to separate the three states a person can be in, because "not yet" is not "absent" until the roll
// call closes.
import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import AttendancePanel from '../AttendancePanel.vue'

// The QR is a <canvas> drawing, which jsdom cannot make; the panel only needs an <img> to be there.
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async () => 'data:image/png;base64,AAAA') } }))

const NOW = Date.parse('2026-11-05T20:00:00Z')
const GROUP = { id: 'g1', name: 'Gate Crew', colour: '#0072B2' }
const MEMBERS = [
  { id: 'u1', groupId: 'g1', username: 'qa_member', display_name: 'QA Member' },
  { id: 'u2', groupId: 'g1', username: 'qa_ic1', display_name: 'QA Ic1' },
]
const rollCall = (extra = {}) => ({
  id: 'r1',
  groupId: 'g1',
  title: 'Morning muster',
  mode: 'manual',
  openedAt: new Date(NOW - 60_000),
  closesAt: new Date(NOW + 9 * 60_000),
  open: true,
  ...extra,
})

function mountPanel(overrides = {}) {
  return mount(AttendancePanel, {
    props: {
      groups: [GROUP],
      members: MEMBERS,
      me: { id: 'p1', groupId: null },
      canManage: true,
      seesWholeEvent: true,
      mode: 'manual',
      rollcalls: [rollCall()],
      checkins: [],
      qr: null,
      now: NOW,
      busy: false,
      ...overrides,
    },
  })
}

describe('taking a roll call', () => {
  it('by hand: counts who is present, who is not marked yet, and sends the one mark that was asked for', async () => {
    const wrapper = mountPanel({
      checkins: [{ rollcallId: 'r1', userId: 'u1', status: 'present', method: 'scan', at: new Date(NOW - 30_000) }],
    })

    // The mode switch is offered to the people who choose it, and left off for everyone else.
    expect(wrapper.find('[data-testid="attendance-mode"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="attendance-mode-qr"]').exists()).toBe(true)

    // One scanned, one not marked. "Not yet" is its own list: nobody is absent while the roll call is open.
    expect(wrapper.get('[data-testid="attendance-count"]').text()).toContain('1 of 2 present')
    expect(wrapper.find('[data-testid="att-present-qa_member"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="att-waiting-qa_ic1"]').exists()).toBe(true)

    // A mark is one message to the page, naming the roll call and the person: this component never writes.
    await wrapper.get('[data-testid="att-mark-qa_ic1"]').trigger('click')
    expect(wrapper.emitted('mark')).toEqual([[{ id: 'r1', userId: 'u2', status: 'present' }]])

    // By hand, the person running it closes it themselves (in QR mode the codes simply stop).
    expect(wrapper.find('[data-testid="attendance-close"]').exists()).toBe(true)
  })

  it('by QR: shows the code that changes every 5 seconds, and only a planner may still tick somebody by hand', async () => {
    const qrCall = rollCall({ mode: 'qr' })
    const qr = { rollcallId: 'r1', text: 'PLANOVA-ATT|r1|tok', secondsLeft: 3 }

    // The IC running their own group's QR roll call: the register is read-only to them.
    const ic = mountPanel({
      rollcalls: [qrCall],
      mode: 'qr',
      // The code arrives after the roll call opens: the page asks the database for one every 5 seconds.
      qr: null,
      canManage: false,
      seesWholeEvent: false,
      // A member who is also the group's IC: they run the roll call, but they are not event staff.
      me: { id: 'u2', groupId: 'g1', isIC: true, isAdmin: false },
    })
    expect(ic.find('[data-testid="attendance-qr-box"]').exists()).toBe(true)
    await ic.setProps({ qr })
    await flushPromises()
    expect(ic.find('[data-testid="attendance-qr"]').exists()).toBe(true)
    // The page is told which roll call's code to show, so it can keep it fresh.
    expect(ic.emitted('show-qr')).toEqual([['r1']])
    // In QR mode nobody ticks by hand, so the IC gets no buttons at all -- and no "not yet" press to make by mistake.
    expect(ic.find('[data-testid="att-mark-qa_member"]').exists()).toBe(false)
    expect(ic.text()).toContain('Only planners can mark people by hand here.')
    // The mode switch belongs to the planners too.
    expect(ic.find('[data-testid="attendance-mode"]').exists()).toBe(false)

    // A planner watching the same QR roll call keeps the by-hand override: it is the fallback for a phone with no
    // camera or a person who arrived without it.
    const planner = mountPanel({ rollcalls: [qrCall], mode: 'qr', qr: null })
    await planner.setProps({ qr })
    expect(planner.find('[data-testid="att-mark-qa_member"]').exists()).toBe(true)
    expect(planner.text()).not.toContain('Only planners can mark people by hand here.')
    // ... and the QR box shows how much of the current code's five seconds is left.
    await flushPromises()
    expect(planner.get('[role="progressbar"]').attributes('aria-valuenow')).toBe('3')
  })
})
