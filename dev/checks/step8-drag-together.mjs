// Step 8's proof, through the browser: tick three groups, drag one badge 30 m, and all three travel by the same
// distance in ONE save -- then an unticked badge moves alone.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json
//     node tools/run.mjs dev/checks/step8-drag-together.mjs --session .tmp/session.json
//
// The bench's "Copy bench" is where this is clickable: +0:00 states three groups (Gate Crew, Sound, Backstage) and
// +1:00 states Gate Crew alone, 11 m east of where it was. So one drag of the three ticked groups west by 30 m
// leaves the 25 m rule with exactly one thing to say -- Gate Crew's 11 m hop becomes 41 m -- which is how this check
// reads the distance the drag really moved, from the plan's own arithmetic rather than from pixels.
//
// What it clicks through:
//   * with nothing ticked the inspector says a drag moves that group, and ticking three names all three;
//   * dragging Gate Crew west is ONE rpc/frame_save (the browser's own resource timing), and all three badges move by
//     the same number of pixels -- the delta, measured on the map;
//   * the warning row reads "Gate Crew: 41 m between +0:00 and +1:00", i.e. the 30 m move plus the 11 m it had;
//   * no toast says anybody else changed anything, and nothing else on the plan moved (the +1:00 note is still
//     "one here");
//   * a reload keeps all of it, and the three badges are still exactly as far apart from each other as they were --
//     so the other two moved with the one under the pointer, on the server and not only on this screen;
//   * with nothing ticked again, dragging Gate Crew another 30 m moves only Gate Crew: the other two stay on their
//     pixels, the toast does not say "together", and the hop grows to 71 m.
// Rebuilding the bench first matters: this check drags Copy bench's +0:00, so a second run without a rebuild starts
// from the already-moved positions and every distance below is about the fixture's own.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Copy bench'

/** Each dot's title: "Frame +1:00" or "Frame +1:00 — one here". The DOM order is the plan's time order. */
function frameTitles(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))`)
}

/** How many requests the page has made to one RPC. The browser's own record, not a count we keep. */
function rpcCalls(tab, name) {
  return tab.eval(`performance.getEntriesByType('resource')
    .filter((e) => e.name.includes('/rpc/${name}')).length`)
}

/** A group's badge, measured inside the map container (the page scrolls, the map does not). */
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

/** The plan's warning rows, with their whitespace collapsed: "Gate Crew: 41 m between +0:00 and +1:00 (limit 25 m)". */
function gapRows(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-gap')].map((r) => r.textContent.replace(/\\s+/g, ' ').trim())`)
}

