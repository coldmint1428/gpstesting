// Unit: the sentences that stop a person at step 1 or step 3 of "Create an event".
//
// The wizard's own store holds the answers and decides whether a step may be left (stores/eventWizard.js). The
// database checks every rule again on Confirm (001/002), so these checks exist to keep a person from filling in four
// steps and being refused at the last one -- which is why what each refusal SAYS matters as much as that it refuses.
import { describe, it, expect, beforeEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useEventWizardStore } from '../eventWizard'

describe('the wizard refuses a step with the sentence that says what to fix', () => {
  let wizard

  beforeEach(() => {
    localStorage.clear()
    setActivePinia(createPinia())
    wizard = useEventWizardStore()
  })

  it('names the missing detail at step 1 and the reason at step 3, and nothing on a step that is fine', () => {
    // ---------- Step 1: the event's details ----------
    // Nothing filled in: each empty detail is named, so the first press of Next is not one useless sentence.
    expect(wizard.validate(1)).toEqual({
      name: 'Give the event a name',
      startsAt: 'Pick a start date and time',
      endsAt: 'Pick an end date and time',
    })

    wizard.details.name = '   ' // whitespace is not a name
    expect(wizard.validate(1)).toMatchObject({ name: 'Give the event a name' })

    wizard.details.name = 'Night Walk'
    wizard.details.startsAt = '2026-11-05T19:00'
    wizard.details.endsAt = '2026-11-05T19:00' // the same moment is not "after"
    expect(wizard.validate(1)).toEqual({ endsAt: 'The end must be after the start' })
    wizard.details.endsAt = '2026-11-05T18:00' // and earlier is certainly not
    expect(wizard.validate(1)).toEqual({ endsAt: 'The end must be after the start' })

    wizard.details.endsAt = '2026-11-05T23:00'
    expect(wizard.validate(1)).toEqual({}) // the step may be left

    // The limits are the database's (001), quoted in the same words the field shows.
    wizard.details.name = 'n'.repeat(81)
    expect(wizard.validate(1)).toEqual({ name: 'At most 80 characters' })
    wizard.details.name = 'Night Walk'
    wizard.details.description = 'd'.repeat(1001)
    expect(wizard.validate(1)).toEqual({ description: 'At most 1000 characters' })
    wizard.details.description = ''

    // ---------- Step 3: the groups ----------
    expect(wizard.addGroup('Gate Crew', '#0072B2')).toBe('')
    expect(wizard.addGroup('gate crew', '#009E73')).toBe('There is already a group called "gate crew"')
    const key = wizard.groups[0].key

    // A group with people in it needs the one phone that shares its location, or the group is invisible on the map --
    // and the sentence has to name the group, because there may be six of them.
    wizard.addToGroup(key, 'u1')
    expect(wizard.validate(3)).toEqual({
      ['group-' + key]: '"Gate Crew" needs at least one IC (the phone that shares the group\'s location)',
    })
    wizard.groups[0].members[0].isIC = true
    expect(wizard.validate(3)).toEqual({})

    // An empty group is fine: it is made before it is filled.
    expect(wizard.addGroup('Stage', '#009E73')).toBe('')
    expect(wizard.validate(3)).toEqual({})

    // Removing somebody from the event takes them out of their group too, so the IC switch cannot be left on for a
    // person who is no longer coming.
    wizard.removePerson('u1')
    expect(wizard.groupOf).toEqual({})
    expect(wizard.validate(3)).toEqual({})

    expect(wizard.addGroup('', '#0072B2')).toBe('Give the group a name')
    expect(wizard.addGroup('g'.repeat(51), '#0072B2')).toBe('Group names can be at most 50 characters')
  })
})
