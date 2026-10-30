// Component tests: the confirm dialog, and the typed word that ending a live event asks for
import { describe, it, expect, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import NotifyHost from '../NotifyHost.vue'
import { askConfirm, answerConfirm, confirmState } from '../../composables/useNotify'

let wrapper

afterEach(() => {
  if (confirmState.value) answerConfirm(false)
  if (wrapper) wrapper.unmount()
})

describe('NotifyHost confirm dialog', () => {
  it('confirms a plain question with one click', async () => {
    wrapper = mount(NotifyHost, { attachTo: document.body })
    const answer = askConfirm({ title: 'Delete this?', confirmText: 'Delete', danger: true })
    await flushPromises()
    expect(wrapper.find('[data-testid=confirm-type]').exists()).toBe(false)
    await wrapper.find('[data-testid=confirm-ok]').trigger('click')
    expect(await answer).toBe(true)
  })

  it('keeps the button disabled until the required word is typed', async () => {
    wrapper = mount(NotifyHost, { attachTo: document.body })
    const answer = askConfirm({ title: 'End the event now?', confirmText: 'End event now', danger: true, requireText: 'END' })
    await flushPromises()

    const ok = wrapper.find('[data-testid=confirm-ok]')
    expect(ok.attributes('disabled')).toBeDefined()
    expect(ok.text()).toBe('Type END to enable')

    await wrapper.find('[data-testid=confirm-type]').setValue('EN')
    expect(ok.attributes('disabled')).toBeDefined()
    await ok.trigger('click') // a disabled button: nothing happens
    expect(confirmState.value).not.toBeNull()

    await wrapper.find('[data-testid=confirm-type]').setValue('end') // any case
    expect(ok.attributes('disabled')).toBeUndefined()
    expect(ok.text()).toBe('End event now')
    await ok.trigger('click')
    expect(await answer).toBe(true)
  })

  it('answers no when cancelled, whatever was typed', async () => {
    wrapper = mount(NotifyHost, { attachTo: document.body })
    const answer = askConfirm({ title: 'End the event now?', confirmText: 'End event now', requireText: 'END' })
    await flushPromises()
    await wrapper.find('[data-testid=confirm-type]').setValue('END')
    await wrapper.find('[data-testid=confirm-cancel]').trigger('click')
    expect(await answer).toBe(false)
  })

  it('starts empty again for the next dialog', async () => {
    wrapper = mount(NotifyHost, { attachTo: document.body })
    const first = askConfirm({ title: 'One', requireText: 'END' })
    await flushPromises()
    await wrapper.find('[data-testid=confirm-type]').setValue('END')
    answerConfirm(false)
    await first
    askConfirm({ title: 'Two', requireText: 'END' })
    await flushPromises()
    expect(wrapper.find('[data-testid=confirm-type]').element.value).toBe('')
    expect(wrapper.find('[data-testid=confirm-ok]').attributes('disabled')).toBeDefined()
  })
})
