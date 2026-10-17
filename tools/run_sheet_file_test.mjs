// tools/run_sheet_file_test.mjs - the run sheet workbook (src/utils/runSheetFile.js), tried hard.
// Run: node tools/run_sheet_file_test.mjs   (no database: the file side only; the database side is
// supabase/tests/run_sheet_import_test.sql)
//
// Every case starts from the real template, changes one thing the way a planner (or Excel) might, and
// checks what the import says. "Break it": wrong times, Excel turning text into times, missing tabs and
// columns, duplicates, unknown references, No-Go destinations, columns moved, rich text / formulas /
// dates in cells, a file that is not Excel at all, and too many rows.
import ExcelJS from 'exceljs'
import { buildWorkbook, readWorkbook, importPayload, TEMPLATE_EXAMPLE, TABS } from '../src/utils/runSheetFile.js'

let passed = 0
const failures = []
function check(name, ok, detail) {
  if (ok) passed++
  else failures.push(name + (detail ? '\n    ' + detail : ''))
}

const APP = {
  eventName: 'NDP Rehearsal 1',
  groups: [
    { id: 'g1', name: 'TKSS Band', code: null, category: null },
    { id: 'g2', name: 'Old Band', code: 'OLD_BAND', category: 'Bands' },
  ],
  zones: [
    { code: 'FORMATION_1', name: 'Formation 1', kind: 'zone' },
    { code: 'PYRO_ZONE', name: 'Pyro', kind: 'no_go' },
    { code: 'SALUTE_DAIS', name: 'Dais', kind: 'stage' },
  ],
}

async function bufferOf(wb) {
  return wb.xlsx.writeBuffer()
}
// Build the template, let fn change it, read it back
async function run(fn, ctx = APP) {
  const wb = buildWorkbook(ExcelJS, TEMPLATE_EXAMPLE)
  if (fn) await fn(wb)
  return readWorkbook(ExcelJS, await bufferOf(wb), ctx)
}
const tab = (wb, name) => wb.getWorksheet(name)
// a cell by tab, Excel row and column header
function cell(wb, name, row, header) {
  const ws = tab(wb, name)
  const ci = TABS[name].findIndex((c) => c.header === header) + 1
  if (!ci) throw new Error('no column ' + header)
  return ws.getRow(row).getCell(ci)
}
const has = (list, tabName, row, text) =>
  list.some((x) => x.tab === tabName && (row === undefined || x.row === row) && x.msg.toLowerCase().includes(text.toLowerCase()))
const show = (r) => JSON.stringify({ errors: r.errors, warnings: r.warnings.slice(0, 6) }, null, 0).slice(0, 900)

