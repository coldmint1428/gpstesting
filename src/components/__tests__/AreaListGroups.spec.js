// Component: the list of areas on the bench, which is where a planner finds "where are my No-Go areas".
//
// AreaList draws the areas grouped by their type (the type decides their colour on the map, so the list has to agree
// with it), and it is the only place a planner sees the whole bench at once. The padlock on those rows has its own
// test (AreaList.spec.js); this one is about the grouping and about what a row is allowed to change.
//
// The "Other" group is the interesting one: an area saved by a newer build can carry a type this build has never
// heard of, and losing it from the list would look exactly like losing it from the plan.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AreaList from '../AreaList.vue'

const SQUARE = [
  [1.293, 103.855],
  [1.293, 103.856],
  [1.292, 103.856],
  [1.292, 103.855],
]

const area = (id, name, kind, extra = {}) => ({ id, name, kind, points: SQUARE, ...extra })

const groupKeys = (wrapper) =>
  wrapper.findAll('[data-testid^="area-group-"]').map((g) => g.attributes('data-testid').replace('area-group-', ''))

describe('the list of areas', () => {
  it('groups the areas by type in the order of the type dropdown, and says nothing about a type with none', () => {
    const wrapper = mount(AreaList, {
      props: {
        areas: [area('a1', 'East Gate', 'entrance'), area('a2', 'Main Stage', 'stage'), area('a3', 'Trees', 'zone')],
        editable: false,
      },
    })

    // Zone, Stage, Entrance: the dropdown's order, not the order the areas were drawn in.
    expect(groupKeys(wrapper)).toEqual(['zone', 'stage', 'entrance'])
    expect(wrapper.get('[data-testid="area-group-zone"]').text()).toBe('Zone (1)')
    // No-Go and Obstacle have no areas, so their headings are not drawn at all: an empty shell is not information.
    expect(wrapper.find('[data-testid="area-group-no_go"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="area-group-obstacle"]').exists()).toBe(false)

    // A reader who cannot edit gets the type as a word on the row; the dropdown is for the people who can change it.
    expect(wrapper.find('[data-testid="area-row-Main Stage"]').text()).toContain('Stage')
    expect(wrapper.find('[data-testid="area-kind-select-Main Stage"]').exists()).toBe(false)

    // With nothing drawn there is an empty state, not an empty list.
    expect(mount(AreaList, { props: { areas: [], editable: true } }).get('[data-testid="no-areas"]').text()).toContain('No areas')
  })

  it('keeps a type this build does not know in Other, and changes the name and the code only when they are valid', async () => {
    const wrapper = mount(AreaList, {
      props: { areas: [area('a9', 'Helipad', 'helipad', { code: 'GATE_A' })], editable: true, showCode: true },
    })

    // A type from a newer build is not dropped and not silently retyped: it keeps its row, under Other.
    expect(groupKeys(wrapper)).toEqual(['other'])
    expect(wrapper.get('[data-testid="area-group-other"]').text()).toBe('Other (1)')
    expect(wrapper.find('[data-testid="area-row-Helipad"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('GATE_A') // the code a plan and the radio refer to

    // Opening the row is what makes its fields live.
    await wrapper.get('[data-testid="area-open-Helipad"]').trigger('click')
    const name = () => wrapper.get('[data-testid="area-name-Helipad"]')
    const code = () => wrapper.get('[data-testid="area-code-Helipad"]')

    // An empty or whitespace name is refused in silence: the old name stays, and nothing is sent to be saved.
    await name().setValue('   ')
    expect(wrapper.emitted('area-updated')).toBeUndefined()

    await name().setValue('  Helipad North ')
    expect(wrapper.emitted('area-updated')).toEqual([[{ id: 'a9', patch: { name: 'Helipad North' } }]])

    // The code is what the database stores: capitals, digits and underscores, and no more than 40 of them.
    await code().setValue('gate a!')
    expect(wrapper.emitted('area-updated')).toEqual([
      [{ id: 'a9', patch: { name: 'Helipad North' } }],
      [{ id: 'a9', patch: { code: 'GATE_A_' } }],
    ])

    // A code that would clean up to the one it already has is not a change, so it is not saved either.
    await code().setValue('GATE_A')
    expect(wrapper.emitted('area-updated')).toHaveLength(2)
  })
})
