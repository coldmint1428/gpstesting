// tools/plan_sheet_test.mjs — the plan's CSV sheet (src/utils/planSheet.js), tried hard.
//
//     node tools/plan_sheet_test.mjs        (also: npm run test:sheet)
//
// No database and no browser: this is the file side only, the part a spreadsheet can get wrong. The product side —
// export, wipe, import, and a sheet refused with the board's own sentence — is dev/checks/step23-csv.mjs.
//
// Every case is a file somebody could really produce: a plan exported and read back, a sheet saved by Excel with
// semicolons or without a BOM, notes with commas, quotes and newlines, a moment repeated down the sheet because a
// frame states three groups, a group renamed since the file was written, and the times a planner types by hand
// ("+1:30") next to the number the app writes (90).
import {
  SHEET_COLUMNS,
  readSheet,
  sheetFileName,
  sheetGaps,
  sheetText,
} from '../src/utils/planSheet.js'
import { gapDetail } from '../src/utils/planFrames.js'

let passed = 0
const failures = []
function check(name, ok, detail) {
  if (ok) passed += 1
  else failures.push(name + (detail ? '\n    ' + detail : ''))
}
const show = (value) => JSON.stringify(value).slice(0, 600)

// ---------- the plan this test exports ----------
const GROUPS = [
  { id: 'g1', name: 'Gate Crew' },
  { id: 'g2', name: 'Sound' },
]
const PLAN = { name: 'Rehearsal, day 2' }
const FRAMES = [
  {
    t_s: 0,
    note: 'Call, "everyone" at the gate',
    positions: {
      g1: { lat: 1.2966123456789012, lng: 103.773102, state: 'on_site', verify: 'auto' },
      g2: { lat: 1.296621, lng: 103.773211, state: 'on_site', verify: 'auto' },
    },
  },
  { t_s: 60, note: '', positions: { g1: { lat: 1.296702, lng: 103.773244, state: 'on_site', verify: 'manual' } } },
  { t_s: 120, note: 'Out for the change', positions: { g1: { lat: 1.296702, lng: 103.773244, state: 'off_site', verify: 'manual' } } },
  { t_s: 180, note: 'Back, nowhere stated', positions: {} },
]

// ---------- 1. the file itself ----------
const text = sheetText(PLAN, FRAMES, GROUPS)
const lines = text.split('\r\n')
check('S1 starts with a BOM', text.charCodeAt(0) === 0xfeff, show(text.slice(0, 20)))
check('S1 CRLF line endings', text.includes('\r\n') && !/[^\r]\n/.test(text), show(text.slice(0, 80)))
check(
  'S1 the title names the plan and what the numbers are, quoted because the name has a comma',
  lines[0] === '\uFEFF"# Rehearsal, day 2 — plan sheet, times are seconds from T+0"',
  show(lines[0]),
)
check('S1 the columns', lines[1] === SHEET_COLUMNS.join(','), show(lines[1]))
check(
  'S1 a note with a comma and quotes is quoted, and its quotes doubled',
  lines[2] === '0,"Call, ""everyone"" at the gate",Gate Crew,1.2966123456789012,103.773102,on_site,auto',
  show(lines[2]),
)
check(
  'S1 the second group of the same moment repeats the time and the note',
  lines[3] === '0,"Call, ""everyone"" at the gate",Sound,1.296621,103.773211,on_site,auto',
  show(lines[3]),
)
check('S1 groups are ordered by name, so a re-export is the same file', lines[2].includes('Gate Crew') && lines[3].includes('Sound'))
check(
  'S1 a frame nobody stands at is one row with the group cells empty',
  lines[6] === '180,"Back, nowhere stated",,,,,',
  show(lines[6]),
)
check('S1 every row states both flags', lines[2].endsWith(',on_site,auto') && lines[4].endsWith(',on_site,manual'))
check('S1 the off-site moment keeps its place and says so', lines[5] === '120,Out for the change,Gate Crew,1.296702,103.773244,off_site,manual', show(lines[5]))

// ---------- 2. the round trip ----------
const back = readSheet(text, GROUPS)
check('R2 the file reads with no errors', back.errors.length === 0, show(back.errors))
check('R2 every moment comes back', back.frames.length === 4, show(back.frames.map((f) => f.t_s)))
check('R2 the times, in order', back.frames.map((f) => f.t_s).join() === '0,60,120,180', show(back.frames.map((f) => f.t_s)))
check('R2 the note survives its comma, its quotes and its spaces', back.frames[0].note === FRAMES[0].note, show(back.frames[0].note))
check('R2 the empty note is empty', back.frames[1].note === '', show(back.frames[1].note))
check(
  'R2 the coordinate is the same double, not a rounded one',
  back.frames[0].positions.g1.lat === FRAMES[0].positions.g1.lat,
  `${back.frames[0].positions.g1.lat} vs ${FRAMES[0].positions.g1.lat}`,
)
check('R2 the flags come back', back.frames[2].positions.g1.state === 'off_site' && back.frames[2].positions.g1.verify === 'manual', show(back.frames[2]))
check('R2 the empty moment comes back empty', Object.keys(back.frames[3].positions).length === 0, show(back.frames[3]))
check('R2 the groups are the event ids, not the names in the file', back.frames[0].positions.g2 && back.frames[0].positions.g2.lat === 1.296621, show(Object.keys(back.frames[0].positions)))
check(
  'R2 the sheet is stable: exporting what was read gives the same file',
  sheetText(PLAN, back.frames, GROUPS) === text,
  show(sheetText(PLAN, back.frames, GROUPS).slice(0, 300)),
)

