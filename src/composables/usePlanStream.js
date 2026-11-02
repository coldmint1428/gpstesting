// usePlanStream -- where a badge is GOING, this second, on everybody else's screen.
//
// The plan board's ownership composable (usePlanLocks) answers "who may change this badge". This one answers a much
// cheaper and purely cosmetic question: where is the badge somebody else is dragging, right now. It exists because a
// hold alone is a poor experience -- a badge a colleague is moving sits perfectly still on your screen (it still
// carries the plan's own position, because nothing has been written yet) and then jumps when they let go. A draft
// makes the drag visible while it happens, so "somebody else is moving that" is something a planner can see rather
// than something they discover by trying to grab it.
//
// REALTIME BROADCAST, NOT A TABLE, and that is the whole design. A draft is not a write: it goes from browser to
// browser through the same Realtime socket the plan row changes arrive on, and it is never stored. That buys three
// things at once:
//
//   - the database never sees a draft, so a drag cannot cost a write, and the thing that decides where a badge stands
//     is still the hold and the per-cell door (081, 082) -- never this;
//   - a draft that is lost costs nothing, because the next one is more current than the one it replaced, which is why
//     reconnecting needs no catch-up read;
//   - a page that holds nothing at all can still publish one, which is exactly why a receiver treats it as a hint and
//     puts it through utils/planDraft.js before drawing it.
//
// THE TAG IT PUBLISHES IS THIS PAGE's OWN, NEVER THE LOCK SESSION. pageSession.js's id is the credential the plan_*
// doors authorise with; the rule from 015 is that the id a page PUBLISHES is not the id it is AUTHORISED by. So `from`
// is a fresh tag, minted per page load and per composable, whose only job is to let a receiver order one sender's
// drafts against each other. Anyone who learns it has learned nothing.
//
// A RECEIVED DRAFT IS DRAWN, NEVER WRITTEN. It cannot become a position: every commit needs a hold the database
// checks. A forged draft is therefore a lie about a preview, not about the plan -- the worst it can do is draw a ghost
// badge somewhere, on the screen of somebody who decided to look at the board.
//
// KNOWN AND ACCEPTED: the channel is public. Any authenticated user who knows a plan id can watch drafts and publish
// fake ones. That is the bench's existing posture for its shapes (useBenchFrames) and it is recorded in
// docs/design/concurrent-plan-editing.md deliberately rather than discovered later.
import { supabase } from '../lib/supabase'
import { uuid4 } from '../utils/uuid'
import { draftCell, draftPatch, draftWhere } from '../utils/planDraft'

/**
 * One draft per badge per 50 ms: twenty a second, which is what a drag looks like on a screen and roughly what the
 * eye needs. The LAST draft of a gesture is always sent (the trailing timer in `send`), so the place the planner let
 * go at is published however fast the drop followed the last movement.
 */
export const DRAFT_MS = 50

/**
 * How long a draft is drawn without being refreshed. A moved badge publishes twenty times a second, so a draft that
 * has not been refreshed for two and a half seconds is a page that stopped dragging without saying so -- a crashed
 * tab, a dropped socket, a closed lid. The ghost goes, and the badge is left where the plan has it: nothing about this
 * can leave a badge in the wrong place, because nothing about it writes.
 */
export const DRAFT_TTL_MS = 2500

/** How often the sweep looks for drafts nobody refreshed. A fifth of the TTL: the ghost lives a little past its time. */
const SWEEP_MS = 500

/**
 * `client` is the Supabase client (injectable so the socket can be faked in a test, the same way usePlanLocks takes
 * its door as an argument). `tag` is this page's published identity; it is minted when it is not given.
 */
