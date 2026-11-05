// Component tests: the plan's Problems panel (components/plan/PlanProblems.vue). The words come from planProblems; this
// panel sorts them into errors and warnings, keeps a dismissed warning tucked away, and decides who gets the buttons.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import PlanProblems from '../plan/PlanProblems.vue'

const problem = (id, level, extra = {}) => ({
  id,
  level,
  kind: 'zone',
  title: 'Alpha crosses the no-go area "Store"',
  detail: '',
  fix: 'Add a frame between, then drag them to the suggested spot.',
  meta: '+0:30 to +1:30',
  actions: [{ key: 'suggest', label: 'Suggest a spot', testid: 'fix-suggest' }],
  dismissed: false,
  ...extra,
})

const problems = [
  problem('e1', 'error'),
  problem('e2', 'error'),
  problem('w1', 'warning', { actions: [] }),
  problem('w2', 'warning', { actions: [], dismissed: true }),
]

describe('PlanProblems', () => {
  it('separates errors from warnings, and keeps a dismissed warning out of the way until it is asked for', async () => {
    const wrapper = mount(PlanProblems, { props: { problems, canEdit: true } })
    expect(wrapper.get('[data-testid="problems-errors"]').text()).toBe('2 errors')
    expect(wrapper.get('[data-testid="problems-warnings"]').text()).toBe('1 warning')
    expect(wrapper.findAll('[data-testid="plan-problem"]')).toHaveLength(2)
    expect(wrapper.findAll('[data-testid="plan-warning"]')).toHaveLength(1)

    // The dismissed one is only a count, until the planner asks to see it
    const toggle = wrapper.get('[data-testid="problems-dismissed"]')
    expect(toggle.text()).toBe('Show 1 dismissed')
    await toggle.trigger('click')
    expect(wrapper.findAll('[data-testid="plan-warning"]')).toHaveLength(2)
    expect(wrapper.findAll('[data-testid="problem-restore"]')).toHaveLength(1)
  })

  it('gives the fixes to a planner, and only points a reader at where the problem is', async () => {
    const editor = mount(PlanProblems, { props: { problems, canEdit: true } })
    expect(editor.findAll('[data-testid="fix-suggest"]')).toHaveLength(2)
    expect(editor.find('[data-testid="problems-lock"]').exists()).toBe(true)

    const reader = mount(PlanProblems, { props: { problems, canEdit: false } })
    expect(reader.find('[data-testid="fix-suggest"]').exists()).toBe(false)
    expect(reader.find('[data-testid="problems-lock"]').exists()).toBe(false) // the lock is a warning to the editor
    await reader.get('[data-testid="problem-show"]').trigger('click')
    expect(reader.emitted('show')[0][0]).toMatchObject({ id: 'e1' })
  })
})
