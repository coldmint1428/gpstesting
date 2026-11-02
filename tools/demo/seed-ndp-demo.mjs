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
const start = new Date()
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
const AREAS = [
  { name: 'Padang', kind: 'zone', code: 'PADANG', points: [[1.29192, 103.85301], [1.29116, 103.85381], [1.28947, 103.85324], [1.28977, 103.85213]] },
  { name: 'Casing Location', kind: 'zone', code: 'CASING', points: [[1.29135, 103.8557], [1.29135, 103.85615], [1.2909, 103.85615], [1.2909, 103.8557]] },
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