export function usePlanStream(opts = {}) {
  const client = opts.client === undefined ? supabase : opts.client
  const frameMs = typeof opts.throttleMs === 'number' ? opts.throttleMs : DRAFT_MS
  const ttlMs = typeof opts.ttlMs === 'number' ? opts.ttlMs : DRAFT_TTL_MS

  const me = opts.tag || uuid4()

  let channel = null
  let joined = false // what the server last said about this subscription
  let seq = 0 // this page's draft counter, one run of numbers for every badge it publishes
  let listener = null // the board: told the whole current set of drafts after every change

  // cell -> { cell, frame, group, lat, lng, from, at }. The whole of what this page is drawing from other browsers.
  const drafts = new Map()
  // cell -> the draft waiting to go out, and when the last one went. Per cell, so two badges dragged together do not
  // starve each other.
  const queued = new Map()
  // sending tag -> the highest draft number already drawn from it, so an out-of-order message can be recognised.
  const newest = new Map()
  let sweep = null

  // ---------- the channel ----------

  /**
   * Join the plan's draft channel. `onDrafts` receives the current draft list -- `[{ cell, frame, group, lat, lng,
   * from }]` -- after every change: one arrives, one is let go of, one expires. Whole lists rather than deltas,
   * because a list is what a renderer wants and the list is never more than a handful of badges.
   */
  function start(planId, onDrafts) {
    stop()
    listener = typeof onDrafts === 'function' ? onDrafts : null
    if (!client || !planId) return // no socket (the dev preview), or no plan: nothing to join, nothing to draw
    channel = client
      // The name is the same for everybody, deliberately the opposite of a presence channel: broadcast is routed by
      // TOPIC, so every planner has to be on the same one or nobody would hear anybody. The page's identity travels
      // in the payload instead (`from`).
      .channel('plan-cells-' + planId, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'draft' }, (message) => receive(message && message.payload))
      .subscribe((status) => {
        joined = status === 'SUBSCRIBED'
      })
  }

  /**
   * May this socket carry a draft at all? Asked before every send, and both halves are deliberate: `joined` is the
   * last thing the server said, and `state` is the client's own view of the channel. This matters more than it looks
   * -- when a broadcast cannot be pushed, send() does NOT wait for the socket: it posts the message to the REST
   * endpoint instead and warns in the console, once per message. At twenty drafts a second that is a request storm,
   * for a hint that is worth nothing the moment it is late.
   */
  function canPush() {
    return Boolean(channel && joined && channel.state === 'joined')
  }

  // ---------- receiving ----------

  function receive(payload) {
    if (!payload) return
    const from = String(payload.from || '')
    if (!from || from === me) return
    const where = draftWhere(payload.cell)
    if (!where) return

    // A sender numbers its drafts in one run of numbers, so "is this newer than what I drew?" is a comparison and not
    // a guess. An older one says something that has already been overtaken: the message carrying it was simply slower
    // than the one behind it.
    const stamp = Number(payload.seq) || 0
    const seen = newest.get(from)
    if (seen && stamp <= seen.seq) return
    newest.set(from, { seq: stamp, at: Date.now() })
    forget()

    const cell = payload.cell
    // The sender has let go of the badge: the ghost goes now rather than when its TTL runs out.
    if (payload.patch == null) {
      if (drafts.delete(cell)) publish()
      return
    }
    // A draft whose place this app cannot use says nothing, and is dropped whole rather than half-drawn. The one
    // already on screen is left alone: it is still where that page last said the badge was going.
    const clean = draftPatch(payload.patch)
    if (!clean) return

    drafts.set(cell, { cell, frame: where.frame, group: where.group, lat: clean.lat, lng: clean.lng, from, at: Date.now() })
    arm()
    publish()
  }

  /** Drop the drafts nobody has refreshed inside the TTL, and say so if that changed the picture. */
  function sweepNow() {
    const cut = Date.now() - ttlMs
    let gone = false
    for (const [cell, draft] of drafts) {
      if (draft.at < cut) {
        drafts.delete(cell)
        gone = true
      }
    }
    if (!gone) return
    if (!drafts.size) disarm()
    publish()
  }

  function arm() {
    if (sweep || !drafts.size) return
    sweep = setInterval(sweepNow, Math.min(SWEEP_MS, Math.max(100, Math.round(ttlMs / 5))))
  }

  function disarm() {
    if (!sweep) return
    clearInterval(sweep)
    sweep = null
  }

  /** A sender's numbers are kept so a late draft can be spotted. Entries are per sending page, so the map grows with
   *  page loads: throw away anything not heard from in five minutes, and only bother once there are more than a
   *  handful -- the same two bounds the bench's frame stream uses. */
  function forget() {
    if (newest.size <= 32) return
    const cut = Date.now() - 5 * 60 * 1000
    for (const [tag, row] of newest) {
      if (row.at < cut) newest.delete(tag)
    }
  }

  function publish() {
    if (listener) listener(rows())
  }

  /** What this page is drawing from other browsers, as a plain list a renderer can hold. */
  function rows() {
    return [...drafts.values()].map((draft) => ({
      cell: draft.cell,
      frame: draft.frame,
      group: draft.group,
      lat: draft.lat,
      lng: draft.lng,
      from: draft.from,
    }))
  }

  // ---------- sending ----------

  /**
   * Publish where a badge is going. Called on every change a drag makes, which is far more often than anybody needs
   * to hear it: the throttle is per badge, and the draft that is left waiting goes out a moment later, so the last
   * place of a gesture is never the one that was dropped.
   *
   * `patch` of null means "this badge is let go of": the ghost on everybody else's screen goes now, which is what a
   * gesture that ends in a refusal wants (the badge went back, and a ghost heading somewhere the plan does not have
   * it would be a lie about a preview).
   */
  function send(cell, patch) {
    if (!channel) return
    if (!draftWhere(cell)) return
    const clean = patch == null ? null : draftPatch(patch)
    if (patch != null && !clean) return // nothing a draft may carry: not worth a message

    const now = Date.now()
    let queue = queued.get(cell)
    if (!queue) {
      queue = { patch: null, at: 0, timer: null }
      queued.set(cell, queue)
    }
    queue.patch = clean

    if (now - queue.at >= frameMs) {
      flush(cell)
      return
    }
    if (!queue.timer) {
      queue.timer = setTimeout(() => flush(cell), frameMs - (now - queue.at))
    }
  }

  /** Let go of these badges on everybody else's screen: `[{ frame, group }]`. */
  function clear(cells) {
    for (const cell of cells || []) send(draftCell(cell.frame, cell.group), null)
  }

  function flush(cell) {
    const queue = queued.get(cell)
    if (!queue) return
    if (queue.timer) {
      clearTimeout(queue.timer)
      queue.timer = null
    }
    const patch = queue.patch
    if (!canPush()) return
    queue.at = Date.now()
    seq += 1
    channel.send({ type: 'broadcast', event: 'draft', payload: { from: me, cell, seq, patch } })
  }

  /** Leave the channel and forget everything: a plan switch, or a page that is going away. */
  function stop() {
    for (const queue of queued.values()) {
      if (queue.timer) clearTimeout(queue.timer)
    }
    queued.clear()
    disarm()
    drafts.clear()
    newest.clear()
    if (channel && client && client.removeChannel) client.removeChannel(channel)
    channel = null
    joined = false
    // The picture those ghosts belonged to is gone: say so while there is still somebody listening.
    if (listener) listener([])
    listener = null
  }

  return { start, send, clear, stop, rows, canPush }
}
