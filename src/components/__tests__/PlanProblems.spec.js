// Component: the list of everything wrong with the plan.
//
// As a plan is built the board collects problems -- a group walking through a No-Go area, a moment with an end
// missing -- and this panel is what turns them into something a planner can act on. Two rules decide how it reads,
// and both are worth a test: an ERROR stops the plan being published (so it must be separated from a warning, and
// must say that the plan is locked), and the buttons that change the plan belong to the people who may change it.
// The sentences themselves come from utils/planProblems.js and are tested there.
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import PlanProblems from '../plan/PlanProblems.vue'

const error = (id, extra = {}) => ({
  id,
  level: 'error',
  kind: 'crossing',
  title: 'Gate Crew walks through No-Go "Trees"',
  detail: 'Between +0:30 and +1:00',
  fix: 'Move the group round it, or move the area.',
  meta: 'Frames 3-4',
  actions: [{ key: 'suggest', label: 'Suggest a way round', testid: 'fix-suggest' }],
  dismissed: false,
  ...extra,
})
const warning = (id, extra = {}) => ({ ...error(id), level: 'warning', kind: 'end', title: 'Bravo has no end', ...extra })

const PROBLEMS = [error('e1'), error('e2'), warning('w1'), warning('w2', { dismissed: true }), warning('w3', { dismissed: true })]

const mountProblems = (props = {}) => mount(PlanProblems, { props: { problems: PROBLEMS, canEdit: true, ...props } })

describe('the plan problems panel', () => {
  it('separates errors from warnings, and keeps a dismissed warning out of the way until it is asked for', async () => {
    const wrapper = mountProblems()

    // Two errors stop the plan; one warning is still open. The two dismissed warnings are not counted as open.
    expect(wrapper.get('[data-testid="problems-errors"]').text()).toBe('2 errors')
    expect(wrapper.get('[data-testid="problems-warnings"]').text()).toBe('1 warning')
    expect(wrapper.findAll('[data-testid="plan-problem"]')).toHaveLength(2)
    expect(wrapper.findAll('[data-testid="plan-warning"]')).toHaveLength(1)

    // An error is not a remark: while one is open, the board says the plan cannot be published.
    expect(wrapper.get('[data-testid="problems-lock"]').text()).toContain('Plan locked')

    // Dismissing is possible for warnings only -- an error cannot be waved away, because publishing would then be
    // allowed on a plan that still crosses a No-Go area.
    expect(wrapper.findAll('[data-testid="problem-dismiss"]')).toHaveLength(1)
    await wrapper.get('[data-testid="problem-dismiss"]').trigger('click')
    expect(wrapper.emitted('dismiss')).toEqual([[expect.objectContaining({ id: 'w1' })]])

    // The two dismissed ones are behind a count, and coming back is one press.
    const toggle = wrapper.get('[data-testid="problems-dismissed"]')
    expect(toggle.text()).toBe('Show 2 dismissed')
    await toggle.trigger('click')
    expect(toggle.text()).toBe('Hide dismissed')
    expect(wrapper.findAll('[data-testid="problem-restore"]')).toHaveLength(2)
    await wrapper.get('[data-testid="problem-restore"]').trigger('click')
    expect(wrapper.emitted('restore')).toEqual([[expect.objectContaining({ id: 'w2' })]])
  })

  it('gives the fixes to a planner, and only points a reader at where the problem is', async () => {
    // Anyone can be shown where it is: that changes nothing.
    const reader = mountProblems({ canEdit: false })
    expect(reader.find('[data-testid="fix-suggest"]').exists()).toBe(false)
    expect(reader.find('[data-testid="problems-lock"]').exists()).toBe(false) // the lock is a warning to the editor
    await reader.get('[data-testid="problem-show"]').trigger('click')
    expect(reader.emitted('show')[0][0]).toMatchObject({ id: 'e1' })
    await reader.get('[data-testid="problem-timeline"]').trigger('click')
    expect(reader.emitted('timeline')[0][0]).toMatchObject({ id: 'e1' })

    // A planner gets the fix itself, and the board is told which problem and which fix -- never "fix something".
    const editor = mountProblems()
    const fix = editor.get('[data-testid="fix-suggest"]')
    await fix.trigger('click')
    expect(editor.emitted('act')).toEqual([[expect.objectContaining({ id: 'e1' }), 'suggest']])

    // While a write is in flight every fix is closed, so a second press cannot start a second one.
    const busy = mountProblems({ busy: true })
    expect(busy.get('[data-testid="fix-suggest"]').attributes('disabled')).toBeDefined()

    // A plan with nothing wrong says so, instead of showing an empty card.
    expect(mount(PlanProblems, { props: { problems: [], canEdit: true } }).find('.pv-probs').exists()).toBe(false)
  })
})
