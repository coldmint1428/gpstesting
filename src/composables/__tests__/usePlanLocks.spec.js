// usePlanLocks: taking a hold on the badges a write is about, keeping it while it is wanted, and letting go.
//
// The database is what actually refuses a write (082) -- these tests are about the ORDER of the calls, about the
// heartbeat that keeps a hold alive, and about what happens when one of them fails, which is the part a SQL suite
// cannot see.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
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
  const call = vi.fn(async (fn, args, opts) => {
    calls.push({ fn, args, opts })
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

  afterEach(() => {
    locks.dispose()
    vi.useRealTimers()
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

  it('an undo asks for every cell of BOTH directions in one call, then writes, then lets go once', async () => {
    // The inverse of a gesture can place some badges and take others away. One hold has to cover all of them, asked
    // for before the first write -- that is what makes a refusal all-or-nothing (decision 10).
    const written = await locks.rewrite('p1', [cell('f1', 'g1'), cell('f1', 'g2')], [
      { frame: 'f1', group: 'g3' },
    ])

    expect(written).toEqual({ placed: 2, removed: 1 })
    expect(rec.doors()).toEqual([
      'plan_lock_cells',
      'frame_place_many',
      'frame_unplace_many',
      'plan_unlock_cells',
    ])
    // The grab is one statement about three cells, and the let-go is one statement about the same three.
    expect(rec.calls[0].args.p_cells).toEqual([
      cell('f1', 'g1'),
      cell('f1', 'g2'),
      { frame: 'f1', group: 'g3' },
    ])
    expect(rec.calls[3].args.p_cells).toHaveLength(3)
  })

  it('an undo refused by a badge being taken away writes nothing at all', async () => {
    const refusal = Object.assign(new Error('Priya is editing Backstage at +1:00.'), { code: 'PT423' })
    rec = recorder({
      plan_lock_cells: () => {
        throw refusal
      },
    })
    locks = usePlanLocks(rec.call)

    await expect(locks.rewrite('p1', [cell('f1', 'g1')], [{ frame: 'f1', group: 'g3' }])).rejects.toThrow(
      /Priya is editing Backstage/,
    )
    // Not a placement, not a removal, and not a release of a hold it never took.
    expect(rec.doors()).toEqual(['plan_lock_cells'])
  })

  it('an undo with nothing to do asks nobody anything', async () => {
    await expect(locks.rewrite('p1', [], [])).resolves.toEqual({ placed: 0, removed: 0 })
    expect(rec.doors()).toEqual([])
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

  it('says "still here" for a held badge every two seconds, and stops when it lets go', async () => {
    vi.useFakeTimers()
    await locks.hold('p1', [cell('f1', 'g1')])
    expect(rec.doors()).toEqual(['plan_lock_cells'])

    await vi.advanceTimersByTimeAsync(2000)
    expect(rec.doors()).toEqual(['plan_lock_cells', 'plan_renew'])
    // The heartbeat is about the CELL, not the coordinates: it asks whether the badge is still mine.
    expect(rec.calls[1].args).toMatchObject({
      p_plan: 'p1',
      p_session: 'session-1',
      p_cells: [{ frame: 'f1', group: 'g1' }],
      p_frames: [],
    })

    await locks.letGo('p1', [cell('f1', 'g1')])
    expect(rec.doors()).toEqual(['plan_lock_cells', 'plan_renew', 'plan_unlock_cells'])
    await vi.advanceTimersByTimeAsync(6000)
    expect(rec.doors().filter((door) => door === 'plan_renew')).toHaveLength(1)
  })

  it('drops a badge the heartbeat says is no longer mine, and tells the board', async () => {
    vi.useFakeTimers()
    const told = vi.fn()
    rec = recorder({
      plan_renew: () => [{ kind: 'badge', frame_id: 'f1', group_id: 'g1', held: false }],
    })
    locks = usePlanLocks(rec.call)
    locks.onLost(told)

    await locks.hold('p1', [cell('f1', 'g1')])
    await vi.advanceTimersByTimeAsync(2000)

    expect(told).toHaveBeenCalledTimes(1)
    expect(told).toHaveBeenCalledWith([{ frame: 'f1', group: 'g1' }])
    // The page must not go on believing it holds it: nothing is left, so the next beat is silent and a let-go
    // does not knock on the door for a row it has already given up.
    expect(locks.heldCells()).toEqual([])
    await locks.letGo('p1', [cell('f1', 'g1')])
    await vi.advanceTimersByTimeAsync(4000)
    expect(rec.doors()).toEqual(['plan_lock_cells', 'plan_renew'])
  })

  it('gives everything up at once, and keeps the heartbeat quiet afterwards', async () => {
    vi.useFakeTimers()
    await locks.hold('p1', cells)
    await locks.releaseAll('p1')

    expect(rec.doors()).toEqual(['plan_lock_cells', 'plan_release_all'])
    expect(rec.calls[1].args).toMatchObject({ p_session: 'session-1', p_plan: 'p1' })
    expect(locks.heldCells()).toEqual([])
    await vi.advanceTimersByTimeAsync(6000)
    expect(rec.doors().filter((door) => door === 'plan_renew')).toHaveLength(0)
  })

  it('asks who is editing the plan, and treats a failed presence read as nobody', async () => {
    rec = recorder({ plan_lock_holders: () => [{ kind: 'badge', display_name: 'Priya' }] })
    locks = usePlanLocks(rec.call)
    await expect(locks.holders('p1')).resolves.toHaveLength(1)
    expect(rec.calls[0].fn).toBe('plan_lock_holders')

    rec = recorder({
      plan_lock_holders: () => {
        throw Object.assign(new Error('not a planner'), { code: '42501' })
      },
    })
    locks = usePlanLocks(rec.call)
    await expect(locks.holders('p1')).resolves.toEqual([])
  })

  it('every door it knocks on is quiet: the strip says the refusal, not the inspector', async () => {
    await locks.place('p1', [cell('f1', 'g1')])
    for (const call of rec.calls) expect(call.opts).toMatchObject({ quiet: true })
  })

  it('asks to take over only when told to, and only for a badge this page did not have', async () => {
    await locks.place('p1', [cell('f1', 'g1')])
    expect(rec.calls[0].args).toMatchObject({ p_take_over: false })

    rec = recorder()
    locks = usePlanLocks(rec.call)
    await locks.place('p1', [cell('f1', 'g1')], { takeOver: true })
    expect(rec.calls[0].args).toMatchObject({ p_take_over: true })
  })

  it('a write inside a gesture is a second reference, not a second grab', async () => {
    await locks.hold('p1', [cell('f1', 'g1')])
    await locks.place('p1', [cell('f1', 'g1')])

    // One grab, one write, and the write's release left the hand's hold standing.
    expect(rec.doors()).toEqual(['plan_lock_cells', 'frame_place_many'])
    expect(locks.heldCells()).toEqual([{ frame: 'f1', group: 'g1', refs: 1 }])

    await locks.letGo('p1', [cell('f1', 'g1')])
    expect(rec.doors()).toEqual(['plan_lock_cells', 'frame_place_many', 'plan_unlock_cells'])
  })
})
