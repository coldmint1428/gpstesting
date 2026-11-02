// usePlanStream: the wire. What a page publishes about a badge it is dragging, what it draws from other pages, and
// the three bounds that keep a cosmetic stream from costing anything: a throttle per badge, a sequence number per
// sender, and a TTL for a page that stopped talking.
//
// The socket is faked exactly where the real one is used (a client with channel/removeChannel), so what is tested is
// the composable's own decisions -- not Supabase's.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { usePlanStream, DRAFT_MS, DRAFT_TTL_MS } from '../usePlanStream'

/** A stand-in for the Realtime client: one channel, and everything the page sent through it. */
function fakeSocket() {
  const sent = []
  const channels = []
  const channel = {
    state: 'joining',
    name: '',
    config: null,
    handler: null,
    subscribed: null,
    on(event, filter, cb) {
      this.event = event
      this.filter = filter
      this.handler = cb
      return this
    },
    subscribe(cb) {
      this.subscribed = cb
      return this
    },
    send(message) {
      sent.push(message)
    },
  }
  const client = {
    channel(name, config) {
      channel.name = name
      channel.config = config
      channels.push(channel)
      return channel
    },
    removeChannel: vi.fn(),
  }
  /** The server says the subscription is up (realtime-js also sets state). */
  function join() {
    channel.state = 'joined'
    channel.subscribed('SUBSCRIBED')
  }
  /** Somebody else's draft arrives on the channel. */
  function arrive(payload) {
    channel.handler({ payload })
  }
  return { client, channel, channels, sent, join, arrive }
}

const draft = (over = {}) => ({ from: 'peer-tag', cell: 'f1|g1', seq: 1, patch: { lat: 1.29, lng: 103.84 }, ...over })

describe('usePlanStream', () => {
  let socket
  let stream
  let drawings

  beforeEach(() => {
    socket = fakeSocket()
    drawings = []
    stream = usePlanStream({ client: socket.client, tag: 'my-tag' })
  })

  afterEach(() => {
    stream.stop()
    vi.useRealTimers()
  })

  it('joins the plan’s one channel, with its own frames and never its own broadcasts', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    expect(socket.channel.name).toBe('plan-cells-p1')
    expect(socket.channel.config).toEqual({ config: { broadcast: { self: false } } })
    expect(socket.channel.event).toBe('broadcast')
    expect(socket.channel.filter).toEqual({ event: 'draft' })
  })

  it('publishes nothing until the socket says it is joined', () => {
    stream.start('p1', null)
    stream.send('f1|g1', { lat: 1.29, lng: 103.84 })
    // A broadcast that cannot be pushed falls back to REST, twenty times a second, once per message: the gate is
    // what keeps a cosmetic hint from becoming a request storm.
    expect(socket.sent).toHaveLength(0)

    socket.join()
    stream.send('f1|g1', { lat: 1.29, lng: 103.84 })
    expect(socket.sent).toHaveLength(1)
    expect(socket.sent[0].payload).toEqual({ from: 'my-tag', cell: 'f1|g1', seq: 1, patch: { lat: 1.29, lng: 103.84 } })
  })

  it('throttles per badge, and the draft left waiting is the last place rather than the first', async () => {
    vi.useFakeTimers()
    stream.start('p1', null)
    socket.join()

    stream.send('f1|g1', { lat: 1.29, lng: 103.84 })
    stream.send('f1|g1', { lat: 1.291, lng: 103.841 })
    stream.send('f1|g2', { lat: 1.292, lng: 103.842 })
    // The first of each badge went at once; the second badge is throttled by its own clock, not the first one's.
    expect(socket.sent.map((m) => m.payload.cell)).toEqual(['f1|g1', 'f1|g2'])

    await vi.advanceTimersByTimeAsync(DRAFT_MS)
    expect(socket.sent).toHaveLength(3)
    expect(socket.sent[2].payload.patch).toEqual({ lat: 1.291, lng: 103.841 })
    expect(socket.sent[2].payload.seq).toBe(3)
  })

  it('draws a draft somebody else published', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft())
    expect(drawings[drawings.length - 1]).toEqual([
      { cell: 'f1|g1', frame: 'f1', group: 'g1', lat: 1.29, lng: 103.84, from: 'peer-tag' },
    ])
  })

  it('drops a draft that has been overtaken, and one from this page', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft({ seq: 5, patch: { lat: 1.3, lng: 103.85 } }))
    socket.arrive(draft({ seq: 4, patch: { lat: 1.31, lng: 103.86 } }))
    expect(drawings[drawings.length - 1][0].lat).toBe(1.3)

    socket.arrive(draft({ from: 'my-tag', seq: 9 }))
    expect(drawings).toHaveLength(1)
  })

  it('drops a draft that would draw a place the plan could not hold, or names no badge', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft({ patch: { lat: 51.5, lng: -0.12 } }))
    socket.arrive(draft({ patch: { lat: 'north', lng: 103.8 } }))
    socket.arrive(draft({ cell: 'f1' }))
    socket.arrive(draft({ from: '' }))
    expect(drawings).toHaveLength(0)
    expect(stream.rows()).toEqual([])
  })

  it('a sender letting go of a badge takes its ghost away, and says so once', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft({ seq: 1 }))
    socket.arrive(draft({ seq: 2, patch: null }))
    expect(drawings[drawings.length - 1]).toEqual([])
    expect(stream.rows()).toEqual([])
  })

  it('a ghost nobody refreshes goes by itself, so a crashed tab does not leave one on the map', async () => {
    vi.useFakeTimers()
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft())
    expect(stream.rows()).toHaveLength(1)

    await vi.advanceTimersByTimeAsync(DRAFT_TTL_MS + 600)
    expect(stream.rows()).toEqual([])
    expect(drawings[drawings.length - 1]).toEqual([])
  })

  it('publishes a let-go for every badge in a gesture', () => {
    stream.start('p1', null)
    socket.join()
    stream.clear([
      { frame: 'f1', group: 'g1' },
      { frame: 'f1', group: 'g2' },
    ])
    expect(socket.sent.map((m) => m.payload)).toEqual([
      { from: 'my-tag', cell: 'f1|g1', seq: 1, patch: null },
      { from: 'my-tag', cell: 'f1|g2', seq: 2, patch: null },
    ])
  })

  it('leaving the plan leaves the channel and forgets what it was drawing', () => {
    stream.start('p1', (rows) => drawings.push(rows))
    socket.arrive(draft())
    stream.stop()

    expect(socket.client.removeChannel).toHaveBeenCalledTimes(1)
    expect(stream.rows()).toEqual([])
    expect(drawings[drawings.length - 1]).toEqual([])
    // Nothing waits behind it: a queued draft for a channel this page has left is not sent on the next one.
    stream.send('f1|g1', { lat: 1.29, lng: 103.84 })
    expect(socket.sent).toHaveLength(0)
  })
})
