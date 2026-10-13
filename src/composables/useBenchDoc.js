// useBenchDoc - the bench's canvas: what is on it, and how a change to it gets written.
//
// THIS REPLACES useBenchClaim, whose name was already a leftover and whose whole design -- one row
// holding the entire canvas, saved by merging the whole document -- is what 009_object_rows.sql
// replaced. The canvas is now ROWS: one per area and per floor plan, each with its own revision, and
// each floor plan's PICTURE is a row of its own that its shape only points at. What this file does is
// turn those rows into the document the bench draws, and turn a planner's change back into a row.
//
// FOUR IDEAS, and everything here follows from them:
//
// 1. A WRITE IS A PATCH. The page reports the FIELDS that changed; save_object() lays them over the
//    stored shape and hands back the result, which is what goes on screen. A page whose copy is behind
//    -- a hidden tab, a screen that missed an event -- therefore writes what it changed and cannot
//    undo what it did not. (Under the old merge the whole object won, and a stale rename could be
//    lost with no error anywhere.)
//
// 2. A WRITE HAPPENS WHEN THE CHANGE SETTLES, and `mode` going to null no longer saves anything: it
//    only lets go of the lock. A gesture (a drag, a resize, a turn) is written at its end, which is
//    why the page tells this file when one begins and ends; an edit that is not a gesture (a typed
//    name, an opacity slider, a visibility switch) is written a moment after it stops. Nothing is
//    written while a pointer is down: a shape being dragged is not a shape anybody should be sent.
//
// 3. WHAT SOMEBODY ELSE DOES ARRIVES BY ITSELF. public.layout_objects is published to Realtime, so a
//    shape created, changed or deleted by another planner reaches every other open page as it happens
//    -- which is the thing the whole-document bench could not do at all: it could only tell you on
//    your next save. An event is a NOTIFICATION and not the truth: the payload carries the row, the
//    row is checked against the revision this page already holds, and a shape this page is HOLDING is
//    never taken from an event, because a lock is what decides that.
//
// 4. THE PICTURES ARE SHARED AND FETCHED, NEVER RE-UPLOADED. A picture is stored once, under the md5
//    of the image itself, so a second plan made from the same file costs nothing and a plan that is
//    only being moved sends no picture at all. This file keeps them by id, which is what lets a shape
//    that arrives from somebody else be drawn without asking the server for it again.
import { onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { benchSession } from './benchSession'
import { withoutImage } from '../utils/layoutLimits'

// How long a change that is not part of a gesture waits before it is written: a name being typed, an
// opacity slider, a show/hide switch. A gesture is written when it ends, which is why this is only a
// backstop -- and short enough that a planner who closes the tab has almost always been written.
const FLUSH_MS = 700

// Where I left the map is a convenience, not a save: coalesce the reports a single pan produces into
// one write, and let the last one win.
const VIEW_SAVE_MS = 600

function firstRow(rows) {
  return Array.isArray(rows) ? rows[0] : rows
}

function emptyCanvas() {
  return { view: null, floorPlans: [], polygons: [] }
}

// Why the database refused, in words. The useful answers -- the shape is invalid, it is too big -- come
// back as a `problem` sentence in the reply rather than as an error (see save_object), so an error here
// is a call that did not happen: a lost connection, or a page that cannot work at all.
function explain(error) {
  if (!error) return ''
  if (error.code === 'PT409') return error.message || 'This page cannot save anything. Reload it.'
  if (error.code === 'PT410' || /upgraded/i.test(error.message || '')) {
    return 'The bench has been upgraded: reload the page to keep working.'
  }
  return error.message || 'The bench could not be reached.'
}

export function useBenchDoc(options = {}) {
  // What the PAGE knows and this file does not: whether a shape is held by this tab (the lock layer's
  // business), and where a refusal should be said (the bench's one strip, and the page's own alert).
  const holds = options.holds || (() => false)
  const refuse = options.refuse || (() => {})
  const say = options.say || (() => {})
  const lost = options.lost || (() => {})

  const data = ref(emptyCanvas())
  const loading = ref(true)
  const errorMsg = ref('')
  const saving = ref(false)
  // How full the bench is, IN THE BYTES THE DATABASE COUNTS (layout_bytes in 009). It comes from the
  // server -- open_bench and every write reply carry it -- because the server is the only side that
  // knows what is really stored.
  const bytes = ref(0)
  // The bench's own revision: the highest one this page has seen. It is how a page that has been away
  // asks "did I miss anything?" with one small query instead of downloading the canvas.
  const rev = ref(0)

  const layoutId = ref('')
  const myView = ref(null)

  // Pictures by id, and the picture each shape points at. Neither is reactive: what the bench draws is
  // `data`, and these are the parts of it that arrived with it.
  const images = new Map()
  const imageOf = new Map()
  // The revision this page holds for each shape. Two jobs: it tells a stale event from a current one, and
  // it is how the page knows whether the bench has ever heard of a shape at all (see `known`).
  const revOf = new Map()

  // What the planner has changed and the database has not been told yet: shape id -> { kind, patch }.
  // One patch per shape however many fields it touched, and the LAST value of each field wins.
  const pending = new Map()
  const timers = new Map()
  // One request at a time per shape (a create and a delete of the same shape must not race), and what
  // is in flight right now -- which is half of what "this shape has unsaved work" means.
  const queue = new Map()
  const flying = new Set()

  let alone = true // true while no pointer is down: see idea 2 at the top
  let channel = null
  let joined = false
  let viewTimer = null
  let pendingView = null

  // ---------- What this file knows about a shape ----------
  function busy(shapeId) {
    return Boolean(shapeId) && (pending.has(shapeId) || flying.has(shapeId))
  }

  // Has the BENCH ever told this page about this shape? One that came from open_bench, from an event or
  // from a write has a revision; one that exists only on this screen does not -- which is how Undo knows
  // that putting a shape back is a CREATE rather than a change (see putBack in PolygonTestView).
  function known(shapeId) {
    return revOf.has(shapeId)
  }

  function shapeList(kind) {
    return kind === 'plan' ? data.value.floorPlans : data.value.polygons
  }

  function forget(shapeId) {
    revOf.delete(shapeId)
    imageOf.delete(shapeId)
  }

  // ---------- The document ----------
  // One shape, replaced. The arrays are rebuilt rather than mutated, because useDocHistory's snapshots
  // are the live objects: a snapshot taken before a change has to keep meaning what it meant.
  function replaceShape(kind, shapeId, shape) {
    const list = shapeList(kind)
    if (!list.some((s) => s.id === shapeId)) {
      if (kind === 'plan') data.value.floorPlans = [...list, shape]
      else data.value.polygons = [...list, shape]
      return
    }
    if (kind === 'plan') data.value.floorPlans = list.map((s) => (s.id === shapeId ? shape : s))
    else data.value.polygons = list.map((s) => (s.id === shapeId ? shape : s))
  }

  function dropEverywhere(shapeId) {
    data.value.floorPlans = data.value.floorPlans.filter((s) => s.id !== shapeId)
    data.value.polygons = data.value.polygons.filter((s) => s.id !== shapeId)
  }

  function rememberImages(map) {
    for (const id of Object.keys(map || {})) images.set(id, map[id])
  }

  // The canvas, as open_bench() hands it over: shapes without pictures, and the pictures beside them.
  function adopt(shapes, home) {
    const floorPlans = []
    const polygons = []
    revOf.clear()
    imageOf.clear()

    for (const row of shapes || []) {
      const image = row.image_id ? images.get(row.image_id) || '' : undefined
      if (row.kind === 'plan') {
        floorPlans.push({ ...row.data, image })
        if (row.image_id) imageOf.set(row.id, row.image_id)
      } else {
        polygons.push(row.data)
      }
      revOf.set(row.id, Number(row.rev) || 0)
    }

    data.value = { view: home || null, floorPlans, polygons }
  }

  // ---------- Opening, and catching up ----------
  async function read() {
    const { data: rows, error } = await supabase.rpc('open_bench')
    if (error) return { error }
    const row = firstRow(rows)
    if (!row) return { error: { message: 'The bench could not be opened.' } }
    return { row }
  }

  async function doOpen() {
    loading.value = true
    errorMsg.value = ''

    if (!supabase) {
      loading.value = false
      errorMsg.value = 'Supabase is not set up, so the bench cannot be loaded.'
      return null
    }

    const { row, error } = await read()
    if (error) {
      loading.value = false
      errorMsg.value = explain(error)
      return null
    }

    // A bench whose database has NOT been upgraded hands back the old reply -- one document, no rows --
    // and the honest answer to that is a sentence, not an empty canvas.
    if (!Array.isArray(row.shapes) || !row.images) {
      loading.value = false
      errorMsg.value =
        'This bench needs its database upgraded: run supabase/migrations/009_object_rows.sql in the Supabase SQL Editor.'
      return null
    }

    images.clear()
    rememberImages(row.images)
    adopt(row.shapes, row.home)
    layoutId.value = row.id || ''
    rev.value = Number(row.rev) || 0
    bytes.value = Number(row.bytes) || 0
    myView.value = await loadMyView()
    subscribe()
    // LAST, and not a moment earlier: the page draws the map as soon as `loading` is false, and the map
    // takes the view it is given at that instant and never looks again.
    loading.value = false
    return data.value
  }

  function open() {
    return doOpen()
  }

  // Has the bench moved on without me? This is what the bench's revision counter is for: a page that
  // has been hidden, or whose socket reconnected, compares its own number with the server's -- one
  // small query -- and only reads the canvas again if it really has missed something.
  //
  // Anything this page has changed but not written goes first, which is also the second chance a write
  // that failed (a lost connection) gets.
  async function catchUp() {
    if (!supabase || !layoutId.value) return false
    await flushAll()

    const { data: row, error } = await supabase.from('layouts').select('rev').maybeSingle()
    if (error || !row) return false
    if (Number(row.rev) <= rev.value) return false

    const { row: fresh, error: readError } = await read()
    if (readError) return false

    // Everything this page is HOLDING stays exactly as it is (the lock says it is this planner's to
    // say, and their change may be on its way in); everything else becomes the bench's version.
    const mine = []
    for (const kind of ['plan', 'area']) {
      for (const shape of shapeList(kind)) {
        if (holds(shape.id)) mine.push({ kind, shape })
      }
    }

    images.clear()
    rememberImages(fresh.images)
    adopt(fresh.shapes, fresh.home)
    for (const held of mine) replaceShape(held.kind, held.shape.id, held.shape)

    rev.value = Number(fresh.rev) || 0
    bytes.value = Number(fresh.bytes) || 0
    return true
  }

  // ---------- Writing ----------
  // The planner changed these fields. The change is already on screen; this remembers it and, unless a
  // pointer is down, writes it a moment later.
  function change(kind, shapeId, patch) {
    if (!shapeId || !patch) return
    const waiting = pending.get(shapeId)
    pending.set(shapeId, { kind, patch: { ...(waiting ? waiting.patch : {}), ...patch } })
    schedule(shapeId)
  }

  function schedule(shapeId) {
    if (!alone) return // a gesture is in progress: nothing is written until it ends
    if (timers.has(shapeId)) return
    timers.set(
      shapeId,
      setTimeout(() => {
        timers.delete(shapeId)
        flush(shapeId)
      }, FLUSH_MS),
    )
  }

  function stopTimer(shapeId) {
    const timer = timers.get(shapeId)
    if (timer) {
      clearTimeout(timer)
      timers.delete(shapeId)
    }
  }

  // Write this shape now, and resolve when the database has answered. Called at the end of a gesture,
  // when a shape is created (so it exists for everybody else at once), and when a lock is about to be
  // let go of.
  function flush(shapeId) {
    const item = pending.get(shapeId)
    if (!item) return Promise.resolve(true)
    pending.delete(shapeId)
    stopTimer(shapeId)
    return chain(shapeId, () => push(shapeId, item))
  }

  function flushAll() {
    return Promise.allSettled([...pending.keys()].map((shapeId) => flush(shapeId)))
  }

  // One request at a time per shape, in the order they were asked for. A create and a delete of the
  // same shape, or a drag that ends while the last write is still in flight, must not race.
  function chain(shapeId, work) {
    const before = queue.get(shapeId) || Promise.resolve()
    const flight = before.then(work)
    queue.set(
      shapeId,
      flight.then(
        () => {},
        () => {},
      ),
    )
    return flight
  }

  // The write itself. `sentImage` is the picture this call carries, if any -- kept so that the reply's
  // image_id can be paired with bytes this page already has, without asking for them back.
  async function push(shapeId, item) {
    if (!supabase) return false
    const patch = { id: shapeId, ...item.patch }
    const sentImage = typeof patch.image === 'string' ? patch.image : ''

    flying.add(shapeId)
    saving.value = true
    const { data: rows, error } = await supabase.rpc('save_object', {
      p_kind: item.kind,
      p_patch: patch,
      p_session: benchSession(),
    })
    flying.delete(shapeId)
    saving.value = flying.size > 0

    const row = firstRow(rows)

    if (error || !row) {
      // The call did not happen, or did not answer. The change is still the planner's and is still
      // unwritten, so it goes back to waiting -- the next change to that shape, the end of the next
      // gesture, or coming back to the tab writes it. Nothing is thrown away, and nothing is retried on
      // a timer.
      errorMsg.value = error ? explain(error) : 'The bench did not answer.'
      requeue(shapeId, item)
      return false
    }

    noteReply(shapeId, row, sentImage)
    if (row.ok) {
      await settle(shapeId, item.kind, row)
      errorMsg.value = ''
      return true
    }

    report(shapeId, row)
    await snapBack(item.kind, shapeId, row)
    return false
  }

  function noteReply(shapeId, row, sentImage) {
    rev.value = Math.max(rev.value, Number(row.rev) || 0)
    if (row.bytes != null) bytes.value = Number(row.bytes) || 0
    if (row.ok) revOf.set(shapeId, Number(row.rev) || 0)
    if (sentImage && row.image_id) images.set(row.image_id, sentImage)
  }

  // Say what happened. A refusal about the LOCK is the lock layer's to say (the bench's strip has one
  // sentence and one source for it); a refusal about the SHAPE is a sentence from the database about
  // that shape -- which is the thing a write of one shape can say and a whole-document save never
  // could: it could only answer "The layout data is not valid" about everything at once.
  function report(shapeId, row) {
    if (row.problem) {
      say(shapeId, row.problem)
      return
    }
    if (row.held_by || row.mine_elsewhere || row.expires_at) {
      refuse(shapeId, row)
      // The database says this shape is not this tab's to write, so it is not this tab's to hold
      // either: stop renewing it and stop claiming it.
      lost(shapeId)
      return
    }
    // NOTHING NAMED AND NOBODY HOLDING IT: the lock this page was relying on has simply gone -- it
    // expired, or the shape was deleted and its lock went with it (see delete_object). That is still a
    // refusal, and a refusal nobody can see is indistinguishable from a broken page, so it is said.
    say(shapeId, 'That change was not stored: this page no longer holds this shape. Do it again.')
    lost(shapeId)
  }

  function requeue(shapeId, item) {
    const waiting = pending.get(shapeId)
    pending.set(shapeId, { kind: item.kind, patch: { ...item.patch, ...(waiting ? waiting.patch : {}) } })
  }

  // The shape as this page should hold it: what the bench has, with anything the planner has changed
  // SINCE (and not yet written) laid over it.
  //
  // Without this, a reply that arrives while the planner has already moved on would put the shape back
  // for a moment -- a drag that ends and a second drag that starts before the first write is answered is
  // the ordinary case here, because a write is a round trip. It is the same class of bug as the
  // whole-document save that merged a snapshot taken twenty seconds earlier, and it is why a reply is
  // never taken as the whole truth about a shape somebody is still working on.
  function mergeWaiting(shapeId, data) {
    const waiting = pending.get(shapeId)
    if (!waiting || !waiting.patch) return data
    return { ...data, ...withoutImage(waiting.patch) }
  }

  // The bench holds what was sent, and the reply is the merged shape: this page takes it, so what is on
  // screen is what is stored -- including the fields another planner had changed and this one had not
  // heard about.
  async function settle(shapeId, kind, row) {
    const imageId = row.image_id || ''
    if (imageId) imageOf.set(shapeId, imageId)
    else imageOf.delete(shapeId)

    const data = mergeWaiting(shapeId, row.data)

    if (kind !== 'plan') {
      replaceShape(kind, shapeId, data)
      return
    }

    let image = imageId ? images.get(imageId) || '' : ''
    if (!image && imageId) image = await fetchImage(imageId)
    replaceShape(kind, shapeId, { ...data, image })
  }

  // Put the bench's version of a shape back on this screen. Called when a write was REFUSED: what the
  // planner sees has to be what the bench holds, which is the only honest answer to "your change was
  // not stored". When the bench has no such shape at all -- one that never made it, or one somebody
  // else deleted -- it goes away.
  async function snapBack(kind, shapeId, row) {
    if (!row || row.data == null) {
      dropEverywhere(shapeId)
      forget(shapeId)
      return
    }
    revOf.set(shapeId, Number(row.rev) || 0)
    const imageId = row.image_id || ''
    if (imageId) imageOf.set(shapeId, imageId)
    else imageOf.delete(shapeId)

    let image
    if (kind === 'plan') {
      image = imageId ? images.get(imageId) || (await fetchImage(imageId)) || '' : ''
    }
    // A change the planner has made since the refused one is theirs and is written next; the refused one
    // is not. So the bench's shape goes back with the newer change still on it.
    const data = mergeWaiting(shapeId, row.data)
    replaceShape(kind, shapeId, kind === 'plan' ? { ...data, image } : data)
  }

  // A whole shape, written as it stands: what Undo puts back. The picture is sent only when the bench
  // does not already have this one -- a plan's picture is up to 512 KB, and undoing a move must not
  // upload it again.
  function replace(kind, shapeId, shape) {
    const patch = { ...withoutImage(shape) }
    const known = imageOf.get(shapeId)
    if (kind === 'plan' && shape.image && !(known && images.get(known) === shape.image)) {
      patch.image = shape.image
    }
    change(kind, shapeId, patch)
    return flush(shapeId)
  }

  // Take a shape off the bench. A change to it that has not been written yet is not a change any more,
  // so it is dropped rather than sent on the way out.
  function remove(kind, shapeId) {
    if (!supabase) return Promise.resolve(false)
    pending.delete(shapeId)
    stopTimer(shapeId)
    return chain(shapeId, async () => {
      flying.add(shapeId)
      saving.value = true
      const { data: rows, error } = await supabase.rpc('delete_object', {
        p_object: shapeId,
        p_session: benchSession(),
      })
      flying.delete(shapeId)
      saving.value = flying.size > 0

      const row = firstRow(rows)
      if (error || !row) {
        errorMsg.value = error ? explain(error) : 'The bench did not answer.'
        return false
      }
      rev.value = Math.max(rev.value, Number(row.rev) || 0)
      if (row.bytes != null) bytes.value = Number(row.bytes) || 0
      if (row.ok) {
        dropEverywhere(shapeId)
        forget(shapeId)
        // The database took the lock with the shape (see delete_object), so this page stops claiming it
        // too. Without this the page believes it still holds a shape that is not there -- and the next
        // change to that id (Undo putting it back, say) would be written without asking for the lock
        // again, and refused.
        lost(shapeId)
        return true
      }
      report(shapeId, row)
      await snapBack(kind, shapeId, row)
      return false
    })
  }

  // ---------- Gestures ----------
  // A pointer is down: a shape is being dragged, resized or turned, and what is on screen is a shape in
  // motion. Nothing is written until it is let go of, which is also the only moment at which "what the
  // planner meant" is knowable at all.
  function beginGesture() {
    alone = false
  }

  function endGesture() {
    alone = true
    return flushAll()
  }

  // ---------- What somebody else is doing ----------
  // A row event is a NOTIFICATION. It says which shape changed; the payload carries the row, and what
  // this page does with it depends on the revision it already has and on whether the shape is HELD --
  // a shape this tab has taken the lock on is never taken from an event, because the lock is what
  // decides who may say what.
  function onRow(payload) {
    const row = payload.eventType === 'DELETE' ? payload.old : payload.new
    const shapeId = row && row.object_id
    if (!shapeId) return
    if (holds(shapeId)) return

    if (payload.eventType === 'DELETE') {
      dropEverywhere(shapeId)
      forget(shapeId)
      return
    }

    const at = Number(row.rev) || 0
    if (at && at <= (revOf.get(shapeId) || 0)) return // already overtaken by something newer

    revOf.set(shapeId, at)
    rev.value = Math.max(rev.value, at)
    applyRow(shapeId, row)
  }

  async function applyRow(shapeId, row) {
    const kind = row.kind === 'plan' ? 'plan' : 'area'
    const imageId = row.image_id || ''
    if (imageId) imageOf.set(shapeId, imageId)
    else imageOf.delete(shapeId)

    if (kind !== 'plan') {
      replaceShape(kind, shapeId, row.data)
      return
    }

    let image = imageId ? images.get(imageId) || '' : ''
    if (!image && imageId) image = await fetchImage(imageId)
    // The shape is drawn even when its picture is not here yet: an outline-less plan for a moment is
    // better than a shape that arrives late, and the next event (or a reload) brings the picture.
    replaceShape(kind, shapeId, { ...row.data, image })
  }

  // A picture this page does not have. Read rather than streamed: layout_images is not published,
  // because an event carrying one would carry half a megabyte of base64 with it.
  async function fetchImage(imageId) {
    if (!imageId || !supabase || !layoutId.value) return ''
    if (images.has(imageId)) return images.get(imageId)

    const { data: row, error } = await supabase
      .from('layout_images')
      .select('image_id, data')
      .eq('layout_id', layoutId.value)
      .eq('image_id', imageId)
      .maybeSingle()

    if (error || !row) return ''
    images.set(imageId, row.data)
    return row.data
  }

  function subscribe() {
    if (!supabase || !layoutId.value || channel) return
    // Unique per mount: channels with the same name are shared, and a second one throws (the same
    // reason useBenchPresence puts this tab's tag in its channel name).
    channel = supabase
      .channel('bench-rows-' + layoutId.value + '-' + benchSession())
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'layout_objects',
          // layout_id is part of the primary key, which is what makes it a legal filter: a DELETE
          // carries the key columns and nothing else.
          filter: 'layout_id=eq.' + layoutId.value,
        },
        onRow,
      )
      .subscribe((status) => {
        if (status !== 'SUBSCRIBED') {
          joined = false
          return
        }
        // Joining and RE-joining are the same thing here: anything that happened while the socket was
        // down is caught up on, which is what makes a reconnect need no replay of old events.
        joined = true
        catchUp()
      })
  }

  function onVisibilityChange() {
    if (document.visibilityState !== 'visible' || !joined) return
    catchUp()
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange)
  }

  // ---------- Where I left the map ----------
  async function loadMyView() {
    if (!supabase) return null
    // No filter: RLS shows a planner their own row and nobody else's, and there is one bench.
    const { data: row, error } = await supabase.from('layout_views').select('lat, lng, zoom').maybeSingle()
    if (error || !row) return null
    return { lat: row.lat, lng: row.lng, zoom: row.zoom }
  }

  function saveView(view) {
    if (!view || !supabase) return
    pendingView = { lat: view.lat, lng: view.lng, zoom: view.zoom }
    if (viewTimer) return
    viewTimer = setTimeout(flushView, VIEW_SAVE_MS)
  }

  async function flushView() {
    if (viewTimer) {
      clearTimeout(viewTimer)
      viewTimer = null
    }

    const next = pendingView
    pendingView = null
    if (!next || !layoutId.value || !supabase) return

    // Best effort, deliberately. The one way this fails is a view outside the box the bench draws in
    // (the map can be panned past Singapore), and "I could not remember where you were looking" is not
    // worth an error message in the middle of somebody's work.
    const { error } = await supabase
      .from('layout_views')
      .upsert({ layout_id: layoutId.value, ...next }, { onConflict: 'layout_id,user_id' })

    if (error) return
    myView.value = next
  }

  onUnmounted(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
    for (const shapeId of [...timers.keys()]) stopTimer(shapeId)
    // A pan that has not been written yet is still worth writing, and so is a change: the page is going
    // away, so this is fire and forget -- a fetch that does not finish simply does not happen.
    flushView()
    flushAll()
    if (channel && supabase) supabase.removeChannel(channel)
    channel = null
    joined = false
  })

  return {
    // The canvas, and how the page watches it
    data,
    loading,
    errorMsg,
    saving,
    bytes,
    rev,
    layoutId,
    myView,
    // Reading
    open,
    catchUp,
    // Writing
    change,
    flush,
    flushAll,
    remove,
    replace,
    busy,
    known,
    beginGesture,
    endGesture,
    // Reading one shape's picture (used by a shape that arrives without one)
    fetchImage,
    // My own camera
    saveView,
  }
}
