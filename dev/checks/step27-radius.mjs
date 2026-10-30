// Step 27, proved through the screen: the IC's arrival radius is a thing a person can set, see, and be refused over --
// and the planner can set it for them.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json   (planner, root)
//     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json  (Gate Crew IC)
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json  (Sound's admin: not an IC)
//     node tools/run.mjs dev/checks/step27-radius.mjs --session .tmp/session.json
//
// Three tabs, one after another (one browser profile, so the newest tab's seeded session is the identity):
//   1. the IC's own page ("My GPS details"): the card is there, it shows the radius the row carries, a change is saved
//      and survives a reload, and 4 m is refused in the database's own words -- which is the proof that the box is
//      validated on the server and not only in the markup;
//   2. the planner's People page: the row carries the IC's number, the planner changes it and the list comes back with
//      the new one, and only ICs have the control -- the group's admin who does not share a phone has none;
//   3. that admin's own GPS page: there is no card at all, because a person who does not share a phone has no radius.
//
// The number is read first and changed relative to what it found, so a second run of this check does not start from a
// value an earlier run left behind.
import fs from 'node:fs'

const icFile = process.env.IC_SESSION || '.tmp/session4.json'
const memberFile = process.env.MEMBER_SESSION || '.tmp/session3.json'

export default {
  name: 'step 27 — the arrival radius, set by the IC and by the planner',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e01'
    const share = `${base}/events/${eventId}/share`
    const people = `${base}/events/${eventId}/people`

    for (const [file, id, who] of [
      [icFile, 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'Gate Crew IC'],
      [memberFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', 'Sound admin'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const ic = JSON.parse(fs.readFileSync(icFile, 'utf8'))
    const soundAdmin = JSON.parse(fs.readFileSync(memberFile, 'utf8'))

    // ---------- 1. the IC's own page ----------
    const mine = await newTab({ session: ic, label: 'gate crew IC', url: share, width: 1200, height: 1000 })
    await mine.waitFor('[data-testid=tolerance-card]', { timeout: 20000 })
    await mine.waitUntil(`document.querySelector('[data-testid=tolerance-input]').value !== ''`, {
      what: 'the radius to arrive from the membership row',
    })

    const before = Number(await mine.eval(`document.querySelector('[data-testid=tolerance-input]').value`))
    mine.pass(`the card opens on ${before} m`)
    await mine.assertThat('the radius is a number inside the band the database allows', before >= 5 && before <= 100)

    // A number the check worked out from the one it found, so a repeat run proves the same thing. The card sits under
    // two others on a tall page, so it is scrolled to the middle of the window first: a click outside the viewport has
    // no element under it to focus.
    const wanted = before >= 90 ? 20 : before + 15
    await mine.eval(`document.querySelector('[data-testid=tolerance-card]').scrollIntoView({ block: 'center' })`)
    await mine.type('[data-testid=tolerance-input]', String(wanted))
    await mine.waitUntil(
      `!document.querySelector('[data-testid=tolerance-save]').disabled`,
      { what: 'the Save button to become live' },
    )
    await mine.click('[data-testid=tolerance-save]')
    await mine.waitForText('[data-testid=tolerance-msg]', 'Saved: ' + wanted + ' m.', { timeout: 8000 })
    mine.pass(`the IC saved ${wanted} m and the page said so`)
    await mine.shot('shots/step27-ic-radius.png')

    const asked = await mine.eval(`performance.getEntriesByType('resource').map((e) => e.name)`)
    const rpcCalls = asked.filter((name) => name.includes('set_arrival_tolerance'))
    await mine.assertThat('the save went to the database, not just to the box', rpcCalls.length > 0)

    // A reload is the only way to know the row carries it: the page reads the membership again.
    await mine.reload()
    await mine.waitFor('[data-testid=tolerance-card]', { timeout: 20000 })
    await mine.waitUntil(`document.querySelector('[data-testid=tolerance-input]').value === '${wanted}'`, {
      what: `the radius to still read ${wanted} after a reload`,
    })
    await mine.assertThat('and the value survived the reload, so it was stored', true)

    // Out of the band: the database's own sentence, shown as it is.
    await mine.eval(`document.querySelector('[data-testid=tolerance-card]').scrollIntoView({ block: 'center' })`)
    await mine.type('[data-testid=tolerance-input]', '4')
    mine.expectHttp(400, 'set_arrival_tolerance') // the refusal is the thing being proved, so it is excused once
    await mine.click('[data-testid=tolerance-save]')
    await mine.waitForText('[data-testid=tolerance-msg]', 'between 5 and 100', { timeout: 8000 })
    const refusal = await mine.text('[data-testid=tolerance-msg]')
    mine.pass(`4 m was refused: ${refusal}`)
    await mine.assertThat('the refusal is the server\'s sentence, not a browser one', /metres/.test(refusal))

    await mine.assertNoErrors()
    await mine.shot('shots/step27-ic-refused.png')
    await mine.close()

    // ---------- 2. the planner sets it for the IC ----------
    const plannerFile = process.env.PLANNER_SESSION || '.tmp/session.json'
    if (!fs.existsSync(plannerFile)) {
      throw new Error(`no planner session at ${plannerFile}. Mint one with: node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 ${plannerFile}`)
    }
    const plannerSession = JSON.parse(fs.readFileSync(plannerFile, 'utf8'))
    const planner = await newTab({ session: plannerSession, label: 'planner', url: people, width: 1440, height: 1000 })
    await planner.waitFor('[data-testid=people-list]', { timeout: 20000 })
    await planner.waitFor('[data-testid=person-tolerance-testuser4]', { timeout: 10000 })

    const seen = Number(await planner.eval(`document.querySelector('[data-testid=person-tolerance-testuser4]').value`))
    planner.pass(`the planner's list says testuser4's radius is ${seen} m`)
    await planner.assertThat("the planner sees the number the IC set for themself", seen === wanted)

    const inputs = await planner.count('[data-testid^=person-tolerance-]')
    await planner.assertThat('only the two ICs have a radius control', inputs === 2)
    await planner.assertThat(
      'the group admin who does not share a phone has none',
      !(await planner.has('[data-testid=person-tolerance-testuser3]')),
    )

    // A number box commits on blur, so the change is made and then the field is left. What proves the write landed is
    // the list being read again afterwards: `run()` emits 'changed' and the event page reloads its people.
    const readsBefore = await planner.eval(
      `performance.getEntriesByType('resource').filter((e) => /\\/rest\\/v1\\/group_members/.test(e.name)).length`,
    )
    const changed = seen === 25 ? 35 : 25
    await planner.type('[data-testid=person-tolerance-testuser4]', String(changed))
    await planner.click('[data-testid=people-scope]')
    await planner.waitUntil(
      `performance.getEntriesByType('resource').filter((e) => /\\/rest\\/v1\\/group_members/.test(e.name)).length > ${readsBefore}`,
      { what: 'the people list to be read back after the change' },
    )
    await planner.waitUntil(
      `document.querySelector('[data-testid=person-tolerance-testuser4]').value === '${changed}'`,
      { what: `testuser4's radius to read ${changed} after the list reloaded` },
    )
    planner.pass(`the planner set ${changed} m and the row came back with it`)

    await planner.assertNoErrors()
    await planner.shot('shots/step27-planner-radius.png')
    await planner.close()

    // ---------- 3. an admin who is not an IC has no radius at all ----------
    const other = await newTab({ session: soundAdmin, label: 'sound admin', url: share, width: 1200, height: 1000 })
    await other.waitFor('[data-testid=not-ic-msg]', { timeout: 20000 })
    await other.assertThat('a person who does not share a phone sees no radius card', !(await other.has('[data-testid=tolerance-card]')))
    await other.assertThat('and no radius box either', !(await other.has('[data-testid=tolerance-input]')))
    await other.assertNoErrors()
    await other.close()
  },
}
