/**
 * planSheet — a plan as a CSV sheet: out to a spreadsheet, and back in as a plan.
 *
 * WHY A CSV OF ITS OWN. The run sheet had an ExcelJS workbook (cues, movements, several tabs) and step 25 deleted it
 * with that engine. A plan is a different document — moments and places, not cues and moves — so this is a small
 * plain-text file with its own reader and writer, and no dependency on any table but the plan's own.
 *
 * THE COLUMNS ARE THE TABLES, one row per statement:
 *
 *     t_s,note,group,lat,lng,state,verify
 *     0,"Call, everyone at the gate",Gate Crew,1.296612,103.773102,on_site,auto
 *     0,,Sound,1.296621,103.773211,on_site,auto
 *     60,,Gate Crew,1.296702,103.773244,on_site,auto
 *     120,"Out for the change",Gate Crew,1.296702,103.773244,off_site,manual
 *
 * A frame that states nobody is one row with the group cells empty. A group missing from a frame is carried from the
 * frame before it — the model's own rule (038) — so a sheet is exactly as sparse as the plan is. That matters for
 * the person editing it: deleting a row means "they did not move here", which is not the same as "they are not
 * here", and it is why the writer never fills every group into every frame.
 *
 * t_s IS SECONDS FROM T+0, a whole number. Not a clock time and not "1:30": Excel turns a time-looking cell into a
 * fraction of a day and saves it back as 1:30:00 AM, which is a different plan. The reader accepts the board's own
 * label as a courtesy ("+1:30", "90s", "2m"), because a planner typing into a spreadsheet will write what the strip
 * says; the writer only ever produces the number.
 *
 * COORDINATES ARE NOT ROUNDED. String() is the shortest exact text for the double, so a number comes back as the same
 * double. Six decimals would look tidier and would move a marker by up to six centimetres on every round trip, and
 * "reproduces every position" has to mean every position. (The database prints a float8 to fifteen significant digits,
 * so what the board holds is already the only precision there is to carry -- the sheet loses nothing the plan had.)
 *
 * THE BOM AND THE `#` LINE ARE FOR THE PERSON, not for the parser: Excel needs the BOM to read accented names, and
 * the line says what the numbers mean. Neither is a column, and both are skipped on the way back in. The rest is
 * RFC 4180 — CRLF, quoted cells, doubled quotes — and the reader also takes a semicolon-separated file, because
 * Excel in a locale where the comma is the decimal separator saves one. (playback.js's reader makes the same two
 * allowances, written here rather than imported: that module is the GPS replay's, and this one has to stand alone.)
 *
 * WHAT THE READER REFUSES, AND WHY. Everything it can see without the map: no t_s column, a time that is not a time,
 * two rows that place one group at one moment, two rows that give one moment two different notes, a group this event
 * does not have, coordinates that are missing or not coordinates, a state or a verify word that is not one of the
 * two. Each is reported with the file's own row number, so the person can find it in Excel. The 25 m rule is the
 * board's to refuse (it needs `findGaps` and the board's sentence — see `sheetGaps`), and the locked polygons and
 * pace are `plan_check`'s, which the board shows as warnings like any other plan.
 *
 * This module is pure: no Vue, no network, no DOM. The board reads and writes files through it; the tests call it
 * directly.
 */
import { MAX_FRAME_GAP_M, findGaps, formatOffset, parseOffset } from './planFrames.js'

/** The columns, in the order the writer puts them. `t_s` is the only one a file must have. */
export const SHEET_COLUMNS = ['t_s', 'note', 'group', 'lat', 'lng', 'state', 'verify']

/** Three days, the same ceiling frame_save enforces (038's plan_frames_t_range). */
export const SHEET_MAX_T_S = 86400 * 3

const BOM = '\uFEFF'
const STATE_WORDS = ['on_site', 'off_site']
const VERIFY_WORDS = ['auto', 'manual']

/** One CSV cell, RFC 4180: quoted only when it has to be. */
function csvCell(value) {
  const text = value === null || value === undefined ? '' : String(value)
  return /[",\r\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text
}

/** A group's position as written: the two flags are explicit, so a cell never depends on a default. */
function flags(point) {
  return {
    state: STATE_WORDS.includes(point && point.state) ? point.state : 'on_site',
    verify: VERIFY_WORDS.includes(point && point.verify) ? point.verify : 'auto',
  }
}

/**
 * The plan's name and what the numbers are, as a line the reader skips and a person reads.
 * Quoted as one cell: a plan can be called "Rehearsal, day 2".
 */
export function sheetTitle(plan) {
  const name = (plan && plan.name ? String(plan.name) : 'Plan').trim() || 'Plan'
  return csvCell(`# ${name} — plan sheet, times are seconds from T+0`)
}

/** `NDP rehearsal.csv`: the plan's own name, with the characters a phone will not accept taken out. */
export function sheetFileName(plan) {
  const name = (plan && plan.name ? String(plan.name) : 'Plan').trim() || 'Plan'
  return name.replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 100) + '.csv'
}

