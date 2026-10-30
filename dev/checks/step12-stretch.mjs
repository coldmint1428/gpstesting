// Step 12's proof, through the browser: the whole impossible stretch is marked, and the door still refuses both hops.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql        # rebuilds the bench
//     node tools/sql.mjs --file dev/checks/step12-stretch-prep.sql      # the ten-frame strip (required)
//     node tools/run.mjs dev/checks/step12-stretch.mjs --session .tmp/session.json
//
// The rule itself lives in the database (049, proved in dev/checks/step12-cumulative.sql). What this check is for is the
// picture: the 25 m rule is a budget per frame step, so a frame dragged away breaks the hops either side of it and the
// whole stretch -- the frames in between, not just the two statements -- is what has to be re-spaced. The board used to
// mark only the two ends of each hop, and to report a walk from whatever frame it last looked at rather than from the
// frame that stated the position.
//
// The bench plan "Stretch bench" is the Done-when's strip: ten frames, fifteen seconds apart, Gate Crew in one place
// across all of them, and Sound standing still 100 m east (the ruler, and the group whose lane must stay clean).
//
// The check drags the badge on the middle frame (+1:15) about 200 m east -- the one write in it -- and then measures:
//   * the two neighbouring hops are the only breaks: 2 rows, each naming Gate Crew and its own pair of moments;
//   * every frame in the stretch is marked: exactly 3 red dots, on +1:00 / +1:15 / +1:30, and one band across them;
//   * the inspector names the group and the span, so the red dot says why it is red;
//   * the lane, the badge ring and the map agree with the rows, and Sound's lane stays clean;
//   * Publish is still refused, for these two hops, in words that name the 25 m limit.
// Then a reload: the same three dots and the same two rows, because this is the plan and not the screen.
//
// Re-run the prep before a second run: the check leaves the strip with a 200 m hop.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const STRIP = 'Stretch bench'

const toastText = `((document.querySelector('[data-testid=toasts]') || {}).textContent || '')`
const toastHas = (needle) => `${toastText}.includes(${JSON.stringify(needle)})`

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

