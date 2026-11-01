// Step 2, proved through the screen: a session is started from the Start dialog on a plan — not merely through the
// function the dialog would have called — and a session started on nothing says so. Step 1 exists so that this
// sentence can be checked instead of believed.
//
//     node tools/run.mjs dev/checks/step2-start-on-a-plan.mjs --session .tmp/session.json
//
// Requires: the plan bench (supabase/fixtures/plan_bench.sql), its "Clean walk" plan published (the SQL check
// dev/checks/step2-session-plan.sql does that), the event not live, and a session for testuser1 as the file above.
//
// Step 30 re-pointed the "no run sheet is claimed" assertion. It used to assert the ABSENCE of a test id called
// `status-run-sheet` on the sentence "running nothing (tracking only)" -- and step 30 renamed that id to
// `status-tracking-only`, so the old assertion would have been permanently true without ever looking at anything. The
// presence that absence was standing in for is now checked directly: the same dialog starts a second, tracking-only
// session, and the sentence it puts on screen is read.
export default {
  name: 'step 2 — start a session from the UI on a plan, and on nothing',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e01'
    const tab = await newTab({ label: 'planner', url: `${base}/events/${eventId}/live`, width: 1440, height: 1000 })

    await tab.waitFor('[data-testid=event-status]', { timeout: 15000 })
    await tab.assertThat('the event is not live yet', `!!document.querySelector('[data-testid=status-not-started]')`)
    // Start is disabled until the list of plans has arrived: otherwise the dialog opens empty and a planner can
    // start a session on nothing by accident.
    await tab.waitUntil(
      `!document.querySelector('[data-testid=start-event-btn]').disabled`,
      { what: 'the Start button to become available once the plans have loaded' },
    )

    // ---------- the Start dialog offers a plan, which until 039 it could not ----------
    await tab.click('[data-testid=start-event-btn]')
    await tab.waitFor('[data-testid=start-form]')

    // 060 retired the run-sheet half of this dialog (step 24). The copy used to say "Run sheets must be Ready; plans
    // must be published first", so this assertion is one the old screen would have failed, not a restatement.
    await tab.assertThat(
      'the Start dialog no longer offers a run sheet',
      `!/run sheet/i.test(document.querySelector('[data-testid=start-form]').textContent)`,
    )

    const options = await tab.eval(`
      [...document.querySelectorAll('#start-engine option')].map((o) => ({
        value: o.value, text: o.textContent.replace(/\\s+/g, ' ').trim(), disabled: o.disabled,
      }))
    `)
    const planOption = options.find((o) => o.value.startsWith('plan:') && o.text.startsWith('Clean walk'))
    tab.pass(`the picker lists the plan: "${planOption ? planOption.text : 'not found'}"`)
    await tab.assertThat('the published plan can be picked', planOption && planOption.disabled === false)
    await tab.assertThat(
      'the unpublished plan cannot be picked',
      options.some((o) => o.value.startsWith('plan:') && o.text.startsWith('Walkthrough') && o.disabled),
    )

    // Choosing it is a change event, which is what v-model listens for.
    await tab.eval(`
      (() => {
        const sel = document.querySelector('#start-engine')
        sel.value = ${JSON.stringify(planOption.value)}
        sel.dispatchEvent(new Event('change'))
        return sel.value
      })()
    `)
    await tab.assertThat('the picker holds the plan', `document.querySelector('#start-engine').value.startsWith('plan:')`)

    await tab.click('[data-testid=start-confirm-btn]')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.assertContains('[data-testid=confirm-dialog]', 'Plan: "Clean walk"')
    await tab.click('[data-testid=confirm-ok]')

    // ---------- and the result is a plan session ----------
    await tab.waitFor('[data-testid=status-live]', { timeout: 15000 })
    await tab.assertContains('[data-testid=status-plan]', 'Clean walk')
    await tab.assertThat(
      'a plan session claims no tracking-only sentence',
      `!document.querySelector('[data-testid=status-tracking-only]')`,
    )
    // The run-sheet machinery is not merely hidden for a plan session: step 25 deleted it, and its testid went with
    // the component. If either were on screen again, something would have brought the engine back.
    await tab.assertThat(
      'the show bar and the ops queue are not rendered for a plan session',
      `!document.querySelector('.show-bar') && !document.querySelector('[data-testid=ops-queue]')`,
    )

    await tab.shot('shots/step2-plan-session-live.png')

    // ---------- tracking only: the sentence a session with no plan says ----------
    await tab.click('[data-testid=end-event-btn]')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitFor('[data-testid=status-not-started]', { timeout: 15000 })

    await tab.click('[data-testid=start-event-btn]')
    await tab.waitFor('[data-testid=start-form]')
    // "Nothing: tracking only" is the empty value of the picker: choosing nothing is a real choice, not the default the
    // dialog opens on, so it is set the way a person choosing it would set it.
    await tab.eval(`
      (() => {
        const sel = document.querySelector('#start-engine')
        sel.value = ''
        sel.dispatchEvent(new Event('change'))
        return sel.value
      })()
    `)
    await tab.click('[data-testid=start-confirm-btn]')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.assertContains('[data-testid=confirm-dialog]', 'tracking only')
    await tab.click('[data-testid=confirm-ok]')

    await tab.waitFor('[data-testid=status-tracking-only]', { timeout: 15000 })
    const tracking = (await tab.text('[data-testid=status-tracking-only]')).replace(/\s+/g, ' ').trim()
    tab.pass(`a session started on nothing says: "${tracking}"`)
    await tab.assertThat('a session started on nothing says so', /tracking only/.test(tracking))
    await tab.assertThat('and claims no plan', `!document.querySelector('[data-testid=status-plan]')`)

    // ---------- put the bench back: end the event ----------
    await tab.click('[data-testid=end-event-btn]')
    await tab.waitFor('[data-testid=confirm-dialog]')
    await tab.click('[data-testid=confirm-ok]')
    await tab.waitFor('[data-testid=status-not-started]', { timeout: 15000 })
    tab.pass('the event ends again, so the bench is back where it started')

    await tab.assertNoErrors()
  },
}