/**
 * The plan as a sheet.
 *
 * @param {{name?:string}} plan
 * @param {Array<{t_s:number, note?:string, positions?:Object<string,{lat:number,lng:number,state?:string,verify?:string}>}>} frames
 * @param {Array<{id:string, name:string}>} groups  the event's groups, for the names in the group column
 */
export function sheetText(plan, frames, groups) {
  const nameOf = new Map((groups || []).map((g) => [g.id, g.name]))
  const lines = [sheetTitle(plan), SHEET_COLUMNS.join(',')]
  const ordered = [...(frames || [])]
    .filter((frame) => frame && Number.isFinite(frame.t_s))
    .sort((a, b) => a.t_s - b.t_s)

  for (const frame of ordered) {
    const note = frame.note == null ? '' : String(frame.note)
    const stated = Object.entries(frame.positions || {})
      .filter(([, point]) => point && Number.isFinite(point.lat) && Number.isFinite(point.lng))
      .map(([groupId, point]) => ({ groupId, point, name: String(nameOf.get(groupId) || groupId) }))
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))

    // Nobody stated at this moment: one row, so the moment itself survives a round trip.
    if (!stated.length) {
      lines.push([frame.t_s, note, '', '', '', '', ''].map(csvCell).join(','))
      continue
    }
    for (const { point, name } of stated) {
      const { state, verify } = flags(point)
      lines.push([frame.t_s, note, name, String(point.lat), String(point.lng), state, verify].map(csvCell).join(','))
    }
  }
  return BOM + lines.join('\r\n') + '\r\n'
}

// ---------- reading ----------

/** A row: its first physical line in the file (1-based) and its cells. Quoted newlines move `line` along. */
function splitRows(text) {
  const source = String(text ?? '').replace(/^\uFEFF/, '')
  const firstBreak = source.indexOf('\n')
  const firstLine = firstBreak === -1 ? source : source.slice(0, firstBreak)
  const sep = (firstLine.match(/;/g) || []).length > (firstLine.match(/,/g) || []).length ? ';' : ','
  const rows = []
  let cells = []
  let value = ''
  let quoted = false
  let line = 1
  let rowLine = 1
  for (let i = 0; i < source.length; i += 1) {
    const c = source[i]
    if (quoted) {
      if (c === '"' && source[i + 1] === '"') {
        value += '"'
        i += 1
      } else if (c === '"') {
        quoted = false
      } else {
        if (c === '\n') line += 1
        value += c
      }
    } else if (c === '"') {
      quoted = true
    } else if (c === sep) {
      cells.push(value)
      value = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && source[i + 1] === '\n') i += 1
      cells.push(value)
      rows.push({ line: rowLine, cells })
      cells = []
      value = ''
      line += 1
      rowLine = line
    } else {
      value += c
    }
  }
  if (value !== '' || cells.length) {
    cells.push(value)
    rows.push({ line: rowLine, cells })
  }
  return rows
}

const blank = (row) => row.cells.every((cell) => String(cell).trim() === '')
const comment = (row) => String(row.cells[0] || '').trim().startsWith('#')

/** Seconds from T+0: a whole number, or the board's own label ("+1:30", "90s", "2m"). Null when neither. */
function readTime(text) {
  const raw = String(text ?? '').trim()
  if (!raw) return null
  if (/^\d+$/.test(raw)) return Number(raw)
  if (/^\d+\.\d+$/.test(raw)) return Number.isInteger(Number(raw)) ? Number(raw) : null
  const parsed = parseOffset(raw)
  return Number.isFinite(parsed) && Number.isInteger(parsed) ? parsed : null
}

function readNumber(text) {
  const raw = String(text ?? '').trim()
  if (!raw) return null
  const value = Number(raw)
  return Number.isFinite(value) ? value : null
}

/** `On-Site` and `on site` are the same word; anything else is refused with the two it could have been. */
function readWord(text, fallback, words) {
  const raw = String(text ?? '').trim()
  if (!raw) return { word: fallback, bad: null }
  const word = raw.toLowerCase().replace(/[\s-]+/g, '_')
  return words.includes(word) ? { word, bad: null } : { word: fallback, bad: raw }
}

/**
 * A sheet, read as frames.
 *
 * @param {string} text
 * @param {Array<{id:string, name:string}>} groups  the event's groups: a name is how a row says who
 * @returns {{frames: Array<{t_s:number, note:string, positions:Object<string,{lat:number,lng:number,state:string,verify:string}>}>,
 *   errors: Array<{line:number, message:string}>}}
 *   `frames` is sorted by time and ready for `frame_save`'s payload shape. When `errors` is not empty the caller
 *   must not write anything: `frames` is the best reading of the parts that made sense, not a plan.
 */
