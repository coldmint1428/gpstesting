// Step 23, proved through the screen: the plan out to a spreadsheet and back, and a sheet with one 100 m step refused
// in the words the strip already uses.
//
//     node tools/sql.mjs --file dev/checks/step23-sheet-prep.sql
//     node tools/run.mjs dev/checks/step23-csv.mjs --session .tmp/session.json
//
// THE FILE IS THE BROWSER'S. The check lets Chrome write its downloads to .tmp/step23-downloads and reads what it
// wrote, so the bytes under test are the bytes a planner gets -- not a string the check called the writer for. THE
// IMPORT IS THE APP'S. CDP hands the board's hidden file input a real file (DOM.setFileInputFiles), which fires the
// same change event the system picker would; the dialog behind it is the product's own.
//
// What is proved, in order:
//   1. THE SHEET IS THE PLAN. "Sheet bench" exports to a six-row file with a BOM, the note's comma and quotation marks
//      quoted, a 16-decimal latitude kept whole, a position off site confirmed by hand, and a moment nobody stands at.
//   2. WIPE, AND BACK. The plan is deleted, a new empty one is made with the same name, and the file is imported into
//      it. The second export is the first one, byte for byte, so every moment, note, place and flag came back.
//   3. THE MOMENTS ARE THE FILE'S, ON SCREEN. The open frame's note is the file's note, and the two flags are the ones
//      the row carried; the undo stack starts again, because a sheet is a whole plan (step 13's boundary).
//   4. A SHEET THAT CANNOT BE WALKED IS REFUSED, WITH THE STRIP'S OWN SENTENCE. "Sheet gap" is exported and imported
//      back untouched: the refusal's line is character-for-character the red row under the strip, nothing is written
//      (the frame ids are the same afterwards), and a refusal is one button.
//   5. AND THE FIX IS A SHEET EDIT. The same file with the one wrong longitude typed over imports: the plan now holds
//      the edited moment, has no red row, and its export carries the number the planner wrote.
import fs from 'node:fs'
import path from 'node:path'

const EVENT = '0b000000-0000-4000-8000-000000000e23'
const PLAN = '0b000000-0000-4000-8000-00000000b231'
const GAP = '0b000000-0000-4000-8000-00000000b232'
const GATE = '0b000000-0000-4000-8000-00000000a231'
const SHEET = 'Sheet bench.csv'
const SHEET_GAP = 'Sheet gap.csv'
const DOWNLOADS = path.resolve('.tmp/step23-downloads')

