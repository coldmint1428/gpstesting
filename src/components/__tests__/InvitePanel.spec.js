// Component: the three ways to bring somebody into an event -- the code, the link, the QR -- must agree.
//
// They are three views of one string. A code that says ABC123 beside a link that says ABC124 is worse than no invite
// at all: the person who received it types it in, is refused, and blames themselves. The panel also has to survive a
// blocked clipboard, which is the normal case on an http page and the reason the link is printed as text anyway.
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import InvitePanel from '../InvitePanel.vue'
import { toast } from '../../composables/useNotify'

// The QR is drawn on a <canvas>, which jsdom does not have; the link inside it is the same one this file checks.
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(async () => 'data:image/png;base64,AAAA') } }))
vi.mock('../../composables/useNotify', () => ({ toast: vi.fn() }))

const mountPanel = () => mount(InvitePanel, { props: { eventName: 'Night Walk', joinCode: 'ABC123' } })

describe('the invite panel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('shows one code in every place it is offered: the panel, the link and both shares', async () => {
    const wrapper = mountPanel()

    expect(wrapper.get('[data-testid="join-code-display"]').text()).toBe('ABC123')

    // The link is the code, made openable. On a laptop running the dev server the app's own address is
    // "localhost", which nobody else can reach, so the deployed site is preferred -- the same database is behind it.
    const link = 'https://gpstesting.vercel.app/join/ABC123'
    expect(wrapper.get('[data-testid="invite-link"]').text()).toBe(link)

    // WhatsApp and Telegram carry the same sentence, built from the same code.
    const whatsapp = wrapper.get('[data-testid="share-whatsapp"]').attributes('href')
    expect(decodeURIComponent(whatsapp)).toContain('Code: ABC123')
    expect(decodeURIComponent(whatsapp)).toContain(link)
    const telegram = wrapper.get('[data-testid="share-telegram"]').attributes('href')
    expect(decodeURIComponent(telegram)).toContain('Night Walk')
    expect(telegram).toContain(encodeURIComponent(link))

    // The QR is made from the link (the watch redraws it whenever the code changes), and can be saved.
    await flushPromises()
    expect(wrapper.find('[data-testid="invite-qr"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="save-qr"]').attributes('download')).toBe('planova-ABC123.png')
  })

  it('copies the code, and still explains itself when the browser refuses the clipboard', async () => {
    const writeText = vi.fn()
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    writeText.mockResolvedValue()

    const wrapper = mountPanel()
    await wrapper.get('[data-testid="copy-code"]').trigger('click')
    await flushPromises()
    expect(writeText).toHaveBeenCalledWith('ABC123')
    expect(toast).toHaveBeenCalledWith('Event code copied.', 'success', 2500)

    // Copying the link says so on the button, since the link itself does not change.
    await wrapper.find('.ov2-link button').trigger('click')
    await flushPromises()
    expect(writeText).toHaveBeenLastCalledWith('https://gpstesting.vercel.app/join/ABC123')
    expect(wrapper.find('.ov2-link button').text()).toBe('Copied!')

    // A blocked clipboard (an http page, a refused permission) must not look like a success...
    vi.clearAllMocks()
    writeText.mockRejectedValue(new Error('NotAllowedError'))
    await wrapper.get('[data-testid="copy-code"]').trigger('click')
    await flushPromises()
    expect(toast).toHaveBeenCalledWith('Could not copy the code.', 'danger', 4000)
    // ... and the code is still on the screen to be read out, which is why the refusal is only a warning.
    expect(wrapper.get('[data-testid="join-code-display"]').text()).toBe('ABC123')
  })
})
