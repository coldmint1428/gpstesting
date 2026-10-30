// E2E tests (IS216 Week 10c: Playwright), run with `npm run test:e2e`.
// By default they run against the app on this laptop (npm run dev, the live Supabase project behind it).
// E2E_BASE=https://gpstesting.vercel.app npm run test:e2e runs the same tests against the deployed site.
// Signed-in tests never type a password into the page: e2e/support/session.js signs the QA accounts in
// through the auth API and hands the browser the session, the way the app itself keeps it.
import { defineConfig, devices } from '@playwright/test'

const base = process.env.E2E_BASE || 'http://localhost:5173'
const local = base.startsWith('http://localhost')

export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['json', { outputFile: '.tmp/e2e/results.json' }], ['html', { outputFolder: '.tmp/e2e/html', open: 'never' }]],
  outputDir: '.tmp/e2e/artifacts',
  use: {
    baseURL: base,
    screenshot: 'on',
    trace: 'retain-on-failure',
    timezoneId: 'Asia/Singapore',
    locale: 'en-SG',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 800 } } },
    { name: 'phone', use: { ...devices['Pixel 7'] }, grep: /@phone/ },
  ],
  webServer: local
    ? { command: 'npm run dev -- --port 5173 --strictPort', url: base, reuseExistingServer: true, timeout: 120_000 }
    : undefined,
})
