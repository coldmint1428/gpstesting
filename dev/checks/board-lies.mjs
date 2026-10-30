// This check is SUPPOSED to fail. It is what proves the runner is honest: the same script that passes
// board-smoke.mjs must exit 1 and print what the page actually said when an assertion is wrong.
//
//     node tools/run.mjs dev/checks/board-lies.mjs    # expect: FAIL, exit code 1
//
// Note what is being asserted. A plan name that IS on screen would pass: .pv-board-head contains the plan
// picker, and a <select>'s innerText includes every option, so "Rehearsal" is present even while another plan
// is the one being edited. The string below is on no screen at all.
export default {
  name: 'board lies — an assertion that is wrong on purpose',

  async run({ newTab, base }) {
    const tab = await newTab({ label: 'wrong', url: `${base}/dev/preview.html` })
    await tab.waitFor('.pv-frame')

    // The page says "Show night — example".
    await tab.assertContains('.pv-board-head', 'Rehearsal is being edited')
    // Never reached: the assertion above throws.
    await tab.assertCount('.pv-frame', 99)
  },
}
