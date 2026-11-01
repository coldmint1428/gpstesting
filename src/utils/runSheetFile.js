// runSheetFile - the run sheet workbook (merger Stage 5): the template, export and import, from ONE list of
// columns, so a downloaded template, an exported version and what the import reads always match.
//
//   buildWorkbook(ExcelJS, data)          -> ExcelJS workbook (template = TEMPLATE_EXAMPLE, export = a version)
//   readWorkbook(ExcelJS, buffer, ctx)    -> { meta, groups, zones, cues, movements, errors, warnings, infos, counts }
//   importPayload(result, name, forDate)  -> what import_run_sheet (025_run_sheet_import.sql) takes
//
// ExcelJS is passed in (the page loads it only when needed; the tests use the Node build). Nothing here talks
// to the database: ctx says what the event already has (groups, zones, version names, event name).
// Rows are reported by their Excel row number, so "Movements row 12" is row 12 in Excel.

// ---------- The columns of each tab ----------
// key, header, required, help, width
const C = (key, header, required, help, width = 14) => ({ key, header, required, help, width })

export const TABS = {
  Event: [
    C('setting', 'Setting', true, 'Name of the setting (do not change these words).', 36),
    C('value', 'Value', true, 'Your value.', 22),
    C('format', 'Unit / format', false, 'How to write the value.', 70),
  ],
  Cues: [
    C('code', 'Cue ID', true, 'Unique, e.g. C034. Movements refer to it. Letters, digits, _ and -.', 10),
    C('section', 'Section', false, 'Pre-Parade, Parade & Ceremony, Act 1 …', 18),
    C('start', 'Start time', true, 'HH:MM:SS planned start (REAL TIME column of the show matrix). After midnight: tick Next day, or write 24:05:00.', 12),
    C('length', 'Length', true, 'MM:SS or HH:MM:SS (DURATION (PER SEGMENT)).', 10),
    C('title', 'Cue name', true, 'PROGRAMME column. Up to 120 characters.', 40),
    C('type', 'Type', true, 'Normal = starts on GO. Flexible = can shrink. Anchor = fixed clock time, never moves.', 12),
    C('shorten', 'Can shorten by', false, 'Flexible only: MM:SS it may lose to absorb delays.', 14),
    C('mode', 'Start mode', true, 'Auto = starts by itself at its time. Auto when ready = starts if its groups have arrived, else holds and asks planners. Manual = waits for GO. Anchors are always Auto.', 16),
    C('area', 'Area', false, 'Where it happens: Padang, Bay, Broadcast, All.', 12),
    C('department', 'Department', false, 'Who runs it: Show Mgmt, Fireworks, Sound …', 14),
    C('notes', 'Notes', false, 'Free text. Not used by the logic. Up to 500 characters.', 40),
    C('nextDay', 'Next day', false, '"yes" if the cue starts after midnight (the day after the show starts).', 10),
  ],
  Groups: [
    C('code', 'Group code', true, 'Unique, e.g. WSSS_BAND. Movements refer to it. Capital letters, digits and _.', 16),
    C('name', 'Group name', true, 'Shown on the map and run sheet. Up to 50 characters. A group with this code (or else this name) in the app is updated; otherwise it is created.', 26),
    C('category', 'Category', true, 'Bands, Choirs, Contingents, VIP, Mobile Column … Movements can target a whole category (CAT:Bands).', 14),
    C('sector', 'Sector', false, 'Area or sector this group belongs to (S3, Bay, Padang).', 10),
    C('headcount', 'Headcount', false, 'For reference: not imported. The app counts the people in each group.', 11),
    C('ics', 'IC usernames', false, 'For reference: not imported. Set ICs in the Members tab.', 34),
    C('admin', 'Group admin username', false, 'For reference: not imported. Set admins in the Members tab.', 20),
    C('colour', 'Colour', false, '#RRGGBB for the map (new groups; changes an existing group\'s colour).', 10),
  ],
  Zones: [
    C('code', 'Zone code', true, 'Unique, e.g. FORMATION_1. Movements refer to it. Capital letters, digits and _.', 16),
    C('name', 'Zone name', true, 'Shown on the map. Up to 50 characters.', 20),
    C('kind', 'Zone kind', true, 'Zone = an area groups move to or wait in. Stage = performance area. Entrance = door / gate. No-go = alert if anyone enters. Obstacle = shown on the map only.', 12),
    C('source', 'Source', true, 'Polygon = drawn in the event\'s Zones tab with this Zone code. Circle = centre + radius below (drawn for you on import).', 12),
    C('lat', 'Centre lat', false, 'Circle only: decimal degrees (Singapore 1.1 to 1.5).', 12),
    C('lng', 'Centre lng', false, 'Circle only (Singapore 103.5 to 104.2).', 12),
    C('radius', 'Radius (m)', false, 'Circle only: metres, 15 to 5000 (GPS accuracy).', 11),
    C('capacity', 'Capacity (people)', false, 'Most people allowed inside at once. Empty = no check.', 12),
  ],
  Movements: [
    C('code', 'Move ID', true, 'Unique, e.g. M012.', 9),
    C('who', 'Group code', true, 'A Group code, or CAT:<category> for every group in that category (CAT:Bands). A row for one group with the same "Must be inside by" and cue as its category row changes that row for this group only.', 16),
    C('zone', 'Zone code', true, 'From the Zones tab or the app (kind Zone or Stage). SKIP = this group skips its category row.', 16),
    C('kind', 'Must be inside by', true, 'Cue start / Cue end (moves with delays) or Fixed time (never moves).', 16),
    C('cue', 'Cue ID', false, 'Needed for Cue start / Cue end.', 9),
    C('fixed', 'Fixed time', false, 'HH:MM:SS - only for Fixed time (24:10:00 = after midnight).', 11),
    C('early', 'Arrive early by', false, 'MM:SS before that moment. Empty = Event default.', 12),
    C('minIcs', 'Min ICs inside', false, 'How many of the group\'s ICs must be inside. Empty or "all sharing" = every IC that is sharing.', 12),
    C('dwell', 'Stay inside for (s)', false, 'Seconds inside before it counts (0 to 600). Empty = Event default.', 12),
    C('amber', 'Amber when spare below (s)', false, 'Seconds (0 to 3600). Empty = Event default.', 14),
    C('leaveBy', 'Must leave by', false, 'Optional, planned only: Cue ID + start or end (C034 end) or HH:MM:SS.', 13),
    C('mode', 'Travel mode', true, 'On foot = walking or marching. Vehicle = public roads. Fixed route = closed roads / parade (Checkpoints). Vehicle and Fixed route are planned only for now.', 13),
    C('pace', 'Planned pace (m/s)', false, 'Speed before they start moving. Empty = 1.2 (walking). Marching band ~0.8.', 12),
    C('arrival', 'Arrival point', false, 'Planned only: Zone code of the door they enter by (D4).', 12),
    C('route', 'Route', false, 'Planned only: Fixed route name in the Checkpoints tab.', 14),
    C('notes', 'Notes', false, 'Free text, up to 500 characters.', 30),
  ],
  Checkpoints: [
    C('route', 'Route', true, 'Route name used in Movements (MC_ROUTE). One route = the rows with the same name, in Order.', 12),
    C('order', 'Order', true, '1, 2, 3 … along the route.', 7),
    C('name', 'Checkpoint name', true, 'Shown on the timeline: "C2 St Andrew\'s Rd".', 26),
    C('kml', 'KML point', false, 'Name of a point in the event KML. Or fill in lat / lng.', 16),
    C('lat', 'Lat', false, 'Decimal degrees.', 11),
    C('lng', 'Lng', false, '', 11),
    C('radius', 'Pass radius (m)', false, 'Counts as passed within this distance. Empty = 30 m.', 12),
    C('time', 'Planned time', false, 'HH:MM:SS when the lead vehicle should pass - OR use the next column.', 12),
    C('offset', 'Offset from start', false, 'MM:SS after the route\'s cue starts.', 14),
    C('startCue', 'Start cue', false, 'Cue ID the offsets count from (first row of the route).', 10),
  ],
}

