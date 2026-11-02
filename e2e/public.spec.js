// E2E: what a visitor who is not signed in can and cannot do.
import { test, expect } from '@playwright/test'
import { shot } from './support/shots.js'

const visible = (page, id) => page.locator(`[data-testid="${id}"]:visible`).first()

test.describe('Visitor', () => {
  test('sees the landing page, with no Events link in the nav', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByRole('heading', { level: 1 })).toContainText('Right place.')
    await expect(page.getByRole('link', { name: 'Events', exact: true })).toHaveCount(0)
    await expect(page.getByRole('link', { name: 'Log in' }).first()).toBeVisible()
    await shot(page, 'pub-01-landing', { fullPage: true })
  })

  test('the event code box keeps letters and digits only, in capitals, six at most', async ({ page }) => {
    await page.goto('/')
    const code = page.getByTestId('visitor-join-code')
    await code.fill('9z8-gg!xq') // a pasted code with a dash in it still keeps all six (bug QA-01)
    await expect(code).toHaveValue('9Z8GGX')
    await shot(page, 'pub-02-code-filter')
  })

  test('joining with a code asks the visitor to log in, and keeps the code for after', async ({ page }) => {
    await page.goto('/')
    await page.getByTestId('visitor-join-code').fill('ABC123')
    await page.getByTestId('visitor-join-code').press('Enter')
    await expect(page).toHaveURL(/\/login\?redirect=(%2F|\/)join(%2F|\/)ABC123/)
    await shot(page, 'pub-03-join-needs-login')
  })

  for (const path of ['/events', '/events/new', '/me', '/profile', '/check-phone']) {
    test(`is sent to log in from ${path}`, async ({ page }) => {
      await page.goto(path)
      await expect(page).toHaveURL(new RegExp('/login\\?redirect=' + path.replace(/\//g, '(%2F|/)') + '$'))
      await expect(visible(page, 'auth-submit')).toBeVisible()
    })
  }

  test('an unknown address goes back to the homepage', async ({ page }) => {
    await page.goto('/this/page/does-not-exist')
    await expect(page).toHaveURL(/\/$/)
  })

  test('a wrong username and password shows an error and stays on the login page', async ({ page }) => {
    await page.goto('/login')
    await visible(page, 'email').fill('nobody_qa_x')
    await visible(page, 'password').fill('not-a-real-password')
    await visible(page, 'auth-submit').click()
    await expect(visible(page, 'auth-error')).toBeVisible()
    await expect(page).toHaveURL(/\/login/)
    await shot(page, 'pub-04-login-wrong')
  })

  test('sign-up checks the password rules and a taken username before it lets you submit', async ({ page }) => {
    await page.goto('/signup')
    const submit = visible(page, 'auth-submit')
    await expect(submit).toBeDisabled()
    await visible(page, 'username').fill('qa_root') // a QA account, so the name is taken
    await expect(visible(page, 'username-status')).toContainText(/taken/i)
    await visible(page, 'password').fill('short')
    await expect(visible(page, 'password-rules').locator('li.text-muted').first()).toBeVisible()
    await expect(submit).toBeDisabled()
    await shot(page, 'pub-05-signup-checks')
  })

  test('the landing page fits a 375 px phone with no sideways scroll @phone', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 })
    await page.goto('/')
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    expect(overflow).toBeLessThanOrEqual(0)
    await shot(page, 'pub-06-phone-375', { fullPage: true })
  })
})
