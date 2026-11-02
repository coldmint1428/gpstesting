// Step 1's proof: the board answers a real click, a real drag and a real keystroke, keeps its answers across a
// reload, and two tabs do not share a selection.
//
//     node tools/run.mjs dev/checks/board-smoke.mjs
//
// Everything here is measured on the rendered page: .pv-frame count, the inspector's text, and an input's value.
// A screenshot is taken at the end so the same run leaves something to look at. Section 6 is the ownership picture:
// a badge a colleague is holding is marked, named, and refused -- snapped back, with the sentence in the strip.
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

    // ---------- 5. a real drag on a badge writes that badge, and it stays where it was put ----------
    // The write behind the gesture is frame_place_many (082): one cell, not the frame's whole map. Measured on the
    // rendered marker, so a badge that was moved on screen but never stored fails at the last assertion below.
    const markerLeft = () =>
      left.eval(`document.querySelectorAll('.pv-marker-wrap')[0].getBoundingClientRect().left`)
    await left.assertCount('.pv-marker-wrap', 3)
    const badgeBefore = await markerLeft()
    await left.drag('.pv-marker-wrap', 34, 0)
    const badgeAfter = await markerLeft()
    await left.assertThat('the badge followed the hand', badgeAfter > badgeBefore + 20)
    await left.assertCount('.pv-frame', 5) // a badge is not a new moment
    // Leave the frame and come back: the badge is drawn again from what the plan holds, so this is the write.
    await left.click('.pv-frame', { index: 0 })
    await left.assertContains('.pv-hint', 'Frame +0:00')
    await left.click('.pv-frame', { index: 2 })
    await left.assertContains('.pv-hint', 'Frame +2:50')
    await left.assertCount('.pv-marker-wrap', 3)
    const badgeKept = await markerLeft()
    await left.assertThat(
      'the badge stayed where it was put',
      badgeKept > badgeBefore + 20 && Math.abs(badgeKept - badgeAfter) < 3,
    )
    // The gesture let go when the hand came up. The hold is not a memory of the badge -- the fixture's `__planPreview`
    // is what the real page keeps in plan_cell_locks, and a hold nobody released would leave a colleague refused.
    await left.assertThat(
      'the hand coming up lets go of the badge',
      `globalThis.__planPreview.holds().mine.length === 0`,
    )

    // ---------- 6. a badge somebody else has says so, and does not move ----------
    // The ownership picture (081, and phase 3's UI): with a colleague's hand on a badge, the board draws a ring,
    // names them, and refuses a drag with the server's sentence instead of silently doing nothing. `?peer=1` is the
    // fixture's colleague, holding the badge the real plan_lock_cells would hold.
    const peer = await newTab({ label: 'peer', url: `${url}?peer=1`, width: 1200, height: 900 })
    await peer.waitFor('.pv-frame')
    await peer.assertCount('[data-testid=plan-badge]', 3)
    await peer.assertThat(
      'the badge somebody else is editing is marked as theirs',
      `document.querySelector('[data-testid=plan-badge][data-group="g2"]').dataset.hold === 'other'`,
    )
    await peer.assertThat(
      'and it says who, without being asked',
      `document.querySelector('[data-testid=plan-badge][data-group="g2"]').dataset.heldBy === 'Priya'`,
    )
    await peer.assertCount('[data-testid=plan-presence-chip]', 1)
    await peer.assertContains('[data-testid=plan-presence]', 'Priya')

    // A real drag on it: it follows the hand while the grab is in the air, and goes back when the refusal lands.
    const heldBadge = () =>
      peer.eval(`document.querySelector('[data-testid=plan-badge][data-group="g2"]').getBoundingClientRect().left`)
    const heldBefore = await heldBadge()
    await peer.drag('[data-testid=plan-badge][data-group="g2"]', 40, 0)
    await peer.sleep(250)
    const heldAfter = await heldBadge()
    await peer.assertThat('a badge somebody else holds did not move', Math.abs(heldAfter - heldBefore) < 3)
    await peer.assertContains('[data-testid=plan-refusal]', 'Priya is editing Sound at +0:00')

    // The same refusal through a different door: taking a badge off site is a position write too, so the strip says
    // no there as well -- and the badge is still on the map, because nothing was written.
    await peer.click('[data-testid=state-off][data-group="g2"]')
    await peer.assertContains('[data-testid=plan-refusal]', 'This badge stopped being yours to edit')
    await peer.assertCount('[data-testid=plan-badge][data-group="g2"]', 1)

    // The drag guard is the LOCAL switch (a slip of the finger), not the ownership of a badge -- and the word "lock"
    // belongs to it alone. The old test id is gone so nothing can pass by asking for the wrong one.
    await peer.assertCount('[data-testid=plan-drag-guard]', 1)
    await peer.assertCount('[data-testid=plan-lock]', 0)

    // ---------- 7. a badge is held while the hand is on it, and let go after five seconds of stillness ----------
    // The 5 s rule is the product's: a planner who stops moving stops holding, so a badge is not kept out of a
    // colleague's hands by somebody who walked away. The next movement takes it back silently -- and that is what
    // makes the write below possible, because a gesture that had not taken it back would have nothing to write with.
    // Driven with raw mouse events because the gesture has to STAY still for five seconds; a drag helper cannot.
    const free = await peer.rect('[data-testid=plan-badge][data-group="g1"]')
    await peer.mouse('mousePressed', free.x, free.y)
    for (let step = 1; step <= 10; step += 1) {
      await peer.mouse('mouseMoved', free.x + step * 3, free.y)
      await peer.sleep(16)
    }
    await peer.sleep(250)
    await peer.assertThat(
      'the badge is held while the hand is on it',
      `globalThis.__planPreview.holds().mine.includes('f1|g1')`,
    )
    await peer.sleep(5600) // five seconds of stillness, plus a margin
    await peer.assertThat(
      'and let go after five seconds without a movement',
      `globalThis.__planPreview.holds().mine.length === 0`,
    )
    for (let step = 1; step <= 6; step += 1) {
      await peer.mouse('mouseMoved', free.x + 30 + step * 2, free.y)
      await peer.sleep(16)
    }
    await peer.sleep(250)
    await peer.assertThat(
      'a movement takes it back, without a word',
      `globalThis.__planPreview.holds().mine.includes('f1|g1')`,
    )
    await peer.mouse('mouseReleased', free.x + 42, free.y)
    await peer.sleep(600)
    await peer.assertThat(
      'and the hand coming up lets go again',
      `globalThis.__planPreview.holds().mine.length === 0`,
    )
    await peer.assertThat(
      'the move it made while it was let go and taken back still landed',
      `document.querySelector('[data-testid=plan-badge][data-group="g1"]').getBoundingClientRect().left > ${free.x + 20}`,
    )

    await peer.shot('shots/step1-peer.png')
    await peer.assertNoErrors()
    await peer.close()

    // ---------- 8. `?concurrent=0` turns the picture off, not the rule ----------
    // The flag exists so the new UI can be looked at from the side; it deliberately cannot bring back the old write
    // path (082 refuses a badge map for a frame that already stands). So: no ring and no stack -- and a badge somebody
    // else has is still refused, by the database, with its sentence in the strip.
    const plain = await newTab({ label: 'plain', url: `${url}?concurrent=0&peer=1`, width: 1100, height: 850 })
    await plain.waitFor('.pv-frame')
    await plain.assertCount('[data-testid=plan-presence]', 0)
    await plain.assertThat(
      'with the flag off nobody is marked as editing',
      `document.querySelector('[data-testid=plan-badge][data-group="g2"]').dataset.hold === ''`,
    )
    await plain.drag('[data-testid=plan-badge][data-group="g2"]', 40, 0)
    await plain.assertContains('[data-testid=plan-refusal]', 'This badge stopped being yours to edit')
    await plain.assertNoErrors()
    await plain.close()

    // ---------- 9. a reload starts again from the fixtures ----------
    await left.reload()
    await left.waitFor('.pv-frame')
    await left.assertCount('.pv-frame', 5)
    await left.assertContains('.pv-hint', 'Frame +0:00')
    await left.assertThat(
      'after the reload the same plan is open',
      `document.querySelector('.pv-board-head select').selectedOptions[0].textContent.trim().replace(/\\s+/g, ' ').startsWith('Show night — example')`,
    )

    // ---------- 10. a second tab, opened on the same page, selects independently ----------
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