// ---------- 1. The template as downloaded ----------
{
  const r = await run(null)
  check('T1 template imports with no errors', r.errors.length === 0, show(r))
  check('T1 counts', r.counts.cues === 8 && r.counts.movements === 4 && r.counts.exceptions === 1, JSON.stringify(r.counts))
  check('T1 TKSS matched by name, 4 new groups', r.counts.groupsNew === 4 && r.counts.groupsUpdated === 1, JSON.stringify(r.counts))
  check('T1 2 circle zones to draw, 1 polygon missing (SECTOR_S3)', r.counts.zonesNew === 2 && r.counts.zonesMissing === 1, JSON.stringify(r.counts))
  check('T1 zones already in the app: one line', r.infos.filter((x) => x.tab === 'Zones').length === 1 && has(r.infos, 'Zones', null, '3 zones are already in the app'), JSON.stringify(r.infos))
  check('T1 SECTOR_S3 not drawn warning', has(r.warnings, 'Zones', undefined, 'SECTOR_S3 is not drawn yet'))
  const y = r.movements.find((m) => m.group_code === 'YHSS_BAND')
  check('T1 YHSS row becomes an exception of M011', y && y.parent_code === 'M011' && y.min_ics === 2, JSON.stringify(y))
  const m20 = r.movements.find((m) => m.code === 'M020')
  check('T1 fixed time', m20 && m20.deadline_kind === 'fixed' && m20.fixed_s === 18 * 3600 + 5 * 60 && m20.zone_code === null, JSON.stringify(m20))
  const c18 = r.cues.find((c) => c.code === 'C018')
  check('T1 flexible cue', c18 && c18.type === 'flexible' && c18.can_shorten_s === 60 && c18.length_s === 150, JSON.stringify(c18))
  check('T1 anchor length 00:00 allowed', r.cues.find((c) => c.code === 'C010').length_s === 0)
  check('T1 meta', r.meta.versionName === 'Rehearsal 1' && r.meta.forDate === '2026-08-01', JSON.stringify(r.meta))
  check('T1 IC usernames not imported note', !has(r.infos, 'Groups', null, 'IC usernames')) // the example has none filled in by export
  check('T1 checkpoints noted', has(r.infos, 'Checkpoints', null, 'not imported yet'))
  const p = importPayload(r, 'Rehearsal 1', '2026-08-01')
  check('T1 payload', p.cues.length === 8 && p.movements.length === 5 && p.cues[1].start_time === '17:35:30' && p.zones.length === 5,
    JSON.stringify({ c: p.cues.length, m: p.movements.length, z: p.zones.map((z) => z.code) }))
  const m11 = p.movements.find((m) => m.code === 'M011')
  check('T1 M011 leave_by and arrival kept', m11.leave_by === 'C034 END' && m11.arrival_point === 'D4' && m11.category === 'Bands', JSON.stringify(m11))
}

// ---------- 2. Times and lengths ----------
{
  let r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = '48:00:00'))
  check('T2a 48:00:00 refused', has(r.errors, 'Cues', 4, 'must be a time'), show(r))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = '25:00:00'))
  check('T2a2 25:00:00 = next day 01:00:00', r.errors.length === 0 && r.cues[0].day_offset === 1 && r.cues[0].start_s === 3600, show(r))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = '18:4'))
  check('T2b 18:4 refused', has(r.errors, 'Cues', 4, 'must be a time'), show(r))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = '6pm'))
  check('T2c 6pm refused', has(r.errors, 'Cues', 4, 'must be a time'))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = '24:05:00'))
  check('T2d 24:05:00 = next day 00:05:00', r.errors.length === 0 && r.cues[0].day_offset === 1 && r.cues[0].start_s === 300, show(r))
  r = await run((wb) => {
    cell(wb, 'Cues', 4, 'Start time').value = '00:05:00'
    cell(wb, 'Cues', 4, 'Next day').value = 'yes'
  })
  check('T2e Next day = yes', r.cues[0].day_offset === 1 && r.cues[0].start_s === 300)
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Next day').value = 'maybe'))
  check('T2f Next day = maybe refused', has(r.errors, 'Cues', 4, 'next day must be yes'))
  // Excel stored the time as a number (General cell): 0.75 = 18:00:00
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = 0.75))
  check('T2g start time as an Excel number', r.errors.length === 0 && r.cues[0].start_s === 18 * 3600, show(r))
  // ...or as a date-formatted cell (ExcelJS gives a Date on 30 Dec 1899)
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = new Date(Date.UTC(1899, 11, 30, 18, 4, 12))))
  check('T2h start time as an Excel time cell', r.errors.length === 0 && r.cues[0].start_s === 18 * 3600 + 4 * 60 + 12, show(r))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start time').value = new Date(Date.UTC(2026, 7, 9, 18, 0, 0))))
  check('T2i a real date in Start time refused', has(r.errors, 'Cues', 4, 'is a date'), show(r))
  // Excel turned "01:26" into 1:26 AM: refused, not read as 86 minutes
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = 86 / 1440))
  check('T2j length changed into a time by Excel is refused', has(r.errors, 'Cues', 5, 'changed by Excel'), show(r))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = '1:26'))
  check('T2k 1:26 = 86 s', r.cues[1].length_s === 86 && r.errors.length === 0)
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = '01:05:00'))
  check('T2l 01:05:00 = 3900 s', r.cues[1].length_s === 3900)
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = '2:75'))
  check('T2m 2:75 refused', has(r.errors, 'Cues', 5, 'must be MM:SS'))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = '90'))
  check('T2n plain 90 refused (seconds or minutes?)', has(r.errors, 'Cues', 5, 'must be MM:SS'))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = '25:00:00'))
  check('T2o length over 24 h refused', has(r.errors, 'Cues', 5, 'more than 24 hours'), show(r))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Length').value = ''))
  check('T2p empty length refused', has(r.errors, 'Cues', 5, 'length is empty'))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Can shorten by').value = '05:00'))
  check('T2q shorten more than the cue refused', has(r.errors, 'Cues', 5, 'longer than the cue'), show(r))
  r = await run((wb) => (cell(wb, 'Cues', 6, 'Can shorten by').value = '00:30'))
  check('T2r shorten on a Normal cue ignored with a warning', has(r.warnings, 'Cues', 6, 'only for flexible') && r.cues[2].can_shorten_s === 0)
}

