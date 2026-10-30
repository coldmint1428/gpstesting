// Stress test, part 3: what a planner sees while it runs. A real browser, signed in as qa_planner, keeps the Live page
// (ops board + map) open, and every two minutes reloads it and times how long until all 46 groups are on the board,
// with a screenshot each time. Run beside loadtest.mjs:
//   E2E_BASE=http://localhost:5174 node tools/qa/loadtest-observe.mjs
import fs from 'node:fs'
import { chromium } from '@playwright/test'
import { contextAs } from '../../e2e/support/session.js'

const base = process.env.E2E_BASE || 'http://localhost:5173'
const seed = JSON.parse(fs.readFileSync('.tmp/loadtest/seed.json', 'utf8'))
const DURATION_S = Number(process.env.DURATION_S || 720)
const dir = '.tmp/loadtest/shots'
fs.mkdirSync(dir, { recursive: true })
const browser = await chromium.launch()
const ctx = await contextAs(browser, 'planner', base, { viewport: { width: 1440, height: 1000 } })
const page = await ctx.newPage()
const samples = []
const t0 = Date.now()
let n = 0
while ((Date.now() - t0) / 1000 < DURATION_S) {
  const t = Date.now()
  await page.goto(`/events/${seed.eventId}/live`)
  let rows = 0
  try {
    await page.getByTestId('ops-row').nth(40).waitFor({ timeout: 60_000 })
    rows = await page.getByTestId('ops-row').count()
  } catch {
    rows = await page.getByTestId('ops-row').count()
  }
  const ms = Date.now() - t
  const people = await page.locator('[data-testid^="person-"]').count()
  samples.push({ s: Math.round((Date.now() - t0) / 1000), boardReadyMs: ms, opsRows: rows, peopleOnMap: people })
  console.log(`[obs ${samples.at(-1).s} s] board ready in ${ms} ms, ${rows} groups, ${people} people listed`)
  await page.screenshot({ path: `${dir}/planner-live-${String(++n).padStart(2, '0')}.png`, fullPage: false })
  await page.mouse.wheel(0, 1600)
  await page.waitForTimeout(800)
  await page.screenshot({ path: `${dir}/planner-live-${String(n).padStart(2, '0')}-map.png`, fullPage: false })
  await page.waitForTimeout(Math.max(0, 120_000 - (Date.now() - t)))
}
fs.writeFileSync('.tmp/loadtest/observer.json', JSON.stringify(samples, null, 1))
await browser.close()