const EVENT_SETTINGS = [
  ['eventName', 'Event name', 'text'],
  ['date', 'Date', 'YYYY-MM-DD (the date this version is for; optional)'],
  ['versionName', 'Version label', 'text - the version\'s name in the app, e.g. Rehearsal 2 (up to 60 characters)'],
  ['early', 'Default arrive early by', 'MM:SS - used when a Movement row leaves it empty'],
  ['dwell', 'Default stay inside for (s)', 'seconds - GPS must show them inside this long to count'],
  ['amber', 'Default amber when spare below (s)', 'seconds'],
  ['minIcs', 'Default min ICs inside', '"all sharing" = every IC that has signal, or a number like 2'],
  ['notify', 'Default notify ICs to leave', 'yes / no - push "Leave now" to the group ICs (Stage 8; not used yet)'],
]

const README = [
  ['Run sheet template · Event Tracker (IS216 G11)', 'title'],
  ['One workbook = one version of one event\'s run sheet. In the app: the event\'s Run sheet tab → Import from Excel. It becomes a new Draft version; nothing is saved until every row is right.', ''],
  ['', ''],
  ['Tabs', 'head'],
  ['Event – the version\'s name and date, and the default numbers used when a Movements row leaves them empty.', ''],
  ['Cues – the show matrix: one row per cue, start time to the second.', ''],
  ['Groups – who moves. A group with the same code (or else name) in the app is updated, otherwise created. ICs are set in the Members tab.', ''],
  ['Zones – the places groups must reach. Polygon = drawn in the Zones tab with the same code. Circle = drawn for you from centre + radius.', ''],
  ['Movements – GROUP must be inside ZONE by CUE (start/end) or a fixed time. One row per category (CAT:Bands) covers every group in it; a row for one group of that category with the same deadline changes it for that group (SKIP = it skips).', ''],
  ['Checkpoints – for Fixed route movements (mobile column). Not imported yet (Stage 9).', ''],
  ['', ''],
  ['Rules that keep the import exact', 'head'],
  ['1. Times are text in 24-hour form HH:MM:SS (18:04:12). After midnight: Next day = yes, or 24:05:00. Lengths are MM:SS or HH:MM:SS (01:26, 51:40, 01:05:00).', ''],
  ['2. IDs (Cue ID, Group code, Zone code, Move ID) link the tabs – spell them the same everywhere.', ''],
  ['3. Pick values from the dropdowns (Type, Start mode, Must be inside by, Travel mode, Zone kind, Source).', ''],
  ['4. Rows 2–3 under each header say what the column means and whether it is required. Data starts at row 4; example rows can be overwritten or deleted.', ''],
  ['5. Every number is a number: seconds, metres, ICs, people.', ''],
  ['6. Keep the time columns formatted as Text. If Excel turns 01:26 into a time of day, the import refuses it rather than guess.', ''],
  ['', ''],
  ['How the app uses each number', 'head'],
  ['Deadline = cue start or end (as delayed) − "Arrive early by"; a Fixed time never moves.', ''],
  ['Arrived = the group\'s sharing ICs (or "Min ICs inside") have been inside for "Stay inside for (s)" before the deadline. Amber when the spare time is below "Amber when spare below (s)".', ''],
  ['Anchor cues never move. Flexible cues can shrink by up to "Can shorten by". Start mode: Auto by the clock, Auto when ready, or Manual (GO).', ''],
]

const OPTIONS = {
  type: { normal: 'Normal', flexible: 'Flexible', anchor: 'Anchor' },
  mode: { auto: 'Auto', auto_ready: 'Auto when ready', manual: 'Manual' },
  deadline: { cue_start: 'Cue start', cue_end: 'Cue end', fixed: 'Fixed time' },
  travel: { on_foot: 'On foot', vehicle: 'Vehicle', fixed_route: 'Fixed route' },
  zoneKind: { zone: 'Zone', stage: 'Stage', entrance: 'Entrance', no_go: 'No-go', obstacle: 'Obstacle' },
  source: { polygon: 'Polygon', circle: 'Circle' },
}
const DROPDOWNS = {
  Cues: { type: Object.values(OPTIONS.type), mode: Object.values(OPTIONS.mode), nextDay: ['yes'] },
  Zones: { kind: Object.values(OPTIONS.zoneKind), source: Object.values(OPTIONS.source) },
  Movements: { kind: Object.values(OPTIONS.deadline), mode: Object.values(OPTIONS.travel) },
}

export const LIMITS = { cues: 500, movements: 2000 }
const DATA_ROW = 4 // rows 1-3: header, REQUIRED / optional, help

