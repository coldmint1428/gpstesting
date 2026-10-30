// Step 1's proof: the board answers a real click, a real drag and a real keystroke, keeps its answers across a
// reload, and two tabs do not share a selection.
//
//     node tools/run.mjs dev/checks/board-smoke.mjs
//
// Everything here is measured on the rendered page: .pv-frame count, the inspector's text, and an input's value.
// A screenshot is taken at the end so the same run leaves something to look at.
export default {
  name: 'board smoke — click, type, drag, reload, and two tabs that stay independent',

  async run({ newTab, base }) {
    const url = `${base}/dev/preview.html`

    // ---------- 1. load, and the page is the page we think it is ----------
    const left = await newTab({ label: 'left', url, width: 1440, height: 1000 })
    await left.waitFor('.pv-frame')
    await left.assertCount('.pv-frame', 5)
    // The plan picker's visible text, not the whole header: a <select>'s innerText contains every option, so
    // "the header mentions the plan" would also be true while a different plan is open.
    await left.assertThat(
      'the open plan is Show night — example',
      `document.querySelector('.pv-board-head select').selectedOptions[0].textContent.trim().replace(/\\s+/g, ' ').startsWith('Show night — example')`,
    )
    // The board opens on the first frame, so there is always something on the map.
    await left.assertContains('.pv-hint', 'Frame +0:00')

    // ---------- 2. a real click opens a frame ----------
    await left.click('.pv-frame', { index: 2 })
    await left.assertContains('.pv-hint', 'Frame +2:00')
    await left.assertThat('#pv-frame-time reads +2:00', `document.querySelector('#pv-frame-time').value === '+2:00'`)

    // ---------- 3. a real drag moves that frame along the bar ----------
    // 55 px at 1.1 px per second is 50 s, and the bar snaps to 5 s: 120 + 50 = +2:50.
    await left.drag('.pv-frame', 55, 0, { index: 2 })
    await left.assertContains('.pv-hint', 'Frame +2:50')
    await left.assertCount('.pv-frame', 5)

    // ---------- 4. a real keystroke edits the frame's note, and it is still there after another frame ----------
    await left.type('#pv-frame-note', 'doors')
    await left.press('Enter')
    await left.assertThat('#pv-frame-note keeps the note', `document.querySelector('#pv-frame-note').value === 'doors'`)
    // The note is on the frame, not only in the field: the dot's title carries it.
    await left.assertThat(
      'the note reaches the frame, not just the field',
      `document.querySelectorAll('.pv-frame')[2].getAttribute('title').includes('— doors')`,
    )
    await left.click('.pv-frame', { index: 0 })
    await left.assertContains('.pv-hint', 'Frame +0:00')
    // +2:50 and +3:00 are ten seconds apart, which at the default scale is 11 px: two dots whose 22 px boxes overlap,
    // and the one drawn later wins the hit test (finding 25). Zoom in before clicking, the way a person would.
    await left.click('[data-testid=zoom-in]')
    await left.click('[data-testid=zoom-in]')
    await left.sleep(150)
    await left.click('.pv-frame', { index: 2 })
    await left.assertContains('.pv-hint', 'Frame +2:50')
    await left.assertThat(
      'the note survives leaving the frame',
      `document.querySelector('#pv-frame-note').value === 'doors'`,
    )

    // ---------- 5. a reload starts again from the fixtures ----------
    await left.reload()
    await left.waitFor('.pv-frame')
    await left.assertCount('.pv-frame', 5)
    await left.assertContains('.pv-hint', 'Frame +0:00')
    await left.assertThat(
      'after the reload the same plan is open',
      `document.querySelector('.pv-board-head select').selectedOptions[0].textContent.trim().replace(/\\s+/g, ' ').startsWith('Show night — example')`,
    )

    // ---------- 6. a second tab, opened on the same page, selects independently ----------
    const right = await newTab({ label: 'right', url, width: 900, height: 800 })
    await right.waitFor('.pv-frame')
    await right.assertCount('.pv-frame', 5)
    await right.click('.pv-frame', { index: 1 })
    await right.assertContains('.pv-hint', 'Frame +1:00')

    await left.click('.pv-frame', { index: 4 })
    await left.assertContains('.pv-hint', 'Frame +4:00')

    // Neither tab's selection leaked into the other: this is the assertion the earlier tool could not make.
    await right.assertContains('.pv-hint', 'Frame +1:00')
    await left.assertContains('.pv-hint', 'Frame +4:00')

    await left.shot('shots/step1-left.png')
    await right.shot('shots/step1-right.png')

    await left.assertNoErrors()
    await right.assertNoErrors()
  },
}
