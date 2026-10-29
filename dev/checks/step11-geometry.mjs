// Step 11's proof, through the browser: a walk through a no-go zone is named twice -- while planning, and at publish.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/run.mjs dev/checks/step11-geometry.mjs --session .tmp/session.json
//
// The rules live in the database (048, proved in dev/checks/step11-geometry.sql). What this check is for is the half
// a person sees. The board derives its own 25 m walk from the frames, so it used to draw a crossing as an ordinary
// line and only speak after Publish refused -- the planner met the zone at the gate. The board now asks plan_check
// after every frame read and paints the row, the badge ring and the segment, so the sentence is on screen while the
// plan is still being drawn.
//
// The bench's "Walkthrough" is that plan: Security walks 20 m east through "Stores (no-go)" between +0:00 and +1:00,
// and Sound is 200 m away between +1:00 and +3:00, so the plan is a two-problem one and the check can assert the
// count as well as the words.
//
// The last section deletes the frame the crossing ends on -- the one write in this check -- to prove an edit is
// followed by a fresh answer: the crossing row gives way to the two long walks, and the plan is left with 5 frames.
// Rebuild the bench before running anything that expects the fixture.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Walkthrough'

// The toast container as a value, already parenthesised: the runner wraps an expression in `!!(...)`, so a missing
// pair of brackets here would make `text || ''.includes(...)` a truthy string and the assertion could not fail.
const toastText = `((document.querySelector('[data-testid=toasts]') || {}).textContent || '')`
const toastHas = (needle) => `${toastText}.includes(${JSON.stringify(needle)})`
const statusBadges = `[...document.querySelectorAll('.pv-toolbar .pv-badge')].map((b) => b.textContent.trim())`

