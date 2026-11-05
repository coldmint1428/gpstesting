// Component tests: the list of areas, grouped by type (components/AreaList.vue). The groups follow the type dropdown's
// order, an empty type is left out, and an area of a type this build does not know is kept, under Other.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AreaList from '../AreaList.vue'

const square = [
  [1.293, 103.855],
  [1.293, 103.856],
  [1.292, 103.856],
  [1.292, 103.855],
]
const area = (id, name, kind, extra = {}) => ({ id, name, kind, code: name.toUpperCase().replace(/\W+/g, '_'), points: square, ...extra })
const groupKeys = (wrapper) => wrapper.findAll('[data-testid^="area-group-"]').map((g) => g.attributes('data-testid').slice('area-group-'.length))

describe('AreaList groups', () => {
  it('groups the areas by type in the order of the type dropdown, and says nothing about a type with none', () => {
    const wrapper = mount(AreaList, {
      props: { areas: [area('a1', 'Way in', 'entrance'), area('a2', 'Main stage', 'stage'), area('a3', 'Field', 'zone')] },
    })
    expect(groupKeys(wrapper)).toEqual(['zone', 'stage', 'entrance'])
    expect(wrapper.get('[data-testid="area-group-zone"]').text()).toBe('Zone (1)')
    expect(wrapper.find('[data-testid="area-group-no_go"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="area-group-obstacle"]').exists()).toBe(false)
  })

  it('keeps a type this build does not know in Other, and changes the name and the code only when they are valid', async () => {
    const wrapper = mount(AreaList, {
      props: { areas: [area('a1', 'Helipad', 'helipad', { code: 'GATE_A' })], editable: true, showCode: true },
    })
    expect(groupKeys(wrapper)).toEqual(['other'])
    expect(wrapper.get('[data-testid="area-group-other"]').text()).toBe('Other (1)')
    expect(wrapper.find('[data-testid="area-row-Helipad"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('GATE_A') // the code a plan and the radio refer to

    await wrapper.get('[data-testid="area-open-Helipad"]').trigger('click')
    expect(wrapper.emitted('area-edit')).toEqual([['a1']])
    const name = wrapper.get('[data-testid="area-name-Helipad"]') // setValue fires the change a planner's Enter or Tab would
    await name.setValue('   ')
    await name.setValue('x'.repeat(51))
    expect(wrapper.emitted('area-updated')).toBeUndefined() // blank, too long: the old name stays

    await name.setValue('Helipad North')
    const code = wrapper.get('[data-testid="area-code-Helipad"]')
    await code.setValue('  ')
    await code.setValue('gate b-2')
    expect(wrapper.emitted('area-updated')).toEqual([
      [{ id: 'a1', patch: { name: 'Helipad North' } }],
      [{ id: 'a1', patch: { code: 'GATE_B_2' } }],
    ])
  })
})
