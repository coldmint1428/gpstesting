// What a live draft may carry, and what a `frame|group` cell may be. The stream itself is tested in
// composables/__tests__/usePlanStream.spec.js; this is the part that decides whether anything travels at all.
import { describe, it, expect } from 'vitest'
import { draftCell, draftPatch, draftWhere } from '../planDraft'

describe('draftPatch', () => {
  it('keeps exactly a place, and nothing else that was in the patch', () => {
    expect(draftPatch({ lat: 1.2902, lng: 103.846, state: 'off_site', verify: 'manual', group: 'g9' })).toEqual({
      lat: 1.2902,
      lng: 103.846,
    })
  })

  it('refuses a place the plan could not hold', () => {
    // The same box 005_layouts.sql enforces: a draft outside it would be a badge drawn where nothing can be saved.
    expect(draftPatch({ lat: 51.5, lng: -0.12 })).toBeNull()
    expect(draftPatch({ lat: 1.29, lng: 104.5 })).toBeNull()
  })

  it('refuses a patch that is not two finite numbers', () => {
    expect(draftPatch(null)).toBeNull()
    expect(draftPatch('1.29,103.8')).toBeNull()
    expect(draftPatch({})).toBeNull()
    expect(draftPatch({ lat: 1.29 })).toBeNull()
    expect(draftPatch({ lat: '1.29', lng: 103.8 })).toBeNull()
    expect(draftPatch({ lat: Number.NaN, lng: 103.8 })).toBeNull()
    expect(draftPatch({ lat: Number.POSITIVE_INFINITY, lng: 103.8 })).toBeNull()
  })

  it('does not alias the sender’s values into the patch it hands back', () => {
    const patch = { lat: 1.29, lng: 103.8 }
    const clean = draftPatch(patch)
    expect(clean).not.toBe(patch)
    expect(clean).toEqual({ lat: 1.29, lng: 103.8 })
  })
})

describe('draftCell / draftWhere', () => {
  it('names one badge in both directions', () => {
    expect(draftCell('f1', 'g2')).toBe('f1|g2')
    expect(draftWhere('f1|g2')).toEqual({ frame: 'f1', group: 'g2' })
    expect(draftWhere(draftCell('a-b', 'c d'))).toEqual({ frame: 'a-b', group: 'c d' })
  })

  it('an empty half is not a badge', () => {
    expect(draftCell('', 'g2')).toBe('')
    expect(draftCell('f1', null)).toBe('')
    expect(draftWhere('|g2')).toBeNull()
    expect(draftWhere('f1|')).toBeNull()
    expect(draftWhere('f1|g2|g3')).toBeNull()
    expect(draftWhere('f1')).toBeNull()
    expect(draftWhere(42)).toBeNull()
    expect(draftWhere(null)).toBeNull()
  })
})
