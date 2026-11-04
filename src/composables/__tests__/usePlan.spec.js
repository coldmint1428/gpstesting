// usePlan's structural doors (083): the session each write carries, and the one that takes a hold.
//
// The rules themselves are SQL (`node tools/pgtest.mjs plan-ops`). What a SQL suite cannot see is the wiring: that the
// page actually SENDS the session the refusal is decided by, and that a retime is wrapped in a moment hold rather than
// merely asking the database about one. Both are one line in usePlan, and one line is exactly what a later refactor
// drops silently -- after which every door still "works" and nobody is ever named.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { effectScope } from 'vue'

const { rpc, channelStub } = vi.hoisted(() => {
  const stub = { on: null, subscribe: null, name: 'channel' }
  stub.on = () => stub
  stub.subscribe = () => stub
  return { rpc: vi.fn(), channelStub: stub }
})

vi.mock('../../lib/supabase', () => ({
  supabase: { rpc, channel: () => channelStub, removeChannel: () => {} },
}))
vi.mock('../pageSession', () => ({ pageSession: () => 'session-1' }))

import { isLockRefusal, usePlan } from '../usePlan'

const refusal = (message) => Object.assign(new Error(message), { code: 'PT423' })

/** The error a call was refused with: a refusal is a sentence, so the test reads it rather than only catching it. */
async function refusedCall(promise) {
  try {
    await promise
  } catch (error) {
    return error
  }
  throw new Error('the call went through, and it should have been refused')
}

/** Answer like PostgREST: `{ data, error }`, with a route per function that needs an answer. */
function answer(routes = {}) {
  rpc.mockImplementation(async (fn, args) => {
    if (routes[fn]) return { data: routes[fn](args), error: null }
    // plan_frames_list is read after every write, and answers rows; everything else answers null.
    if (fn === 'plan_frames_list') return { data: [], error: null }
    return { data: null, error: null }
  })
}

function doors() {
  return rpc.mock.calls.map(([fn]) => fn)
}

function argsOf(fn) {
  const hit = rpc.mock.calls.find(([name]) => name === fn)
  return hit ? hit[1] : null
}

describe('usePlan: the structural doors (083)', () => {
  let scope
  let api

  beforeEach(() => {
    rpc.mockReset()
    answer()
    scope = effectScope()
    scope.run(() => {
      api = usePlan('event-1')
    })
    api.plans.value = [{ id: 'p1', name: 'Show night', status: 'draft', rev: 3 }]
    api.plan.value = api.plans.value[0]
  })

  afterEach(() => {
    scope.stop()
  })

  it('a retime is one moment hold around the write, with the session', async () => {
    await api.moveFrame('f1', 90, 3)
    expect(doors()).toEqual([
      'plan_lock_frame',
      'frame_move',
      'plan_unlock_frame',
      'plan_frames_list',
      'plan_list',
    ])
    expect(argsOf('frame_move')).toMatchObject({ p_id: 'f1', p_t_s: 90, p_rev: 3, p_session: 'session-1' })
    expect(argsOf('plan_lock_frame')).toMatchObject({ p_plan: 'p1', p_frame: 'f1', p_session: 'session-1' })
  })

  it('a moment somebody else has is refused before the retime is sent', async () => {
    answer({
      plan_lock_frame: () => {
        throw refusal('Daniel Planner is editing the moment at +1:00, so this moment cannot be moved yet.')
      },
    })
    const error = await refusedCall(api.moveFrame('f1', 90, 3))
    expect(isLockRefusal(error)).toBe(true)
    expect(doors()).not.toContain('frame_move')
    expect(api.busy.value).toBe(false)
  })

  it('a refused retime does not leave the moment held', async () => {
    answer({
      frame_move: () => {
        throw refusal('This moment stopped being yours to edit. Try again.')
      },
    })
    const error = await refusedCall(api.moveFrame('f1', 90, 3))
    expect(isLockRefusal(error)).toBe(true)
    // The hold was taken and put back: a page that keeps a moment after a failed write locks a colleague out for 12 s.
    expect(doors().filter((fn) => fn === 'plan_lock_frame')).toHaveLength(1)
    expect(doors().filter((fn) => fn === 'plan_unlock_frame')).toHaveLength(1)
    expect(api.busy.value).toBe(false)
  })

  it('every other structural door carries the session', async () => {
    const cases = [
      ['deleteFrame', () => api.deleteFrame('f1', 3), 'frame_delete', { p_id: 'f1', p_rev: 3 }],
      ['shiftFrom', () => api.shiftFrom(60, 120, 180), 'frame_shift', { p_from_s: 60, p_delta_s: 120, p_to_s: 180 }],
      ['holdFrame', () => api.holdFrame('f1', 60, ['g1']), 'frame_hold', { p_frame: 'f1', p_seconds: 60 }],
      ['setVerify', () => api.setVerify(['f1'], ['g1'], 'manual'), 'frame_set_verify', { p_verify: 'manual' }],
      ['importFrames', () => api.importFrames('p1', [{ t_s: 60 }]), 'plan_import', { p_plan: 'p1' }],
      ['deletePlan', () => api.deletePlan('p1'), 'plan_delete', { p_plan: 'p1' }],
    ]
    for (const [name, run, door, expected] of cases) {
      rpc.mockClear()
      answer()
      await run()
      const args = argsOf(door)
      expect(args, `${name}: ${door} was not called`).toBeTruthy()
      expect(args.p_session, `${name}: ${door} was sent no session`).toBe('session-1')
      expect(args).toMatchObject(expected)
    }
  })

  it('a delete refused while somebody is mid-edit is a lock refusal, not a stale one', async () => {
    answer({
      frame_delete: () => {
        throw refusal('Priya is editing Gate Crew at +1:00, so this moment cannot be deleted yet.')
      },
    })
    const error = await refusedCall(api.deleteFrame('f1', 3))
    expect(isLockRefusal(error)).toBe(true)
    expect(error.message).toContain('so this moment cannot be deleted yet')
    // Nothing was read back: a refused delete changed nothing, so there is nothing to reload.
    expect(doors()).toEqual(['frame_delete'])
  })
})