export default {
  name: 'geometry — a 20 m walk through a no-go zone is refused at publish, in words that name it',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 5`, {
      what: 'the plan list to load (five plans in the bench -- rebuild the fixture if it is short)',
    })

    // The page opens the newest plan by itself when it mounts; wait for the picker and the board to agree before
    // changing the picker, or the mount's own load lands after the change and overwrites it.
    await tab.waitUntil(
      `(() => {
        const sel = document.querySelector('.pv-select')
        if (!sel) return false
        const m = sel.options[sel.selectedIndex].textContent.match(/\\((\\d+)\\)/)
        return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
      })()`,
      { what: 'the board to show the plan the picker names' },
    )

    const picked = await tab.eval(`(() => {
      const sel = document.querySelector('.pv-select')
      const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(PLAN)}))
      if (!opt) return 'no "${PLAN}" option'
      if (sel.value !== opt.value) {
        sel.value = opt.value
        sel.dispatchEvent(new Event('change'))
      }
      return opt.textContent.replace(/\\s+/g, ' ').trim()
    })()`)
    tab.pass(`opened "${picked}"`)

    // Six frames is the unfilled walkthrough; the check would also be wrong on a bench left filled by step 5.
    await tab.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 6 &&
       document.querySelector('.pv-select').selectedOptions[0].textContent.includes(${JSON.stringify(PLAN)})`,
      { what: 'the six frames of the walkthrough, with the picker still naming it' },
    )
    const before = await tab.eval(statusBadges)
    tab.pass(`status before: ${JSON.stringify(before)}`)
    await tab.assertThat('the walkthrough is a draft, so it can be published', `${statusBadges}.includes('draft')`)

    // ---------- the board knows before Publish does ----------
    await tab.waitUntil(`document.querySelectorAll('[data-testid=plan-problem]').length === 1`, {
      what: 'the board to name the crossing before Publish is pressed',
    })
    const problems = await tab.eval(
      `[...document.querySelectorAll('[data-testid=plan-problem]')].map((r) => r.textContent.replace(/\\s+/g, ' ').trim())`,
    )
    tab.pass(`board problems: ${JSON.stringify(problems)}`)
    await tab.assertThat(
      'the row names the group, the zone and the rule',
      problems.length === 1 &&
        problems[0].includes('Security') &&
        problems[0].includes('Stores') &&
        problems[0].includes('crosses'),
    )
    await tab.assertThat(
      'the toolbar badge counts it before Publish is pressed',
      `document.querySelector('[data-testid=plan-blocked]').textContent.trim() === '1 problem'`,
    )
    await tab.assertThat(
      'and the badge is drawn as the refusal it is',
      `!!document.querySelector('[data-testid=plan-blocked].pv-badge.is-blocked')`,
    )
    await tab.assertThat(
      'the group that crosses is flagged in the lane at +0:00',
      `[...document.querySelectorAll('.pv-group-row.is-bad')].some((r) => r.textContent.includes('Security'))`,
    )
    await tab.assertThat(
      'its badge on the map is ringed, and only it',
      `[...document.querySelectorAll('.pv-marker.is-bad')].length === 1`,
    )
    await tab.assertThat(
      'the refused stretch is drawn as its own dashed red line',
      `document.querySelectorAll('.pv-map path[stroke-dasharray="2 4"]').length === 1`,
    )

    // "Show" opens the moment the sentence ends on: the frame where Security has arrived.
    await tab.click('[data-testid=problem-show]')
    await tab.sleep(250)
    await tab.assertThat(
      'Show opens the frame the crossing ends on (+1:00)',
      `document.querySelector('#pv-frame-time').value === '+1:00'`,
    )
    // Back to +0:00, the moment the picture above was asserted at.
    await tab.click('.pv-frame', { index: 0 })
    await tab.sleep(250)
    await tab.eval(`document.querySelector('.pv-map').scrollIntoView({ block: 'center' })`)
    await tab.sleep(250)
    await tab.shot('shots/step11-board-zone.png')

    // ---------- the refusal ----------
    const clicked = await tab.eval(`(() => {
      const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish')
      if (!button) return 'no Publish button'
      button.click()
      return 'clicked'
    })()`)
    tab.pass(`publish: ${clicked}`)
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.assertContains('[data-testid=confirm-dialog]', `Publish "${PLAN}"?`)
    // The refusal is a 400 from the database and the page is supposed to show it: one is expected, no more.
    tab.expectHttp(400, '/rpc/plan_publish')
    await tab.click('[data-testid=confirm-ok]')

    await tab.waitUntil(toastHas('cannot be published'), {
      what: 'the refusal toast',
      timeout: 12000,
    })
    const toast = await tab.eval(toastText)
    tab.pass(`refusal: ${toast}`)

    // The four groups of the walkthrough are still drawn: the refusal is about the plan, not about the map.
    await tab.assertThat(
      'the four groups are still on the map',
      `document.querySelectorAll('.pv-marker').length === 4`,
    )
    // The inspector's error block makes the board taller than the window, so the middle of the map -- where the
    // camera put the plan -- is below the fold. Centre it before the screenshot, the way a person would scroll.
    await tab.eval(`document.querySelector('.pv-map').scrollIntoView({ block: 'center' })`)
    await tab.sleep(250)
    await tab.shot('shots/step11-geometry.png')

    await tab.assertThat('the refusal says the zone: Stores', toastHas('Stores'))
    await tab.assertThat('and what is wrong: the straight line crosses it', toastHas('crosses'))
    await tab.assertThat('and that it is a no-go area', toastHas('no-go'))
    await tab.assertThat('it counts both problems', toastHas('2 problems'))
    await tab.assertThat(
      'it no longer claims a 25 m break it does not have',
      `!${toastText}.includes('more than 25 m apart')`,
    )

    // ---------- nothing was published ----------
    const after = await tab.eval(statusBadges)
    tab.pass(`status after: ${JSON.stringify(after)}`)
    await tab.assertThat('the plan is still a draft', `${statusBadges}.includes('draft')`)
    await tab.assertThat('and does not claim to be live', `!${statusBadges}.includes('live')`)
    await tab.assertThat(
      'the button still offers to publish it',
      `!![...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish')`,
    )

    // It is the database that refused, not a toast over a write that went through: a reload reads the row back.
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 5`, {
      what: 'the plan list to load after the reload',
    })
    await tab.waitUntil(
      `(() => {
        const sel = document.querySelector('.pv-select')
        if (!sel) return false
        const m = sel.options[sel.selectedIndex].textContent.match(/\\((\\d+)\\)/)
        return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
      })()`,
      { what: 'the board to show the plan the picker names after the reload' },
    )
    await tab.eval(`(() => {
      const sel = document.querySelector('.pv-select')
      const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(PLAN)}))
      sel.value = opt.value
      sel.dispatchEvent(new Event('change'))
    })()`)
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 6`, {
      what: 'the walkthrough to still hold its six frames after the reload',
    })
    await tab.assertThat(
      'after a reload it is still a draft',
      `${statusBadges}.includes('draft') && !${statusBadges}.includes('live')`,
    )
    await tab.assertThat(
      'and the live plan is still the one that was live before',
      `[...document.querySelectorAll('.pv-select option')].filter((o) => o.textContent.includes('· live')).every((o) => !o.textContent.includes(${JSON.stringify(PLAN)}))`,
    )

    // ---------- an edit is followed by a fresh answer ----------
    // The same refresh runs after every write, which is the half a drag exercises. Deleting the frame the crossing
    // ended on merges the pair into a 155 m walk, so the crossing row has to give way to the board's own 25 m rows.
    await tab.click('.pv-frame', { index: 1 })
    await tab.sleep(250)
    await tab.click('[data-testid=frame-delete]')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 5 &&
       document.querySelectorAll('[data-testid=plan-problem]').length === 0`,
      { what: 'the frame to go, and the crossing row to go with it', timeout: 12000 },
    )
    tab.pass('deleted +1:00: the crossing gave way after the write')
    await tab.assertThat(
      'with the crossing pair gone the board reports the two long walks instead',
      `[...document.querySelectorAll('.pv-gap')].length === 2`,
    )

    await tab.assertNoErrors()
  },
}