/** The dots on the time bar that the board has marked, in strip order, by the moment each one names. */
function badDots(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')]
    .filter((b) => b.classList.contains('is-bad'))
    .map((b) => b.title.replace(/^Frame /, ''))`)
}

/** The warning rows, whitespace collapsed: ["Gate Crew: 198 m between +1:00 and +1:15 (limit 25 m)", ...]. */
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

export default {
  name: 'cumulative stretch — one frame dragged away marks every frame in the stretch, and both hops are refused',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 5`, {
      what: 'the plan list to load (rebuild the fixture if it is short)',
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
        if (!opt) return 'no "${name}" option'
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

    async function openTheStrip() {
      await boardMatchesPicker()
      await openPlan(STRIP)
      await tab.waitUntil(
        `document.querySelectorAll('.pv-frame').length === 10 &&
         document.querySelector('.pv-select').selectedOptions[0].textContent.includes(${JSON.stringify(STRIP)})`,
        { what: 'the ten frames of the stretch bench (run dev/checks/step12-stretch-prep.sql first)' },
      )
      // The map animates its fit for a quarter second; pressing on a badge while it is still travelling starts no drag.
      await tab.waitUntil(`!document.querySelector('.leaflet-zoom-anim')`, { what: 'the map to stop fitting' })
      await tab.sleep(250)
      // 15 s apart is 16 px at the default scale, and one dot's box overlaps the next: zoom the bar in twice so a dot
      // can be clicked on its own (the same trick step 5 uses for a 13 s gap).
      await tab.click('[data-testid=zoom-in]')
      await tab.click('[data-testid=zoom-in]')
      await tab.sleep(150)
    }

    await openTheStrip()

    // ---------- 1. the strip is legal before anything is dragged ----------
    await tab.assertThat(
      'the strip is the fixture: ten frames and nothing wrong with them',
      `document.querySelectorAll('.pv-frame').length === 10 &&
       document.querySelectorAll('.pv-gap').length === 0 &&
       !document.querySelector('.pv-badge.is-bad') &&
       document.querySelectorAll('.pv-frame.is-bad').length === 0`,
    )

    // ---------- 2. the middle frame, and what it does not yet say ----------
    await openFrame(5, '+1:15')
    await tab.assertThat(
      'a legal frame is not inside any stretch',
      `!document.querySelector('[data-testid=frame-stretch]')`,
    )

    // The map is its own ruler: Sound stands 100 m east of Gate Crew in the fixture, and both badges are drawn.
    const gateBefore = await markerAt(tab, 'Gate Crew')
    const soundBefore = await markerAt(tab, 'Sound')
    tab.pass(`badges at +1:15: ${JSON.stringify({ gate: gateBefore, sound: soundBefore })}`)
    const ruler = Math.abs(soundBefore.x - gateBefore.x)
    const mPerPx = 100 / ruler
    tab.pass(`the map's own ruler: ${ruler.toFixed(1)} px between Gate Crew and Sound, ${mPerPx.toFixed(3)} m/px`)
    await tab.assertThat(
      'the two badges are far enough apart to measure a metre by',
      ruler > 20 && mPerPx > 0.2 && mPerPx < 2,
    )
    const mapWidth = await tab.eval(`document.querySelector('.pv-map').getBoundingClientRect().width`)
    const dx = Math.round(200 / mPerPx)
    tab.pass(`200 m east is ${dx} px at this zoom`)
    await tab.assertThat(
      'and there is room on the map to drag that far without reaching the edge',
      gateBefore.x + dx < mapWidth - 30 && gateBefore.x > 20,
    )

    // ---------- 3. the drag: one write, and both neighbouring hops break ----------
    const callsBefore = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length`,
    )
    await tab.drag('.leaflet-marker-icon[title="Gate Crew"]', dx, 0, { steps: 20, settle: 250 })
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'the two hops either side of the dragged frame to break',
      timeout: 12000,
    })
    const callsAfter = await tab.eval(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('/rpc/frame_save')).length`,
    )
    await tab.assertThat('one drag is one save', callsAfter - callsBefore === 1)

    const rows = await gapRows(tab)
    tab.pass(`rows: ${JSON.stringify(rows)}`)
    await tab.assertThat('the two neighbouring hops are the only breaks', rows.length === 2)
    await tab.assertThat(
      'each row names Gate Crew and its own 200 m',
      rows.every((text) => text.startsWith('Gate Crew:') && (rowMetres(text) ?? 0) > 100),
    )
    await tab.assertThat(
      'the row before names +1:00 to +1:15, and the row after +1:15 to +1:30',
      rows.some((t) => t.includes('+1:00') && t.includes('+1:15')) &&
        rows.some((t) => t.includes('+1:15') && t.includes('+1:30')),
    )
    await tab.assertThat(
      'one step is one 25 m: neither row claims a budget it does not have',
      rows.every((text) => text.includes('(limit 25 m)')),
    )
    await tab.assertThat(
      'the toolbar counts two problems, not four ends',
      `document.querySelector('.pv-badge.is-bad').textContent.trim() === '2 too far apart'`,
    )

    // ---------- 4. the whole stretch is marked, and nothing else ----------
    const dots = await badDots(tab)
    tab.pass(`marked dots: ${JSON.stringify(dots)}`)
    await tab.assertThat(
      'every frame in the stretch is marked, and only those three',
      dots.length === 3 && dots[0] === '+1:00' && dots[1] === '+1:15' && dots[2] === '+1:30',
    )
    const bands = await tab.eval(`[...document.querySelectorAll('.pv-band')].map((b) => {
      const left = parseFloat(b.style.left)
      return { left, width: parseFloat(b.style.width) }
    })`)
    tab.pass(`bands: ${JSON.stringify(bands)}`)
    await tab.assertThat('the stretch is one band, not two overlapping ones', bands.length === 1)
    const dotLefts = await tab.eval(`[...document.querySelectorAll('.pv-frame')]
      .filter((b) => b.classList.contains('is-bad'))
      .map((b) => parseFloat(b.style.left))`)
    await tab.assertThat(
      'and the band runs from the first marked frame to the last',
      bands.length === 1 &&
        Math.abs(bands[0].left - dotLefts[0]) <= 2 &&
        Math.abs(bands[0].left + bands[0].width - dotLefts[2]) <= 2,
    )

    // The inspector answers "why is this dot red?" in one sentence, naming the group and the span.
    const note = await tab.eval(
      `(document.querySelector('[data-testid=frame-stretch]') || {}).textContent?.replace(/\\s+/g, ' ').trim() || ''`,
    )
    tab.pass(`inspector: ${note}`)
    await tab.assertThat(
      'the inspector names the group and the span of the stretch',
      note.includes('Gate Crew') && note.includes('+1:00') && note.includes('+1:30'),
    )

    await tab.assertThat(
      'the lane marks the group the walk belongs to, and only that group',
      `document.querySelectorAll('.pv-group-row.is-bad').length === 1 &&
       document.querySelector('.pv-group-row.is-bad').textContent.includes('Gate Crew')`,
    )
    await tab.assertThat(
      'the badge is ringed, and Sound is not',
      `document.querySelectorAll('.pv-marker.is-bad').length === 1`,
    )
    await tab.assertThat(
      'both hops are drawn red on the map as their own segments',
      `[...document.querySelectorAll('.pv-map path')].filter((p) => p.getAttribute('stroke') === '#a63a2f' && !p.getAttribute('stroke-dasharray')).length === 2`,
    )
    await tab.assertThat(
      'and the database has nothing to add: no crossing, no pace',
      `document.querySelectorAll('[data-testid=plan-problem]').length === 0`,
    )

    // ---------- 5. publish still fails for the two hops ----------
    // The drag's own reload is still finishing for a moment after the rows appear; a person waits for the button to
    // be usable, so the check does too.
    await tab.waitUntil(
      `(() => {
        const b = [...document.querySelectorAll('button')].find((n) => n.textContent.trim() === 'Publish')
        return !!b && !b.disabled
      })()`,
      { what: 'Publish to be ready again after the drag', timeout: 12000 },
    )
    const clicked = await tab.eval(`(() => {
      const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish')
      if (!button) return 'no Publish button'
      if (button.disabled) return 'Publish is disabled'
      button.click()
      return 'clicked'
    })()`)
    tab.pass(`publish: ${clicked}`)
    await tab.waitFor('[data-testid=confirm-dialog]')
    tab.expectHttp(400, '/rpc/plan_publish')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitUntil(toastHas('cannot be published'), { what: 'the refusal toast', timeout: 12000 })
    const toast = await tab.eval(toastText)
    tab.pass(`refusal: ${toast}`)
    await tab.assertThat('the refusal counts both hops', toastHas('2 problems'))
    await tab.assertThat('and says which rule refused it', toastHas('the limit is 25 m'))
    await tab.assertThat(
      'the plan is still a draft',
      `[...document.querySelectorAll('.pv-toolbar .pv-badge')].map((b) => b.textContent.trim()).includes('draft')`,
    )

    // ---------- 6. it is the plan, not this tab ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 5`, {
      what: 'the plan list to load after the reload',
      timeout: 25000,
    })
    await openTheStrip()
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'the two rows to survive the reload',
    })
    const reloadedDots = await badDots(tab)
    tab.pass(`marked dots after the reload: ${JSON.stringify(reloadedDots)}`)
    await tab.assertThat(
      'after a reload the same three frames are marked',
      reloadedDots.length === 3 && reloadedDots[0] === '+1:00' && reloadedDots[2] === '+1:30',
    )
    await tab.click('.pv-frame', { index: 5 })
    await tab.sleep(250)
    await tab.assertThat(
      'and the inspector still says which stretch the frame is inside',
      `(document.querySelector('[data-testid=frame-stretch]') || {}).textContent.includes('+1:00')`,
    )

    // The subject is the strip: the three marked dots and the band are what this step is about, so the picture is
    // taken with the bar in view rather than the middle of the map.
    await tab.eval(`document.querySelector('.pv-bar').scrollIntoView({ block: 'center' })`)
    await tab.sleep(250)
    await tab.shot('shots/step12-stretch.png')

    await tab.assertNoErrors()
  },
}