// ---------- Small helpers ----------
const z2 = (n) => String(n).padStart(2, '0')
export function clockText(s) {
  // seconds from the show day's midnight -> "18:04:12" (24:05:00 and on = next day)
  return z2(Math.floor(s / 3600)) + ':' + z2(Math.floor((s % 3600) / 60)) + ':' + z2(s % 60)
}
export function lengthText(s) {
  // seconds -> "01:26" or "01:05:00"
  const h = Math.floor(s / 3600)
  return h ? z2(h) + ':' + z2(Math.floor((s % 3600) / 60)) + ':' + z2(s % 60) : z2(Math.floor(s / 60)) + ':' + z2(s % 60)
}
const norm = (s) => String(s ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
const EXCEL_EPOCH = Date.UTC(1899, 11, 30)

// What a cell holds, as a string, a number, or a Date (ExcelJS gives formulas, rich text and links as objects)
function cellRaw(cell) {
  let v = cell ? cell.value : null
  if (v && typeof v === 'object' && !(v instanceof Date)) {
    if ('result' in v) v = v.result
    else if (Array.isArray(v.richText)) v = v.richText.map((t) => t.text).join('')
    else if ('text' in v) v = v.text
    else if ('error' in v) v = ''
    else v = String(v)
  }
  if (v === null || v === undefined) return ''
  if (typeof v === 'string') return v.replace(/ /g, ' ').trim()
  if (typeof v === 'boolean') return v ? 'yes' : ''
  return v
}
function asText(raw) {
  if (raw instanceof Date) return raw.toISOString()
  return String(raw ?? '').trim()
}
// Excel day fractions (a time Excel stored as a number or a date-formatted cell) -> seconds
function excelSeconds(raw) {
  if (raw instanceof Date) return Math.round(((raw.getTime() - EXCEL_EPOCH) / 86400000) * 86400)
  if (typeof raw === 'number') return Math.round(raw * 86400)
  return null
}

// "18:04:12" -> { s, day } ; 24:05:00 and on = next day. Excel time values are read too.
function parseClock(raw) {
  if (raw === '') return { empty: true }
  const xs = excelSeconds(raw)
  if (xs !== null) {
    if (xs < 0 || xs >= 2 * 86400) return { error: 'is a date, not a time of day like 18:04:12' }
    return { s: xs % 86400, day: xs >= 86400 ? 1 : 0 }
  }
  const m = String(raw).match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/)
  if (!m) return { error: 'must be a time like 18:04:12' }
  const [h, mi, se] = [Number(m[1]), Number(m[2]), Number(m[3] || 0)]
  if (h > 47 || mi > 59 || se > 59) return { error: 'must be a time like 18:04:12' }
  return { s: (h % 24) * 3600 + mi * 60 + se, day: h >= 24 ? 1 : 0 }
}
// "01:26" (MM:SS) or "01:05:00" (HH:MM:SS) -> seconds. A number Excel made of it is refused, not guessed.
function parseLength(raw) {
  if (raw === '') return { empty: true }
  if (raw instanceof Date || typeof raw === 'number') {
    const xs = excelSeconds(raw)
    return {
      error:
        'was changed by Excel into a time of day (' + clockText(Math.max(0, xs) % 86400) + '). Format the column as Text and type it again as MM:SS',
    }
  }
  const t = String(raw)
  let m = t.match(/^(\d{1,3}):(\d{2})$/)
  if (m && Number(m[2]) < 60) return { s: Number(m[1]) * 60 + Number(m[2]) }
  m = t.match(/^(\d{1,2}):(\d{2}):(\d{2})$/)
  if (m && Number(m[2]) < 60 && Number(m[3]) < 60) return { s: Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) }
  return { error: 'must be MM:SS or HH:MM:SS, like 01:26' }
}
function parseInt0(raw, min, max) {
  if (raw === '') return { empty: true }
  const n = typeof raw === 'number' ? raw : /^-?\d+(\.0+)?$/.test(String(raw)) ? Number(raw) : NaN
  if (!Number.isInteger(n) || n < min || n > max) return { error: 'must be a whole number from ' + min + ' to ' + max }
  return { n }
}
function parseNumber(raw, min, max) {
  if (raw === '') return { empty: true }
  const n = typeof raw === 'number' ? raw : /^-?\d+(\.\d+)?$/.test(String(raw)) ? Number(raw) : NaN
  if (!Number.isFinite(n) || n < min || n > max) return { error: 'must be a number from ' + min + ' to ' + max }
  return { n }
}
function pick(raw, options) {
  // "auto when ready" -> 'auto_ready'
  const want = norm(raw)
  return Object.keys(options).find((k) => norm(options[k]) === want || k === want.replace(/[ -]/g, '_')) || null
}
const asCode = (raw) => asText(raw).toUpperCase().replace(/\s+/g, '_')
const CUE_CODE = /^[A-Z0-9_-]{1,20}$/ // cue and movement IDs (024)
const APP_CODE = /^[A-Z0-9_]{1,40}$/ // group and zone codes (020)

// A sheet by name, ignoring case and spaces
function findSheet(wb, name) {
  return wb.worksheets.find((ws) => norm(ws.name) === norm(name)) || null
}

// Rows of one tab as { row, values: { key: raw } }, by header text (columns may be in any order).
function readTab(wb, tabName, report) {
  const ws = findSheet(wb, tabName)
  if (!ws) return null
  const spec = TABS[tabName]
  const header = ws.getRow(1)
  const colOf = {}
  for (let c = 1; c <= Math.max(header.cellCount, spec.length + 10); c++) {
    const h = norm(cellRaw(header.getCell(c)))
    const col = spec.find((s) => norm(s.header) === h)
    if (col && !colOf[col.key]) colOf[col.key] = c
  }
  for (const col of spec) {
    if (col.required && !colOf[col.key]) report.error(tabName, 1, 'the column "' + col.header + '" is missing (row 1 holds the column names)')
  }
  // Data starts after the REQUIRED / optional and help rows when they are there
  const second = norm(cellRaw(ws.getRow(2).getCell(colOf[spec[0].key] || 1)))
  const start = second === 'required' || second === 'optional' ? DATA_ROW : 2
  const rows = []
  for (let r = start; r <= ws.rowCount; r++) {
    const row = ws.getRow(r)
    const values = {}
    let any = false
    for (const col of spec) {
      const v = colOf[col.key] ? cellRaw(row.getCell(colOf[col.key])) : ''
      values[col.key] = v
      if (v !== '') any = true
    }
    if (any) rows.push({ row: r, values })
  }
  return rows
}

