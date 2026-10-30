// Ctrl+C and Ctrl+V are the Copy and Paste buttons for a planner working on the map, and they must not steal the
// keys from a field: Ctrl+C in the note field copies the words being typed, and a paste after that must not
// suddenly create a frame.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/run.mjs dev/checks/shortcuts.mjs --session .tmp/session.json
//
// HOW THE KEY GETS THERE, AND WHY IT IS NOT A TRUSTED PRESS. A real Ctrl+C through the DevTools input pipeline
// wedges this sandbox's headless Edge: the browser's copy command reaches for the OS clipboard, the renderer
// blocks, and every later CDP call times out (three of five attempts hung; the two that returned were identical
// code paths). So the key is dispatched as a DOM KeyboardEvent on the focused element — the board's real
// `keydown` listener, the real guard and the real handler run, and the event's `defaultPrevented` says whether
// the board claimed the key. What this cannot prove is that the platform delivers a physical Ctrl+C to the
// page; what it does prove is that the page does the right thing when it arrives. The buttons themselves are
// proved with trusted clicks in dev/checks/step4-copy-paste.mjs, so the shortcut only has to be shown to call
// the same two functions.
//
// Rebuilding the bench first matters: this check pastes a frame and leaves it there, so a second run without a
// rebuild starts at three frames and fails on "exactly two" rather than measuring a fresh paste. Ctrl+Z is not
// tested here on purpose: undo arrives with the inverse stack in step 13.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Copy bench'

/** Send a key the way the board's listener sees it, and report whether the board claimed (cancelled) it. */
function sendKey(tab, key) {
  return tab.eval(`(() => {
    const target = document.activeElement || document.body
    const event = new KeyboardEvent('keydown', {
      key: ${JSON.stringify(key)},
      ctrlKey: true,
      bubbles: true,
      cancelable: true,
    })
    target.dispatchEvent(event)
    return { target: target.tagName + (target.id ? '#' + target.id : ''), claimed: event.defaultPrevented }
  })()`)
}

export default {
  name: 'keyboard — Ctrl+C copies the open frame, Ctrl+V pastes it, typing keeps the keys',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load (three plans in the bench)',
    })
    await tab.eval(`(() => {
      const sel = document.querySelector('.pv-select')
      const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(PLAN)}))
      if (sel.value !== opt.value) {
        sel.value = opt.value
        sel.dispatchEvent(new Event('change'))
      }
      return true
    })()`)
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the copy bench to hold exactly two frames (rebuild the fixture if it does not)',
    })
    // The plan opens on its first frame asynchronously: waiting for the frames alone can catch the board between
    // "frames loaded" and "a frame is selected", and a click in that gap is then overwritten. A selected dot is
    // the board saying it is ready to be pointed at a moment.
    await tab.waitUntil(`!!document.querySelector('.pv-frame.is-selected')`, { what: 'the board to open a frame' })
    // The inspector renders with the selection and the board gets taller, so the bar (and its dots) move down once.
    // A click measured before that lands on nothing at all, which reads as "the shortcut is broken" -- it is not.
    await tab.sleep(300)
    await tab.click('.pv-frame', { index: 1 })
    await tab.waitUntil(`document.querySelector('.pv-hint').textContent.includes('Frame +1:00')`, {
      what: 'frame +1:00 to open',
    })

    // ---------- 1. the keys in a field belong to the field ----------
    // Nothing has been copied from the board yet, so if the in-field Ctrl+C reached the board, this paste would
    // create a frame. It must not: the board must not even claim the key.
    await tab.click('#pv-frame-note')
    const inField = await sendKey(tab, 'c')
    tab.pass(`Ctrl+C with focus in the note field: ${JSON.stringify(inField)}`)
    await tab.assertThat('the board does not claim Ctrl+C while a field has focus', inField.claimed === false)
    await tab.assertThat('the keystroke was sent to the note field', inField.target === 'INPUT#pv-frame-note')

    await tab.click('.pv-frame', { index: 1 })
    await tab.assertThat(
      'clicking a frame gives the keyboard back to the board (the note field lets go)',
      `document.activeElement.id !== 'pv-frame-note'`,
    )
    const pasteWithoutCopy = await sendKey(tab, 'v')
    tab.pass(`Ctrl+V after that: ${JSON.stringify(pasteWithoutCopy)}`)
    await tab.assertThat('the board does not claim Ctrl+V with nothing on its clipboard', pasteWithoutCopy.claimed === false)
    await tab.sleep(600)
    await tab.assertCount('.pv-frame', 2)
    await tab.assertThat(
      'no frame was pasted from a clipboard the board never filled',
      `!/Copied \\+/.test(document.querySelector('[data-testid=toasts]').textContent)`,
    )

    // ---------- 2. the keys on the board copy and paste the open frame ----------
    const copy = await sendKey(tab, 'c')
    tab.pass(`Ctrl+C on the board: ${JSON.stringify(copy)}`)
    await tab.assertThat('the board claims Ctrl+C when the focus is not in a field', copy.claimed === true)
    await tab.waitUntil(`document.querySelector('[data-testid=toasts]').textContent.includes('Copied +1:00')`, {
      what: 'the copy confirmation from the keyboard',
    })
    await tab.assertThat(
      'paste is available after a keyboard copy',
      `!document.querySelector('[data-testid=frame-paste]').disabled`,
    )

    const paste = await sendKey(tab, 'v')
    tab.pass(`Ctrl+V on the board: ${JSON.stringify(paste)}`)
    await tab.assertThat('the board claims Ctrl+V once something is on its clipboard', paste.claimed === true)
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      what: 'the pasted frame to appear',
      timeout: 12000,
    })
    await tab.waitUntil(`document.querySelector('.pv-hint').textContent.includes('Frame +2:00')`, {
      what: 'the pasted frame to open',
    })
    const states = await tab.eval(`Object.fromEntries([...document.querySelectorAll('.pv-group-row')].map((row) => [
      row.querySelector('.pv-group-name').textContent.trim(),
      row.querySelector('.pv-group-state').textContent.trim(),
    ]))`)
    tab.pass(`states at +2:00: ${JSON.stringify(states)}`)
    await tab.assertThat(
      'the keyboard paste carries all three groups, not just the stated one',
      states['Gate Crew'] === 'set' && states['Sound'] === 'set' && states['Backstage'] === 'set',
    )
    await tab.assertThat(
      'the note came across with the frame',
      `document.querySelector('#pv-frame-note').value === 'one here'`,
    )
    await tab.assertCount('.pv-marker', 3)

    await tab.shot('shots/shortcuts.png')
    await tab.assertNoErrors()
  },
}
