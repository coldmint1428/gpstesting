// useBenchFrames - what one planner is doing to a shape RIGHT NOW, on everybody else's screen.
//
// The other two benches-as-a-group composables answer "who is here" (useBenchPresence) and "who may
// change what" (useBenchLocks). This one answers a third and much cheaper question: where is the
// shape this second. It exists because a lock alone is a poor experience -- a shape somebody else
// is holding would sit perfectly still on your screen and then jump to its new place when they let
// go, and "another planner is moving this" would be a sentence rather than something you can see.
//
// REALTIME BROADCAST, NOT A TABLE, and that is the whole design. A frame is not a save: it goes
// from browser to browser through the same Realtime socket the presence rows arrive on, and it is
// never written down. That buys three things at once:
//
//   - the database never sees a frame, so a drag cannot cost a write, and the thing that decides
//     who wins is still the lock (008) -- never this;
//   - a frame that is lost costs nothing, because the next one is more current than the one it
//     replaced, which is also why reconnecting needs no catch-up read (unlike presence, which is a
//     row and does);
//   - and it can be published by a page that holds no lock at all, which is exactly why a receiver
//     treats it as a hint and puts it through utils/benchFrame.js before drawing it.
//
// TWO DECISIONS WORTH KNOWING:
//
// 1. THE CHANNEL NAME IS THE SAME FOR EVERYBODY -- deliberately the opposite of the presence
//    channel, which carries this tab's tag so that two tabs never share a subscription. Broadcast
//    is routed BY TOPIC, so every planner has to be on the same one or nobody would hear anybody;
//    the tab's identity travels in the payload instead (`from`).
//
// 2. THE TAG IT PUBLISHES IS THE PRESENCE TAG, NEVER THE LOCK SESSION. The rule from 007 is that
//    the id you publish is not the id you are authorised by: `from` is only ever used to order one
//    sender's frames against each other, and anyone who learns it has learned nothing at all. The
//    session id that save_object() authorises with never leaves the browser (see benchSession.js).
import { onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { framePatch } from '../utils/benchFrame'

// One frame per object per 50 ms: twenty a second, which is what a drag looks like on a screen and
// roughly what the eye needs. The LAST frame of a gesture is always sent (see the trailing timer in
// send), so letting go publishes the position the planner let go at, however fast the drop followed
// the last move.
const FRAME_MS = 50

// A sender's frame numbers are kept so an out-of-order frame can be recognised and dropped. Entries
// are per sending TAB, so this map grows with tabs and page loads -- hence the two bounds: throw
// away anything not heard from in five minutes, and only bother once there are more than a handful.
const FORGET_MS = 5 * 60 * 1000
const MAX_SENDERS = 32

export function useBenchFrames() {
  let channel = null
  let joined = false // what the server last said about this subscription
  let me = '' // this tab's published tag (the presence one)
  let seq = 0 // this tab's frame counter, one run of numbers for every object it sends
  let handler = null // what the page does with a frame it receives

  const queued = {} // object id -> the patch waiting to go out, and when the last one went
  const newest = {} // sending tab -> the highest frame number already drawn from it

  // Join the bench's frame channel. `tag` must be the presence tag, `onFrame` receives
  // { kind, id, patch, from } for frames somebody else published.
  function start(layoutId, tag, onFrame) {
    if (!supabase || !layoutId || channel) return
    me = tag || ''
    handler = onFrame

    channel = supabase
      // `self: false` is the default and is said out loud because the code below also checks `from`:
      // a tab drawing its own frames back would fight its own drag, and it is one line to be sure.
      .channel('bench-frames-' + layoutId, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'shape' }, (message) => receive(message && message.payload))
      .subscribe((status) => {
        joined = status === 'SUBSCRIBED'
      })
  }

  // May this socket carry a frame at all? Asked before every send, and both halves are deliberate:
  // `joined` is the last thing the server said, and `state` is the client's own view of the channel
  // (it is the same pair realtime-js itself checks). This matters more than it looks -- when a
  // broadcast cannot be pushed, send() does NOT wait for the socket: it posts the message to the
  // REST endpoint instead and warns in the console, once per message. At twenty frames a second
  // that is a request storm and a console full of warnings, for a hint that is worth nothing the
  // moment it is late: the next frame replaces it, so dropping one here costs exactly nothing.
  function canPush() {
    return Boolean(channel && joined && channel.state === 'joined')
  }

  function receive(payload) {
    if (!payload || typeof payload.id !== 'string' || !payload.id) return
    const from = String(payload.from || '')
    if (!from || from === me) return

    // A sender numbers its frames in one run of numbers, so "is this newer than what I drew?" is a
    // comparison and not a guess. An older one says something that has already been overtaken: the
    // message that carried it was simply slower than the one behind it.
    const stamp = Number(payload.seq) || 0
    const seen = newest[from]
    if (seen && stamp <= seen.seq) return
    newest[from] = { seq: stamp, at: Date.now() }
    prune()

    if (!handler) return
    handler({
      kind: payload.kind === 'plan' ? 'plan' : 'area',
      id: payload.id,
      patch: payload.patch,
      from,
    })
  }

  function prune() {
    const keys = Object.keys(newest)
    if (keys.length <= MAX_SENDERS) return
    const cut = Date.now() - FORGET_MS
    for (const key of keys) {
      if (newest[key].at < cut) delete newest[key]
    }
  }

  // Publish what a shape is doing. Called on every change a drag makes, which is far more often
  // than anybody needs to hear it: the throttle is per object, and the frame that is left waiting
  // goes out a moment later, so the last position of a gesture is never the one that was dropped.
  function send(kind, id, patch) {
    if (!channel || !id) return

    const clean = framePatch(kind, patch)
    if (!clean) return // nothing a frame is allowed to carry: not worth a message

    const now = Date.now()
    const queue = queued[id] || (queued[id] = { kind, patch: null, at: 0, timer: null })
    queue.kind = kind
    queue.patch = clean

    if (now - queue.at >= FRAME_MS) {
      flush(id)
      return
    }
    if (!queue.timer) {
      queue.timer = setTimeout(() => flush(id), FRAME_MS - (now - queue.at))
    }
  }

  function flush(id) {
    const queue = queued[id]
    if (!queue) return
    if (queue.timer) {
      clearTimeout(queue.timer)
      queue.timer = null
    }

    const patch = queue.patch
    queue.patch = null
    if (!patch || !canPush()) return

    queue.at = Date.now()
    seq += 1
    channel.send({
      type: 'broadcast',
      event: 'shape',
      payload: { from: me, id, kind: queue.kind, seq, patch },
    })
  }

  function stop() {
    for (const id of Object.keys(queued)) {
      if (queued[id].timer) clearTimeout(queued[id].timer)
      delete queued[id]
    }
    if (channel && supabase) supabase.removeChannel(channel)
    channel = null
    joined = false
    handler = null
    me = ''
    // Everybody else's frame numbers are forgotten on purpose: this page is leaving the bench, and
    // a planner who comes back to it must not have frames dropped because of numbers counted
    // before it left.
    for (const key of Object.keys(newest)) delete newest[key]
  }

  onUnmounted(stop)

  return { start, send, stop }
}
