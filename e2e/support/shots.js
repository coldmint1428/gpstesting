// Named screenshots for the test report: .tmp/e2e/shots/<site>/<name>.png, one per step worth showing.
import fs from 'node:fs'
import path from 'node:path'

const site = (process.env.E2E_BASE || 'http://localhost:5173').includes('vercel.app') ? 'live' : 'local'
const dir = path.resolve('.tmp/e2e/shots', site)
fs.mkdirSync(dir, { recursive: true })

export async function shot(page, name, options = {}) {
  await page.waitForTimeout(250) // let a transition settle so the picture shows the state the assertion saw
  await page.screenshot({ path: path.join(dir, name + '.png'), ...options })
}

export const onLive = site === 'live'
