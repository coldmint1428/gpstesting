// usePlanLocks: taking a hold on the badges a write is about, and letting go of them afterwards.
//
// The database is what actually refuses a write (082) -- these tests are about the ORDER of the three calls and
// about what happens when one of them fails, which is the part a SQL suite cannot see.
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { usePlanLocks } from '../usePlanLocks'

vi.mock('../pageSession', () => ({ pageSession: () => 'session-1' }))

const cell = (frame, group, extra = {}) => ({ frame, group, lat: 1.3, lng: 103.8, ...extra })
const cells = [cell('f1', 'g1'), cell('f1', 'g2')]

/**
 * A stand-in for the board's `call`: it records every door that was knocked on and answers like the real ones do
 * (the place doors answer with a count). `overrides` replaces an answer, or throws from it.
 */
function recorder(overrides = {}) {
  const calls = []
  const call = vi.fn(async (fn, args) => {
    calls.push({ fn, args })
    if (overrides[fn]) return overrides[fn](args)
    if (fn === 'frame_place_many' || fn === 'frame_unplace_many') return (args.p_cells || []).length
    return null
  })
  return { call, calls, doors: () => calls.map((c) => c.fn) }
}

describe('usePlanLocks', () => {
  let locks
  let rec

  beforeEach(() => {
    rec = recorder()
    locks = usePlanLocks(rec.call)
  })

  it('holds the badges, writes them, and lets go — in that order', async () => {
    const written = await locks.place('p1', cells)

    expect(written).toBe(2)
    expect(rec.doors()).toEqual(['plan_lock_cells', 'frame_place_many', 'plan_unlock_cells'])
    // the hold and the write are the same session, and the cells go up exactly as the board built them
    expect(rec.calls[0].args).toMatchObject({ p_plan: 'p1', p_session: 'session-1', p_cells: cells })
    expect(rec.calls[1].args).toMatchObject({ p_plan: 'p1', p_session: 'session-1', p_cells: cells })
  })

  it('writes nothing when the hold is refused, and does not let go of what it never had', async () => {
    const refusal = Object.assign(new Error('Priya Planner is editing Gate Crew at +1:00.'), { code: 'PT423' })
    rec = recorder({
      plan_lock_cells: () => {
        throw refusal
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.place('p1', cells)).rejects.toThrow(/Priya Planner is editing Gate Crew/)

    expect(rec.doors()).toEqual(['plan_lock_cells'])
  })

  it('asks again after a refusal, rather than believing it still holds the badge', async () => {
    let refuse = true
    rec = recorder({
      plan_lock_cells: () => {
        if (refuse) throw Object.assign(new Error('Somebody else'), { code: 'PT423' })
        return null
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.place('p1', [cell('f1', 'g1')])).rejects.toThrow()
    refuse = false
    await locks.place('p1', [cell('f1', 'g1')])

    expect(rec.doors()).toEqual([
      'plan_lock_cells',
      'plan_lock_cells',
      'frame_place_many',
      'plan_unlock_cells',
    ])
  })

  it('lets go once when two writes are inside one badge at the same time', async () => {
    let release
    const gate = new Promise((resolve) => (release = resolve))
    rec = recorder({ frame_place_many: async () => { await gate; return 1 } })
    locks = usePlanLocks(rec.call)

    const first = locks.place('p1', [cell('f1', 'g1')])
    const second = locks.place('p1', [cell('f1', 'g1')])
    release()
    await Promise.all([first, second])

    const unlocks = rec.doors().filter((door) => door === 'plan_unlock_cells')
    expect(unlocks).toHaveLength(1)
  })

  it('lets go when the write itself fails, so a dead write does not hold the badge', async () => {
    rec = recorder({
      frame_place_many: () => {
        throw new Error('the network died')
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.place('p1', cells)).rejects.toThrow('the network died')

    expect(rec.doors()).toEqual(['plan_lock_cells', 'frame_place_many', 'plan_unlock_cells'])
  })

  it('a release that fails is not an error — the hold lapses by itself in 12 s', async () => {
    rec = recorder({
      plan_unlock_cells: () => {
        throw new Error('offline')
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.place('p1', cells)).resolves.toBe(2)
  })

  it('removing a badge takes the hold first, like any other write', async () => {
    await locks.unplace('p1', [{ frame: 'f1', group: 'g1' }])

    expect(rec.doors()).toEqual(['plan_lock_cells', 'frame_unplace_many', 'plan_unlock_cells'])
  })

  it('holds the moment around the write, and lets go even when the write throws', async () => {
    await locks.withMoment('p1', 'f1', async () => 'saved')
    expect(rec.doors()).toEqual(['plan_lock_frame', 'plan_unlock_frame'])

    await expect(
      locks.withMoment('p1', 'f1', async () => {
        throw new Error('stale')
      }),
    ).rejects.toThrow('stale')
    expect(rec.doors()).toEqual([
      'plan_lock_frame',
      'plan_unlock_frame',
      'plan_lock_frame',
      'plan_unlock_frame',
    ])
  })

  it('a moment that cannot be held does not run the write', async () => {
    const asked = vi.fn()
    rec = recorder({
      plan_lock_frame: () => {
        throw Object.assign(new Error('Somebody else is editing this moment.'), { code: 'PT423' })
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.withMoment('p1', 'f1', asked)).rejects.toThrow('editing this moment')
    expect(asked).not.toHaveBeenCalled()
    expect(rec.doors()).toEqual(['plan_lock_frame'])
  })

  it('an empty gesture asks nobody anything', async () => {
    await expect(locks.place('p1', [])).resolves.toBe(0)
    await expect(locks.unplace('p1', [])).resolves.toBe(0)
    expect(rec.doors()).toEqual([])
  })
})
