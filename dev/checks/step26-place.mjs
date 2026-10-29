// Step 26, proved through the screen: a timetable row says WHERE the moment is.
//
//     node tools/sql.mjs --file dev/checks/step16-schedule-prep.sql
//     node tools/run.mjs dev/checks/step26-place.mjs --session .tmp/session.json
//
// Needs two more sessions (the check says so if they are missing):
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound, plain member)
//     node tools/authlink.mjs 00cd023b-0e26-4574-a635-760e782c8029 .tmp/session5.json   (marshal, no group)
//
// The bench is step 16's own event (e16), which now carries three zones: the dock (a plain zone), the stage (kind
// stage) and the main gate (a plain zone). Sound's five moments are therefore: a placed call, an off-site moment (no
// place, even though its coordinate is inside the dock), a placed stage moment, and two frames that only carry it
// forward (no point, so no place). The places are asserted by name, and the nulls are asserted as nulls -- a row that
// prints a dash, an empty chip or "unknown" would fail.
//
// What is proved, in order:
//   1. the member's schedule prints the place on the moments that have one and prints nothing on the rest, while the
//      five state words are exactly what they were before this step;
//   2. the place comes from the one timetable read -- the page still makes no plan_positions request, and does make a
//      session_timetable one (so the assertion is not passing because the read never happened);
//   3. the marshal's timetable names the other group's place too: both groups' first rows are on one screen and say
//      different places, which is what makes a row-level column the right shape rather than a frame-level one.
import fs from 'node:fs'

const memberFile = process.env.MEMBER_SESSION || '.tmp/session3.json'
const marshalFile = process.env.MARSHAL_SESSION || '.tmp/session5.json'

export default {
  name: 'step 26 — a timetable row says where the moment is',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e16'
    const timeline = `${base}/events/${eventId}/timeline`

    for (const [file, id, who] of [
      [memberFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', 'Sound member'],
      [marshalFile, '00cd023b-0e26-4574-a635-760e782c8029', 'marshal'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const member = JSON.parse(fs.readFileSync(memberFile, 'utf8'))
    const marshal = JSON.parse(fs.readFileSync(marshalFile, 'utf8'))

    // ---------- 1. the member's schedule says where ----------
    const viewer = await newTab({
      session: member,
      label: 'sound member',
      url: timeline,
      width: 1440,
      height: 1000,
    })
    await viewer.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await viewer.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length > 0`, {
      what: 'the timetable rows to arrive',
    })

    const moments = await viewer.eval(`[...document.querySelectorAll('[data-testid=sched-moment]')].map((m) => {
      const row = m.querySelector('[data-testid=sched-row]')
      const place = m.querySelector('[data-testid=sched-place]')
      return {
        t: Number(m.dataset.t),
        state: row ? row.dataset.state : null,
        place: place ? place.textContent.replace(/\\s+/g, ' ').trim() : null,
      }
    })`)

    viewer.pass(`the member's moments: ${moments.map((m) => `${m.t}s ${m.state} ${m.place || '—'}`).join(' | ')}`)
    await viewer.assertThat('five moments, one per frame', moments.length === 5)
    await viewer.assertThat(
      'the five state words are unmoved by the place',
      moments.map((m) => m.state).join(',') === 'arrived,not_required,late,missed,pending',
    )
    await viewer.assertThat(
      'the call is at the dock, the +10:00 is at the stage, and the off-site moment and the two carried frames say nothing',
      moments.map((m) => m.place).join('|') === 'Sound Dock||Stage||',
    )

    // ---------- 2. the place came from the one read ----------
    const asked = await viewer.eval(`performance.getEntriesByType('resource').map((e) => e.name)`)
    const planSurface = asked.filter((name) => /\/rest\/v1\/(plan_frames|plan_list|plan_positions|plan_progress)/.test(name))
    const timetableCalls = asked.filter((name) => name.includes('session_timetable'))
    viewer.pass(`${timetableCalls.length} timetable read(s), ${planSurface.length} plan-surface resource(s)`)
    await viewer.assertThat('the page asked the timetable for the place', timetableCalls.length > 0)
    await viewer.assertThat("and still never asks for the plan's frames or positions", planSurface.length === 0)

    await viewer.assertNoErrors()
    await viewer.shot('shots/step26-member-place.png')
    await viewer.close()

    // ---------- 3. the marshal sees both groups' places at once ----------
    const ops = await newTab({
      session: marshal,
      label: 'marshal',
      url: timeline,
      width: 1440,
      height: 1000,
    })
    await ops.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await ops.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length === 10`, {
      what: "the marshal's ten rows",
    })

    const rows = await ops.eval(`[...document.querySelectorAll('[data-testid=sched-row]')].map((r) => {
      const place = r.querySelector('[data-testid=sched-place]')
      return { group: r.dataset.group, place: place ? place.textContent.trim() : null }
    })`)
    const first = rows.slice(0, 2)
    ops.pass(`the first moment's two rows: ${JSON.stringify(first)}`)
    await ops.assertThat('the first frame carries both groups', new Set(rows.map((r) => r.group)).size === 2)
    await ops.assertThat(
      'and the two rows name different places',
      first.length === 2 && first[0].place !== first[1].place &&
        [first[0].place, first[1].place].sort().join('|') === 'Main Gate|Sound Dock',
    )

    await ops.assertNoErrors()
    await ops.shot('shots/step26-marshal-place.png')
    await ops.close()
  },
}
