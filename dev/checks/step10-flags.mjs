// Step 10's proof, through the browser: the board's flags -- a group off the map, and a position that must be
// confirmed by hand -- with the bulk controls writing a whole grid in one call.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql          # rebuilds the bench (required)
//     node tools/sql.mjs --file dev/checks/step10-verify-prep.sql         # adds "Flags bench" (required)
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json
//     node tools/run.mjs dev/checks/step10-flags.mjs --session .tmp/session.json
//
// "Flags bench" has three frames. +0:00 and +5:00 state Gate Crew, Sound and Backstage; +10:00 states only Sound, so
// the last frame carries the other two forward -- the case a confirmation must count and not invent.
//
// What it clicks through:
//   * the Done-when's first half: Gate Crew off site at +0:00 -> TWO markers instead of three, the row still listed
//     as "off site", the plan still legal, and exactly one frame_save; a reload keeps all of it;
//   * back on site -> three markers again;
//   * one position confirmed by hand -> ONE frame_set_verify and no frame_save, because a flag is not a save;
//   * tick two groups, select two frames, "By hand" -> ONE frame_set_verify for FOUR positions, the third group's
//     position and flag untouched;
//   * tick two groups on +5:00, "Off site" -> ONE frame_save, two badges gone and Backstage's badge on the same pixel
//     it had: the payload carried the frame's whole map, which is the trap step 10 names;
//   * at +10:00, where only Sound is stated, the other groups' confirmation chips are disabled and the bulk button
//     says it will confirm ONE position and leaves the two carried-forward cells alone.
//
// The check writes: it needs step10-verify-prep.sql before every run.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Flags bench'
const GATE = '0b000000-0000-4000-8000-00000000a001'
const SOUND = '0b000000-0000-4000-8000-00000000a002'
const BACKSTAGE = '0b000000-0000-4000-8000-00000000a003'
const SECURITY = '0b000000-0000-4000-8000-00000000a004'

/** Each dot's title: "Frame +1:00" or "Frame +1:00 — doors". The DOM order is the plan's time order. */
function frameTitles(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))`)
}

/** How many requests the page has made to one RPC. The browser's own record, not a count we keep. */
function rpcCalls(tab, name) {
  return tab.eval(`performance.getEntriesByType('resource')
    .filter((e) => e.name.includes('/rpc/${name}')).length`)
}

/** A group's badge, measured inside the map container (the page scrolls, the map does not). Null when not drawn. */
function markerAt(tab, title) {
  return tab.eval(`(() => {
    const map = document.querySelector('.pv-map').getBoundingClientRect()
    const el = document.querySelector('.leaflet-marker-icon[title=${JSON.stringify(title)}]')
    if (!el) return null
    const b = el.getBoundingClientRect()
    return {
      x: Math.round((b.left + b.width / 2 - map.left) * 10) / 10,
      y: Math.round((b.top + b.height / 2 - map.top) * 10) / 10,
    }
  })()`)
}

function markerCount(tab) {
  return tab.eval(`document.querySelectorAll('.pv-marker').length`)
}

/** The warning rows, as one sentence each. */
function gapTexts(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-gap-text')].map((e) => e.textContent.replace(/\\s+/g, ' ').trim())`)
}

/** What the inspector says beside one group's name on the open frame. */
function stateOf(tab, name) {
  return tab.eval(`(() => {
    const row = [...document.querySelectorAll('[data-testid=group-row]')]
      .find((r) => r.querySelector('.pv-group-name').textContent.trim() === ${JSON.stringify(name)})
    return row ? row.querySelector('.pv-group-state').textContent.trim() : null
  })()`)
}

/** A chip's on/off state, by group id and test id. Null when the chip is not on screen. */
function chipPressed(tab, groupId, testid) {
  return tab.eval(`(() => {
    const chip = document.querySelector('[data-testid=${testid}][data-group="${groupId}"]')
    return chip ? chip.getAttribute('aria-pressed') === 'true' : null
  })()`)
}