export function readSheet(text, groups = []) {
  const errors = []
  const rows = splitRows(text)
  const headerAt = rows.findIndex((row) => !blank(row) && !comment(row))
  if (headerAt === -1) return { frames: [], errors: [{ line: 1, message: 'The file has no rows in it.' }] }

  const header = rows[headerAt]
  const names = header.cells.map((cell) => String(cell).trim().toLowerCase())
  const columnOf = (name) => names.indexOf(name)
  const at = (row, name) => {
    const index = columnOf(name)
    return index === -1 ? '' : String(row.cells[index] ?? '').trim()
  }

  if (columnOf('t_s') === -1) {
    return {
      frames: [],
      errors: [
        {
          line: header.line,
          message: `The first row must name the columns, and there is no t_s column in it (it has ${names.filter(Boolean).join(', ') || 'none'}).`,
        },
      ],
    }
  }

  const byName = new Map()
  for (const group of groups || []) {
    if (group && group.name) byName.set(String(group.name).trim().toLowerCase(), group)
  }

  /** t_s -> the frame being built. A Map, because the file's row order carries no meaning. */
  const byTime = new Map()
  const frameAt = (t) => {
    if (!byTime.has(t)) byTime.set(t, { t_s: t, note: '', positions: {} })
    return byTime.get(t)
  }

  for (const row of rows.slice(headerAt + 1)) {
    if (blank(row) || comment(row)) continue

    const rawTime = at(row, 't_s')
    const t = readTime(rawTime)
    if (t === null) {
      errors.push({ line: row.line, message: `"${rawTime}" is not a time. Write seconds from T+0 (90), or +1:30.` })
      continue
    }
    if (t < 0) {
      errors.push({ line: row.line, message: 'A frame cannot sit before T+0.' })
      continue
    }
    if (t > SHEET_MAX_T_S) {
      errors.push({ line: row.line, message: 'A plan stops three days after T+0. That would push a frame past the end.' })
      continue
    }

    const frame = frameAt(t)
    const note = at(row, 'note')
    if (note) {
      if (!frame.note) frame.note = note
      else if (frame.note !== note) {
        errors.push({
          line: row.line,
          message: `The rows at ${formatOffset(t)} disagree about its note ("${frame.note}" and "${note}"). One moment has one note.`,
        })
      }
    }

    const who = at(row, 'group')
    const latText = at(row, 'lat')
    const lngText = at(row, 'lng')
    if (!who) {
      if (latText || lngText || at(row, 'state') || at(row, 'verify')) {
        errors.push({ line: row.line, message: `A position needs a group: the row at ${formatOffset(t)} has no name.` })
      }
      continue
    }

    const group = byName.get(who.toLowerCase())
    if (!group) {
      errors.push({ line: row.line, message: `There is no group called "${who}" in this event.` })
      continue
    }
    if (frame.positions[group.id]) {
      errors.push({ line: row.line, message: `${group.name} is placed twice at ${formatOffset(t)}. One moment states one place per group.` })
      continue
    }

    const lat = readNumber(latText)
    const lng = readNumber(lngText)
    if (lat === null || lng === null) {
      errors.push({
        line: row.line,
        message: `${group.name} at ${formatOffset(t)} needs a latitude and a longitude.`,
      })
      continue
    }
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      errors.push({ line: row.line, message: `${group.name} at ${formatOffset(t)} is not on the map: ${lat}, ${lng}.` })
      continue
    }

    const state = readWord(at(row, 'state'), 'on_site', STATE_WORDS)
    if (state.bad) {
      errors.push({ line: row.line, message: `A position is on_site or off_site, not "${state.bad}" (${group.name} at ${formatOffset(t)}).` })
      continue
    }
    const verify = readWord(at(row, 'verify'), 'auto', VERIFY_WORDS)
    if (verify.bad) {
      errors.push({ line: row.line, message: `A position is auto or manual, not "${verify.bad}" (${group.name} at ${formatOffset(t)}).` })
      continue
    }

    frame.positions[group.id] = { lat, lng, state: state.word, verify: verify.word }
  }

  const frames = [...byTime.values()].sort((a, b) => a.t_s - b.t_s)
  return { frames, errors }
}

/**
 * Every walk in a read sheet that breaks the 25 m rule, in the same shape the board's own warnings use.
 *
 * The sheet's frames have no ids (they are not saved yet), so each gets one for the duration of the check: the
 * ordinals matter, because the budget is 25 m per frame step and the steps are counted by position in the strip.
 *
 * @param {Array<{t_s:number, positions:Object}>} frames  the `frames` of readSheet()
 */
export function sheetGaps(frames, maxM = MAX_FRAME_GAP_M) {
  const shaped = (frames || []).map((frame, index) => ({
    id: `sheet-${index + 1}`,
    t_s: frame.t_s,
    positions: frame.positions || {},
  }))
  return findGaps(shaped, maxM)
}
