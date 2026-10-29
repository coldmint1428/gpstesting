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
  return { id: `f${nextId++}`, t_s, note: note || null, rev: 1, positions }
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

function findFrame(id) {
  return frames.value.find((f) => f.id === id)
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
      if (input.positions !== undefined) existing.positions = input.positions
      if (input.note !== undefined) existing.note = input.note
      existing.rev += 1
    } else {
      frames.value.push(frame(input.t_s, input.positions || {}, input.note))
      frames.value.sort((a, b) => a.t_s - b.t_s)
    }
  },
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
      target.positions[id] = { lat: at.lat, lng: at.lng }
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
