// Development harness for the plan board: fixtures instead of a database, so the screen can be rendered and
// screenshotted without a login. Everything here is fake and lives only in memory; the component under test is
// the real src/components/plan/PlanBoard.vue.
import { computed, createApp, h, ref } from 'vue'
import PlanBoard from '../src/components/plan/PlanBoard.vue'

const eventId = 'preview-event'

const groups = ref([
  { id: 'g1', name: 'Gate Crew', code: 'GC' },
  { id: 'g2', name: 'Sound', code: 'SN' },
  { id: 'g3', name: 'Backstage', code: 'BS' },
])

function box(lat0, lng0, lat1, lng1) {
  return {
    type: 'Polygon',
    coordinates: [
      [
        [lng0, lat0],
        [lng1, lat0],
        [lng1, lat1],
        [lng0, lat1],
        [lng0, lat0],
      ],
    ],
  }
}

const zones = ref([
  { id: 'z1', code: 'MAIN_STAGE', name: 'Main stage', kind: 'stage', geojson: box(1.2899, 103.8457, 1.2903, 103.8461) },
  { id: 'z2', code: 'BACKSTAGE', name: 'Backstage', kind: 'zone', geojson: box(1.2905, 103.8457, 1.2909, 103.8461) },
  { id: 'z3', code: 'STORE', name: 'Store (no-go)', kind: 'no_go', geojson: box(1.2899, 103.8464, 1.2903, 103.8468) },
])

let nextId = 1
function frame(t_s, positions, note) {
  // A position from the database always carries both flags (046 made them NOT NULL with defaults), and the board's
  // inverse commands compare whole rows -- so a fixture that left them off would make an undo write badges that had
  // not changed, which is a dev page that behaves worse than the app.
  const map = {}
  for (const [group, at] of Object.entries(positions || {})) {
    map[group] = { lat: at.lat, lng: at.lng, state: at.state || 'on_site', verify: at.verify || 'auto' }
  }
  return { id: `f${nextId++}`, t_s, note: note || null, rev: 1, positions: map }
}

// A walk from the stage up to backstage in 20 m steps, then one deliberate 90 m jump so the warning styling
// and the highlighted chain can be seen.
const frames = ref([
  frame(0, { g1: { lat: 1.2902, lng: 103.846 }, g2: { lat: 1.2907, lng: 103.846 }, g3: { lat: 1.2902, lng: 103.8463 } }, 'call'),
  frame(60, { g1: { lat: 1.2904, lng: 103.846 } }),
  frame(120, { g1: { lat: 1.2906, lng: 103.846 } }, 'doors'),
  frame(180, { g1: { lat: 1.2908, lng: 103.846 } }),
  frame(240, { g1: { lat: 1.2908, lng: 103.8468 } }, 'on stage'),
])

const plan = ref({ id: 'p1', name: 'Show night — example', status: 'draft', rev: 1, frame_count: 5 })
const plans = ref([plan.value, { id: 'p2', name: 'Rehearsal', status: 'ready', rev: 1, frame_count: 0 }])
const loading = ref(false)
const busy = ref(false)
const errorMsg = ref('')
const livePlan = computed(() => plans.value.find((p) => p.status === 'live') || null)

// ---------- who is editing (081), as far as a fixture can have it ----------
//
// The real holds live in public.plan_cell_locks and are decided by the database; the fixture keeps the same facts in
// memory and says the same sentences, so the ownership UI (a ring on somebody else's badge, the stack of who is
// editing, a drag that is refused) can be seen and checked in a browser without a second account.
//
// `?peer=1` puts a colleague's hand on one badge from the start -- Sound at the first moment -- which is the case the
// strip, the ring and the snap-back all exist for.
const PEER = new URLSearchParams(location.search).has('peer')
const refusals = new Map() // cell key -> the name of whoever has it, for a colleague's hold
const mine = new Set() // cells this page is holding

function cellKey(frame, group) {
  return `${frame}|${group}`
}

function clockOf(frameId) {
  const f = findFrame(frameId)
  if (!f) return '?'
  return `+${Math.floor(f.t_s / 60)}:${String(f.t_s % 60).padStart(2, '0')}`
}

function groupName(id) {
  const group = groups.value.find((g) => g.id === id)
  return group ? group.name : 'that group'
}

function lockRefusal(message) {
  return Object.assign(new Error(message), { code: 'PT423' })
}

