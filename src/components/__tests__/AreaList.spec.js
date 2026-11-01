// Component tests: the padlock on the list of areas (1 Nov). A locked area must not be opened, renamed, retyped or
// deleted from its row, and pressing the padlock is the one thing that asks the page to change it.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AreaList from '../AreaList.vue'

const square = [
  [1.293, 103.855],
  [1.293, 103.856],
  [1.292, 103.856],
  [1.292, 103.855],
]
const areas = [
  { id: 'a1', name: 'Gate A', kind: 'zone', code: 'GATE_A', points: square },
  { id: 'a2', name: 'Stage', kind: 'zone', code: 'STAGE', points: square, locked: true },
]

function mountList() {
  return mount(AreaList, { props: { areas, editable: true, showCode: true } })
}

describe('AreaList padlock', () => {
  it('asks the page to lock an unlocked area, and only that', async () => {
    const wrapper = mountList()
    const lock = wrapper.find('[data-testid="area-lock-Gate A"]')
    expect(lock.attributes('aria-pressed')).toBe('false')
    await lock.trigger('click')
    expect(wrapper.emitted('area-updated')).toEqual([[{ id: 'a1', patch: { locked: true } }]])
    // The padlock is not a click on the row: it must not open the area as well.
    expect(wrapper.emitted('area-edit')).toBeUndefined()
  })

  it('closes every field of a locked area and keeps its row from opening it', async () => {
    const wrapper = mountList()
    expect(wrapper.find('[data-testid="area-lock-Stage"]').attributes('aria-pressed')).toBe('true')
    expect(wrapper.find('[data-testid="area-name-Stage"]').attributes('disabled')).toBeDefined()
    expect(wrapper.find('[data-testid="area-code-Stage"]').attributes('disabled')).toBeDefined()
    expect(wrapper.find('[data-testid="area-kind-select-Stage"]').attributes('disabled')).toBeDefined()
    expect(wrapper.find('[data-testid="area-delete-Stage"]').attributes('disabled')).toBeDefined()

    await wrapper.find('[data-testid="area-row-Stage"]').trigger('click')
    expect(wrapper.emitted('area-edit')).toBeUndefined()
    await wrapper.find('[data-testid="area-row-Gate A"]').trigger('click')
    expect(wrapper.emitted('area-edit')).toEqual([['a1']])
  })

  it('unlocks a locked area from the padlock', async () => {
    const wrapper = mountList()
    await wrapper.find('[data-testid="area-lock-Stage"]').trigger('click')
    expect(wrapper.emitted('area-updated')).toEqual([[{ id: 'a2', patch: { locked: false } }]])
  })
})