// ---------- 3. files a spreadsheet really makes ----------
const semicolon = 't_s;note;group;lat;lng;state;verify\r\n0;Call;Gate Crew;1.296600;103.773100;on_site;auto\r\n'
const semi = readSheet(semicolon, GROUPS)
check('S3 a semicolon-separated file (Excel in a comma-decimal locale) reads', semi.errors.length === 0 && semi.frames.length === 1, show(semi))
check('S3 and its numbers are numbers', semi.frames[0] && semi.frames[0].positions.g1.lat === 1.2966)

const plain = 't_s,group,lat,lng\n0,Gate Crew,1.2966,103.7731\n60,Gate Crew,1.2967,103.7732\n'
const bare = readSheet(plain, GROUPS)
check('S3 no BOM, LF line endings, no optional columns', bare.errors.length === 0 && bare.frames.length === 2, show(bare.errors))
check('S3 absent flags default to on site and auto', bare.frames[0].positions.g1.state === 'on_site' && bare.frames[0].positions.g1.verify === 'auto')

const crlf = 't_s,note,group,lat,lng\r\n0,"two\r\nlines",Gate Crew,1.2966,103.7731\r\n'
const multi = readSheet(crlf, GROUPS)
check('S3 a quoted newline stays inside the note', multi.errors.length === 0 && multi.frames[0].note === 'two\r\nlines', show(multi))

const spaced = '  t_s , Note , group , lat , lng \n 0 , hello , Gate Crew , 1.2966 , 103.7731 \n'
const tidy = readSheet(spaced, GROUPS)
check('S3 headers and cells are trimmed', tidy.errors.length === 0 && tidy.frames[0].note === 'hello', show(tidy))

const titled = '# anything\n# else\n\nt_s,group,lat,lng\n0,Gate Crew,1.2966,103.7731\n'
const withTitle = readSheet(titled, GROUPS)
check('S3 comment lines before the header are skipped', withTitle.errors.length === 0 && withTitle.frames.length === 1, show(withTitle.errors))

const twice = 't_s,note,group,lat,lng\n0,Call,Gate Crew,1.2966,103.7731\n0,Call,Sound,1.2967,103.7732\n'
const repeat = readSheet(twice, GROUPS)
check('S3 the same moment on two rows is one moment, if the note agrees', repeat.errors.length === 0 && repeat.frames.length === 1, show(repeat.errors))
check('S3 both groups land on it', Object.keys((repeat.frames[0] || { positions: {} }).positions).length === 2)

// ---------- 4. times ----------
const timeForms = [
  ['+1:30', 90],
  ['90s', 90],
  ['2m', 120],
  ['90', 90],
  ['1:30', 90],
  [' 90 ', 90],
]
for (const [form, expected] of timeForms) {
  const r = readSheet(`t_s,note,group,lat,lng\n${form},,Gate Crew,1.2966,103.7731\n`, GROUPS)
  check(
    `T4 "${form.trim()}" is ${expected} s`,
    r.errors.length === 0 && r.frames.length === 1 && r.frames[0].t_s === expected,
    show({ t: r.frames[0] && r.frames[0].t_s, errors: r.errors }),
  )
}

for (const [bad, why] of [
  ['90.5', 'half a second'],
  ['abc', 'not a time'],
  ['', 'empty'],
]) {
  const r = readSheet(`t_s,note,group,lat,lng\n${bad},,Gate Crew,1.2966,103.7731\n`, GROUPS)
  check(`T4 ${why} is refused with the row number`, r.errors.length === 1 && r.errors[0].line === 2 && /is not a time|needs a time/.test(r.errors[0].message), show(r.errors))
}

const late = readSheet('t_s,group,lat,lng\n999999,,,\n', GROUPS)
check('T4 a time past three days is refused', late.errors.some((e) => /three days/.test(e.message)), show(late.errors))

// ---------- 5. refusals a person has to be able to act on ----------
const noTime = readSheet('note,group,lat,lng\n0,Gate Crew,1.2966,103.7731\n', GROUPS)
check(
  'R5 a sheet without a t_s column says so and names the columns it has',
  noTime.errors.length === 1 && noTime.errors[0].message.includes('no t_s column') && noTime.errors[0].message.includes('note, group, lat, lng'),
  show(noTime.errors),
)

const unknown = readSheet('t_s,group,lat,lng\n0,Gate Cew,1.2966,103.7731\n', GROUPS)
check('R5 an unknown group is refused by the name in the file', unknown.errors.length === 1 && unknown.errors[0].message.includes('"Gate Cew"'), show(unknown.errors))

