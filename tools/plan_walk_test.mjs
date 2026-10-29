// tools/plan_walk_test.mjs — the plan's walk (src/utils/planWalk.js), tried hard.
//
//     node tools/plan_walk_test.mjs        (also: npm run test:walk)
//
// No database and no browser: this is the arithmetic in the middle of step 30 -- which statements make a line, which
// moment the clock is between -- the part a map can only show you by looking right. The product side (two dashed lines
// under the people, the bold leg, the scope of two identities) is dev/checks/step30-planline.mjs.
//
// The cases are the ones a real walk has: a stretch of on-site statements, a moment that only carries the group
// forward, an off-site statement and the walk that starts again after it, a group whose whole walk is one point, and a
// clock put in five places (before the first statement, on the first leg, exactly on a statement, into an off-site
// gap, after the last one).
//
// WRITTEN TO FAIL FIRST. The last four cases run MUTATED copies of planWalk.js -- an off-site moment that does not
// break, a carried moment that does, a leg that does not include its own end, and a leg for a walk of one point -- and
// each must turn its named case red. If a mutation ever stops applying (the line it rewrites is gone), the test throws
// rather than quietly passing: a red-first proof that cannot go red is not a proof.
import fs from 'node:fs'
import { runsOf, walksOf, legNow } from '../src/utils/planWalk.js'

let passed = 0
const failures = []
function check(name, ok, detail) {
  if (ok) passed += 1
  else failures.push(name + (detail ? '\n    ' + detail : ''))
}
const show = (value) => JSON.stringify(value).slice(0, 400)

// ---------- the rows, shaped as session_timetable (065) answers them ----------
const T0 = Date.parse('2026-10-30T12:00:00.000Z')
const at = (t_s) => T0 + t_s * 1000

/** One row: a moment on the plan's clock, its state, and the point it states (none for a carried or off-site one). */
function row(t_s, latLng, state = 'pending', group = ['g1', 'Gate Crew']) {
  const [lat, lng] = latLng || [null, null]
  return {
    group_id: group[0],
    group_name: group[1],
    frame_id: 'f-' + group[0] + '-' + t_s,
    t_s,
    planned_at: new Date(at(t_s)).toISOString(),
    state,
    lat,
    lng,
  }
}
const GATE_LINE = [1.3300, 103.774]
const GATE_5 = [1.33018, 103.774]
const GATE_10 = [1.33036, 103.774]
const GATE_15 = [1.33054, 103.774]
const GATE_20 = [1.33072, 103.774]

// ---------- 1. the four rules of a run ----------
const PLAIN = [row(0, GATE_LINE), row(300, GATE_5), row(600, GATE_10), row(900, GATE_15)]
const plain = runsOf(PLAIN)
check('R1 a stretch of on-site statements is one run, in the plan’s order', plain.length === 1 && plain[0].length === 4, show(plain))
check('R1 and it is drawn from the points themselves', plain[0][0][0] === GATE_LINE[0] && plain[0][3][1] === GATE_15[1], show(plain[0]))

// A cared moment states no point of its own: the line continues from the last point the group did state.
const CARRIED = [row(0, GATE_LINE), row(300, GATE_5), row(600, null), row(900, GATE_15)]
const carried = runsOf(CARRIED)
check('R2 a moment that only carries the group forward does not break the walk', carried.length === 1, show(carried))
check('R2 and it adds no vertex: three statements with a point, not four', carried.length === 1 && carried[0].length === 3, show(carried))

// An off-site statement is not a place on the map: the walk stops there and starts again on site.
const OFFSITE = [row(0, GATE_LINE), row(300, GATE_5), row(600, null, 'not_required'), row(900, GATE_15), row(1200, GATE_20)]
const offsite = runsOf(OFFSITE)
check('R3 an off-site statement breaks the walk', offsite.length === 2, show(offsite))
check('R3 into the two stretches either side of it', offsite[0].length === 2 && offsite[1].length === 2, show(offsite))
check(
  'R3 and the line never bridges the gap (the last point before, the first after)',
  offsite[0][1][0] === GATE_5[0] && offsite[1][0][0] === GATE_15[0],
  show(offsite),
)

// A run of one point is a mark, not a line: there is no second point to join it to.
const LONE = [row(0, GATE_LINE), row(300, null, 'not_required'), row(600, GATE_15)]
const lone = runsOf(LONE)
check('R4 a walk with one stated point either side of a gap draws two runs of one', lone.length === 2 && lone[0].length === 1 && lone[1].length === 1, show(lone))
check('R4 so a run of one is kept as a run (a dot is a moment, not a road)', lone.every((run) => run.length === 1), show(lone))