// ---------- Read a workbook ----------
// ctx: { eventName, groups: [{id, name, code, category}], zones: [{code, name, kind}], versionNames: [..] }
export async function readWorkbook(ExcelJS, buffer, ctx = {}) {
  const errors = []
  const warnings = []
  const infos = []
  const report = {
    error: (tab, row, msg) => errors.push({ tab, row, msg }),
    warn: (tab, row, msg) => warnings.push({ tab, row, msg }),
    info: (tab, row, msg) => infos.push({ tab, row, msg }),
  }
  const out = { meta: {}, groups: [], zones: [], cues: [], movements: [], errors, warnings, infos, counts: {} }

  const wb = new ExcelJS.Workbook()
  try {
    await wb.xlsx.load(buffer)
  } catch {
    report.error('File', null, 'This is not an Excel workbook (.xlsx). Download the template and fill that in.')
    return out
  }
  if (!findSheet(wb, 'Cues')) {
    report.error('File', null, 'This workbook has no Cues tab. Download the template and fill that in.')
    return out
  }

  // ----- Event -----
  const settings = {}
  const eventRows = readTab(wb, 'Event', report)
  if (!eventRows) report.warn('Event', null, 'No Event tab: the defaults are used (arrive early 00:30, stay inside 20 s, amber 30 s).')
  for (const { row, values } of eventRows || []) {
    const s = EVENT_SETTINGS.find(([, label]) => norm(label) === norm(values.setting))
    if (s) settings[s[0]] = { raw: values.value, row }
    else if (values.setting !== '') report.warn('Event', row, 'Unknown setting "' + asText(values.setting) + '" is ignored.')
  }
  const meta = out.meta
  meta.eventName = asText(settings.eventName ? settings.eventName.raw : '')
  if (meta.eventName && ctx.eventName && norm(meta.eventName) !== norm(ctx.eventName)) {
    report.warn('Event', settings.eventName.row, 'This file is for the event "' + meta.eventName + '"; you are importing into "' + ctx.eventName + '".')
  }
  meta.versionName = asText(settings.versionName ? settings.versionName.raw : '').slice(0, 200)
  meta.forDate = ''
  if (settings.date && settings.date.raw !== '') {
    const d = settings.date.raw
    if (d instanceof Date) meta.forDate = d.toISOString().slice(0, 10)
    // a date in a cell not formatted as a date: Excel's day number (46243 = 2026-08-09)
    else if (typeof d === 'number' && d > 30000 && d < 80000) meta.forDate = new Date(EXCEL_EPOCH + Math.round(d) * 86400000).toISOString().slice(0, 10)
    else if (/^\d{4}-\d{2}-\d{2}$/.test(asText(d)) && !Number.isNaN(Date.parse(asText(d) + 'T00:00:00Z'))) meta.forDate = asText(d)
    else report.warn('Event', settings.date.row, 'Date "' + asText(d) + '" is not YYYY-MM-DD: left empty (set it below).')
    if (meta.forDate && new Date(meta.forDate + 'T00:00:00Z').toISOString().slice(0, 10) !== meta.forDate) {
      report.warn('Event', settings.date.row, 'Date ' + meta.forDate + ' does not exist: left empty (set it below).')
      meta.forDate = ''
    }
  }
  const def = { early: 30, dwell: 20, amber: 30, minIcs: null }
  const defNum = (key, parse, label) => {
    if (!settings[key] || settings[key].raw === '') return
    const p = parse(settings[key].raw)
    if (p.error) report.error('Event', settings[key].row, label + ' ' + p.error + '.')
    else def[key] = p.s ?? p.n
  }
  defNum('early', parseLength, 'Default arrive early by')
  if (def.early > 7200) report.error('Event', settings.early.row, 'Default arrive early by is at most 02:00:00.')
  defNum('dwell', (v) => parseInt0(v, 0, 600), 'Default stay inside for (s)')
  defNum('amber', (v) => parseInt0(v, 0, 3600), 'Default amber when spare below (s)')
  if (settings.minIcs && !/^all( sharing)?$/i.test(asText(settings.minIcs.raw)) && settings.minIcs.raw !== '') {
    defNum('minIcs', (v) => parseInt0(v, 1, 50), 'Default min ICs inside')
  }
  if (settings.notify && settings.notify.raw !== '') {
    report.info('Event', settings.notify.row, '"Notify ICs to leave" is not used yet (Stage 8: Leave now).')
  }
  meta.defaults = def

  // ----- Groups -----
  const existingGroups = ctx.groups || []
  const byCode = new Map(existingGroups.filter((g) => g.code).map((g) => [g.code, g]))
  const byName = new Map(existingGroups.map((g) => [norm(g.name), g]))
  const fileGroups = new Map() // code -> group row
  const fileNames = new Set()
  let icNote = false
  for (const { row, values } of readTab(wb, 'Groups', report) || []) {
    const code = asCode(values.code)
    const name = asText(values.name)
    if (!code) report.error('Groups', row, 'Group code is empty.')
    else if (!APP_CODE.test(code)) report.error('Groups', row, 'Group code "' + code + '" may only have capital letters, digits and _ (up to 40).')
    else if (fileGroups.has(code)) report.error('Groups', row, 'Group code ' + code + ' is used twice (also row ' + fileGroups.get(code).row + ').')
    if (!name) report.error('Groups', row, 'Group name is empty.')
    else if (name.length > 50) report.error('Groups', row, 'Group name is longer than 50 characters.')
    else if (fileNames.has(norm(name))) report.error('Groups', row, 'Group name "' + name + '" is used twice.')
    fileNames.add(norm(name))
    const category = asText(values.category)
    if (category.length > 50) report.error('Groups', row, 'Category is longer than 50 characters.')
    if (!category) report.warn('Groups', row, 'No category: movements for a whole category (CAT:…) will not include ' + (name || code) + '.')
    const sector = asText(values.sector)
    if (sector.length > 50) report.error('Groups', row, 'Sector is longer than 50 characters.')
    const head = parseInt0(values.headcount, 0, 100000)
    if (head.error) report.error('Groups', row, 'Headcount ' + head.error + '.')
    let colour = asText(values.colour)
    if (colour && !/^#[0-9a-fA-F]{6}$/.test(colour)) {
      report.warn('Groups', row, 'Colour "' + colour + '" is not #RRGGBB; it is ignored.')
      colour = ''
    }
    if (values.ics !== '' || values.admin !== '') icNote = true
    const match = (code && byCode.get(code)) || (name && byName.get(norm(name))) || null
    if (match && !byCode.get(code) && match.code && match.code !== code) {
      report.warn('Groups', row, 'The app\'s group "' + match.name + '" has the code ' + match.code + '; importing changes it to ' + code + '.')
    }
    const g = { row, code, name, category, sector, headcount: head.n ?? null, colour, existing: match }
    if (code && !fileGroups.has(code)) fileGroups.set(code, g)
    out.groups.push(g)
  }
  if (icNote) report.info('Groups', null, 'IC usernames and group admins are not imported: set them in the Members tab.')
  // The groups after the import: the app's, updated by the file, plus the new ones
  const finalGroups = existingGroups.map((g) => ({ ...g }))
  for (const g of out.groups) {
    if (g.existing) {
      const f = finalGroups.find((x) => x.id === g.existing.id)
      f.code = g.code || f.code
      if (g.category) f.category = g.category
    } else finalGroups.push({ id: null, name: g.name, code: g.code, category: g.category })
  }
  const groupByCode = new Map(finalGroups.filter((g) => g.code).map((g) => [g.code, g]))
  const inCategory = (cat) => finalGroups.filter((g) => g.category && norm(g.category) === norm(cat))
  const categorySpelling = (cat) => (inCategory(cat)[0] || {}).category || cat

  // ----- Zones -----
  const appZones = new Map((ctx.zones || []).map((z) => [z.code, z]))
  const fileZones = new Map()
  const keptZones = [] // already in the app: said once, not once per zone (an NDP has dozens)
  for (const { row, values } of readTab(wb, 'Zones', report) || []) {
    const code = asCode(values.code)
    const name = asText(values.name)
    const kind = pick(values.kind, OPTIONS.zoneKind)
    const source = pick(values.source, OPTIONS.source)
    if (!code) report.error('Zones', row, 'Zone code is empty.')
    else if (!APP_CODE.test(code)) report.error('Zones', row, 'Zone code "' + code + '" may only have capital letters, digits and _ (up to 40).')
    else if (fileZones.has(code)) report.error('Zones', row, 'Zone code ' + code + ' is used twice (also row ' + fileZones.get(code).row + ').')
    if (!kind) report.error('Zones', row, 'Zone kind must be one of: ' + Object.values(OPTIONS.zoneKind).join(', ') + '.')
    if (!source) report.error('Zones', row, 'Source must be Polygon or Circle.')
    const cap = parseInt0(values.capacity, 0, 1000000)
    if (cap.error) report.error('Zones', row, 'Capacity ' + cap.error + '.')
    const z = { row, code, name, kind, source, capacity: cap.n ?? null, lat: null, lng: null, radius: null, existing: appZones.get(code) || null }
    if (z.existing) {
      if (kind && z.existing.kind !== kind) {
        report.warn('Zones', row, code + ' is a ' + OPTIONS.zoneKind[z.existing.kind] + ' in the app; the file says ' + OPTIONS.zoneKind[kind] + '. The app\'s zone is kept as it is.')
      } else keptZones.push(code)
    } else if (source === 'circle') {
      if (!name) report.error('Zones', row, 'Zone name is empty.')
      else if (name.length > 50) report.error('Zones', row, 'Zone name is longer than 50 characters.')
      const lat = parseNumber(values.lat, 1.1, 1.5)
      const lng = parseNumber(values.lng, 103.5, 104.2)
      const rad = parseNumber(values.radius, 15, 5000)
      if (lat.error || lat.empty) report.error('Zones', row, 'Centre lat must be a number inside Singapore (1.1 to 1.5).')
      if (lng.error || lng.empty) report.error('Zones', row, 'Centre lng must be a number inside Singapore (103.5 to 104.2).')
      if (rad.error || rad.empty) report.error('Zones', row, 'Radius (m) must be from 15 to 5000.')
      Object.assign(z, { lat: lat.n ?? null, lng: lng.n ?? null, radius: rad.n ?? null })
    } else if (source === 'polygon') {
      report.warn(
        'Zones',
        row,
        code + ' is not drawn yet: draw it in the Zones tab with the code ' + code + '.' +
          (kind === 'no_go' || kind === 'obstacle' ? '' : ' Movements to it are imported without a zone until then.'),
      )
    }
    if (code && !fileZones.has(code)) fileZones.set(code, z)
    out.zones.push(z)
  }
  if (keptZones.length) {
    const list = keptZones.length > 8 ? keptZones.slice(0, 8).join(', ') + ' and ' + (keptZones.length - 8) + ' more' : keptZones.join(', ')
    report.info('Zones', null, keptZones.length + (keptZones.length === 1 ? ' zone is' : ' zones are') + ' already in the app and kept as drawn (capacity from the file): ' + list + '.')
  }
  // Zones after the import (kind only matters): the app's plus new circles
  const zoneKind = (code) =>
    appZones.has(code) ? appZones.get(code).kind : fileZones.has(code) && fileZones.get(code).source === 'circle' ? fileZones.get(code).kind : null
  const zoneKnown = (code) => appZones.has(code) || fileZones.has(code)

  // ----- Cues -----
  const cueRows = readTab(wb, 'Cues', report) || []
  const cueCodes = new Map()
  for (const { row, values } of cueRows) {
    const code = asCode(values.code)
    const e = (msg) => report.error('Cues', row, msg)
    if (!code) e('Cue ID is empty.')
    else if (!CUE_CODE.test(code)) e('Cue ID "' + code + '" may only have letters, digits, _ and - (up to 20).')
    else if (cueCodes.has(code)) e('Cue ID ' + code + ' is used twice (also row ' + cueCodes.get(code).row + ').')
    const start = parseClock(values.start)
    if (start.empty) e('Start time is empty.')
    else if (start.error) e('Start time "' + asText(values.start) + '" ' + start.error + '.')
    const next = norm(values.nextDay)
    if (next && !['yes', 'y', 'true', '1', 'no', 'n', 'false', '0'].includes(next)) e('Next day must be yes or empty.')
    const length = parseLength(values.length)
    if (length.empty) e('Length is empty (write 00:00 for a moment).')
    else if (length.error) e('Length "' + asText(values.length) + '" ' + length.error + '.')
    else if (length.s > 86400) e('Length is more than 24 hours.')
    const title = asText(values.title)
    if (!title) e('Cue name is empty.')
    else if (title.length > 120) e('Cue name is longer than 120 characters.')
    const type = pick(values.type, OPTIONS.type)
    if (!type) e('Type must be Normal, Flexible or Anchor.')
    let mode = pick(values.mode, OPTIONS.mode)
    if (values.mode === '') {
      mode = 'auto'
      report.warn('Cues', row, 'Start mode is empty: Auto.')
    } else if (!mode) e('Start mode must be Auto, Auto when ready or Manual.')
    if (type === 'anchor' && mode && mode !== 'auto') {
      report.warn('Cues', row, 'An anchor always starts by the clock: Start mode becomes Auto.')
      mode = 'auto'
    }
    const shorten = parseLength(values.shorten)
    let shortenS = 0
    if (type === 'flexible') {
      if (shorten.error) e('Can shorten by "' + asText(values.shorten) + '" ' + shorten.error + '.')
      else if (!shorten.empty) {
        shortenS = shorten.s
        if (length.s !== undefined && shortenS > length.s) e('Can shorten by is longer than the cue.')
      }
    } else if (!shorten.empty) report.warn('Cues', row, 'Can shorten by is only for Flexible cues; it is ignored.')
    for (const [key, label, max] of [['section', 'Section', 60], ['area', 'Area', 60], ['department', 'Department', 60], ['notes', 'Notes', 500]]) {
      if (asText(values[key]).length > max) e(label + ' is longer than ' + max + ' characters.')
    }
    const cue = {
      row,
      code,
      section: asText(values.section),
      title,
      start_s: start.s ?? 0,
      day_offset: (start.day || 0) || (['yes', 'y', 'true', '1'].includes(next) ? 1 : 0),
      length_s: length.s ?? 0,
      type: type || 'normal',
      can_shorten_s: shortenS,
      start_mode: mode || 'auto',
      area: asText(values.area),
      department: asText(values.department),
      notes: asText(values.notes),
    }
    if (code && !cueCodes.has(code)) cueCodes.set(code, cue)
    out.cues.push(cue)
  }
  if (!out.cues.length) report.error('Cues', null, 'The Cues tab has no cues (data starts at row 4).')
  if (out.cues.length > LIMITS.cues) report.error('Cues', null, 'A run sheet can have at most ' + LIMITS.cues + ' cues; this file has ' + out.cues.length + '.')

  // ----- Movements -----
  const moveRows = readTab(wb, 'Movements', report) || []
  const moveCodes = new Map()
  const deadlineKey = (m) => m.deadline_kind + '|' + (m.deadline_kind === 'fixed' ? m.fixed_s + '+' + m.fixed_day_offset : m.cue_code)
  const parsed = []
  for (const { row, values } of moveRows) {
    const e = (msg) => report.error('Movements', row, msg)
    const w = (msg) => report.warn('Movements', row, msg)
    const code = asCode(values.code)
    const m = { row, code }
    // who
    const who = asText(values.who)
    const cat = who.match(/^cat\s*:\s*(.+)$/i)
    if (!who) e('Group code is empty (a Group code, or CAT:<category>).')
    else if (cat) {
      m.category = cat[1].trim()
      if (m.category.length > 50) e('A category is up to 50 characters.')
      else if (!inCategory(m.category).length) w('No group has the category "' + m.category + '": the check will show it in red.')
      m.category = categorySpelling(m.category)
    } else {
      m.group_code = asCode(who)
      if (!groupByCode.has(m.group_code)) e('No group has the code ' + m.group_code + ' (in the Groups tab or the app).')
    }
    // where
    const zone = asCode(values.zone)
    if (zone === 'SKIP') m.skip = true
    else if (!zone) w('No Zone code: imported without a zone; pick one in the app.')
    else if (!zoneKnown(zone)) w('Zone ' + zone + ' is not in the Zones tab or the app: imported without a zone.')
    else {
      const k = zoneKind(zone)
      if (k === 'no_go') e('Zone ' + zone + ' is a No-go zone: a movement cannot go there.')
      else if (k === 'entrance' || k === 'obstacle') w('Zone ' + zone + ' is an ' + OPTIONS.zoneKind[k] + '; movements usually go to a Zone or Stage.')
      if (k === null) w('Zone ' + zone + ' is not drawn yet: imported without a zone until it is.')
      m.zone_code = k === null ? null : zone
    }
    // by when
    const kind = pick(values.kind, OPTIONS.deadline)
    if (!kind) e('Must be inside by must be Cue start, Cue end or Fixed time.')
    m.deadline_kind = kind || 'cue_start'
    if (m.deadline_kind === 'fixed') {
      const f = parseClock(values.fixed)
      if (f.empty) e('Fixed time is empty.')
      else if (f.error) e('Fixed time "' + asText(values.fixed) + '" ' + f.error + '.')
      m.fixed_s = f.s ?? 0
      m.fixed_day_offset = f.day || 0
      if (asText(values.cue)) w('Cue ID is ignored for a Fixed time.')
    } else {
      m.cue_code = asCode(values.cue)
      if (!m.cue_code) e('Cue ID is empty (needed for ' + OPTIONS.deadline[m.deadline_kind] + ').')
      else if (!cueCodes.has(m.cue_code)) e('No cue has the ID ' + m.cue_code + ' in the Cues tab.')
      if (asText(values.fixed)) w('Fixed time is ignored for ' + OPTIONS.deadline[m.deadline_kind] + '.')
    }
    // arrived
    const early = parseLength(values.early)
    if (early.error) e('Arrive early by "' + asText(values.early) + '" ' + early.error + '.')
    m.early_s = early.empty ? def.early : early.s
    if (m.early_s > 7200) e('Arrive early by is at most 02:00:00.')
    if (values.minIcs === '' || /^all( sharing)?$/i.test(asText(values.minIcs))) m.min_ics = values.minIcs === '' ? def.minIcs : null
    else {
      const n = parseInt0(values.minIcs, 1, 50)
      if (n.error) e('Min ICs inside ' + n.error + ' (or "all sharing").')
      m.min_ics = n.n ?? null
    }
    const dwell = parseInt0(values.dwell, 0, 600)
    if (dwell.error) e('Stay inside for (s) ' + dwell.error + '.')
    m.dwell_s = dwell.empty ? def.dwell : dwell.n
    const amber = parseInt0(values.amber, 0, 3600)
    if (amber.error) e('Amber when spare below (s) ' + amber.error + '.')
    m.amber_s = amber.empty ? def.amber : amber.n
    // how
    if (values.mode === '') {
      m.travel_mode = 'on_foot'
      w('Travel mode is empty: On foot.')
    } else {
      m.travel_mode = pick(values.mode, OPTIONS.travel)
      if (!m.travel_mode) e('Travel mode must be On foot, Vehicle or Fixed route.')
    }
    const pace = parseNumber(values.pace, 0.01, 60)
    if (pace.error) e('Planned pace (m/s) ' + pace.error + '.')
    m.pace_mps = pace.empty ? 1.2 : Math.round(pace.n * 100) / 100
    // planned only
    const leave = asText(values.leaveBy).toUpperCase().replace(/\s+/g, ' ')
    if (leave) {
      const lm = leave.match(/^([A-Z0-9_-]{1,20}) (START|END)$/)
      const lt = parseClock(values.leaveBy)
      if (lm) {
        if (!cueCodes.has(lm[1])) w('Must leave by: no cue has the ID ' + lm[1] + '.')
        m.leave_by = leave
      } else if (!lt.error && !lt.day) m.leave_by = clockText(lt.s)
      else e('Must leave by must be a Cue ID and start or end (C034 end) or a time like 18:20:00.')
    }
    const arrival = asCode(values.arrival)
    if (arrival) {
      if (!APP_CODE.test(arrival)) e('Arrival point must be a zone code.')
      else if (!zoneKnown(arrival)) w('Arrival point ' + arrival + ' is not in the Zones tab or the app.')
      m.arrival_point = arrival
    }
    m.route = asText(values.route)
    if (m.route.length > 60) e('Route is longer than 60 characters.')
    if (m.travel_mode === 'fixed_route' && !m.route) w('A Fixed route movement needs a Route (Checkpoints tab).')
    m.notes = asText(values.notes)
    if (m.notes.length > 500) e('Notes are longer than 500 characters.')
    parsed.push(m)
  }

  // Category rows first: a one-group row with the same deadline as its category's row changes that row
  const catRows = parsed.filter((m) => m.category)
  for (const m of parsed) {
    if (m.category) continue
    const g = m.group_code && groupByCode.get(m.group_code)
    const parent = g && g.category && catRows.find((c) => norm(c.category) === norm(g.category) && deadlineKey(c) === deadlineKey(m))
    if (parent) {
      m.parent_code = parent.code
      const twice = parsed.find((x) => x !== m && x.parent_code === parent.code && x.group_code === m.group_code)
      if (twice) report.error('Movements', m.row, m.group_code + ' already changes ' + parent.code + ' in row ' + twice.row + '.')
    } else if (m.skip) {
      report.error('Movements', m.row, 'SKIP only works on a row for one group that changes its category row (same Must be inside by and cue).')
    }
  }
  // Move IDs: unique among the rows that are movements of their own (a changing row keeps its category row's ID)
  for (const m of parsed) {
    if (m.parent_code) continue
    if (!m.code) report.error('Movements', m.row, 'Move ID is empty.')
    else if (!CUE_CODE.test(m.code)) report.error('Movements', m.row, 'Move ID "' + m.code + '" may only have letters, digits, _ and - (up to 20).')
    else if (moveCodes.has(m.code)) report.error('Movements', m.row, 'Move ID ' + m.code + ' is used twice (also row ' + moveCodes.get(m.code) + ').')
    else moveCodes.set(m.code, m.row)
  }
  out.movements = parsed
  if (parsed.length > LIMITS.movements) report.error('Movements', null, 'A run sheet can have at most ' + LIMITS.movements + ' movements; this file has ' + parsed.length + '.')

  // ----- Checkpoints -----
  const cps = readTab(wb, 'Checkpoints', { error() {}, warn() {}, info() {} }) || []
  if (cps.length) report.info('Checkpoints', null, cps.length + ' checkpoint rows are not imported yet: fixed routes come in Stage 9.')

  // ----- Version name -----
  if (!meta.versionName) report.warn('Event', null, 'No Version label: give the new version a name below.')

  out.counts = {
    cues: out.cues.length,
    movements: parsed.filter((m) => !m.parent_code).length,
    exceptions: parsed.filter((m) => m.parent_code).length,
    groupsNew: out.groups.filter((g) => !g.existing).length,
    groupsUpdated: out.groups.filter((g) => g.existing).length,
    zonesNew: out.zones.filter((z) => !z.existing && z.source === 'circle').length,
    zonesMissing: out.zones.filter((z) => !z.existing && z.source === 'polygon').length,
  }
  return out
}

