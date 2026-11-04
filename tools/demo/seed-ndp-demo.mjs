// The presentation video's event: the NE4 rehearsal at the Padang, set up so the demo can start at segment 5.
//
//   node tools/demo/seed-ndp-demo.mjs        (after tools/demo/ndp-demo-plan.mjs has written docs/demo/)
//
// qa_root makes "NDP 2025 NE4 Rehearsal" with the demo's 13 groups (create_event_with_setup, the wizard's call):
// qa_planner is a planner, and P&C Contingent 3 has qa_ic1 as its IC and qa_member as a cadet.
// The Padang and the casing location are drawn on the event's map (save_object, the bench's own call), and an empty
// plan is made for the video to import ndp-ne4-demo.csv into. Nothing is started or published: the video does that.
// Run it again for a fresh event to retake on; delete old ones from their Overview page.
import fs from 'node:fs'
import { randomUUID } from 'node:crypto'
import { clientFor } from '../../e2e/support/session.js'

const groups = JSON.parse(fs.readFileSync('docs/demo/ndp-ne4-demo-groups.json', 'utf8'))
const must = (r, what) => {
  if (r.error) throw new Error(`${what}: ${r.error.message}`)
  return r.data
}

const { sb: root } = await clientFor('root')
const id = async (name) => (await clientFor(name)).user.id
const [planner, ic, cadet] = [await id('planner'), await id('ic1'), await id('member')]

// ---------- the event, its people and its groups ----------
// A week ahead: a rehearsal must be before the event day (090), and segment 6 adds one. Start now still runs it today.
const start = new Date(Date.now() + 7 * 86400_000)
const eventId = must(
  await root.rpc('create_event_with_setup', {
    p_event: {
      name: 'NDP 2025 NE4 Rehearsal',
      venue: 'The Padang, Singapore',
      description: 'Parade & Ceremony to Mobile Column, from the NE4 Adjusted Show Matrix (17 Jul) and the NDP 25 map. Demo event for the IS216 G11 video.',
      starts_at: start.toISOString(),
      ends_at: new Date(start.getTime() + 7 * 86400_000).toISOString(),
    },
    p_members: [
      { user_id: planner, role: 'planner' },
      { user_id: ic, role: 'participant' },
      { user_id: cadet, role: 'participant' },
    ],
    p_groups: groups.map((g) => ({
      name: g.name,
      colour: g.colour,
      members:
        g.name === 'P&C Contingent 3'
          ? [
              { user_id: ic, is_admin: false, is_ic: true },
              { user_id: cadet, is_admin: false, is_ic: false },
            ]
          : [],
    })),
  }),
  'create event',
)
const event = must(await root.from('events').select('id, join_code').eq('id', eventId).single(), 'event')

