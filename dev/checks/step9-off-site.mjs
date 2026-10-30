// Step 9's proof, through the browser: a group can be off site at a moment, and the board stops calling that moment
// an impossible walk -- without forgetting that the group is there.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql          # rebuilds the bench (required)
//     node tools/sql.mjs --file dev/checks/step9-off-site-prep.sql        # adds "Off-site twin" (required)
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json
//     node tools/run.mjs dev/checks/step9-off-site.mjs --session .tmp/session.json
//
// Two plans, one flag apart. "Twin gap" is the fixture's: both groups are 200 m east between +0:00 and +5:00, and the
// board reports both breaks. "Off-site twin" has the same coordinates to the digit, with Gate Crew's arrival marked
// off site -- so the only thing that changed is the flag, and the check can say what the flag did.
//
// What it clicks through:
//   * the control: Twin gap shows 2 breaks, two warning rows, two red bands, and both group rows flagged;
//   * Off-site twin shows 1 -- Sound's, still 200 m -- one band, and no mention of Gate Crew in the warnings;
//   * the group is still LISTED: at +5:00 its row says "off site", and the map draws ONE badge, not two: a position
//     that is not on the map is not a person standing there (step 10's marker treatment; step 9 drew it hollow while
//     the toggle did not exist yet);
//   * at +0:00 the same group is ordinary -- the flag belongs to the position, not the group;
//   * after a reload the word and the single warning are still there, because they came from the server.
//
// Until step 10 there was no way to make a group off site from the board; the flag is set by
// step9-off-site-prep.sql. Step 10 owns the toggle, the confirmation chips and the bulk writes, and proves them in
// dev/checks/step10-flags.mjs -- this check stays about what the flag means to the 25 m rule.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Twin gap'
const OFF_PLAN = 'Off-site twin'
const GATE = '0b000000-0000-4000-8000-00000000a001'