// What import_run_sheet takes (names as the database functions expect them)
export function importPayload(result, name, forDate) {
  return {
    name,
    for_date: forDate || null,
    groups: result.groups.map((g) => ({
      row: g.row, code: g.code, name: g.name, category: g.category, sector: g.sector, headcount: g.headcount, colour: g.colour,
    })),
    zones: result.zones
      .filter((z) => z.existing || z.source === 'circle')
      .map((z) => ({
        row: z.row, code: z.code, name: z.name, kind: z.kind, source: z.source, lat: z.lat, lng: z.lng, radius_m: z.radius, capacity: z.capacity,
      })),
    cues: result.cues.map((c) => ({
      row: c.row,
      code: c.code,
      section: c.section,
      title: c.title,
      start_time: clockText(c.start_s),
      day_offset: c.day_offset,
      length_s: c.length_s,
      type: c.type,
      can_shorten_s: c.can_shorten_s,
      start_mode: c.start_mode,
      area: c.area,
      department: c.department,
      notes: c.notes,
    })),
    movements: result.movements.map((m) => ({
      row: m.row,
      code: m.code,
      group_code: m.group_code || null,
      category: m.category || null,
      parent_code: m.parent_code || null,
      skip: !!m.skip,
      zone_code: m.zone_code || null,
      deadline_kind: m.deadline_kind,
      cue_code: m.deadline_kind === 'fixed' ? null : m.cue_code,
      fixed_time: m.deadline_kind === 'fixed' ? clockText(m.fixed_s) : null,
      fixed_day_offset: m.deadline_kind === 'fixed' ? m.fixed_day_offset : 0,
      early_s: m.early_s,
      min_ics: m.min_ics,
      dwell_s: m.dwell_s,
      amber_s: m.amber_s,
      travel_mode: m.travel_mode,
      pace_mps: m.pace_mps,
      leave_by: m.leave_by || null,
      arrival_point: m.arrival_point || null,
      route: m.route || null,
      notes: m.notes,
    })),
  }
}