// ---------- the venue: the Padang field and the contingents' casing location on Raffles Avenue ----------
// Corners checked against OneMap's own map: the Padang between St Andrew's Road and Connaught Drive, from the
// Recreation Club to the Cricket Club; the casing location where the NDP 25 map's casing routes start.
// A piece of the Padang, by how far across it is: a from the St Andrew's Road side (0) to Connaught Drive (1), b from
// the Victoria Concert Hall end (0) to the Recreation Club end (1). Its corners are the Padang's own, below.
const PADANG = { west: [1.28977, 103.85213], north: [1.29192, 103.85301], east: [1.29116, 103.85381], south: [1.28947, 103.85324] }
function padangAt(a, b) {
  const { west: D, north: A, east: B, south: C } = PADANG
  const mix = (i) => (1 - a) * (1 - b) * D[i] + (1 - a) * b * A[i] + a * b * B[i] + a * (1 - b) * C[i]
  return [Math.round(mix(0) * 1e6) / 1e6, Math.round(mix(1) * 1e6) / 1e6]
}
function padangPart(a0, a1, b0, b1) {
  return [padangAt(a0, b1), padangAt(a1, b1), padangAt(a1, b0), padangAt(a0, b0)]
}
const AREAS = [
  { name: 'Padang', kind: 'zone', code: 'PADANG', points: [[1.29192, 103.85301], [1.29116, 103.85381], [1.28947, 103.85324], [1.28977, 103.85213]] },
  { name: 'Casing Location', kind: 'zone', code: 'CASING', points: [[1.29135, 103.8557], [1.29135, 103.85615], [1.2909, 103.85615], [1.2909, 103.8557]] },
  // The show's own layout on the field, as the Padang is built for an NDP: the performance floor in the middle, the big
  // stand along Connaught Drive, a stand at each end, and the St Andrew's Road side left open (padangPart below)
  { name: 'Performance Floor', kind: 'stage', code: 'FLOOR', points: padangPart(0.12, 0.7, 0.18, 0.8) },
  { name: 'East Stand', kind: 'zone', code: 'EAST_STAND', points: padangPart(0.76, 0.97, 0.06, 0.94) },
  { name: 'South Stand', kind: 'zone', code: 'SOUTH_STAND', points: padangPart(0.1, 0.7, 0.03, 0.14) },
  { name: 'North Stand', kind: 'zone', code: 'NORTH_STAND', points: padangPart(0.1, 0.7, 0.86, 0.97) },
  // The parade's formation on the floor, as NDP lays it out, rows from the St Andrew's Road side towards the big screen
  // and the centre stage: the State Colours, the Guard of Honour, the Regimental Colours Party, the uniformed
  // contingents, the Youth Uniform Groups, the Social and Economic Groups, then the Combined Band
  { name: 'State Colours', kind: 'zone', code: 'STATE_COLOURS', points: padangPart(0.13, 0.17, 0.44, 0.56) },
  { name: 'Guard of Honour', kind: 'zone', code: 'GUARD_OF_HONOUR', points: padangPart(0.19, 0.27, 0.22, 0.78) },
  { name: 'Regimental Colours Party', kind: 'zone', code: 'COLOURS_PARTY', points: padangPart(0.29, 0.33, 0.26, 0.74) },
  { name: 'Contingents', kind: 'zone', code: 'CONTINGENTS', points: padangPart(0.35, 0.44, 0.22, 0.78) },
  { name: 'Youth Uniform Groups', kind: 'zone', code: 'YOUTH_UNIFORM_GROUPS', points: padangPart(0.46, 0.52, 0.3, 0.7) },
  { name: 'Social and Economic Groups', kind: 'zone', code: 'SOCIAL_ECONOMIC_GROUPS', points: padangPart(0.54, 0.6, 0.24, 0.76) },
  { name: 'Combined Band', kind: 'zone', code: 'COMBINED_BAND', points: padangPart(0.61, 0.67, 0.4, 0.6) },
  { name: 'Centre Stage', kind: 'stage', code: 'CENTRE_STAGE', points: padangPart(0.67, 0.73, 0.43, 0.57) },
  // The NDP 25 Main map's own posts and outlines (tools/demo/ndp-kml-areas.mjs): stations, access control points,
  // medical posts and the contingents' holding area, each on its real coordinates
  ...JSON.parse(fs.readFileSync('docs/demo/ndp25-areas.json', 'utf8')).areas.map(({ name, kind, code, points }) => ({ name, kind, code, points })),
]
const bench = must(await root.rpc('open_bench', { p_event: eventId }), 'open bench')
const layout = (Array.isArray(bench) ? bench[0] : bench).id
const session = randomUUID()
// The bench's rule: a shape is written only by whoever holds its lock, so take it, write, and let it go.
for (const a of AREAS) {
  const id = randomUUID()
  const lock = must(await root.rpc('lock_object', { p_object: id, p_session: session, p_layout: layout }), `${a.name} lock`)
  if (!lock[0]?.granted) throw new Error(`${a.name}: lock not granted`)
  const saved = must(await root.rpc('save_object', { p_kind: 'area', p_patch: { id, ...a }, p_session: session, p_layout: layout }), a.name)
  if (!saved[0]?.ok) throw new Error(`${a.name}: ${saved[0]?.problem || 'not saved'}`)
  await root.rpc('unlock_object', { p_object: id, p_session: session, p_layout: layout })
}

// ---------- an empty plan for the video's import; T+0 is set on the start panel ----------
const sg = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit' }).format(start)
const plan = must(await root.rpc('plan_save', { p_event: eventId, p_plan: { name: 'NE4 Rehearsal: Parade & Ceremony', for_date: sg, t0_time: '18:00:00' } }), 'plan')

console.log(`event ${eventId}`)
console.log(`join code ${event.join_code}`)
console.log(`${groups.length} groups, ${AREAS.length} areas, empty plan ${plan.id}`)
console.log(`open: https://gpstesting.vercel.app/events/${eventId}`)
