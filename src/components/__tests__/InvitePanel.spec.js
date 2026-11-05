// Component tests: the Invite people card (components/InvitePanel.vue). One code, the same everywhere it is offered,
// and a copy button that still says something useful when the browser will not let it at the clipboard.
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async () => 'data:image/png;base64,') } }))
const toast = vi.fn()
vi.mock('../../composables/useNotify', () => ({ toast: (...args) => toast(...args) }))

// The link is built when the module loads, so the public address is fixed before it is imported
vi.stubEnv('VITE_PUBLIC_APP_URL', '')
const { default: InvitePanel } = await import('../InvitePanel.vue')

function mountPanel() {
  return mount(InvitePanel, { props: { eventName: 'Night Walk', joinCode: 'ABC123' } })
}

describe('InvitePanel', () => {
  let writeText
  beforeEach(() => {
    toast.mockClear()
    writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
  })

  it('shows one code in every place it is offered: the panel, the link and both shares', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    expect(wrapper.get('[data-testid="join-code-display"]').text()).toBe('ABC123')
    const link = 'https://gpstesting.vercel.app/join/ABC123'
    expect(wrapper.get('[data-testid="invite-link"]').text()).toBe(link)
    const whatsapp = wrapper.get('[data-testid="share-whatsapp"]').attributes('href')
    expect(decodeURIComponent(whatsapp)).toBe('https://wa.me/?text=Join "Night Walk" on Planova. Code: ABC123 - ' + link)
    const telegram = decodeURIComponent(wrapper.get('[data-testid="share-telegram"]').attributes('href'))
    expect(telegram).toContain('url=' + link)
    expect(telegram).toContain('Code: ABC123')
    expect(wrapper.get('[data-testid="save-qr"]').attributes('download')).toBe('planova-ABC123.png')
  })

  it('copies the code, and still explains itself when the browser refuses the clipboard', async () => {
    const wrapper = mountPanel()
    await wrapper.get('[data-testid="copy-code"]').trigger('click')
    await flushPromises()
    expect(writeText).toHaveBeenCalledWith('ABC123')
    expect(toast).toHaveBeenCalledWith('Event code copied.', 'success', 2500)

    await wrapper.find('.ov2-link button').trigger('click')
    await flushPromises()
    expect(writeText).toHaveBeenLastCalledWith('https://gpstesting.vercel.app/join/ABC123')
    expect(wrapper.find('.ov2-link button').text()).toBe('Copied!')

    // Refused (an http page, a locked-down browser): say so, and the link is still on screen to copy by hand
    writeText.mockRejectedValue(new Error('NotAllowedError'))
    await wrapper.get('[data-testid="copy-code"]').trigger('click')
    await flushPromises()
    expect(toast).toHaveBeenLastCalledWith('Could not copy the code.', 'danger', 4000)
    expect(wrapper.get('[data-testid="invite-link"]').text()).toContain('/join/ABC123')
  })
})