// ---------- Write a workbook ----------
const HEAD_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF0F1B2D' } }
const REQ_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFDE68A' } }
const OPT_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE2E8F0' } }
const THIN = { style: 'thin', color: { argb: 'FFCBD5E1' } }
const BOX = { top: THIN, left: THIN, bottom: THIN, right: THIN }

function addTab(wb, name, rows) {
  const spec = TABS[name]
  const ws = wb.addWorksheet(name, { views: [{ state: 'frozen', xSplit: 1, ySplit: 3 }] })
  spec.forEach((col, i) => {
    const c = i + 1
    ws.getColumn(c).width = col.width
    ws.getColumn(c).numFmt = '@' // text: Excel never turns 01:26 into a time of day
    const h = ws.getCell(1, c)
    h.value = col.header
    h.font = { bold: true, color: { argb: 'FFFFFFFF' } }
    h.fill = HEAD_FILL
    h.alignment = { wrapText: true, vertical: 'middle' }
    h.border = BOX
    h.note = col.help
    const r = ws.getCell(2, c)
    r.value = col.required ? 'REQUIRED' : 'optional'
    r.fill = col.required ? REQ_FILL : OPT_FILL
    r.font = { bold: col.required, size: 9, color: { argb: 'FF334155' } }
    r.border = BOX
    const t = ws.getCell(3, c)
    t.value = col.help
    t.font = { italic: true, size: 9, color: { argb: 'FF475569' } }
    t.alignment = { wrapText: true, vertical: 'top' }
    t.border = BOX
  })
  ws.getRow(3).height = 60
  rows.forEach((values, i) => {
    const row = ws.getRow(DATA_ROW + i)
    spec.forEach((col, ci) => {
      const v = values[col.key]
      const cell = row.getCell(ci + 1)
      cell.value = v === null || v === undefined ? null : String(v)
      cell.numFmt = '@'
      cell.border = BOX
    })
  })
  const last = Math.max(400, DATA_ROW + rows.length + 100)
  for (const [key, list] of Object.entries(DROPDOWNS[name] || {})) {
    const ci = spec.findIndex((c) => c.key === key) + 1
    const letter = ws.getColumn(ci).letter
    ws.dataValidations.add(letter + DATA_ROW + ':' + letter + last, {
      type: 'list',
      allowBlank: true,
      formulae: ['"' + list.join(',') + '"'],
      showErrorMessage: true,
      errorTitle: 'Pick from the list',
      error: 'Choose one of: ' + list.join(', '),
    })
  }
  return ws
}

