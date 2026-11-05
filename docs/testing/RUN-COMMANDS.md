# Team test commands (TEAM-TESTS.pdf)

Run from the `gpstesting` folder. Every pair below was run on Kenneth's laptop on 5 Nov and matched the PDF. Times change a little from run to run.

## Linus — timeline planner
```
npx vitest run src/utils/__tests__/planWalk.spec.js src/components/__tests__/PlanProblems.spec.js
npx playwright test --project=desktop e2e/planning.spec.js e2e/touch.spec.js -g "a group with no position|a finger a little off"
```
Vitest: Test Files 2 passed (2), Tests 5 passed (5). Playwright: 2 passed.

## Komin — live operations dashboard
```
npx vitest run src/utils/__tests__/permissions.spec.js src/components/__tests__/EventOverview.spec.js
npx playwright test --project=desktop e2e/komin.spec.js
```
Vitest: Test Files 2 passed (2), Tests 3 passed (3). Playwright: 2 passed.

## Ern Qi — attendance
```
npx vitest run src/composables/__tests__/useAttendance.spec.js src/components/__tests__/AttendancePanel.spec.js
npx playwright test --project=desktop e2e/sos-attendance.spec.js -g "roll call by hand|in QR mode"
```
Vitest: Test Files 2 passed (2), Tests 3 passed (3). Playwright: 2 passed.

## Rui Heng — event setup and invite
```
npx vitest run src/stores/__tests__/eventWizard.spec.js src/components/__tests__/InvitePanel.spec.js
npx playwright test --project=desktop e2e/wizard.spec.js e2e/event-flow.spec.js -g "root makes an event|someone outside joins"
```
Vitest: Test Files 2 passed (2), Tests 3 passed (3). Playwright: 2 passed.
Playwright lists files alphabetically, so event-flow prints before wizard. For the PDF's order, run them one at a time:
```
npx playwright test --project=desktop e2e/wizard.spec.js
npx playwright test --project=desktop e2e/event-flow.spec.js -g "someone outside joins"
```

## Kenneth — groups and users
```
npx vitest run src/utils/__tests__/people.spec.js src/components/__tests__/MembersPanel.spec.js src/components/__tests__/PeoplePanel.spec.js
npx playwright test --project=desktop e2e/kenneth.spec.js
```
Vitest: Test Files 3 passed (3), Tests 3 passed (3). Playwright: 2 passed.

## Hazel — venue areas on the map
```
npx vitest run src/utils/__tests__/areaShape.spec.js src/components/__tests__/AreaListGroups.spec.js
npx playwright test --project=desktop e2e/hazel.spec.js e2e/planning.spec.js -g "No-Go is still No-Go|a locked area"
```
Vitest: Test Files 2 passed (2), Tests 3 passed (3). Playwright: 2 passed.

## Things to know
- The e2e tests need the team's full `.tmp/qa-accounts.json` (root, planner, admin, ic1, ic2, member, outsider), and Playwright's browser (`npx playwright install chromium`, once).
- If the demo names are switched on (`node tools/demo/take-setup.mjs names on`), the tests that look for "QA Member" fail. Run `names off` first.
- Four existing tests were edited so they also run on their own with `-g`: in planning.spec.js, touch.spec.js and sos-attendance.spec.js. No titles or checks changed, and the whole files still pass.
- "Internal error: step id not found: fixture@…" in the output is a harmless Playwright warning about its end-of-test screenshot; the test result is unaffected.
- Clean up QA events afterwards: `node -e "import('./e2e/support/fixture.js').then(m=>m.deleteQaEvents()).then(n=>console.log('deleted',n))"`