if (PEER) refusals.set(cellKey('f1', 'g2'), 'Priya')

/** The hold the drag takes as it begins (081's plan_lock_cells): all or none, and somebody else's is refused. */
async function holdCells(cells) {
  for (const cell of cells || []) {
    const blocker = refusals.get(cellKey(cell.frame, cell.group))
    if (blocker) {
      throw lockRefusal(`${blocker} is editing ${groupName(cell.group)} at ${clockOf(cell.frame)}.`)
    }
  }
  for (const cell of cells || []) mine.add(cellKey(cell.frame, cell.group))
  return (cells || []).length
}

async function releaseCells(cells) {
  for (const cell of cells || []) mine.delete(cellKey(cell.frame, cell.group))
}

/** Who is editing what, shaped like plan_lock_holders (081). */
async function lockHolders() {
  const rows = []
  for (const cell of mine) {
    const [frame, group] = cell.split('|')
    const f = findFrame(frame)
    if (!f) continue
    rows.push({
      kind: 'badge',
      frame_id: frame,
      group_id: group,
      t_s: f.t_s,
      group_name: groupName(group),
      user_id: 'me',
      display_name: 'You',
      mine: true,
    })
  }
  for (const [cell, name] of refusals) {
    const [frame, group] = cell.split('|')
    const f = findFrame(frame)
    if (!f) continue
    rows.push({
      kind: 'badge',
      frame_id: frame,
      group_id: group,
      t_s: f.t_s,
      group_name: groupName(group),
      user_id: 'peer',
      display_name: name,
      mine: false,
    })
  }
  return rows
}

async function releaseAllHolds() {
  mine.clear()
}

// ---------- where a colleague's drag is going (phase 4) ----------
//
// The real stream is a Realtime broadcast (usePlanStream): a page publishes where the badge under its finger is going,
// twenty times a second, and every other page draws it as a ghost. The fixture has no socket, so it keeps the board's
// renderer and hands it whatever a check asks a "colleague" to publish -- the same rows, through the same seam the app
// uses. Nothing here writes anything, which is the point of a draft.
let draftHandler = null
const draftRows = new Map()

function startDrafts() {}

function stopDrafts() {
  draftRows.clear()
  if (draftHandler) draftHandler([])
}

function planDraft() {} // this page has no colleague to tell

function clearDrafts() {}

function onDraft(fn) {
  draftHandler = fn
}

/**
 * The real one is 082's two doors under ONE hold (usePlanLocks.rewrite): every cell an inverse touches -- the ones to
 * place and the ones to take away -- is checked before a single row is written, so a badge somebody else is holding
 * refuses the whole undo. The fixture checks exactly that, first, and writes nothing at all when it is refused.
 */
async function rewriteCells(frameId, target) {
  const frame = findFrame(frameId)
  if (!frame) throw new Error('That frame is not in the plan, so there is nothing to put back.')
  const wanted = target || {}
  const current = frame.positions || {}
  const changed = {}
  for (const [group, at] of Object.entries(wanted)) {
    const was = current[group]
    if (!was || was.lat !== at.lat || was.lng !== at.lng || was.state !== at.state || was.verify !== at.verify) {
      changed[group] = at
    }
  }
  const gone = Object.keys(current).filter((group) => !(group in wanted))
  for (const group of [...Object.keys(changed), ...gone]) {
    const blocker = refusals.get(cellKey(frameId, group))
    if (blocker) throw lockRefusal(`${blocker} is editing ${groupName(group)} at ${clockOf(frameId)}.`)
  }
  if (Object.keys(changed).length) await api.placeCells(frameId, changed)
  if (gone.length) await api.unplaceCells(frameId, gone)
  return { placed: Object.keys(changed).length, removed: gone.length }
}

