// Unit test: the Create an event wizard's checks (stores/eventWizard.js). Each step names what is missing, in the
// words the page shows under the field, and a step with nothing wrong has nothing to say.
import { describe, it, expect, beforeEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useEventWizardStore } from '../eventWizard'

describe('eventWizard', () => {
  beforeEach(() => {
    localStorage.clear()
    setActivePinia(createPinia())
  })

  it('names the missing detail at step 1 and the reason at step 3, and nothing on a step that is fine', () => {
    const wizard = useEventWizardStore()
    expect(wizard.validate(1)).toEqual({
      name: 'Give the event a name',
      startsAt: 'Pick a start date and time',
      endsAt: 'Pick an end date and time',
    })

    wizard.details = { ...wizard.details, name: 'Night Walk', startsAt: '2026-11-05T19:00', endsAt: '2026-11-05T18:00' }
    expect(wizard.validate(1)).toEqual({ endsAt: 'The end must be after the start' })
    wizard.details.endsAt = '2026-11-05T23:00'
    expect(wizard.validate(1)).toEqual({})

    wizard.addPerson({ id: 'u1', display_name: 'Komin Chow', email: 'komin@example.com' })
    wizard.addGroup('Alpha', '#0072B2')
    const alpha = wizard.groups[0]
    wizard.addToGroup(alpha.key, 'u1')
    expect(wizard.validate(3)).toEqual({
      ['group-' + alpha.key]: '"Alpha" needs at least one IC (the phone that shares the group\'s location)',
    })
    wizard.groups[0].members[0].isIC = true
    expect(wizard.validate(3)).toEqual({})
    expect(wizard.validate(2)).toEqual({}) // step 2 (people) has no rule of its own
  })
})