function metresInGap(text) {
  const hit = /(\d+) m between/.exec(String(text || ''))
  return hit ? Number(hit[1]) : null
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

/**
 * Metres per pixel, measured on the map rather than assumed: Gate Crew and Sound stand 55.645 m apart on +0:00 in
 * the fixture (0.0005 degrees of longitude at 1.331°), and their badges are that many pixels apart. Using the map as
 * its own ruler keeps "drag 30 m" honest whatever the container size or zoom turns out to be.
 */
const GATE_TO_SOUND_M = 55.645
// Sound and Backstage are 59.936 m apart in the fixture (0.0005° of longitude and 0.0002° of latitude), and neither
// of them is dragged after the first gesture -- so they are the ruler to use once Gate Crew has moved away from the
// east-west line Gate Crew and Sound shared.
const SOUND_TO_BACKSTAGE_M = 59.936

export default {
  name: 'drag several groups — one save, one delta, and only the ticked groups move',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 20000 })
    // The plan list is the third round trip of the page load (session, event, plans); a cold project can take a few
    // seconds, and a check that gives up at eight seconds would read as a broken board. (It did once, here.)
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load (five plans in the bench)',
      timeout: 25000,
    })

    async function openPlan(name = PLAN) {
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
      tab.pass(`opened "${picked}"`)
    }

    // The page opens the newest plan on its own when it mounts; a change dispatched before that load finishes is
    // overwritten by it. Waiting for the picker and the board to agree is what a person does by looking.
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

    /** The inspector row for a group, by name. Rows are alphabetical. */
    async function groupRow(name) {
      const index = await tab.eval(
        `[...document.querySelectorAll('[data-testid=group-row]')].findIndex((r) => r.textContent.includes(${JSON.stringify(name)}))`,
      )
      if (index < 0) throw new Error(`no group row for ${name}`)
      return index
    }

    /** One number for "how far apart are these two badges, on screen". */
    async function pairDistance(nameA, nameB) {
      const a = await markerAt(tab, nameA)
      const b = await markerAt(tab, nameB)
      return a && b ? distance(a, b) : 0
    }

    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the copy bench strip (rebuild the fixture if it does not hold two frames)',
    })
    // Opening a plan (or reloading the page) animates the map's fit for a quarter of a second. Pressing on a badge
    // while it is still travelling aims at where it was a moment ago, and Leaflet starts no drag at all -- so wait
    // for the animation to finish, the way a person waits for the map to stop moving before grabbing something.
    await tab.waitUntil(`!document.querySelector('.leaflet-zoom-anim')`, {
      what: 'the map to finish fitting the plan',
      timeout: 6000,
    })
    await tab.sleep(250)

    // ---------- 1. the strip, and who a drag would move ----------
    const start = await frameTitles(tab)
    tab.pass(`strip: ${JSON.stringify(start)}`)
    await tab.assertThat(
      'the copy bench opens on +0:00 / +1:00, the note intact',
      start.length === 2 && start[0] === 'Frame +0:00' && start[1] === 'Frame +1:00 — one here',
    )
    await tab.assertThat(
      'the bench is the fixture: the plan is legal before the drag (rebuild plan_bench.sql if it is not)',
      `document.querySelectorAll('.pv-gap').length === 0 && !document.querySelector('.pv-badge.is-bad')`,
    )
    await tab.assertThat(
      'with nothing ticked, the inspector says a drag moves that one group',
      `document.querySelector('[data-testid=drag-target]').textContent.replace(/\\s+/g, ' ').trim() ===
       'Drag a badge to move that group; tick two or more to move them together.'`,
    )
    await tab.assertThat(
      'no badge is stepped back before anything is ticked',
      `document.querySelectorAll('.pv-marker.is-dim').length === 0`,
    )

    // ---------- 2. tick three: the drag now names all three ----------
    for (const name of ['Backstage', 'Gate Crew', 'Sound']) await tab.click('[data-testid=group-row]', { index: await groupRow(name) })
    await tab.assertThat(
      'ticking three groups names all three as travelling together',
      `document.querySelector('[data-testid=drag-target]').textContent.replace(/\\s+/g, ' ').trim() ===
       'Drag any of Backstage, Gate Crew and Sound: they move together, by the same distance.'`,
    )
    await tab.assertContains('.pv-hint', 'drag any of the 3 ticked groups')
    await tab.assertThat(
      'all three drawn groups are the ticked ones, so none is stepped back',
      `document.querySelectorAll('.pv-marker.is-dim').length === 0 &&
       document.querySelectorAll('.pv-marker').length === 3`,
    )

    // ---------- 3. the Done-when: drag one badge 30 m ----------
    const before = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    tab.pass(`badges at +0:00: ${JSON.stringify(before)}`)
    const ruler = distance(before['Gate Crew'], before.Sound)
    const mPerPx = GATE_TO_SOUND_M / ruler
    tab.pass(`the map's own ruler: ${ruler.toFixed(1)} px between Gate Crew and Sound, ${mPerPx.toFixed(3)} m/px`)
    await tab.assertThat(
      'the two rulers the drag needs are sane: two badges visible, and one pixel is under a metre',
      ruler > 20 && mPerPx > 0.2 && mPerPx < 2,
    )
    const dx = -Math.round(30 / mPerPx)
    tab.pass(`30 m west is ${Math.abs(dx)} px at this zoom`)
    await tab.assertThat(
      'and there is room to drag that far without running out of map',
      before['Gate Crew'].x > Math.abs(dx) + 30,
    )

    const callsBefore = await rpcCalls(tab, 'frame_save')
    await tab.drag('.leaflet-marker-icon[title="Gate Crew"]', dx, 0, { steps: 18, settle: 200 })
    await tab.waitForText('[data-testid=toasts]', 'moved together at +0:00')
    const callsAfter = await rpcCalls(tab, 'frame_save')
    tab.pass(`frame_save round trips: ${callsBefore} → ${callsAfter}`)
    await tab.assertThat('three badges dragged is one save, not one each', callsAfter === callsBefore + 1)
    await tab.assertThat(
      'and it is not a stale-revision toast',
      `!document.querySelector('[data-testid=toasts]').innerText.includes('Someone else changed')`,
    )
    const toast = await tab.text('[data-testid=toasts]')
    tab.pass(`toast: ${JSON.stringify(toast)}`)
    await tab.assertThat(
      'the toast names the three that moved and the distance',
      /Backstage, Gate Crew and Sound moved together at \+0:00 — \d+ m\./.test(toast),
    )

    const after = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    const deltas = Object.fromEntries(
      Object.keys(before).map((name) => [name, [after[name].x - before[name].x, after[name].y - before[name].y]]),
    )
    tab.pass(`badges after the drag: ${JSON.stringify(deltas)}`)
    await tab.assertThat(
      'every ticked badge moved, by the same amount the one under the pointer moved',
      Object.values(deltas).every(([x, y]) => Math.abs(x - dx) <= 1.5 && Math.abs(y) <= 1.5),
    )
    await tab.assertThat(
      'the three deltas are the same delta, within a pixel',
      Math.max(...Object.values(deltas).map(([x]) => x)) - Math.min(...Object.values(deltas).map(([x]) => x)) <= 1,
    )
    // All three badges still sit on the lines they sat on: a shared delta is a translation of the group, not each
    // badge rounded to the pointer.
    const gateToSoundAfter = await pairDistance('Gate Crew', 'Sound')
    tab.pass(`Gate Crew–Sound spacing after the drag: ${gateToSoundAfter.toFixed(1)} px (was ${ruler.toFixed(1)})`)
    await tab.assertThat(
      'and the three are still as far apart from each other as they were',
      Math.abs(gateToSoundAfter - ruler) <= 2 && Math.abs(after['Gate Crew'].y - before['Gate Crew'].y) <= 1.5,
    )

    // ---------- 4. what the plan makes of it ----------
    // The 25 m rule reads the moved position: Gate Crew's 11 m hop to +1:00 is now ~41 m, and it is the only thing
    // the plan has to complain about -- the other two groups are stated once and have no hop at all.
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 1`, { what: 'the one warning the drag earns' })
    const gaps = await gapRows(tab)
    tab.pass(`warning rows: ${JSON.stringify(gaps)}`)
    await tab.assertThat(
      'the warning is Gate Crew between the two moments, and 30 m further than it was',
      gaps.length === 1 &&
        gaps[0].includes('Gate Crew') &&
        gaps[0].includes('+0:00') &&
        gaps[0].includes('+1:00') &&
        (metresInGap(gaps[0]) ?? 0) >= 39 &&
        (metresInGap(gaps[0]) ?? 0) <= 43,
    )
    await tab.assertThat(
      'the header counts one broken stretch, not two',
      `document.querySelector('.pv-badge.is-bad').textContent.trim() === '1 too far apart'`,
    )
    const afterTitles = await frameTitles(tab)
    await tab.assertThat(
      'the drag wrote positions, not frames: the strip is still the two moments it had',
      afterTitles.length === 2 && afterTitles[0] === 'Frame +0:00' && afterTitles[1] === 'Frame +1:00 — one here',
    )
    await tab.assertThat('the frame the planner was on is still +0:00', `document.querySelector('#pv-frame-time').value === '+0:00'`)
    await tab.sleep(300)
    // The drag scrolled the badge into view; centre the board so the picture shows the whole of it — map, strip and
    // inspector — while the toast is still up.
    await tab.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'center' })`)
    await tab.sleep(300)
    await tab.shot('shots/step8-drag-together.png')

    // ---------- 5. it is in the database, and the other two travelled too ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 20000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list after the reload',
      timeout: 25000,
    })
    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the dragged strip to survive the reload',
    })
    await tab.waitUntil(`!document.querySelector('.leaflet-zoom-anim')`, {
      what: 'the map to finish fitting the strip after the reload',
      timeout: 6000,
    })
    await tab.sleep(250)
    await tab.waitUntil(`!!document.querySelector('.leaflet-marker-icon[title="Backstage"]')`, {
      what: 'the badges after the reload',
    })
    await tab.assertThat(
      'the strip and its note survived the reload',
      JSON.stringify(await frameTitles(tab)) === JSON.stringify(start),
    )
    const reloaded = await gapRows(tab)
    tab.pass(`warning rows after the reload: ${JSON.stringify(reloaded)}`)
    await tab.assertThat(
      'the moved position is in the database: the same 41 m hop is reported from a fresh read',
      reloaded.length === 1 && (metresInGap(reloaded[0]) ?? 0) >= 39 && (metresInGap(reloaded[0]) ?? 0) <= 43,
    )
    // The three badges are rigid: whatever the new fit's scale, the distances between them are in the same ratio as
    // before. Had only Gate Crew been written (the per-badge bug), its distance from each of the others would have
    // grown by more than a third and this ratio would move with it.
    const ratioBefore = distance(before['Gate Crew'], before.Sound) / distance(before['Gate Crew'], before.Backstage)
    const ratioAfter = (await pairDistance('Gate Crew', 'Sound')) / (await pairDistance('Gate Crew', 'Backstage'))
    tab.pass(`badge-spacing ratio: ${ratioBefore.toFixed(3)} → ${ratioAfter.toFixed(3)}`)
    await tab.assertThat(
      'after the reload the three are still one rigid group — the companions were written too',
      Math.abs(ratioAfter - ratioBefore) / ratioBefore <= 0.02,
    )
    const states = await tab.eval(`(() => {
      const out = {}
      for (const row of document.querySelectorAll('[data-testid=group-row]')) {
        out[row.querySelector('.pv-group-name').textContent.trim()] = row.querySelector('.pv-group-state').textContent.trim()
      }
      return out
    })()`)
    await tab.assertThat(
      'and every group this frame states is still stated, with the fourth still unplaced',
      states['Gate Crew'] === 'set' && states.Sound === 'set' && states.Backstage === 'set' && states.Security === 'not yet placed',
    )

    // ---------- 6. only the ticked ones move ----------
    // The reload cleared the ticks. With nothing ticked a drag is the old single-group gesture: one badge, one
    // position. That is the other half of "several at once" -- it must not quietly become "all of them, always".
    await tab.assertThat(
      'the reload leaves nothing ticked, so the drag is the single-group one again',
      `document.querySelector('[data-testid=drag-target]').textContent.replace(/\\s+/g, ' ').trim() ===
       'Drag a badge to move that group; tick two or more to move them together.'`,
    )
    const beforeSolo = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    const soloRuler = distance(beforeSolo['Gate Crew'], beforeSolo.Sound)
    const soloDx = -Math.round(30 / (GATE_TO_SOUND_M / soloRuler))
    const soloCalls = await rpcCalls(tab, 'frame_save')
    await tab.drag('.leaflet-marker-icon[title="Gate Crew"]', soloDx, 0, { steps: 18, settle: 200 })
    // The proof that it was one group is geometric, not rhetorical: wait for the plan to be re-read (the warning row
    // is already there, so wait for its distance to change, not for it to appear), then read the badges. The toast is
    // deliberately not asserted here: the confirmation arrives after the reads that follow the write, so it is the
    // weaker evidence.
    await tab.waitUntil(
      `(() => {
        const row = document.querySelector('.pv-gap')
        if (!row) return false
        const hit = /(\\d+) m between/.exec(row.textContent)
        return !!hit && Number(hit[1]) > 60
      })()`,
      { what: 'the plan to be re-read after the solo drag, with the hop grown to about 71 m' },
    )
    await tab.assertThat(
      'the unticked drag is one save too',
      (await rpcCalls(tab, 'frame_save')) === soloCalls + 1,
    )
    const afterSolo = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    tab.pass(
      `solo deltas: ${JSON.stringify(
        Object.fromEntries(
          Object.keys(beforeSolo).map((name) => [
            name,
            [afterSolo[name].x - beforeSolo[name].x, afterSolo[name].y - beforeSolo[name].y],
          ]),
        ),
      )}`,
    )
    await tab.assertThat(
      'the unticked group moved, and only it',
      Math.abs(afterSolo['Gate Crew'].x - beforeSolo['Gate Crew'].x - soloDx) <= 1.5 &&
        Math.abs(afterSolo.Sound.x - beforeSolo.Sound.x) <= 1.5 &&
        Math.abs(afterSolo.Backstage.x - beforeSolo.Backstage.x) <= 1.5,
    )
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 1`, { what: 'the one warning, still' })
    const soloGaps = await gapRows(tab)
    tab.pass(`warning rows after the solo drag: ${JSON.stringify(soloGaps)}`)
    await tab.assertThat(
      'a second 30 m west leaves a 71 m hop, and still only the one row',
      soloGaps.length === 1 && (metresInGap(soloGaps[0]) ?? 0) >= 68 && (metresInGap(soloGaps[0]) ?? 0) <= 74,
    )

    // ---------- 7. a ticked set is not a magnet for an unticked badge ----------
    // Ticking names who travels together; it does not mean "everything a drag touches". Grabbing a badge outside the
    // ticked set moves that badge alone, which is what the sentence says -- it does not name the grabbed group.
    for (const name of ['Backstage', 'Sound']) await tab.click('[data-testid=group-row]', { index: await groupRow(name) })
    await tab.assertThat(
      'ticking two groups names those two, and not the badge about to be grabbed',
      `document.querySelector('[data-testid=drag-target]').textContent.replace(/\\s+/g, ' ').trim() ===
       'Drag any of Backstage and Sound: they move together, by the same distance.'`,
    )
    await tab.assertThat(
      'and the unticked badge is the one stepped back',
      `document.querySelectorAll('.pv-marker.is-dim').length === 1 &&
       !!document.querySelector('.leaflet-marker-icon[title="Gate Crew"] .pv-marker.is-dim')`,
    )
    const beforeUnticked = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    const untickedRuler = await pairDistance('Sound', 'Backstage')
    const untickedDx = -Math.round(30 / (SOUND_TO_BACKSTAGE_M / untickedRuler))
    await tab.drag('.leaflet-marker-icon[title="Gate Crew"]', untickedDx, 0, { steps: 18, settle: 200 })
    await tab.waitUntil(
      `(() => {
        const row = document.querySelector('.pv-gap')
        if (!row) return false
        const hit = /(\\d+) m between/.exec(row.textContent)
        return !!hit && Number(hit[1]) > 90
      })()`,
      { what: 'the plan to be re-read after dragging a badge outside the ticked set (a ~101 m hop)' },
    )
    const afterUnticked = {
      'Gate Crew': await markerAt(tab, 'Gate Crew'),
      Sound: await markerAt(tab, 'Sound'),
      Backstage: await markerAt(tab, 'Backstage'),
    }
    tab.pass(
      `unticked-leader deltas: ${JSON.stringify(
        Object.fromEntries(
          Object.keys(beforeUnticked).map((name) => [
            name,
            [afterUnticked[name].x - beforeUnticked[name].x, afterUnticked[name].y - beforeUnticked[name].y],
          ]),
        ),
      )}`,
    )
    await tab.assertThat(
      'the ticked groups stayed where they were; only the grabbed badge moved',
      Math.abs(afterUnticked['Gate Crew'].x - beforeUnticked['Gate Crew'].x - untickedDx) <= 1.5 &&
        Math.abs(afterUnticked.Sound.x - beforeUnticked.Sound.x) <= 1.5 &&
        Math.abs(afterUnticked.Backstage.x - beforeUnticked.Backstage.x) <= 1.5,
    )
    const untickedGaps = await gapRows(tab)
    tab.pass(`warning rows after the unticked-leader drag: ${JSON.stringify(untickedGaps)}`)
    await tab.assertThat(
      'three 30 m drags leave a 101 m hop, still in one row',
      untickedGaps.length === 1 && (metresInGap(untickedGaps[0]) ?? 0) >= 97 && (metresInGap(untickedGaps[0]) ?? 0) <= 104,
    )

    await tab.assertNoErrors()
  },
}
