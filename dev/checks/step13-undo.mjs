// Step 13's proof, through the browser: Ctrl+Z takes a drag back, Ctrl+Y puts it back, a reload does not forget, and
// a publish ends the stack.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql          # rebuilds the bench
//     node tools/sql.mjs --file dev/checks/step13-undo-prep.sql           # the four-frame strip (required)
//     node tools/run.mjs dev/checks/step13-undo.mjs --session .tmp/session.json
//
// The rule itself is not the database's: an undo is a write, and the writes are the ones steps 5-12 already proved
// (frame_save's client id, frame_delete, frame_shift). What this check is for is the stack: that the keys work, that
// the inverse is the inverse, that it survives a reload, and that it stops at a publish.
//
// THE KEYS ARE REAL PRESSES. Unlike Ctrl+C (dev/checks/shortcuts.mjs explains why that one is a DOM event: the copy
// command reaches for the OS clipboard and wedges this sandbox's headless Edge), a trusted Control+z through the
// DevTools input pipeline arrives and does not hang the renderer -- so this check presses the key the platform would
// deliver, which is the thing step 4 could not prove for Ctrl+C.
//
// The bench plan "Undo bench" is the Done-when's strip: four frames a minute apart, Gate Crew at the same coordinate
// on all of them, Sound 100 m east as the map's own ruler. The drag is 40 m -- over the 25 m a single step allows, so
// it breaks both hops either side of the middle frame, which gives the check a count to watch (two rows, three dots).
//
// The sequence is the Done-when's, in order:
//   * drag 40 m, then Ctrl+Z: the two rows go, the dots go, and the badge is back where it stood;
//   * reload: the plan, not just the screen, is back -- and the redo stack survived, because a command is data;
//   * Ctrl+Y: the 40 m and the two rows come back (Ctrl+Shift+Z does the same, so both keys are exercised);
//   * push +1:00 and +2:00 past the frame at +3:00, then Ctrl+Z: the frame that never moved must not move;
//   * Delete, then Ctrl+Z: the frame comes back with the id it had (041), its note and its positions;
//   * Add frame, then Ctrl+Z / Ctrl+Y: the same for a frame that was created rather than destroyed;
//   * publish, then Ctrl+Z and Ctrl+Y: both say there is nothing to take back, and nothing is written.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const STRIP = 'Undo bench'

/** One badge's centre in CSS pixels inside the map container: what a drag needs, and what a ruler is made of. */
function markerAt(tab, name) {
  return tab.eval(`(() => {
    const map = document.querySelector('.pv-map').getBoundingClientRect()
    const el = document.querySelector('.leaflet-marker-icon[title=${JSON.stringify(name)}]') ||
               [...document.querySelectorAll('.leaflet-marker-icon')].find((n) => n.title === ${JSON.stringify(name)})
    if (!el) return null
    const box = el.getBoundingClientRect()
    return { x: box.left + box.width / 2 - map.left, y: box.top + box.height / 2 - map.top }
  })()`)
}

/** The warning rows, whitespace collapsed: ["Gate Crew: 40 m between +0:00 and +1:00 (limit 25 m)", ...]. */
function gapRows(tab) {
  return tab.eval(
    `[...document.querySelectorAll('.pv-gap')].map((r) => r.textContent.replace(/\\s+/g, ' ').trim())`,
  )
}

/** How many metres a row claims. */
function rowMetres(text) {
  const hit = /(\d+) m between/.exec(String(text || ''))
  return hit ? Number(hit[1]) : null
}

/** The dots on the time bar the board has marked, by the moment each one names. */
function badDots(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')]
    .filter((b) => b.classList.contains('is-bad'))
    .map((b) => b.title.replace(/^Frame /, ''))`)
}

/** The identity of every frame on the strip, in order: the only thing on screen that says "this is that frame". */
function frameIds(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.dataset.frameId)`)
}

/** Which moment each frame names, by id. The title is "Frame +1:00 — doors" when there is a note, so the time is the
 *  part before the note rather than the whole title. */
function frameTimes(tab) {
  return tab.eval(`Object.fromEntries([...document.querySelectorAll('.pv-frame')].map((b) => [
    b.dataset.frameId,
    b.title.replace(/^Frame /, '').split(' — ')[0],
  ]))`)
}