// data: { event: {name}, sheet: {name, forDate}, cues, movements (with exceptions), groups, zones, members }
//   cues/movements as the database rows (024/025), groups {id, name, code, category, sector, headcount, colour},
//   zones {id, code, name, kind, capacity, isCircle, radius, centre:[lat,lng]}, members {groupId, username, isIC, isAdmin}
export function buildWorkbook(ExcelJS, data) {
  const wb = new ExcelJS.Workbook()
  wb.creator = 'Event Tracker'
  wb.created = new Date()

  const readme = wb.addWorksheet('README')
  readme.getColumn(1).width = 140
  README.forEach(([text, style], i) => {
    const c = readme.getCell(i + 1, 1)
    c.value = text
    c.font = { bold: style !== '', size: style === 'title' ? 14 : 11 }
    c.alignment = { wrapText: true }
  })

  const d = data.defaults || { early: 30, dwell: 20, amber: 30, minIcs: null }
  const ev = {
    eventName: data.event ? data.event.name : '',
    date: data.sheet && data.sheet.forDate ? data.sheet.forDate : '',
    versionName: data.sheet ? data.sheet.name : '',
    early: lengthText(d.early),
    dwell: d.dwell,
    amber: d.amber,
    minIcs: d.minIcs === null ? 'all sharing' : d.minIcs,
    notify: 'yes',
  }
  addTab(wb, 'Event', EVENT_SETTINGS.map(([key, label, format]) => ({ setting: label, value: ev[key], format })))

  // Every group the file refers to needs a code: one without a code gets one made from its name
  const groups = (data.groups || []).map((g) => ({ ...g }))
  const used = new Set(groups.map((g) => g.code).filter(Boolean))
  for (const g of groups) {
    if (g.code) continue
    const base = (g.name || 'GROUP').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 36) || 'GROUP'
    let code = base
    for (let n = 2; used.has(code); n++) code = base.slice(0, 36) + '_' + n
    used.add(code)
    g.code = code
  }
  const groupById = new Map(groups.map((g) => [g.id, g]))
  const zoneById = new Map((data.zones || []).map((z) => [z.id, z]))
  const cueById = new Map((data.cues || []).map((c) => [c.id, c]))
  const members = data.members || []

  addTab(
    wb,
    'Cues',
    (data.cues || []).map((c) => ({
      code: c.code,
      section: c.section || '',
      start: c.start_time ? c.start_time.slice(0, 8) : '',
      length: lengthText(c.length_s),
      title: c.title,
      type: OPTIONS.type[c.type],
      shorten: c.type === 'flexible' ? lengthText(c.can_shorten_s) : '',
      mode: OPTIONS.mode[c.start_mode],
      area: c.area || '',
      department: c.department || '',
      notes: c.notes || '',
      nextDay: c.day_offset ? 'yes' : '',
    })),
  )
  addTab(
    wb,
    'Groups',
    groups.map((g) => ({
      code: g.code,
      name: g.name,
      category: g.category || '',
      sector: g.sector || '',
      headcount: g.headcount ?? '',
      ics: members.filter((m) => m.groupId === g.id && m.isIC).map((m) => m.username).join('; '),
      admin: members.filter((m) => m.groupId === g.id && m.isAdmin).map((m) => m.username).join('; '),
      colour: g.colour || '',
    })),
  )
  addTab(
    wb,
    'Zones',
    (data.zones || []).map((z) => ({
      code: z.code,
      name: z.name,
      kind: OPTIONS.zoneKind[z.kind],
      source: z.isCircle ? 'Circle' : 'Polygon',
      lat: z.isCircle && z.centre ? z.centre[0].toFixed(6) : '',
      lng: z.isCircle && z.centre ? z.centre[1].toFixed(6) : '',
      radius: z.isCircle ? Math.round(z.radius) : '',
      capacity: z.capacity ?? '',
    })),
  )
  const moves = data.movements || []
  const top = moves.filter((m) => !m.parent_id)
  const rows = []
  const moveRow = (m, code, who, zone) => ({
    code,
    who,
    zone,
    kind: OPTIONS.deadline[m.deadline_kind],
    cue: m.deadline_kind === 'fixed' ? '' : (cueById.get(m.cue_id) || {}).code || '',
    fixed: m.deadline_kind === 'fixed' && m.fixed_time ? clockText(timeSeconds(m.fixed_time) + (m.fixed_day_offset ? 86400 : 0)) : '',
    early: lengthText(m.early_s),
    minIcs: m.min_ics ?? 'all sharing',
    dwell: m.dwell_s,
    amber: m.amber_s,
    leaveBy: m.leave_by || '',
    mode: OPTIONS.travel[m.travel_mode],
    pace: Number(m.pace_mps),
    arrival: m.arrival_point || '',
    route: m.route || '',
    notes: m.notes || '',
  })
  const naturally = (a, b) => a.code.localeCompare(b.code, undefined, { numeric: true })
  for (const m of [...top].sort(naturally)) {
    const g = groupById.get(m.group_id)
    rows.push(moveRow(m, m.code, m.category ? 'CAT:' + m.category : g ? g.code : '', (zoneById.get(m.zone_id) || {}).code || ''))
    moves
      .filter((x) => x.parent_id === m.id)
      .forEach((x, i) => {
        const xg = groupById.get(x.group_id)
        rows.push(moveRow({ ...x, deadline_kind: m.deadline_kind, cue_id: m.cue_id, fixed_time: m.fixed_time, fixed_day_offset: m.fixed_day_offset },
          (m.code + '-' + (i + 1)).slice(0, 20), xg ? xg.code : '', x.skip ? 'SKIP' : (zoneById.get(x.zone_id) || {}).code || ''))
      })
  }
  addTab(wb, 'Movements', rows)
  addTab(wb, 'Checkpoints', data.checkpoints || [])
  return wb
}
function timeSeconds(t) {
  const [h, m, s] = String(t).split(':').map(Number)
  return h * 3600 + m * 60 + (s || 0)
}

