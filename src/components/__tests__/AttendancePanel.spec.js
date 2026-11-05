// Component tests: the Attendance page (components/AttendancePanel.vue), in its two modes. The panel only shows things
// and says what was asked for; the event page calls the database.
import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import AttendancePanel from '../AttendancePanel.vue'

// The QR is drawn by a canvas library jsdom does not have
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async (text) => 'data:image/png;base64,' + btoa(text)) } }))

const NOW = new Date('2026-11-05T12:00:00Z').getTime()
const groups = [{ id: 'g1', name: 'Alpha', colour: '#0072B2' }]
const person = (id, username, extra = {}) => ({ id, username, display_name: username, groupId: 'g1', isIC: false, isAdmin: false, ...extra })
const ic = person('u-ic', 'qa_ic1', { isIC: true })
const member = person('u-m', 'qa_member')
const other = person('u-o', 'qa_ic2')
const planner = { id: 'u-p', username: 'qa_planner', display_name: 'qa_planner', groupId: null }
const rollcall = (mode) => ({
  id: 'rc1',
  groupId: 'g1',
  title: 'Morning muster',
  mode,
  openedAt: new Date(NOW - 60_000),
  closesAt: new Date(NOW + 9 * 60_000),
  closedAt: null,
  open: true,
})

function mountPanel(props) {
  return mount(AttendancePanel, {
    props: { groups, members: [ic, member, other], checkins: [], now: NOW, ...props },
    global: { stubs: { QrScanner: true } },
  })
}

describe('AttendancePanel', () => {
  it('by hand: counts who is present, who is not marked yet, and sends the one mark that was asked for', async () => {
    const wrapper = mountPanel({
      me: planner,
      canManage: true,
      seesWholeEvent: true,
      members: [member, other],
      rollcalls: [rollcall('manual')],
      checkins: [{ rollcallId: 'rc1', userId: 'u-m', status: 'present', method: 'manual', at: new Date(NOW - 30_000) }],
    })
    expect(wrapper.find('[data-testid="attendance-mode"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="attendance-mode-qr"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="attendance-count"]').text()).toContain('1 of 2 present')
    expect(wrapper.find('[data-testid="att-present-qa_member"]').exists()).toBe(true)

    await wrapper.get('[data-testid="att-mark-qa_ic2"]').trigger('click')
    expect(wrapper.emitted('mark')).toEqual([[{ id: 'rc1', userId: 'u-o', status: 'present' }]])
  })

  it('by QR: shows the code that changes every 5 seconds, and only a planner may still tick somebody by hand', async () => {
    const ic = mountPanel({ me: { ...person('u-ic', 'qa_ic1'), isIC: true }, mode: 'qr', rollcalls: [rollcall('qr')] })
    expect(ic.emitted('show-qr')).toEqual([['rc1']]) // the page is asked to start the changing code
    expect(ic.find('[data-testid="attendance-qr-box"]').exists()).toBe(true)
    expect(ic.find('[data-testid="attendance-qr"]').exists()).toBe(false) // no code yet: "Loading…"

    const qr = { rollcallId: 'rc1', text: 'PLANOVA-ATT|rc1|t0k3n', secondsLeft: 5 }
    await ic.setProps({ qr })
    await flushPromises()
    expect(ic.find('[data-testid="attendance-qr"]').exists()).toBe(true)
    expect(ic.find('[data-testid="attendance-mode"]').exists()).toBe(false) // the IC does not choose the mode
    expect(ic.find('[data-testid="att-mark-qa_member"]').exists()).toBe(false)
    expect(ic.text()).toContain('Only planners can mark people by hand here.')

    const staff = mountPanel({ me: planner, canManage: true, seesWholeEvent: true, mode: 'qr', rollcalls: [rollcall('qr')], qr })
    expect(staff.find('[data-testid="att-mark-qa_member"]').exists()).toBe(true)
  })
})