// ---------- 2. the groups ----------
const TWO = [...PLAIN, ...PLAIN.map((r) => ({ ...row(r.t_s, GATE_5, 'pending', ['g2', 'Sound']) }))]
const walks = walksOf(TWO)
check('G1 the read is arranged per group, in the order it named them', [...walks.keys()].join(',') === 'g1,g2', show([...walks.keys()]))
check('G1 a group keeps every row it was given, in the plan’s order', walks.get('g1').rows.map((r) => r.t_s).join(',') === '0,300,600,900')
check('G1 the points are the rows that state one, and only those', walks.get('g1').points.length === 4 && walks.get('g1').runs[0].length === 4)

// ---------- 3. five places the clock can be ----------
const LEGS = PLAIN // four on-site statements, five minutes apart
check('C1 before the first statement there is no leg', legNow(LEGS, at(0) - 1000) === null)
const first = legNow(LEGS, at(0) + 1000)
check('C2 on the first leg, the leg is the first pair', !!first && first.map((r) => r.t_s).join(',') === '0,300', show(first && first.map((r) => r.t_s)))
const middle = legNow(LEGS, at(420))
check('C3 between two statements, the leg is theirs', !!middle && middle.map((r) => r.t_s).join(',') === '300,600', show(middle && middle.map((r) => r.t_s)))
const exact = legNow(LEGS, at(300))
check('C4 exactly on a statement, the leg is the one that LEAVES it', !!exact && exact.map((r) => r.t_s).join(',') === '300,600', show(exact && exact.map((r) => r.t_s)))
const gapInto = legNow(OFFSITE, at(420))
check('C5 a leg into an off-site statement is no leg at all (the plan says they are leaving)', gapInto === null, show(gapInto))
const gapAcross = legNow(OFFSITE, at(700))
check('C5 across the gap, while they are off site, there is no leg', gapAcross === null, show(gapAcross))
const after = legNow(LEGS, at(900))
check('C6 after the last statement there is no leg', after === null, show(after))
const carriedOn = legNow(CARRIED, at(420))
const carriedAt = legNow(CARRIED, at(620))
check('C7 a carried moment is not a leg: the plan says the group is still where it was', carriedOn === null && carriedAt === null, show([carriedOn, carriedAt]))

// ---------- 4. the four mutations, each turned against its own case ----------
const source = fs.readFileSync(new URL('../src/utils/planWalk.js', import.meta.url), 'utf8')
async function mutant(name, from, to) {
  if (!source.includes(from)) throw new Error(`the mutation "${name}" no longer applies: planWalk.js does not contain ${JSON.stringify(from)}`)
  const text = source.replace(from, to)
  return import('data:text/javascript;base64,' + Buffer.from(text, 'utf8').toString('base64'))
}

const noBreak = await mutant('an off-site moment does not break', "if (row.state === 'not_required') {", 'if (false) {')
const noBreakRuns = noBreak.runsOf(OFFSITE)
check('M1 the mutant joins the walk across the gap, so R3 is red', noBreakRuns.length === 1, show(noBreakRuns))
check('M1 and its one run is every point, the two sides of the gap included', noBreakRuns[0].length === 4, show(noBreakRuns))

const breaksCarried = await mutant('a carried moment breaks', "if (row.state === 'not_required') {", "if (row.state === 'not_required' || row.lat == null) {")
const breaksCarriedRuns = breaksCarried.runsOf(CARRIED)
check('M2 the mutant breaks the walk at a carried moment, so R2 is red', breaksCarriedRuns.length === 2, show(breaksCarriedRuns))

const noEnd = await mutant('the leg does not include its own end', 'if (at(rows[k]) <= clockMs) reached = k', 'if (at(rows[k]) < clockMs) reached = k')
const noEndLeg = noEnd.legNow(LEGS, at(300))
check(
  'M3 the mutant puts the clock on the leg before the statement, so C4 is red',
  !!noEndLeg && noEndLeg.map((r) => r.t_s).join(',') === '0,300',
  show(noEndLeg && noEndLeg.map((r) => r.t_s)),
)

const legOfOne = await mutant(
  'a walk of one point has a leg',
  'if (reached < 0 || reached + 1 >= rows.length) return null',
  'if (reached < 0) return null\n  if (reached + 1 >= rows.length) return [rows[reached], rows[reached]]',
)
const legOfOneResult = legOfOne.legNow(LEGS, at(900))
check('M4 the mutant invents a leg at the last statement, so C6 is red', Array.isArray(legOfOneResult) && legOfOneResult.length === 2, show(legOfOneResult && legOfOneResult.map((r) => r.t_s)))
check('M4 and it is the same statement twice: a walk of one point, joined to itself', !!legOfOneResult && legOfOneResult[0].t_s === legOfOneResult[1].t_s)

// ---------- verdict ----------
if (failures.length) {
  console.log('')
  for (const failure of failures) console.log('  FAIL  ' + failure)
  console.log('')
  console.log(`FAIL plan walk: ${failures.length} of ${passed + failures.length} assertion(s)`)
  process.exit(1)
}
console.log(`PASS plan walk (${passed} assertion${passed === 1 ? '' : 's'})`)