function chipDisabled(tab, groupId, testid) {
  return tab.eval(`(() => {
    const chip = document.querySelector('[data-testid=${testid}][data-group="${groupId}"]')
    return chip ? chip.disabled : null
  })()`)
}

function scopeText(tab) {
  return tab.text('[data-testid=verify-scope]')
}

function flagTarget(tab) {
  return tab.text('[data-testid=flag-target]')
}

/** The row index of a group in the tick list, for the harness's index-addressed click. */
async function groupRow(tab, name) {
  return tab.eval(`[...document.querySelectorAll('[data-testid=group-row]')]
    .findIndex((r) => r.querySelector('.pv-group-name').textContent.trim() === ${JSON.stringify(name)})`)
}

export default {
  name: 'flags — off site, confirmation, and the bulk controls that write a grid in one call',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load (five fixture plans plus "Flags bench" — run step10-verify-prep.sql)',
      timeout: 25000,
    })

    /** The page opens the newest plan on its own when it mounts; a change dispatched before that lands is lost. */
    async function boardMatchesPicker() {
      await tab.waitUntil(
        `(() => {
          const sel = document.querySelector('.pv-select')
          if (!sel || !sel.selectedOptions[0]) return false
          const m = sel.selectedOptions[0].textContent.match(/\\((\\d+)\\)/)
          return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
        })()`,
        { what: 'the board to show the plan the picker names', timeout: 20000 },
      )
    }

    /**
     * Pick "Flags bench", then wait for the plan itself: its three notes, the first frame open with its note in the
     * field, and the map's fit finished. A frame count alone is not a plan switch (finding 35); the strip's own
     * titles are.
     */
    async function openPlan() {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(PLAN)}))
        if (!opt) return 'no such option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      if (!picked.startsWith(PLAN)) throw new Error(`could not open "${PLAN}" — the picker offered "${picked}"`)
      tab.pass(`opened "${picked}"`)
      await tab.waitUntil(
        `(() => {
          const sel = document.querySelector('.pv-select')
          if (!sel || !sel.selectedOptions[0]) return false
          if (!sel.selectedOptions[0].textContent.trim().startsWith(${JSON.stringify(PLAN)})) return false
          const titles = [...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))
          if (titles.length !== 3) return false
          if (titles[0] !== 'Frame +0:00 — six flags' || titles[1] !== 'Frame +5:00 — nine flags' ||
              titles[2] !== 'Frame +10:00 — twelve flags') return false
          const note = document.querySelector('#pv-frame-note')
          if (!note || note.value !== 'six flags') return false
          return !document.querySelector('.leaflet-zoom-anim')
        })()`,
        { what: `the board to show ${PLAN} at +0:00`, timeout: 20000 },
      )
      await tab.sleep(250) // the map has stopped fitting; a press before now starts no drag (finding 33)
    }

    async function openMoment(index) {
      await tab.click('.pv-frame', { index })
      await tab.sleep(300)
    }

    /**
     * Press a chip or a bulk button only once it is enabled. Every write in this board sets `busy` for as long as the
     * save and the reads that follow it are in flight, and a disabled button swallows the press without a word -- the
     * check that clicked during a save waited for a request that was never made.
     */
    async function press(selector) {
      await tab.waitUntil(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); return !!el && !el.disabled })()`, {
        what: `${selector} to be ready to press`,
        timeout: 15000,
      })
      await tab.click(selector)
    }

    async function pressChip(groupId, testid) {
      await press(`[data-testid=${testid}][data-group="${groupId}"]`)
    }

    // ---------- 1. the plan opens legal, every position on site and trusted ----------
    await boardMatchesPicker()
    await openPlan()
    const titles = await frameTitles(tab)
    tab.pass(`strip: ${JSON.stringify(titles)}`)
    await tab.assertThat(
      'the strip is the plan asked for: three frames, three notes',
      titles.length === 3 &&
        titles[0] === 'Frame +0:00 — six flags' &&
        titles[1] === 'Frame +5:00 — nine flags' &&
        titles[2] === 'Frame +10:00 — twelve flags',
    )
    await tab.assertThat('three groups stand at +0:00, one badge each', (await markerCount(tab)) === 3)
    await tab.assertThat(
      'every row reads "set", and the groups this plan never places read "not yet placed"',
      (await stateOf(tab, 'Backstage')) === 'set' &&
        (await stateOf(tab, 'Gate Crew')) === 'set' &&
        (await stateOf(tab, 'Sound')) === 'set' &&
        (await stateOf(tab, 'Security')) === 'not yet placed',
    )
    await tab.assertThat(
      'every position is on site and trusted to begin with',
      (await chipPressed(tab, GATE, 'state-on')) === true &&
        (await chipPressed(tab, GATE, 'verify-auto')) === true &&
        (await chipPressed(tab, SOUND, 'verify-auto')) === true &&
        (await chipPressed(tab, BACKSTAGE, 'verify-auto')) === true,
    )
    await tab.assertThat(
      'a group this frame does not place has no chips to press',
      (await chipDisabled(tab, SECURITY, 'state-on')) === true &&
        (await chipDisabled(tab, SECURITY, 'verify-auto')) === true,
    )
    await tab.assertThat('opening a plan writes nothing', (await rpcCalls(tab, 'frame_save')) === 0)

    // ---------- 2. the Done-when, first half: one group off the map ----------
    await pressChip(GATE, 'state-off')
    await tab.waitUntil(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length === 1 &&
       document.querySelectorAll('.pv-marker').length === 2 &&
       !document.querySelector('.leaflet-marker-icon[title="Gate Crew"]')`,
      { what: 'the off-site group to lose its badge', timeout: 15000 },
    )
    await tab.sleep(250)
    tab.pass(`badges after the state change: ${await markerCount(tab)}`)
    await tab.assertThat('one group off site is one fewer marker', (await markerCount(tab)) === 2)
    await tab.assertThat(
      'the other two badges are still drawn',
      (await markerAt(tab, 'Sound')) !== null && (await markerAt(tab, 'Backstage')) !== null,
    )
    await tab.assertThat('the group is still listed, as "off site"', (await stateOf(tab, 'Gate Crew')) === 'off site')
    await tab.assertThat(
      'the row says which it is: on site off, off site on',
      (await chipPressed(tab, GATE, 'state-off')) === true && (await chipPressed(tab, GATE, 'state-on')) === false,
    )
    await tab.assertThat(
      'taking a group off the map wrote one frame and no confirmation',
      (await rpcCalls(tab, 'frame_save')) === 1 && (await rpcCalls(tab, 'frame_set_verify')) === 0,
    )
    await tab.assertThat(
      'the plan is still legal: an off-site position is not a walk',
      (await gapTexts(tab)).length === 0 && (await tab.eval(`!document.querySelector('.pv-badge.is-bad')`)) === true,
    )
    await tab.assertThat(
      'and the two groups that stayed kept their coordinates: the write carried the whole frame',
      (await markerAt(tab, 'Sound')) !== null && (await markerAt(tab, 'Backstage')) !== null,
    )
    await tab.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await tab.sleep(300)
    await tab.shot('shots/step10-flags.png')

    // ---------- 3. it came from the server, so a reload keeps it ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load again',
      timeout: 25000,
    })
    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-marker').length === 2`, {
      what: 'the off-site group to still have no badge',
      timeout: 15000,
    })
    await tab.assertThat(
      'after a reload Gate Crew is still off site and still listed, with two badges',
      (await stateOf(tab, 'Gate Crew')) === 'off site' &&
        (await markerCount(tab)) === 2 &&
        (await chipPressed(tab, GATE, 'state-off')) === true,
    )
    await tab.assertThat('a fresh page has written nothing', (await rpcCalls(tab, 'frame_save')) === 0)

    // ---------- 4. back on the map, at the place it already had ----------
    await pressChip(GATE, 'state-on')
    await tab.waitUntil(
      `document.querySelectorAll('.pv-marker').length === 3 &&
       !!document.querySelector('.leaflet-marker-icon[title="Gate Crew"]')`,
      { what: 'the group to come back on site', timeout: 15000 },
    )
    await tab.assertThat('putting it back on site draws three badges again', (await markerCount(tab)) === 3)
    await tab.assertThat('and the row says "set"', (await stateOf(tab, 'Gate Crew')) === 'set')
    await tab.assertThat('that is one more save, and still no confirmation', (await rpcCalls(tab, 'frame_save')) === 1)

    // ---------- 5. one position confirmed by hand: the batch function, not a save ----------
    await pressChip(SOUND, 'verify-manual')
    await tab.waitUntil(`performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_set_verify')).length === 1`, {
      what: 'one confirmation to reach the database',
      timeout: 15000,
    })
    await tab.waitUntil(`document.querySelector('[data-testid=verify-manual][data-group="${SOUND}"]').getAttribute('aria-pressed') === 'true'`, {
      what: 'the chip to read back as manual',
      timeout: 15000,
    })
    await tab.assertThat(
      'confirming one position is one frame_set_verify and no frame_save',
      (await rpcCalls(tab, 'frame_set_verify')) === 1 && (await rpcCalls(tab, 'frame_save')) === 1,
    )
    await tab.assertThat(
      'the other two groups are still trusted as drawn',
      (await chipPressed(tab, GATE, 'verify-auto')) === true && (await chipPressed(tab, BACKSTAGE, 'verify-auto')) === true,
    )
    // Back to trusted, so the bulk below changes all four cells and its count is a count of the whole grid.
    await pressChip(SOUND, 'verify-auto')
    await tab.waitUntil(`document.querySelector('[data-testid=verify-auto][data-group="${SOUND}"]').getAttribute('aria-pressed') === 'true'`, {
      what: 'the chip to read back as automatic',
      timeout: 15000,
    })
    await tab.assertThat(
      'the same control lets the app trust it again: two flags, still one save',
      (await rpcCalls(tab, 'frame_set_verify')) === 2 && (await rpcCalls(tab, 'frame_save')) === 1,
    )

    // ---------- 6. the bulk confirmation: two frames, two groups, four positions, one call ----------
    await tab.click('[data-testid=group-row]', { index: await groupRow(tab, 'Gate Crew') })
    await tab.click('[data-testid=group-row]', { index: await groupRow(tab, 'Sound') })
    await tab.click('.pv-frame', { index: 1, modifiers: 8 }) // Shift+click +5:00: select both frames
    await tab.sleep(200)
    await tab.assertThat(
      'two frames and two groups are selected',
      (await tab.eval(`document.querySelectorAll('.pv-frame.is-selected').length`)) === 2 &&
        (await tab.eval(`!!document.querySelector('[data-testid=selection-band]')`)) === true,
    )
    const scope = await scopeText(tab)
    tab.pass(`the confirmation panel says: ${JSON.stringify(scope)}`)
    await tab.assertThat('the panel counts four positions, two of them per frame', scope.trim() === 'Confirm 4 positions in 2 frames')
    await tab.assertThat('and it names the two groups it will touch', (await flagTarget(tab)).includes('Gate Crew and Sound'))

    await press('[data-testid=bulk-verify-manual]')
    await tab.waitUntil(`performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_set_verify')).length === 3`, {
      what: 'one batch call for the whole grid',
      timeout: 15000,
    })
    await tab.waitForText('[data-testid=toasts]', '4 positions confirmed by hand across 2 frames')
    await tab.assertThat(
      'the grid is ONE frame_set_verify, not one save per frame',
      (await rpcCalls(tab, 'frame_set_verify')) === 3 && (await rpcCalls(tab, 'frame_save')) === 1,
    )

    // Read the result at +5:00, where the chips exist again: the two named groups are manual, the third is not.
    await openMoment(1)
    await tab.assertThat(
      'only the two named groups changed: Gate Crew and Sound are manual, Backstage is untouched',
      (await chipPressed(tab, GATE, 'verify-manual')) === true &&
        (await chipPressed(tab, SOUND, 'verify-manual')) === true &&
        (await chipPressed(tab, BACKSTAGE, 'verify-auto')) === true,
    )
    await tab.assertThat(
      'and every position survived: three badges, all three rows "set"',
      (await markerCount(tab)) === 3 &&
        (await stateOf(tab, 'Gate Crew')) === 'set' &&
        (await stateOf(tab, 'Sound')) === 'set' &&
        (await stateOf(tab, 'Backstage')) === 'set',
    )

    // ---------- 7. the bulk state control sends the whole map ----------
    const backstage = await markerAt(tab, 'Backstage')
    tab.pass(`Backstage stands at ${JSON.stringify(backstage)} at +5:00`)
    await press('[data-testid=bulk-state-off]')
    await tab.waitUntil(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length === 2 &&
       document.querySelectorAll('.pv-marker').length === 1`,
      { what: 'two groups to leave the map in one write', timeout: 15000 },
    )
    await tab.sleep(250)
    await tab.assertThat(
      'the two ticked groups are off site, with one badge left',
      (await markerCount(tab)) === 1 &&
        (await stateOf(tab, 'Gate Crew')) === 'off site' &&
        (await stateOf(tab, 'Sound')) === 'off site',
    )
    await tab.assertThat(
      'the third group is untouched: still "set", its badge on the same pixel',
      (await stateOf(tab, 'Backstage')) === 'set' &&
        JSON.stringify(await markerAt(tab, 'Backstage')) === JSON.stringify(backstage),
    )
    await tab.assertThat(
      'and it was one save, with no confirmation calls added',
      (await rpcCalls(tab, 'frame_save')) === 2 && (await rpcCalls(tab, 'frame_set_verify')) === 3,
    )
    await tab.waitForText('[data-testid=toasts]', 'Gate Crew and Sound are off site at +5:00')

    await press('[data-testid=bulk-state-on]')
    await tab.waitUntil(`document.querySelectorAll('.pv-marker').length === 3`, {
      what: 'the two groups to come back', timeout: 15000,
    })
    await tab.assertThat('bringing them back draws three badges', (await markerCount(tab)) === 3)

    // ---------- 8. a frame that carries a group forward cannot confirm it ----------
    await openMoment(2)
    await tab.assertThat(
      'at +10:00 only Sound is stated; the other two are carried forward',
      (await stateOf(tab, 'Sound')) === 'set' &&
        (await stateOf(tab, 'Gate Crew')) === 'same' &&
        (await stateOf(tab, 'Backstage')) === 'same',
    )
    await tab.assertThat(
      "so their confirmation chips are disabled, and Sound's is not",
      (await chipDisabled(tab, GATE, 'verify-manual')) === true &&
        (await chipDisabled(tab, BACKSTAGE, 'verify-manual')) === true &&
        (await chipDisabled(tab, SOUND, 'verify-manual')) === false,
    )
    // Clear the ticks: with nothing ticked the flags act on everyone standing here, which is the case the
    // carried-forward frames have to count honestly.
    await tab.click('[data-testid=group-row]', { index: await groupRow(tab, 'Gate Crew') })
    await tab.click('[data-testid=group-row]', { index: await groupRow(tab, 'Sound') })
    const scopeOne = await scopeText(tab)
    tab.pass(`the confirmation panel says: ${JSON.stringify(scopeOne)}`)
    await tab.assertThat('the panel counts the one position this frame states', scopeOne.trim() === 'Confirm 1 position in 1 frame')
    await tab.assertThat('and names all three groups standing here', (await flagTarget(tab)).includes('Backstage, Gate Crew and Sound'))

    await press('[data-testid=bulk-verify-manual]')
    await tab.waitUntil(`performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_set_verify')).length === 4`, {
      what: 'the confirmation call', timeout: 15000,
    })
    await tab.waitForText('[data-testid=toasts]', '2 left alone')
    await tab.assertThat(
      'one position confirmed, and the two cells that frame does not state are reported, not invented',
      (await chipPressed(tab, SOUND, 'verify-manual')) === true &&
        (await stateOf(tab, 'Sound')) === 'set' &&
        (await stateOf(tab, 'Gate Crew')) === 'same',
    )
  },
}