const dupe = readSheet('t_s,group,lat,lng\n0,Gate Crew,1.2966,103.7731\n0,Gate Crew,1.2967,103.7732\n', GROUPS)
check('R5 a group placed twice at one moment is refused', dupe.errors.length === 1 && dupe.errors[0].line === 3 && /twice/.test(dupe.errors[0].message), show(dupe.errors))

const twoNotes = readSheet('t_s,note,group,lat,lng\n0,Call,Gate Crew,1.2966,103.7731\n0,Call 2,Sound,1.2967,103.7732\n', GROUPS)
check('R5 one moment with two notes is refused', twoNotes.errors.length === 1 && /disagree/.test(twoNotes.errors[0].message), show(twoNotes.errors))

const noPlace = readSheet('t_s,group,lat,lng\n0,Gate Crew,,\n', GROUPS)
check('R5 a position without coordinates is refused', noPlace.errors.length === 1 && /latitude and a longitude/.test(noPlace.errors[0].message), show(noPlace.errors))

const offMap = readSheet('t_s,group,lat,lng\n0,Gate Crew,95,103.7731\n', GROUPS)
check('R5 a latitude off the map is refused', offMap.errors.length === 1 && /not on the map/.test(offMap.errors[0].message), show(offMap.errors))

const badState = readSheet('t_s,group,lat,lng,state\n0,Gate Crew,1.2966,103.7731,onsite\n', GROUPS)
check('R5 a state that is not one of the two words is refused with the words', badState.errors.length === 1 && badState.errors[0].message.includes('on_site or off_site'), show(badState.errors))

const dashy = readSheet('t_s,group,lat,lng,state,verify\n0,Gate Crew,1.2966,103.7731,Off-Site,Manual\n', GROUPS)
check(
  'R5 but "Off-Site" and "Manual" are the words',
  dashy.errors.length === 0 && dashy.frames[0].positions.g1.state === 'off_site' && dashy.frames[0].positions.g1.verify === 'manual',
  show(dashy.errors),
)

const headerOnly = readSheet('t_s,note,group,lat,lng\n', GROUPS)
check('R5 a header with no rows is not an error, just nothing to import', headerOnly.errors.length === 0 && headerOnly.frames.length === 0)

const empty = readSheet('', GROUPS)
check('R5 an empty file says it has no rows', empty.errors.length === 1 && /no rows/.test(empty.errors[0].message), show(empty.errors))

// ---------- 6. the 25 m rule, in the board's words ----------
const gapSheet = readSheet(
  't_s,note,group,lat,lng\n0,,Sound,1.296600,103.773100\n60,,Sound,1.296600,103.774000\n',
  GROUPS,
)
const gaps = sheetGaps(gapSheet.frames)
check('G6 a 100 m step in a sheet is found', gaps.length === 1 && Math.round(gaps[0].metres) === 100, show(gaps.map((g) => g.metres)))
check('G6 it is Sound, the group in the file', gaps[0] && gaps[0].groupId === 'g2', show(gaps[0] && gaps[0].groupId))
check(
  'G6 and it says what the board says: group name plus gapDetail',
  gaps.length === 1 && `Sound: ${gapDetail(gaps[0])}` === 'Sound: 100 m between +0:00 and +1:00 (limit 25 m)',
  gaps.length === 1 ? `Sound: ${gapDetail(gaps[0])}` : 'no gap',
)

const carried = readSheet(
  't_s,note,group,lat,lng\n0,,Sound,1.296600,103.773100\n30,,,,,\n60,,,,,\n90,,Sound,1.296600,103.773729\n',
  GROUPS,
)
check('G6 70 m over three frames is legal, because three frames allow 75 m', sheetGaps(carried.frames).length === 0, show(sheetGaps(carried.frames)))

const tooFar = readSheet(
  't_s,note,group,lat,lng\n0,,Sound,1.296600,103.773100\n30,,,,,\n60,,,,,\n90,,Sound,1.296600,103.7739985\n',
  GROUPS,
)
const far = sheetGaps(tooFar.frames)
check('G6 100 m over the same three frames breaks', far.length === 1 && Math.round(far[0].metres) === 100, show(far.map((g) => g.metres)))
check('G6 and the budget is the frame steps it had (3 x 25 m)', far.length === 1 && far[0].steps === 3 && Math.round(far[0].budget) === 75, show(far))
check(
  'G6 the sentence says the budget and the steps, as the strip does',
  far.length === 1 && gapDetail(far[0]) === '100 m between +0:00 and +1:30 (limit 75 m, 3 steps)',
  far.length === 1 ? gapDetail(far[0]) : 'no gap',
)

// ---------- 7. the name of the file ----------
check('F7 a file name a phone accepts', sheetFileName({ name: 'Rehearsal, day 2 / v3' }) === 'Rehearsal, day 2 - v3.csv', sheetFileName({ name: 'Rehearsal, day 2 / v3' }))
check('F7 an unnamed plan still has a name', sheetFileName(null) === 'Plan.csv', sheetFileName(null))

// ---------- verdict ----------
console.log(`${passed} passed, ${failures.length} failed`)
for (const failure of failures) console.log('\nFAIL ' + failure)
process.exit(failures.length ? 1 : 0)