/** The words in the newest toast. The container keeps older ones until they fade, so "the last one" is what counts. */
async function lastToast(tab) {
  return tab.eval(`(() => {
    const items = [...document.querySelectorAll('[data-testid=toasts] .toast-body')]
    return items.length ? items[items.length - 1].textContent.replace(/\\s+/g, ' ').trim() : ''
  })()`)
}

async function waitForToast(tab, needle) {
  await tab.waitUntil(
    `(() => {
      const items = [...document.querySelectorAll('[data-testid=toasts] .toast-body')]
      const last = items.length ? items[items.length - 1].textContent : ''
      return last.includes(${JSON.stringify(needle)})
    })()`,
    { what: `the toast "${needle}"`, timeout: 12000 },
  )
  tab.pass(`toast: ${JSON.stringify(await lastToast(tab))}`)
}

/** A key on the board, with the focus nowhere in particular -- which is where clicking a frame leaves it. */
async function press(tab, combo) {
  await tab.press(combo)
  await tab.sleep(80)
}

export default {
  name: 'undo — Ctrl+Z takes a drag back across a reload, Ctrl+Y redoes it, and a publish ends the stack',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load (rebuild the fixture and run the prep if it is short)',
      timeout: 25000,
    })

    async function boardMatchesPicker() {
      await tab.waitUntil(
        `(() => {
          const sel = document.querySelector('.pv-select')
          if (!sel) return false
          const m = sel.options[sel.selectedIndex].textContent.match(/\\((\\d+)\\)/)
          return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
        })()`,
        { what: 'the board to show the plan the picker names' },
      )
    }

    async function openPlan(name) {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
        if (!opt) return 'no option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      tab.pass(`opened "${picked}"`)
    }

    /** Click a dot and wait for the board to say it opened -- the patch lands after the click returns. */
    async function openFrame(index, offset) {
      for (let attempt = 1; attempt <= 3; attempt += 1) {
        try {
          await tab.click('.pv-frame', { index })
        } catch {
          await tab.sleep(400)
          continue
        }
        if (await tab.eval(`!!(document.querySelector('.pv-hint') || {}).textContent?.includes('Frame ${offset}')`)) return
        await tab.sleep(400)
      }
      await tab.assertContains('.pv-hint', `Frame ${offset}`)
    }

    async function openTheBench() {
      await boardMatchesPicker()
      await openPlan(STRIP)
      await tab.waitUntil(
        `document.querySelectorAll('.pv-frame').length === 4 &&
         document.querySelector('.pv-select').selectedOptions[0].textContent.includes(${JSON.stringify(STRIP)})`,
        { what: 'the four frames of the undo bench (run dev/checks/step13-undo-prep.sql first)' },
      )
      // The map animates its fit for a quarter second; pressing on a badge while it is still travelling starts no drag.
      await tab.waitUntil(`!document.querySelector('.leaflet-zoom-anim')`, { what: 'the map to stop fitting' })
      await tab.sleep(250)
    }

    /** Wait for a write that follows a key or a click to have been read back into the board. */
    async function settled() {
      await tab.sleep(450)
      await tab.waitUntil(
        `(() => {
          const undo = document.querySelector('[data-testid=undo]')
          const redo = document.querySelector('[data-testid=redo]')
          const add = document.querySelector('[data-testid=frame-add]')
          return !!undo && !!redo && !!add && !add.disabled
        })()`,
        { what: 'the toolbar to be ready again', timeout: 15000 },
      )
    }

    await openTheBench()

    // ---------- 0. the strip is the fixture, and the stack starts empty ----------
    await tab.assertThat(
      'the bench is the fixture: four frames and nothing wrong with them',
      `document.querySelectorAll('.pv-frame').length === 4 &&
       document.querySelectorAll('.pv-gap').length === 0 &&
       !document.querySelector('.pv-badge.is-bad')`,
    )
    await tab.assertThat(
      'a fresh plan has nothing to undo and nothing to redo',
      `document.querySelector('[data-testid=undo]').disabled &&
       document.querySelector('[data-testid=redo]').disabled`,
    )
    const originalIds = await frameIds(tab)
    tab.pass(`frame ids: ${JSON.stringify(originalIds)}`)

    // ---------- 1. the drag that the rest of the check takes back ----------
    await openFrame(1, '+1:00')
    const gateBefore = await markerAt(tab, 'Gate Crew')
    const soundBefore = await markerAt(tab, 'Sound')
    tab.pass(`badges at +1:00: ${JSON.stringify({ gate: gateBefore, sound: soundBefore })}`)
    const ruler = Math.abs(soundBefore.x - gateBefore.x)
    const mPerPx = 100 / ruler
    tab.pass(`the map's own ruler: ${ruler.toFixed(1)} px between Gate Crew and Sound, ${mPerPx.toFixed(3)} m/px`)
    await tab.assertThat(
      'the two badges are far enough apart to measure a metre by',
      ruler > 20 && mPerPx > 0.2 && mPerPx < 2,
    )
    const dx = Math.round(40 / mPerPx)
    const mapWidth = await tab.eval(`document.querySelector('.pv-map').getBoundingClientRect().width`)
    tab.pass(`40 m east is ${dx} px at this zoom`)
    await tab.assertThat('and there is room on the map to drag that far', gateBefore.x + dx < mapWidth - 30)

    const savesBefore = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length`,
    )
    await tab.drag('.leaflet-marker-icon[title="Gate Crew"]', dx, 0, { steps: 20, settle: 250 })
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'the two hops either side of the moved frame to break',
      timeout: 12000,
    })
    await settled()
    const savesAfter = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length`,
    )
    await tab.assertThat('one drag is one save', savesAfter - savesBefore === 1)

    const dragged = await gapRows(tab)
    tab.pass(`rows after the drag: ${JSON.stringify(dragged)}`)
    await tab.assertThat('the two neighbouring hops are the only breaks', dragged.length === 2)
    await tab.assertThat(
      'each names Gate Crew and about 40 m, over one step each',
      dragged.every((text) => text.startsWith('Gate Crew:') && (rowMetres(text) ?? 0) >= 36 && (rowMetres(text) ?? 0) <= 45),
    )
    await tab.assertThat(
      'the rows are +0:00 to +1:00 and +1:00 to +2:00, both under the 25 m limit',
      dragged.some((t) => t.includes('+0:00') && t.includes('+1:00') && t.includes('(limit 25 m)')) &&
        dragged.some((t) => t.includes('+1:00') && t.includes('+2:00') && t.includes('(limit 25 m)')),
    )
    await tab.assertThat(
      'the strip marks the whole stretch: three dots',
      `document.querySelectorAll('.pv-frame.is-bad').length === 3`,
    )
    await tab.assertThat(
      'a drag is an edit, so undo is offered and redo is not',
      `!document.querySelector('[data-testid=undo]').disabled &&
       document.querySelector('[data-testid=redo]').disabled`,
    )
    const gateMoved = await markerAt(tab, 'Gate Crew')

    // ---------- 2. Ctrl+Z: the walk is back, in the plan and on the screen ----------
    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 0`, {
      what: 'the two rows to go when the drag is taken back',
      timeout: 12000,
    })
    await waitForToast(tab, 'Undid — moved Gate Crew at +1:00')
    await settled()
    await tab.assertThat(
      'the strip has nothing marked again',
      `document.querySelectorAll('.pv-frame.is-bad').length === 0 && !document.querySelector('.pv-badge.is-bad')`,
    )
    const gateUndone = await markerAt(tab, 'Gate Crew')
    tab.pass(`badge after the undo: ${JSON.stringify(gateUndone)}, before the drag: ${JSON.stringify(gateBefore)}`)
    await tab.assertThat(
      'the badge is back where it stood, to within two pixels',
      Math.abs(gateUndone.x - gateBefore.x) <= 2 && Math.abs(gateUndone.y - gateBefore.y) <= 2,
    )
    await tab.assertThat(
      'and the stack has turned round: nothing left to undo, one thing to redo',
      `document.querySelector('[data-testid=undo]').disabled &&
       !document.querySelector('[data-testid=redo]').disabled`,
    )

    // The picture for this step: the strip after the undo, with the sentence saying what was taken back. The bar is
    // scrolled into view because the strip is the evidence -- the plan is legal again and the drag is named in the
    // toast, which is the only thing on this screen that says "this was a change, and here is the change".
    await tab.eval(`document.querySelector('.pv-bar').scrollIntoView({ block: 'center' })`)
    await tab.sleep(200)
    await tab.shot('shots/step13-undo.png')

    // ---------- 3. the reload: it is the plan that changed, and the stack remembers ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load after the reload',
      timeout: 25000,
    })
    await openTheBench()
    await tab.assertThat(
      'after a reload the plan is still legal',
      `document.querySelectorAll('.pv-frame').length === 4 && document.querySelectorAll('.pv-gap').length === 0`,
    )
    await tab.assertThat(
      'and the same four frames, by id',
      JSON.stringify((await frameIds(tab)).sort()) === JSON.stringify([...originalIds].sort()),
    )
    await tab.assertThat(
      'the redo stack survived the reload: a command is data, not a closure in a dead tab',
      `!document.querySelector('[data-testid=redo]').disabled &&
       document.querySelector('[data-testid=undo]').disabled`,
    )
    await openFrame(1, '+1:00')
    const gateReloaded = await markerAt(tab, 'Gate Crew')
    const soundReloaded = await markerAt(tab, 'Sound')
    tab.pass(`badges after the reload: ${JSON.stringify({ gate: gateReloaded, sound: soundReloaded })}`)
    await tab.assertThat(
      'the camera is framed the same way, so the pixels mean the same thing',
      Math.abs(soundReloaded.x - soundBefore.x) <= 2,
    )
    await tab.assertThat(
      'and Gate Crew is back at its original coordinates, not the dragged ones',
      Math.abs(gateReloaded.x - gateBefore.x) <= 2,
    )

    // ---------- 4. Ctrl+Y puts the 40 m back ----------
    await press(tab, 'Control+y')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'the two rows to come back when the drag is redone',
      timeout: 12000,
    })
    await waitForToast(tab, 'Redid — moved Gate Crew at +1:00')
    await settled()
    const gateRedone = await markerAt(tab, 'Gate Crew')
    tab.pass(`badge after the redo: ${JSON.stringify(gateRedone)}, after the drag: ${JSON.stringify(gateMoved)}`)
    await tab.assertThat(
      'the redo put the badge back where the drag left it',
      Math.abs(gateRedone.x - gateMoved.x) <= 2,
    )
    const redoneRows = await gapRows(tab)
    tab.pass(`rows after the redo: ${JSON.stringify(redoneRows)}`)
    await tab.assertThat(
      'and the same two rows with the same distances',
      redoneRows.length === 2 &&
        redoneRows.every((text) => (rowMetres(text) ?? 0) >= 36 && (rowMetres(text) ?? 0) <= 45),
    )

    // Step back, then forward with the other redo key: Ctrl+Shift+Z is the same stack from the other side.
    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 0`, {
      what: 'the drag to go again',
      timeout: 12000,
    })
    await settled()
    await press(tab, 'Control+Shift+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'Ctrl+Shift+Z to redo the drag',
      timeout: 12000,
    })
    await waitForToast(tab, 'Redid — moved Gate Crew at +1:00')
    await settled()
    tab.pass('Ctrl+Shift+Z redid what Ctrl+Z had taken back')

    // Back to the legal plan for the rest of the check.
    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 0`, {
      what: 'the plan to be legal again before the frame edits',
      timeout: 12000,
    })
    await settled()

    // ---------- 5. a push past a frame that stays put, taken back by id ----------
    // Selecting +1:00 and +2:00 and dragging them +1:30 lands them at +2:30 and +3:30, which puts the frame that
    // stayed at +3:00 *inside* the range they now occupy. An undo that named that range would drag the fourth frame
    // back with them; the stack moves the two by id instead, and the frame that never moved has to still be at +3:00.
    await openFrame(1, '+1:00')
    await tab.click('.pv-frame', { index: 2, modifiers: 8 })
    await tab.waitUntil(`document.querySelector('.pv-hint').textContent.includes('2 frames')`, {
      what: 'the two frames +1:00 and +2:00 to be selected',
    })
    const beforePush = await frameTimes(tab)
    tab.pass(`id -> time before the push: ${JSON.stringify(beforePush)}`)
    // 1:30 of strip at the default scale is 99 px; the drag snaps to the five-second grid, so it lands exactly.
    await tab.drag('.pv-frame', 99, 0, { index: 1, steps: 16, settle: 250 })
    await tab.waitUntil(`[...document.querySelectorAll('.pv-frame')].some((b) => b.title.includes('+3:30'))`, {
      what: 'the two selected frames to move +1:30',
      timeout: 12000,
    })
    await settled()
    const pushed = await frameTimes(tab)
    tab.pass(`id -> time after the push: ${JSON.stringify(pushed)}`)
    await tab.assertThat(
      'the pushed pair is at +2:30 and +3:30, and the frame that stayed is still at +3:00',
      `(() => {
        const times = [...document.querySelectorAll('.pv-frame')].map((b) => b.title.replace(/^Frame /, '').split(' — ')[0])
        return times.length === 4 && ['+0:00', '+2:30', '+3:00', '+3:30'].every((t) => times.includes(t))
      })()`,
    )
    await tab.assertThat(
      'the range the pair now occupies holds three frames: the +3:00 frame that never moved is inside it',
      `(() => {
        const times = [...document.querySelectorAll('.pv-frame')].map((b) => b.title.replace(/^Frame /, '').split(' — ')[0])
        return ['+2:30', '+3:00', '+3:30'].every((t) => times.includes(t))
      })()`,
    )

    await press(tab, 'Control+z')
    await tab.waitUntil(`[...document.querySelectorAll('.pv-frame')].some((b) => b.title.includes('+2:00'))`, {
      what: 'the push to be taken back',
      timeout: 12000,
    })
    await waitForToast(tab, 'Undid — 2 frames moved by +1:30')
    await settled()
    const afterUndoPush = await frameTimes(tab)
    tab.pass(`id -> time after the undo: ${JSON.stringify(afterUndoPush)}`)
    await tab.assertThat(
      'every frame is back at its own time, the one that never moved included',
      JSON.stringify(afterUndoPush) === JSON.stringify(beforePush),
    )

    // ---------- 6. Delete from the keyboard, and an undo that brings the same frame back ----------
    await openFrame(1, '+1:00')
    const beforeDelete = await frameIds(tab)
    await tab.assertThat(
      'the open frame is the one with a note on it',
      `document.querySelector('#pv-frame-note').value === 'doors'`,
    )
    await press(tab, 'Delete')
    await tab.waitFor('[data-testid=confirm-dialog]', { timeout: 6000 })
    tab.pass('Delete asked before it deleted, the same question the button asks')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      what: 'the frame to be deleted',
      timeout: 12000,
    })
    await settled()
    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      what: 'the deleted frame to come back',
      timeout: 12000,
    })
    await waitForToast(tab, 'Undid — deleted the frame at +1:00')
    await settled()
    const afterUndoDelete = await frameIds(tab)
    tab.pass(`frame ids after the undo: ${JSON.stringify(afterUndoDelete)}`)
    await tab.assertThat(
      'the restored frame is the same frame, by id (041)',
      JSON.stringify(afterUndoDelete) === JSON.stringify(beforeDelete),
    )
    await tab.assertThat(
      'its note came back with it',
      `document.querySelector('#pv-frame-note').value === 'doors'`,
    )
    await tab.assertThat(
      'and the positions it carried came back with it: Gate Crew stated here, Sound still carried',
      `(() => {
        if (document.querySelectorAll('.pv-marker').length !== 2) return false
        const states = Object.fromEntries([...document.querySelectorAll('.pv-group-row')].map((row) => [
          row.querySelector('.pv-group-name').textContent.trim(),
          row.querySelector('.pv-group-state').textContent.trim(),
        ]))
        return states['Gate Crew'] === 'set' && states['Sound'] === 'same'
      })()`,
    )
    await tab.assertThat(
      'the frame the undo restored is the one that is open',
      `document.querySelector('.pv-hint').textContent.includes('Frame +1:00')`,
    )

    // ---------- 7. a created frame, taken back and put back with the same id ----------
    await tab.click('[data-testid=frame-add]')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 5`, {
      what: 'the added frame',
      timeout: 12000,
    })
    await settled()
    const withAdded = await frameIds(tab)
    const added = withAdded.find((id) => !beforeDelete.includes(id))
    tab.pass(`the added frame is ${added}`)
    await tab.assertThat('adding a frame is an edit: redo is not offered', `document.querySelector('[data-testid=redo]').disabled`)

    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      what: 'the added frame to be taken away',
      timeout: 12000,
    })
    await waitForToast(tab, 'Undid — added a frame at +4:00')
    await settled()
    await tab.assertThat('the undo is a delete of the same frame', `!document.querySelector('.pv-frame[data-frame-id="${added}"]')`)

    await press(tab, 'Control+y')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 5`, {
      what: 'the frame to be created again',
      timeout: 12000,
    })
    await waitForToast(tab, 'Redid — added a frame at +4:00')
    await settled()
    const redone = await frameIds(tab)
    tab.pass(`frame ids after the redo: ${JSON.stringify(redone)}`)
    await tab.assertThat(
      'the redo created the same frame, not a lookalike at the same time',
      JSON.stringify(redone) === JSON.stringify(withAdded),
    )

    await press(tab, 'Control+z')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      what: 'the frame to be taken away again',
      timeout: 12000,
    })
    await settled()

    // The strip as this step leaves it: legal, four frames, and a stack that can still be walked back.
    await openFrame(1, '+1:00')
    const finalIds = await frameIds(tab)
    await tab.assertThat(
      'the plan is the one it started as',
      JSON.stringify([...finalIds].sort()) === JSON.stringify([...originalIds].sort()),
    )
    await tab.assertThat('and legal again', `document.querySelectorAll('.pv-gap').length === 0`)

    // ---------- 8. a publish ends the stack ----------
    await tab.assertThat(
      'the plan is a draft, so it can be published',
      `[...document.querySelectorAll('.pv-toolbar .pv-badge')].map((b) => b.textContent.trim()).includes('draft')`,
    )
    const published = await tab.eval(`(() => {
      const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish')
      if (!button) return 'no Publish button'
      if (button.disabled) return 'Publish is disabled'
      button.click()
      return 'clicked'
    })()`)
    tab.pass(`publish: ${published}`)
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.click('[data-testid=confirm-ok]')
    await waitForToast(tab, 'Published. This is now the plan people see.')
    await settled()
    await tab.assertThat(
      'the plan is live',
      `[...document.querySelectorAll('.pv-toolbar .pv-badge')].map((b) => b.textContent.trim()).includes('live')`,
    )
    await tab.assertThat(
      'and the publish cleared both stacks',
      `document.querySelector('[data-testid=undo]').disabled && document.querySelector('[data-testid=redo]').disabled`,
    )

    const gatePublished = await markerAt(tab, 'Gate Crew')
    const savesAtPublish = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save') || e.name.includes('/rpc/frame_delete') || e.name.includes('/rpc/frame_shift')).length`,
    )
    await press(tab, 'Control+z')
    await waitForToast(tab, 'Nothing to undo.')
    await settled()
    await press(tab, 'Control+y')
    await waitForToast(tab, 'Nothing to redo.')
    await settled()
    const savesAfterKeys = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save') || e.name.includes('/rpc/frame_delete') || e.name.includes('/rpc/frame_shift')).length`,
    )
    const gateStill = await markerAt(tab, 'Gate Crew')
    await tab.assertThat(
      'after a publish the keys write nothing at all',
      savesAfterKeys === savesAtPublish,
    )
    await tab.assertThat(
      'and the plan is exactly where the publish left it',
      `document.querySelectorAll('.pv-frame').length === 4 && document.querySelectorAll('.pv-gap').length === 0`,
    )
    await tab.assertThat(
      'the badge has not moved',
      Math.abs(gateStill.x - gatePublished.x) <= 1 && Math.abs(gateStill.y - gatePublished.y) <= 1,
    )

    await tab.assertNoErrors()
  },
}