const rowOf = (text, needle) => text.split('\r\n').find((line) => line.includes(needle)) || ''
// The title is a comment, and it is quoted when the plan's name (or the line's own comma) needs it -- so `#` may hide
// behind a quote. A data row always starts with a time.
const dataRows = (text) =>
  text
    .replace(/^\uFEFF/, '')
    .split('\r\n')
    .filter((line) => line !== '' && !/^"?#/.test(line))

/** Let Chrome save downloads here; the browser domain first, the page-domain spelling as a fallback. */
async function allowDownloads(tab, dir) {
  fs.rmSync(dir, { recursive: true, force: true })
  fs.mkdirSync(dir, { recursive: true })
  for (const [method, params] of [
    ['Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir, eventsEnabled: true }],
    ['Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dir }],
  ]) {
    try {
      await tab.cdp.send(method, params)
      return method
    } catch {
      /* try the other spelling */
    }
  }
  throw new Error('this browser refused both download-behaviour commands')
}

/** Press Export and read the file the browser wrote. The file is removed first so a stale one cannot pass. */
async function exportSheet(tab, fileName) {
  const file = path.join(DOWNLOADS, fileName)
  fs.rmSync(file, { force: true })
  await tab.waitUntil(
    `(() => { const b = document.querySelector('[data-testid=sheet-export]'); return !!b && !b.disabled })()`,
    { what: 'the export button to be ready' },
  )
  await tab.click('[data-testid=sheet-export]')
  const deadline = Date.now() + 15000
  while (Date.now() < deadline) {
    if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8')
    await tab.sleep(200)
  }
  throw new Error(`${tab.label}: the browser never wrote ${fileName}`)
}

/** Hand the board's hidden input a real file, the way the picker would. */
async function chooseSheet(tab, filePath) {
  const { result } = await tab.cdp.send('Runtime.evaluate', {
    expression: `document.querySelector('[data-testid=sheet-file]')`,
    returnByValue: false,
  })
  if (!result || !result.objectId) throw new Error(`${tab.label}: the board has no sheet input`)
  await tab.cdp.send('DOM.setFileInputFiles', { files: [filePath], objectId: result.objectId })
}

/** Pick a plan in the picker by id (the picker's options are plan ids, never names). */
async function selectPlan(tab, planId) {
  const ok = await tab.eval(`(() => {
    const sel = document.querySelector('.pv-select')
    if (!sel) return false
    sel.value = ${JSON.stringify(planId)}
    sel.dispatchEvent(new Event('change', { bubbles: true }))
    return sel.value === ${JSON.stringify(planId)}
  })()`)
  if (!ok) throw new Error(`${tab.label}: the plan picker has no ${planId}`)
}

async function pressButton(tab, label) {
  await tab.waitUntil(
    `(() => {
       const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(label)})
       return !!button && !button.disabled
     })()`,
    { what: `"${label}" to be ready` },
  )
  const clicked = await tab.eval(`(() => {
    const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(label)})
    if (!button) return 'missing'
    button.click()
    return 'clicked'
  })()`)
  if (clicked !== 'clicked') throw new Error(`${tab.label}: no "${label}" button`)
}

const frameIds = (tab) => tab.eval(`[...document.querySelectorAll('.pv-frame')].map((f) => f.dataset.frameId)`)

export default {
  name: 'step 23 — a plan out to a spreadsheet and back, and a sheet with a 100 m step refused',

  async run({ newTab, base }) {
    if (!fs.existsSync('.tmp/session.json')) {
      throw new Error('no planner session at .tmp/session.json. Mint one with: node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json')
    }
    const tab = await newTab({ label: 'planner, the sheet', url: `${base}/events/${EVENT}/timeline`, width: 1440, height: 1000 })
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      timeout: 20000,
      what: 'the four moments of "Sheet bench"',
    })
    await allowDownloads(tab, DOWNLOADS)

    // ---------- 1. the sheet is the plan ----------
    const opened = await tab.eval(`(() => { const sel = document.querySelector('.pv-select'); return sel.options[sel.selectedIndex].textContent.trim() })()`)
    await tab.assertThat(`the board opens the newest plan (${opened})`, opened.startsWith('Sheet bench'))
    await tab.assertThat('the plan is legal before a sheet is ever involved', `document.querySelectorAll('.pv-gap').length === 0`)
    await tab.assertThat('the open moment is the call, with the note the file has to carry', `document.querySelector('#pv-frame-note').value === 'Call, everyone at the "gate"'`)

    const first = await exportSheet(tab, SHEET)
    await tab.assertThat('the file starts with a BOM, so Excel reads the names', first.charCodeAt(0) === 0xfeff)
    await tab.assertThat(
      'the file is titled, and the title is a comment rather than a column',
      first.replace(/^\uFEFF/, '').split('\r\n')[0] === '"# Sheet bench — plan sheet, times are seconds from T+0"',
      first.replace(/^\uFEFF/, '').split('\r\n')[0],
    )
    await tab.assertThat(
      'the columns are the tables',
      dataRows(first)[0] === 't_s,note,group,lat,lng,state,verify',
      dataRows(first)[0],
    )
    await tab.assertThat(
      `six rows: two at the call, one at the move, two at the change, and the moment nobody stands at (${dataRows(first).length - 1})`,
      dataRows(first).length - 1 === 6,
    )
    await tab.assertThat(
      'the note keeps its comma and its quotation marks, quoted the CSV way',
      first.includes('0,"Call, everyone at the ""gate""",Gate Crew,1.2966123456789,103.773102,on_site,auto'),
      rowOf(first, 'Call'),
    )
    await tab.assertThat(
      'the latitude is the one the board holds, not six decimals of it',
      first.includes('1.2966123456789') && !first.includes('1.296612,'),
    )
    await tab.assertThat(
      'the off-site moment says so, and says somebody must confirm it',
      first.includes(',off_site,manual'),
      rowOf(first, 'off_site'),
    )
    await tab.assertThat(
      'the moment nobody stands at is still a row',
      first.includes('180,"Back at the gate",,,,,') || first.includes('180,Back at the gate,,,,,'),
      rowOf(first, '180'),
    )
    await tab.assertThat('the file names the plan it came from, not its id', !first.includes(PLAN))

    // ---------- 2. wipe, and back ----------
    await pressButton(tab, 'Delete plan')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.assertContains('[data-testid=confirm-dialog]', 'Delete "Sheet bench"?')
    await tab.click('[data-testid=confirm-ok]')
    tab.pass('the plan was thrown away')
    // The board had been drawing that plan. It opens the one that is left rather than sitting on an empty strip with
    // its buttons disabled (finding 88).
    await tab.waitUntil(
      `(() => { const sel = document.querySelector('.pv-select'); return !!sel && sel.options[sel.selectedIndex] && sel.options[sel.selectedIndex].textContent.includes('Sheet gap') })()`,
      { timeout: 15000, what: 'the board to open the remaining plan' },
    )
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      timeout: 15000,
      what: "the remaining plan's two moments",
    })
    await tab.assertThat(
      'after the deletion the strip is the other plan, not an empty bar',
      `document.querySelectorAll('.pv-frame').length === 2 && !document.querySelector('[data-testid=plan-empty]')`,
    )

    await pressButton(tab, 'New plan')
    await tab.waitFor('[data-testid=plan-create-name]')
    await tab.type('[data-testid=plan-create-name]', 'Sheet bench')
    await pressButton(tab, 'Create')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 0`, {
      what: 'the new plan to be empty',
    })
    await tab.assertThat(
      'the plan being wiped is a fresh one with the same name, and nothing in it',
      `document.querySelector('.pv-select').options[document.querySelector('.pv-select').selectedIndex].textContent.includes('Sheet bench') &&
       document.querySelectorAll('.pv-frame').length === 0`,
    )

    await chooseSheet(tab, path.join(DOWNLOADS, SHEET))
    await tab.waitFor('[data-testid=confirm-dialog]', { timeout: 15000 })
    await tab.assertContains('[data-testid=confirm-dialog]', 'Import "Sheet bench.csv" into "Sheet bench"?')
    await tab.assertContains('[data-testid=confirm-dialog]', '4 frames and 5 positions in the file.')
    await tab.assertContains('[data-testid=confirm-dialog]', 'Every moment of the file is written into the plan.')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      timeout: 20000,
      what: 'the sheet to become the plan',
    })
    await tab.waitUntil(
      `(() => { const t = [...document.querySelectorAll('.toast-body')].pop(); return !!t && /Imported 4 frames and 5 positions/.test(t.textContent) })()`,
      { timeout: 8000, what: 'the board to say what it imported' },
    )
    tab.pass('the file became a plan again, with the counts it carried')

    const second = await exportSheet(tab, SHEET)
    await tab.assertThat('the plan exported after the round trip is the file that was imported', second === first)
    await tab.assertThat('and it is not empty: the same 6 rows', dataRows(second).length - 1 === 6)

    // ---------- 3. the moments on screen are the file's ----------
    await tab.assertThat('the call note is the one in the file', `document.querySelector('#pv-frame-note').value === 'Call, everyone at the "gate"'`)
    await tab.assertThat('the undo stack starts again, because a sheet is a whole plan', `document.querySelector('[data-testid=undo]').disabled === true`)
    const ids = await frameIds(tab)
    await tab.assertThat('the four moments are new frames, not the deleted plan\'s', ids.length === 4 && !ids.includes('0b000000-0000-4000-8000-0000000f2311'))

    // Open the change: the two flags the row carried must be the two the board shows.
    await tab.click('.pv-frame', { index: 2 })
    await tab.waitUntil(`document.querySelector('#pv-frame-note').value === 'Out for the change'`, {
      what: 'the change moment to open',
    })
    await tab.assertThat(
      'the off-site row came back as an off-site statement, for the group in it',
      `document.querySelector('[data-testid=state-off][data-group="${GATE}"]').getAttribute('aria-pressed') === 'true'`,
    )
    await tab.assertThat(
      'and the manual flag came back with it',
      `document.querySelector('[data-testid=verify-manual][data-group="${GATE}"]').getAttribute('aria-pressed') === 'true'`,
    )
    await tab.assertThat('a sheet that obeys the rule raises no warning', `document.querySelectorAll('.pv-gap').length === 0`)

    // ---------- 4. a sheet that cannot be walked ----------
    await selectPlan(tab, GAP)
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, { timeout: 15000, what: '"Sheet gap"' })
    const sentence = await tab.text('.pv-gap-text')
    await tab.assertThat(
      `the strip names the impossible walk (${sentence})`,
      sentence === 'Sound: 100 m between +0:00 and +1:00 (limit 25 m)',
    )
    const gapFile = await exportSheet(tab, SHEET_GAP)
    await tab.assertThat('the broken plan exports too: four rows, two groups, two moments', dataRows(gapFile).length - 1 === 4)
    const brokenIds = await frameIds(tab)

    await chooseSheet(tab, path.join(DOWNLOADS, SHEET_GAP))
    await tab.waitFor('[data-testid=confirm-dialog]', { timeout: 15000 })
    await tab.assertContains('[data-testid=confirm-dialog]', 'This sheet was not imported')
    const refusedLine = await tab.text('[data-testid=confirm-lines] li')
    await tab.assertThat(
      `the refusal uses the strip's own sentence, not a second wording of it (${refusedLine})`,
      refusedLine === sentence,
    )
    await tab.assertContains('[data-testid=confirm-dialog]', 'longer than the plan allows. Nothing was changed.')
    await tab.assertThat('a refusal has nothing to confirm: one button', `!document.querySelector('[data-testid=confirm-cancel]')`)
    await tab.click('[data-testid=confirm-ok]')
    await tab.assertThat('nothing was written: the same two frames, by id', JSON.stringify(await frameIds(tab)) === JSON.stringify(brokenIds))
    await tab.assertThat('and the walk is still exactly as red as it was', `document.querySelectorAll('.pv-gap').length === 1`)

    // ---------- 5. the fix is an edit in the sheet ----------
    const fixed = gapFile.replace(
      '60,,Sound,1.2966,103.774,on_site,auto',
      '60,,Sound,1.2966,103.7733,on_site,auto',
    )
    await tab.assertThat('the check really changed one number in the file', fixed !== gapFile && fixed.includes('103.7733'))
    const fixedFile = path.join(DOWNLOADS, 'Sheet gap edited.csv')
    fs.writeFileSync(fixedFile, fixed)
    await chooseSheet(tab, fixedFile)
    await tab.waitFor('[data-testid=confirm-dialog]', { timeout: 15000 })
    await tab.assertContains('[data-testid=confirm-dialog]', 'Import "Sheet gap edited.csv" into "Sheet gap"?')
    await tab.click('[data-testid=confirm-ok]')
    // The plan has two moments before and after the import, so the frame count cannot tell when the write landed. The
    // warning going out is the thing that changes.
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 0`, {
      timeout: 20000,
      what: 'the corrected sheet to be imported and the warning to clear',
    })
    await tab.assertThat('the corrected sheet imports: the warning is gone', `document.querySelectorAll('.pv-gap').length === 0`)
    await tab.assertThat(
      'and the moments are new frames, not the ones the refusal left alone',
      JSON.stringify(await frameIds(tab)) !== JSON.stringify(brokenIds),
    )
    const corrected = await exportSheet(tab, SHEET_GAP)
    await tab.assertThat(
      'and the plan now holds the number the planner typed, not the one it had',
      corrected.includes('60,,Sound,1.2966,103.7733,on_site,auto'),
      rowOf(corrected, '103.77').slice(0, 160),
    )
    await tab.assertThat('the corrected file is the sheet that was imported, minus its name', dataRows(corrected).length - 1 === 4)

    await tab.assertNoErrors()
    return tab
  },
}