// ---------- 3. Values from the dropdowns, typed by hand ----------
{
  let r = await run((wb) => {
    cell(wb, 'Cues', 4, 'Type').value = '  anchor '
    cell(wb, 'Cues', 7, 'Start mode').value = 'auto WHEN ready'
    cell(wb, 'Movements', 4, 'Must be inside by').value = 'cue START'
    cell(wb, 'Movements', 4, 'Travel mode').value = 'on foot'
  })
  check('T3a case and spaces do not matter', r.errors.length === 0 && r.cues[3].start_mode === 'auto_ready', show(r))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Type').value = 'Fixed'))
  check('T3b unknown type refused', has(r.errors, 'Cues', 4, 'type must be'))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Start mode').value = 'GO'))
  check('T3c unknown start mode refused', has(r.errors, 'Cues', 5, 'start mode must be'))
  r = await run((wb) => (cell(wb, 'Cues', 4, 'Start mode').value = 'Manual'))
  check('T3d anchor + Manual -> Auto with a warning', has(r.warnings, 'Cues', 4, 'anchor always') && r.cues[0].start_mode === 'auto')
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Travel mode').value = 'Bus'))
  check('T3e unknown travel mode refused', has(r.errors, 'Movements', 4, 'travel mode must be'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Travel mode').value = ''))
  check('T3f empty travel mode = On foot, warned', has(r.warnings, 'Movements', 4, 'on foot') && r.errors.length === 0)
  r = await run((wb) => (cell(wb, 'Zones', 4, 'Zone kind').value = 'Car park'))
  check('T3g unknown zone kind refused', has(r.errors, 'Zones', 4, 'zone kind must be'))
}

// ---------- 4. Codes and references ----------
{
  let r = await run((wb) => (cell(wb, 'Cues', 5, 'Cue ID').value = 'C010'))
  check('T4a duplicate Cue ID', has(r.errors, 'Cues', 5, 'used twice'))
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Cue ID').value = 'c 18'))
  check('T4b "c 18" becomes C_18', r.cues[1].code === 'C_18')
  r = await run((wb) => (cell(wb, 'Cues', 5, 'Cue ID').value = 'C/18'))
  check('T4c bad Cue ID characters', has(r.errors, 'Cues', 5, 'may only have'))
  r = await run((wb) => (cell(wb, 'Movements', 5, 'Cue ID').value = 'C099'))
  check('T4d unknown cue', has(r.errors, 'Movements', 5, 'no cue has the id c099'), show(r))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Group code').value = 'NOBODY'))
  check('T4e unknown group', has(r.errors, 'Movements', 4, 'no group has the code nobody'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Group code').value = 'old_band'))
  check('T4f group code of a group already in the app (lowercase)', r.errors.length === 0, show(r))
  r = await run((wb) => (cell(wb, 'Movements', 5, 'Group code').value = 'CAT : bands'))
  check('T4g "CAT : bands" = the Bands category, app spelling', r.movements.find((m) => m.row === 5).category === 'Bands', show(r))
  r = await run((wb) => (cell(wb, 'Movements', 5, 'Group code').value = 'CAT:Pipers'))
  check('T4h empty category is a warning (the check shows it)', has(r.warnings, 'Movements', 5, 'no group has the category "pipers"') && r.errors.length === 0)
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Zone code').value = 'PYRO_ZONE'))
  check('T4i No-go destination refused', has(r.errors, 'Movements', 4, 'no-go'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Zone code').value = 'MOON'))
  check('T4j unknown zone = warning, no zone', has(r.warnings, 'Movements', 4, 'not in the zones tab') && r.movements[0].zone_code === undefined)
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Zone code').value = 'D4'))
  check('T4k entrance destination warned', has(r.warnings, 'Movements', 4, 'entrance'))
  r = await run((wb) => (cell(wb, 'Movements', 7, 'Move ID').value = 'M010'))
  check('T4l duplicate Move ID', has(r.errors, 'Movements', 7, 'used twice'), show(r))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Zone code').value = 'SKIP'))
  check('T4m SKIP on a row that changes nothing refused', has(r.errors, 'Movements', 4, 'skip only works'))
  r = await run((wb) => (cell(wb, 'Movements', 6, 'Zone code').value = 'skip'))
  check('T4n SKIP on the YHSS change row = skip', r.errors.length === 0 && r.movements.find((m) => m.row === 6).skip === true, show(r))
  // a second YHSS row changing the same category row
  r = await run(async (wb) => {
    const ws = tab(wb, 'Movements')
    ws.getRow(9).values = ws.getRow(6).values
  })
  check('T4o two change rows for one group refused', has(r.errors, 'Movements', 9, 'already changes m011'), show(r))
  // YHSS row with another cue = its own movement, not a change
  r = await run((wb) => (cell(wb, 'Movements', 6, 'Cue ID').value = 'C038'))
  const own = r.movements.find((m) => m.row === 6)
  check('T4p same group, other deadline = own movement', !own.parent_code && own.code === 'M011-1' && r.errors.length === 0, show(r))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Arrival point').value = 'GATE_99'))
  check('T4q unknown arrival point warned', has(r.warnings, 'Movements', 4, 'arrival point gate_99'))
  r = await run((wb) => (cell(wb, 'Movements', 5, 'Must leave by').value = 'C034 later'))
  check('T4r bad Must leave by', has(r.errors, 'Movements', 5, 'must leave by'))
  r = await run((wb) => (cell(wb, 'Movements', 5, 'Must leave by').value = '18:20:00'))
  check('T4s Must leave by time', r.movements.find((m) => m.row === 5).leave_by === '18:20:00')
  r = await run((wb) => (cell(wb, 'Movements', 8, 'Route').value = ''))
  check('T4t Fixed route without a route warned', has(r.warnings, 'Movements', 8, 'needs a route'))
}

// ---------- 5. Numbers and defaults ----------
{
  let r = await run((wb) => (cell(wb, 'Movements', 4, 'Min ICs inside').value = 'most'))
  check('T5a "most" refused', has(r.errors, 'Movements', 4, 'min ics inside'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Min ICs inside').value = '0'))
  check('T5b 0 ICs refused', has(r.errors, 'Movements', 4, 'from 1 to 50'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Min ICs inside').value = 3))
  check('T5c a real number cell', r.movements[0].min_ics === 3 && r.errors.length === 0)
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Planned pace (m/s)').value = 'fast'))
  check('T5d pace fast refused', has(r.errors, 'Movements', 4, 'planned pace'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Stay inside for (s)').value = '601'))
  check('T5e stay inside 601 refused', has(r.errors, 'Movements', 4, 'stay inside'))
  r = await run((wb) => (cell(wb, 'Movements', 4, 'Arrive early by').value = '02:00:01'))
  check('T5f early > 2 h refused', has(r.errors, 'Movements', 4, 'at most 02:00:00'))
  // empty values take the Event defaults
  r = await run((wb) => {
    const ev = tab(wb, 'Event')
    ev.getRow(7).getCell(2).value = '01:15' // Default arrive early by (row 4 + 3)
    ev.getRow(8).getCell(2).value = '45'
    ev.getRow(10).getCell(2).value = '2'
    cell(wb, 'Movements', 4, 'Arrive early by').value = ''
    cell(wb, 'Movements', 4, 'Stay inside for (s)').value = ''
    cell(wb, 'Movements', 4, 'Min ICs inside').value = ''
  })
  const m = r.movements[0]
  check('T5g Event defaults fill empty cells', m.early_s === 75 && m.dwell_s === 45 && m.min_ics === 2, JSON.stringify(m) + show(r))
  r = await run((wb) => (tab(wb, 'Event').getRow(8).getCell(2).value = 'twenty'))
  check('T5h bad default refused', has(r.errors, 'Event', 8, 'default stay inside'))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Headcount').value = '-3'))
  check('T5i headcount -3 refused', has(r.errors, 'Groups', 4, 'headcount'))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Colour').value = 'blue'))
  check('T5j colour "blue" ignored with a warning', has(r.warnings, 'Groups', 4, 'not #rrggbb') && r.errors.length === 0)
}

// ---------- 6. Event tab ----------
{
  let r = await run((wb) => (tab(wb, 'Event').getRow(5).getCell(2).value = '09/08/2026'))
  check('T6a date 09/08/2026 = warning, left empty', has(r.warnings, 'Event', 5, 'not yyyy-mm-dd') && r.meta.forDate === '' && r.errors.length === 0)
  r = await run((wb) => (tab(wb, 'Event').getRow(5).getCell(2).value = '2026-02-30'))
  check('T6b 30 Feb warned', has(r.warnings, 'Event', 5, 'does not exist'))
  r = await run((wb) => {
    const c = tab(wb, 'Event').getRow(5).getCell(2)
    c.value = new Date(Date.UTC(2026, 7, 9))
    c.numFmt = 'yyyy-mm-dd'
  })
  check('T6c a real Excel date cell', r.meta.forDate === '2026-08-09', JSON.stringify(r.meta))
  r = await run((wb) => (tab(wb, 'Event').getRow(5).getCell(2).value = 46243))
  check('T6c2 a date as an Excel day number', r.meta.forDate === '2026-08-09', JSON.stringify(r.meta))
  r = await run((wb) => (tab(wb, 'Event').getRow(4).getCell(2).value = 'Another event'))
  check('T6d other event name warned', has(r.warnings, 'Event', 4, 'this file is for the event "another event"'))
  r = await run((wb) => (tab(wb, 'Event').getRow(6).getCell(2).value = ''))
  check('T6e no version label warned', has(r.warnings, 'Event', null, 'no version label'))
  r = await run((wb) => wb.removeWorksheet(tab(wb, 'Event').id))
  check('T6f no Event tab = defaults, warning', has(r.warnings, 'Event', null, 'no event tab') && r.errors.length === 0, show(r))
  r = await run((wb) => (tab(wb, 'Event').getRow(11).getCell(1).value = 'Favourite colour'))
  check('T6g unknown setting warned', has(r.warnings, 'Event', 11, 'unknown setting'))
}

// ---------- 7. Tabs, columns and the file itself ----------
{
  let r = await run((wb) => wb.removeWorksheet(tab(wb, 'Cues').id))
  check('T7a no Cues tab', has(r.errors, 'File', null, 'no cues tab'))
  r = await readWorkbook(ExcelJS, new TextEncoder().encode('this is a csv, not excel').buffer, APP)
  check('T7b not an Excel file', has(r.errors, 'File', null, 'not an excel workbook'))
  r = await run((wb) => (tab(wb, 'Cues').getRow(1).getCell(3).value = 'Starting'))
  check('T7c a required column renamed', has(r.errors, 'Cues', 1, 'the column "start time" is missing'))
  // columns moved: swap Cue name and Start time columns entirely
  r = await run((wb) => {
    const ws = tab(wb, 'Cues')
    for (let row = 1; row <= ws.rowCount; row++) {
      const a = ws.getRow(row).getCell(3)
      const b = ws.getRow(row).getCell(5)
      const tmp = a.value
      a.value = b.value
      b.value = tmp
    }
  })
  check('T7d columns in another order still read', r.errors.length === 0 && r.cues[0].title === 'Broadcast start time' && r.cues[0].start_s === 17.5 * 3600, show(r))
  // header in other case, a sheet renamed with spaces
  r = await run((wb) => {
    tab(wb, 'Cues').getRow(1).getCell(1).value = '  cue id '
    tab(wb, 'Groups').name = ' groups '
  })
  check('T7e header and tab names ignore case and spaces', r.errors.length === 0, show(r))
  // the REQUIRED / help rows deleted: data from row 2
  r = await run((wb) => tab(wb, 'Cues').spliceRows(2, 2))
  check('T7f without the help rows', r.errors.length === 0 && r.cues.length === 8 && r.cues[0].row === 2, show(r))
  // empty rows in the middle and at the end are skipped; a row with only a space too
  r = await run((wb) => {
    const ws = tab(wb, 'Cues')
    ws.spliceRows(6, 0, [], [])
    ws.getRow(30).getCell(11).value = '   '
  })
  check('T7g blank rows skipped', r.cues.length === 8 && r.errors.length === 0, show(r))
  // rich text, a formula, a hyperlink and a non-breaking space
  r = await run((wb) => {
    cell(wb, 'Cues', 4, 'Cue name').value = { richText: [{ text: 'Broadcast ' }, { font: { bold: true }, text: 'start' }] }
    cell(wb, 'Cues', 5, 'Length').value = { formula: '"02:"&"30"', result: '02:30' }
    cell(wb, 'Cues', 6, 'Notes').value = { text: 'link', hyperlink: 'https://example.com' }
    cell(wb, 'Cues', 7, 'Cue ID').value = 'C034 '
  })
  check('T7h rich text, formula, link, nbsp', r.errors.length === 0 && r.cues[0].title === 'Broadcast start' && r.cues[1].length_s === 150 && r.cues[3].code === 'C034', show(r))
  // all cue rows emptied
  r = await run((wb) => {
    const ws = tab(wb, 'Cues')
    for (let row = 4; row <= ws.rowCount; row++) ws.getRow(row).values = []
  })
  check('T7i no cues', has(r.errors, 'Cues', null, 'no cues'))
  // an extra tab is ignored
  r = await run((wb) => wb.addWorksheet('My notes').getCell('A1').value = 'hello')
  check('T7j extra tab ignored', r.errors.length === 0)
  // no Groups / Zones / Movements tabs: just cues
  r = await run((wb) => ['Groups', 'Zones', 'Movements', 'Checkpoints'].forEach((n) => wb.removeWorksheet(tab(wb, n).id)))
  check('T7k only Cues and Event', r.errors.length === 0 && r.movements.length === 0 && r.cues.length === 8, show(r))
}

// ---------- 8. Groups and zones ----------
{
  let r = await run((wb) => (cell(wb, 'Groups', 5, 'Group code').value = 'TKSS_BAND'))
  check('T8a duplicate group code', has(r.errors, 'Groups', 5, 'used twice'))
  r = await run((wb) => (cell(wb, 'Groups', 5, 'Group name').value = 'tkss band'))
  check('T8b duplicate group name', has(r.errors, 'Groups', 5, 'used twice'))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Group code').value = 'TKSS-BAND'))
  check('T8c group code with - refused (app codes: A-Z 0-9 _)', has(r.errors, 'Groups', 4, 'may only have'))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Group name').value = 'x'.repeat(51)))
  check('T8d group name 51 chars', has(r.errors, 'Groups', 4, 'longer than 50'))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Group name').value = 'Old Band'))
  check('T8e a file group matching an app group by name with another code warned', has(r.warnings, 'Groups', 4, 'changes it to tkss_band'), show(r))
  r = await run((wb) => (cell(wb, 'Groups', 4, 'Category').value = ''))
  check('T8f no category warned', has(r.warnings, 'Groups', 4, 'no category'))
  r = await run((wb) => (cell(wb, 'Zones', 5, 'Centre lat').value = '51.5'))
  check('T8g circle outside Singapore refused', has(r.errors, 'Zones', 5, 'inside singapore'))
  r = await run((wb) => (cell(wb, 'Zones', 6, 'Radius (m)').value = '5'))
  check('T8h radius 5 m refused', has(r.errors, 'Zones', 6, '15 to 5000'))
  r = await run((wb) => (cell(wb, 'Zones', 5, 'Zone code').value = 'FORMATION_1'))
  check('T8i duplicate zone code', has(r.errors, 'Zones', 5, 'used twice'))
  r = await run((wb) => (cell(wb, 'Zones', 4, 'Zone kind').value = 'Stage'))
  check('T8j kind differs from the app: warned, kept', has(r.warnings, 'Zones', 4, 'the app\'s zone is kept'))
  r = await run((wb) => (cell(wb, 'Zones', 5, 'Source').value = 'Square'))
  check('T8k bad source', has(r.errors, 'Zones', 5, 'source must be'))
}

// ---------- 9. Size ----------
{
  let r = await run((wb) => {
    const ws = tab(wb, 'Cues')
    for (let i = 0; i < 495; i++) ws.getRow(12 + i).values = ['X' + i, '', '20:00:00', '00:10', 'Cue ' + i, 'Normal', '', 'Auto']
  })
  check('T9a 503 cues refused', has(r.errors, 'Cues', null, 'at most 500 cues'), r.cues.length)
  const t0 = Date.now()
  r = await run((wb) => {
    const ws = tab(wb, 'Cues')
    for (let i = 0; i < 400; i++) ws.getRow(12 + i).values = ['X' + i, 'S', '20:00:00', '00:10', 'Cue ' + i, 'Normal', '', 'Auto']
    const mv = tab(wb, 'Movements')
    for (let i = 0; i < 1500; i++) mv.getRow(9 + i).values = ['MX' + i, 'CAT:Bands', 'FORMATION_1', 'Cue start', 'X' + (i % 400), '', '00:30', '', '20', '30', '', 'On foot']
  })
  const ms = Date.now() - t0
  check('T9b 408 cues + 1505 movements read', r.errors.length === 0 && r.cues.length === 408 && r.movements.length === 1505, show(r))
  check('T9c in under 6 s (' + ms + ' ms)', ms < 6000)
}

// ---------- 10. Export -> import gives the same data ----------
{
  const r1 = await run(null)
  const p1 = importPayload(r1, 'A', '2026-08-01')
  // rebuild the workbook from the payload as the database would hold it, read again
  const data = {
    event: TEMPLATE_EXAMPLE.event,
    sheet: { name: 'A', forDate: '2026-08-01' },
    cues: p1.cues.map((c) => ({ ...c, id: c.code })),
    groups: TEMPLATE_EXAMPLE.groups,
    zones: TEMPLATE_EXAMPLE.zones,
    movements: [],
  }
  for (const m of p1.movements) {
    const base = {
      ...m,
      id: m.parent_code ? m.parent_code + '>' + m.group_code : m.code,
      parent_id: m.parent_code || null,
      group_id: m.group_code || null,
      zone_id: m.zone_code || (m.code === 'M020' ? 'SECTOR_S3' : m.code === 'M030' ? 'SALUTE_DAIS' : null),
      cue_id: m.cue_code,
    }
    data.movements.push(base)
  }
  const wb2 = buildWorkbook(ExcelJS, data)
  const r2 = await readWorkbook(ExcelJS, await wb2.xlsx.writeBuffer(), APP)
  const p2 = importPayload(r2, 'A', '2026-08-01')
  const strip = (p) => JSON.stringify({ cues: p.cues.map(({ row, ...c }) => c), moves: p.movements.map(({ row, ...m }) => m) })
  check('T10 export then import = the same cues and movements', strip(p1) === strip(p2), strip(p1).slice(0, 400) + '\n    ' + strip(p2).slice(0, 400))
}

console.log(passed + ' passed, ' + failures.length + ' failed')
for (const f of failures) console.log('FAIL ' + f)
process.exit(failures.length ? 1 : 0)