/** Each dot's title: "Frame +1:00" or "Frame +1:00 — doors". The DOM order is the plan's time order. */
function frameTitles(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))`)
}

/** How many requests the page has made to one RPC. The browser's own record, not a count we keep. */
function rpcCalls(tab, name) {
  return tab.eval(`performance.getEntriesByType('resource')
    .filter((e) => e.name.includes('/rpc/${name}')).length`)
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

/** The groups whose inspector row is flagged red on this frame. */
function badRows(tab) {
  return tab.eval(`[...document.querySelectorAll('[data-testid=group-row].is-bad')]
    .map((r) => r.querySelector('.pv-group-name').textContent.trim())`)
}

export default {
  name: 'off site — a position that is not on the map stops being an impossible walk, and stays in the plan',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load (five fixture plans plus "Off-site twin" — run step9-off-site-prep.sql)',
      timeout: 25000,
    })

    /**
     * The page opens the newest plan on its own when it mounts, and a change dispatched into the picker before that
     * load finishes is overwritten by it (step 7 met the same race). Waiting for the picker and the board to agree is
     * what a person does by looking at the screen before touching it.
     */
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
     * Pick a plan by name, then wait for the board to show *that* plan.
     *
     * A frame count is not enough, and neither is the picker: "Twin gap" and "Off-site twin" hold two frames each and
     * share the same two notes, so the board can still be showing the plan it opened by itself while the picker
     * already says otherwise (the select's value comes from `plan`, which changes before the frames do). The strip's
     * own titles plus the warning the plan earns are what actually say the load has landed -- and for these two plans
     * the warning is also the only thing that tells them apart.
     */
    async function openPlan(name, badge) {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
        if (!opt) return 'no such option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      if (!picked.startsWith(name)) throw new Error(`could not open "${name}" — the picker offered "${picked}"`)
      tab.pass(`opened "${picked}"`)
      await tab.waitUntil(
        `(() => {
          const sel = document.querySelector('.pv-select')
          if (!sel || !sel.selectedOptions[0]) return false
          if (!sel.selectedOptions[0].textContent.trim().startsWith(${JSON.stringify(name)})) return false
          const titles = [...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))
          if (titles.length !== 2 || titles[0] !== 'Frame +0:00 — both here' || titles[1] !== 'Frame +5:00 — both there') {
            return false
          }
          const bad = document.querySelector('.pv-badge.is-bad')
          if (!bad || bad.textContent.trim() !== ${JSON.stringify(badge)}) return false
          return !document.querySelector('.leaflet-zoom-anim')
        })()`,
        { what: `the board to show ${name} (${badge})`, timeout: 20000 },
      )
      await tab.sleep(250) // the map has stopped fitting; a press before now starts no drag (finding 33)
    }

    async function openMoment(index) {
      await tab.click('.pv-frame', { index })
      await tab.sleep(300)
    }

    // ---------- 1. the control: Twin gap, where both groups really do walk 200 m ----------
    await boardMatchesPicker()
    await openPlan(PLAN, '2 too far apart')
    const controlTitles = await frameTitles(tab)
    tab.pass(`Twin gap strip: ${JSON.stringify(controlTitles)}`)
    await tab.assertThat(
      'the control plan opens on +0:00 / +5:00',
      controlTitles.length === 2 && controlTitles[0].startsWith('Frame +0:00') && controlTitles[1].startsWith('Frame +5:00'),
    )
    await tab.assertThat(
      'the control plan reports both breaks in its badge',
      `document.querySelector('.pv-badge.is-bad').textContent.trim() === '2 too far apart'`,
    )
    const controlGaps = await gapTexts(tab)
    tab.pass(`Twin gap warnings: ${JSON.stringify(controlGaps)}`)
    await tab.assertThat(
      'both 200 m walks are reported, one row each',
      controlGaps.length === 2 &&
        controlGaps.some((t) => t.startsWith('Gate Crew: 200 m')) &&
        controlGaps.some((t) => t.startsWith('Sound: 200 m')),
    )
    await tab.assertThat('and both stretches are banded on the bar', `document.querySelectorAll('.pv-band').length === 2`)

    await openMoment(1)
    const controlBad = await badRows(tab)
    tab.pass(`Twin gap, +5:00 flagged: ${JSON.stringify(controlBad)}`)
    await tab.assertThat(
      'at +5:00 both groups are still on the map and both rows are flagged',
      controlBad.length === 2 && controlBad.includes('Gate Crew') && controlBad.includes('Sound'),
    )
    await tab.assertThat(
      'and both rows read "set" — this frame states where they are',
      (await stateOf(tab, 'Gate Crew')) === 'set' && (await stateOf(tab, 'Sound')) === 'set',
    )
    await tab.assertThat('with two badges on the map', (await markerCount(tab)) === 2)

    // ---------- 2. the same walk, one flag apart ----------
    await openPlan(OFF_PLAN, '1 too far apart')
    await tab.assertThat(
      'the off-site plan reports one break in its badge',
      `document.querySelector('.pv-badge.is-bad').textContent.trim() === '1 too far apart'`,
    )
    const offGaps = await gapTexts(tab)
    tab.pass(`Off-site twin warnings: ${JSON.stringify(offGaps)}`)
    await tab.assertThat(
      'the off-site group is not reported, and the one that really walks still is',
      offGaps.length === 1 && offGaps[0].startsWith('Sound: 200 m between +0:00 and +5:00'),
    )
    await tab.assertThat(
      'Gate Crew is no longer named anywhere in the warnings',
      (await tab.eval(`document.querySelector('.pv-warnings').textContent.includes('Gate Crew')`)) === false,
    )
    await tab.assertThat('one band on the bar, not two', `document.querySelectorAll('.pv-band').length === 1`)

    // The flag belongs to the position, not the group: at +0:00 Gate Crew is an ordinary badge.
    await tab.assertThat(
      'at +0:00 the same group is on site: an ordinary badge, and "set"',
      (await markerCount(tab)) === 2 && !(await tab.eval(`!!document.querySelector('.pv-marker.is-offsite')`)),
    )
    await tab.assertThat('its row says "set" there', (await stateOf(tab, 'Gate Crew')) === 'set')

    // ---------- 3. listed, not drawn, and not measured ----------
    await openMoment(1)
    await tab.waitUntil(`document.querySelectorAll('.pv-marker').length === 1 && !document.querySelector('.leaflet-marker-icon[title="Gate Crew"]')`, {
      what: 'the off-site group to have no badge at all',
      timeout: 15000,
    })
    const offBad = await badRows(tab)
    tab.pass(`Off-site twin, +5:00 flagged: ${JSON.stringify(offBad)}`)
    await tab.assertThat('only the group that walks is flagged', offBad.length === 1 && offBad[0] === 'Sound')
    await tab.assertThat('the off-site group is still listed, as "off site"', (await stateOf(tab, 'Gate Crew')) === 'off site')
    await tab.assertThat('and it is still listed with "set" for the walking group', (await stateOf(tab, 'Sound')) === 'set')
    await tab.assertThat(
      'the map draws one badge, for the group that is really there — no marker for the off-site group',
      (await markerCount(tab)) === 1 &&
        (await tab.eval(`!!document.querySelector('.leaflet-marker-icon[title="Sound"]')`)) === true &&
        (await tab.eval(`!!document.querySelector('.leaflet-marker-icon[title="Gate Crew"]')`)) === false,
    )
    await tab.assertThat(
      'and nothing is drawn hollow any more: off site is absent from the map, not a place on it',
      (await tab.eval(`document.querySelectorAll('.pv-marker.is-offsite').length`)) === 0,
    )
    await tab.assertThat('the frame is still on the strip', (await frameTitles(tab)).length === 2)
    await tab.assertThat('nothing was written just by opening the plan', (await rpcCalls(tab, 'frame_save')) === 0)

    // ---------- 4. it came from the server, so a reload keeps it ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 6`, {
      what: 'the plan list to load again',
      timeout: 25000,
    })
    await boardMatchesPicker()
    await openPlan(OFF_PLAN, '1 too far apart')
    await openMoment(1)
    await tab.waitUntil(`document.querySelectorAll('.pv-marker').length === 1`, {
      what: 'the single badge after a fresh read',
      timeout: 15000,
    })
    await tab.assertThat(
      'after a reload the group is still off site, the map still draws one badge, and the plan still reports one break',
      (await stateOf(tab, 'Gate Crew')) === 'off site' &&
        (await markerCount(tab)) === 1 &&
        (await gapTexts(tab)).length === 1,
    )

    await tab.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await tab.sleep(300)
    await tab.shot('shots/step9-off-site.png')
  },
}