// The template's example (the NDP show matrix sample): Download template = buildWorkbook(ExcelJS, TEMPLATE_EXAMPLE)
export const TEMPLATE_EXAMPLE = {
  event: { name: 'NDP Rehearsal 1' },
  sheet: { name: 'Rehearsal 1', forDate: '2026-08-01' },
  cues: [
    ['C010', 'Pre-Parade', '17:30:00', 0, 'Broadcast start time', 'anchor', 0, 'auto', 'Broadcast', 'Broadcast', 'Live on TV'],
    ['C018', 'Pre-Parade', '17:35:30', 150, 'Padang Wave (buffer to meet go-live)', 'flexible', 60, 'auto', 'Padang', 'Show Mgmt', ''],
    ['C033', 'Pre-Parade', '18:01:35', 157, 'Our Singapore Wish', 'normal', 0, 'auto', 'Padang', 'Show Mgmt', 'Bands enter and preset in Formation 1'],
    ['C034', 'Pre-Parade', '18:04:12', 86, 'Combined School Marching Bands Feature', 'normal', 0, 'auto_ready', 'Padang', 'Show Mgmt', ''],
    ['C038', 'Pre-Parade', '18:08:57', 45, 'Audience Placard + Choir Feature', 'normal', 0, 'auto_ready', 'Padang', 'Show Mgmt', 'Choir @ S1, S2, S3, S7, S8'],
    ['C040', 'Parade & Ceremony', '18:11:00', 3100, 'Parade & Ceremony', 'flexible', 70, 'manual', 'Padang', 'Parade', ''],
    ['C045', 'Mobile Column', '19:02:40', 560, 'Mobile Column', 'normal', 0, 'auto', 'All', 'Mobile Column', 'Vehicles follow MC_ROUTE (Checkpoints tab)'],
    ['C052', 'Mobile Column', '19:12:00', 65, 'Flypast', 'anchor', 0, 'auto', 'All', 'RSAF', 'Anchor Timing 19:12:00'],
  ].map(([code, section, start_time, length_s, title, type, can_shorten_s, start_mode, area, department, notes]) => ({
    id: code, code, section, start_time, day_offset: 0, length_s, title, type, can_shorten_s, start_mode, area, department, notes,
  })),
  groups: [
    ['TKSS_BAND', 'TKSS Band', 'Bands', 'Padang', 36, '#0D6EFD'],
    ['WSSS_BAND', 'WSSS Band', 'Bands', 'Padang', 32, '#DC3545'],
    ['YHSS_BAND', 'YHSS Band', 'Bands', 'Padang', 32, '#198754'],
    ['MOE_CHOIR_S3', 'MOE Choir (S3)', 'Choirs', 'S3', 40, '#6F42C1'],
    ['MOBILE_COLUMN', 'Mobile Column (lead vehicles)', 'Mobile Column', 'Route', 24, '#FD7E14'],
  ].map(([code, name, category, sector, headcount, colour]) => ({ id: code, code, name, category, sector, headcount, colour })),
  zones: [
    { id: 'FORMATION_1', code: 'FORMATION_1', name: 'Formation 1', kind: 'zone', capacity: 120 },
    { id: 'HOLD_D4', code: 'HOLD_D4', name: 'Holding area D4', kind: 'zone', capacity: 150, isCircle: true, radius: 25, centre: [1.29041, 103.85215] },
    { id: 'D4', code: 'D4', name: 'Door D4', kind: 'entrance', capacity: null, isCircle: true, radius: 15, centre: [1.2909, 103.8517] },
    { id: 'SECTOR_S3', code: 'SECTOR_S3', name: 'Sector S3', kind: 'zone', capacity: 60 },
    { id: 'PYRO_ZONE', code: 'PYRO_ZONE', name: 'Pyro zone', kind: 'no_go', capacity: null },
    { id: 'SALUTE_DAIS', code: 'SALUTE_DAIS', name: 'Saluting dais', kind: 'stage', capacity: null },
  ],
  movements: [
    { id: 'M010', code: 'M010', group_id: 'TKSS_BAND', zone_id: 'HOLD_D4', deadline_kind: 'cue_start', cue_id: 'C033', early_s: 60, min_ics: null, dwell_s: 20, amber_s: 30, travel_mode: 'on_foot', pace_mps: 0.8, arrival_point: 'D4' },
    { id: 'M011', code: 'M011', category: 'Bands', zone_id: 'FORMATION_1', deadline_kind: 'cue_start', cue_id: 'C034', early_s: 30, min_ics: null, dwell_s: 20, amber_s: 30, leave_by: 'C034 END', travel_mode: 'on_foot', pace_mps: 0.8, arrival_point: 'D4' },
    { id: 'M011-1', parent_id: 'M011', group_id: 'YHSS_BAND', zone_id: 'FORMATION_1', early_s: 30, min_ics: 2, dwell_s: 20, amber_s: 30, leave_by: 'C034 END', travel_mode: 'on_foot', pace_mps: 0.8, arrival_point: 'D4' },
    { id: 'M020', code: 'M020', group_id: 'MOE_CHOIR_S3', zone_id: 'SECTOR_S3', deadline_kind: 'fixed', fixed_time: '18:05:00', fixed_day_offset: 0, early_s: 0, min_ics: 1, dwell_s: 20, amber_s: 60, travel_mode: 'on_foot', pace_mps: 1.2 },
    { id: 'M030', code: 'M030', group_id: 'MOBILE_COLUMN', zone_id: 'SALUTE_DAIS', deadline_kind: 'cue_start', cue_id: 'C052', early_s: 0, min_ics: 1, dwell_s: 0, amber_s: 20, travel_mode: 'fixed_route', pace_mps: 1.2, route: 'MC_ROUTE' },
  ],
  checkpoints: [
    ['1', 'C1 Start – Nicoll Hwy', '1.297100', '103.861900', '30', '00:00', 'C045'],
    ['2', 'C2 Esplanade Dr', '1.291300', '103.855900', '30', '02:10', ''],
    ['3', "C3 St Andrew's Rd", '1.290600', '103.852300', '30', '04:40', ''],
    ['4', 'C4 Saluting dais', '1.290300', '103.851200', '20', '06:40', ''],
    ['5', 'C5 Exit – Coleman St', '1.292300', '103.849900', '30', '08:20', ''],
  ].map(([order, name, lat, lng, radius, offset, startCue]) => ({ route: 'MC_ROUTE', order, name, kml: '', lat, lng, radius, time: '', offset, startCue })),
  defaults: { early: 30, dwell: 20, amber: 30, minIcs: null },
}