// A seam for the browser checks (dev/checks/board-smoke.mjs): what this page is holding, so a gesture can be watched
// taking a badge and giving it up without a database. In the app the answer is public.plan_cell_locks, which no page
// reads directly -- it is the doors that read it -- so this exists only where the doors are faked.
globalThis.__planPreview = {
  holds: () => ({ mine: [...mine].sort(), refusals: [...refusals.keys()].sort() }),
  /** Where the fixture has a badge standing, so a check can aim a ghost at a place it can measure on screen. */
  at: (frameId, groupId) => {
    const f = findFrame(frameId)
    const at = f && f.positions ? f.positions[groupId] : null
    return at ? { lat: at.lat, lng: at.lng } : null
  },
  /** A "colleague" dragging a badge: the rows the stream would have delivered. No coordinates means "let go". */
  draft: (frameId, groupId, lat, lng) => {
    const key = cellKey(frameId, groupId)
    if (lat == null || lng == null) draftRows.delete(key)
    else draftRows.set(key, { cell: key, frame: frameId, group: groupId, lat, lng, from: 'peer-tag' })
    if (draftHandler) draftHandler([...draftRows.values()])
  },
  /** Put a colleague's hand on a badge, or take it off: the refusal case, driven from a check. */
  block: (key, name) => {
    refusals.set(key, name || 'Priya')
  },
  unblock: (key) => {
    refusals.delete(key)
  },
}

function findFrame(id) {
  return frames.value.find((f) => f.id === id)
}

/**
 * The real doors are followed by a read (usePlan's "a write is followed by a read"): `loadFrames` replaces the array,
 * and that is what makes the board draw the new positions. The fixture's array IS its read, so a nested mutation alone
 * would leave the markers where the hand put them -- a dev page disagreeing with the app about when a screen redraws.
 */
function reread() {
  frames.value = frames.value.map((frame) => ({ ...frame }))
}

/** The position that stands at a moment: the last thing the group said at or before it (the database resolves the
 *  same way in 042 and 045, and the board draws with it). */
function standingAt(t_s, groupId) {
  const said = frames.value
    .filter((f) => f.t_s <= t_s && f.positions && f.positions[groupId])
    .sort((a, b) => a.t_s - b.t_s)
  return said.length ? said[said.length - 1].positions[groupId] : null
}

