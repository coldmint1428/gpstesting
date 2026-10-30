// Unit tests: the group palette and the text colour on a group's dot
import { describe, it, expect } from 'vitest'
import { GROUP_PALETTE, nextGroupColour, textOn } from '../groupColours'

describe('GROUP_PALETTE', () => {
  it('has no warm hues: orange, vermilion and red mean live, late and danger', () => {
    for (const hex of GROUP_PALETTE) {
      expect(['#E69F00', '#D55E00', '#C4321F', '#F2A541']).not.toContain(hex)
    }
  })

  it('has five distinct colours', () => {
    expect(new Set(GROUP_PALETTE).size).toBe(5)
  })
})

describe('nextGroupColour', () => {
  it('gives the first colour for the first group', () => {
    expect(nextGroupColour([])).toBe(GROUP_PALETTE[0])
    expect(nextGroupColour(null)).toBe(GROUP_PALETTE[0])
  })

  it('follows the number of groups and wraps after the last colour', () => {
    expect(nextGroupColour([{}, {}])).toBe(GROUP_PALETTE[2])
    expect(nextGroupColour([{}, {}, {}, {}, {}])).toBe(GROUP_PALETTE[0])
  })
})

describe('textOn', () => {
  it('uses white on the dark group colours', () => {
    expect(textOn('#0072B2')).toBe('#FFFFFF')
    expect(textOn('#6A4C93')).toBe('#FFFFFF')
  })

  it('uses ink on the light group colours, where white would fail contrast', () => {
    expect(textOn('#56B4E9')).toBe('#14201B')
    expect(textOn('#009E73')).toBe('#14201B')
    expect(textOn('#CC79A7')).toBe('#14201B')
  })

  it('copes with a colour that is not a hex value', () => {
    expect(['#FFFFFF', '#14201B']).toContain(textOn('blue'))
  })
})