const api = {
  plans,
  plan,
  frames,
  groups,
  zones,
  loading,
  busy,
  errorMsg,
  livePlan,
  async loadPlans() {},
  async loadGroups() {},
  async loadZones() {},
  async loadFrames() {},
  async openPlan(id) {
    plan.value = plans.value.find((p) => p.id === id) || plan.value
  },
  async createPlan() {},
  async renamePlan() {},
  async deletePlan() {},
  async forkPlan() {},
  async publishPlan() {},
  async saveFrame(input) {
    const existing = input.id ? findFrame(input.id) : frames.value.find((f) => f.t_s === input.t_s)
    if (existing) {
      // 082: a frame that already stands refuses a badge map, because the map is what carried everybody else's
      // positions back. The fixture says the same thing, so a page that starts sending one is caught here.
      if (input.positions !== undefined) {
        throw new Error('This frame already has badges, and they are edited one at a time. Reload the board.')
      }
      if (input.note !== undefined) existing.note = input.note
      existing.rev += 1
    } else {
      frames.value.push(frame(input.t_s, input.positions || {}, input.note))
      frames.value.sort((a, b) => a.t_s - b.t_s)
    }
  },
  // One badge, one row (082). The real one is frame_place_many(), checked against a hold; the fixture has no server
  // and one page, so there is nothing to hold and no revision to bump -- a badge move is not a change to the frame's
  // time or note, and the dev page should not pretend it is.
  async placeCells(frameId, map) {
    const target = findFrame(frameId)
    if (!target) throw new Error('That frame is not in this plan.')
    // 082 checks every cell against a live hold before it writes. The fixture checks the one fact it has: somebody
    // else's hand on that badge.
    for (const groupId of Object.keys(map || {})) {
      if (refusals.has(cellKey(frameId, groupId))) {
        throw lockRefusal('This badge stopped being yours to edit. Try again.')
      }
    }
    let written = 0
    for (const [groupId, at] of Object.entries(map || {})) {
      const was = target.positions[groupId] || {}
      target.positions[groupId] = {
        lat: at.lat,
        lng: at.lng,
        state: at.state || was.state || 'on_site',
        verify: at.verify || was.verify || 'auto',
      }
      written += 1
    }
    if (written) reread()
    return written
  },
  // The only way a position disappears (082).
  async unplaceCells(frameId, groupIds) {
    const target = findFrame(frameId)
    if (!target) return 0
    let removed = 0
    for (const id of groupIds || []) {
      if (target.positions[id]) {
        delete target.positions[id]
        removed += 1
      }
    }
    if (removed) reread()
    return removed
  },
  // Ownership (081): the hold a gesture takes, the hold it gives up, who is editing, and the way out of it.
  holdCells,
  releaseCells,
  lockHolders,
  releaseAllHolds,
  // Where a colleague's drag is going (phase 4): in the app a Realtime broadcast, here the board's renderer plus a
  // seam a check can push a draft through. Nothing in this pair writes anything.
  startDrafts,
  stopDrafts,
  planDraft,
  clearDrafts,
  onDraft,
  // An undo or a redo of a badge map, under one hold for both directions (phase 4).
  rewriteCells,
  async moveFrame(id, t_s) {
    const target = findFrame(id)
    if (target) {
      target.t_s = t_s
      target.rev += 1
    }
  },
  async deleteFrame(id) {
    frames.value = frames.value.filter((f) => f.id !== id)
  },
  async shiftFrom(from_s, delta_s, to_s = null) {
    const inRange = frames.value.filter((f) => f.t_s >= from_s && (to_s == null || f.t_s <= to_s))
    if (!inRange.length) return 0
    // A chunk moves rigidly: it stops at T+0 rather than squashing its first frames onto it (044 does the same).
    const first = Math.min(...inRange.map((f) => f.t_s))
    const delta = Math.max(delta_s, -first)
    for (const f of inRange) f.t_s += delta
    frames.value.sort((a, b) => a.t_s - b.t_s)
    return inRange.length
  },
  // The real one is the database's (045): write the named groups at their standing position on a later frame,
  // touching nobody else. The fixture does the same arithmetic, because a dev page that disagreed with the app
  // would be a second product -- but it keeps the two refusals in one sentence each.
  async holdFrame(frameId, seconds, groupIds) {
    const source = findFrame(frameId)
    if (!source) throw new Error('That frame is not in this plan.')
    const target_s = source.t_s + seconds
    const wanted = groupIds && groupIds.length
      ? groupIds
      : groups.value.map((g) => g.id).filter((id) => standingAt(source.t_s, id))
    let target = frames.value.find((f) => f.t_s === target_s) || null
    const existed = !!target
    let created = 0
    let written = 0
    for (const id of wanted) {
      const at = standingAt(source.t_s, id)
      if (!at) throw new Error('That group stands nowhere to hold.')
      const row = target && target.positions[id]
      if (row) {
        if (row.lat !== at.lat || row.lng !== at.lng) {
          throw new Error('That group already stands somewhere else at that moment.')
        }
        continue
      }
      if (!target) {
        target = frame(target_s, {}, null)
        frames.value.push(target)
        frames.value.sort((a, b) => a.t_s - b.t_s)
        created = 1
      }
      target.positions[id] = { lat: at.lat, lng: at.lng, state: at.state || 'on_site', verify: at.verify || 'auto' }
      written += 1
    }
    if (existed && written) target.rev += 1
    return {
      held_frame_id: target ? target.id : null,
      held_t_s: target_s,
      frames_added: created,
      frames_reused: existed && written ? 1 : 0,
      positions_written: written,
      groups_held: wanted.length,
    }
  },
  // The real one is the database's (042); the fixture has nothing to fill, and a fixture that quietly rewrote
  // frames would make the dev page disagree with the app.
  async fillGap() {
    return { frames_added: 0, frames_reused: 0, positions_written: 0, groups_filled: 0, max_step_m: null }
  },
  // The real one is the database's (047): patch the rows these frames already hold, one revision per frame touched,
  // and count the named cells it could not reach. The fixture mirrors it so the dev page is the same product.
  async setVerify(frameIds, groupIds, verify) {
    const wantedFrames = new Set(frameIds)
    const named = groupIds && groupIds.length ? groupIds : null
    const touched = new Set()
    let set = 0
    let skipped = 0
    for (const f of frames.value) {
      if (!wantedFrames.has(f.id)) continue
      const wanted = named || Object.keys(f.positions || {})
      for (const id of wanted) {
        const row = f.positions && f.positions[id]
        if (!row) {
          skipped += 1
          continue
        }
        if ((row.verify === 'manual' ? 'manual' : 'auto') === verify) continue
        row.verify = verify
        set += 1
        touched.add(f.id)
      }
    }
    for (const f of frames.value) if (touched.has(f.id)) f.rev += 1
    return { frames_touched: touched.size, positions_set: set, positions_skipped: skipped }
  },
  async check() {
    return []
  },
}

createApp({
  render: () => h(PlanBoard, { eventId, canEdit: true, api }),
}).mount('#app')
