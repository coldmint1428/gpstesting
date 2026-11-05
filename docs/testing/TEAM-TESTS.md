# The five tests each: one key feature per person

Every member owns one key feature and five tests for it: **1 unit, 2 component, 2 E2E**. Thirty in all — 22 written for
this, and 8 that already existed and already covered the feature, which are named here rather than duplicated.

| Level | What it means here | Where it lives | Runs with |
|---|---|---|---|
| Unit | one pure function, no DOM, no database | `src/**/__tests__/*.spec.js` (Vitest) | `npm run test:unit` |
| Component | one Vue component mounted with `@vue/test-utils`, its props in, its emits out; no network | `src/components/__tests__/*.spec.js` (Vitest + jsdom) | `npm run test:unit` |
| E2E | the real app against the real Supabase, in a real browser | `e2e/**/*.spec.js` (Playwright) | `npm run test:e2e` |

Run one person's five:

```bash
# Komin
npx vitest run src/utils/__tests__/permissions.spec.js src/components/__tests__/EventOverview.spec.js
npx playwright test e2e/komin.spec.js

# Rui
npx vitest run src/stores/__tests__/eventWizard.spec.js src/components/__tests__/InvitePanel.spec.js
npx playwright test e2e/wizard.spec.js e2e/event-flow.spec.js -g "root makes an event|someone outside joins"

# Hazel
npx vitest run src/utils/__tests__/areaShape.spec.js src/components/__tests__/AreaListGroups.spec.js
npx playwright test e2e/hazel.spec.js e2e/planning.spec.js -g "No-Go|locked area"

# Linus
npx vitest run src/utils/__tests__/planWalk.spec.js src/components/__tests__/PlanProblems.spec.js
npx playwright test e2e/planning.spec.js e2e/touch.spec.js -g "Place on map|frame dot"

# Em
npx vitest run src/composables/__tests__/useAttendance.spec.js src/components/__tests__/AttendancePanel.spec.js
npx playwright test e2e/sos-attendance.spec.js

# Kenneth
npx vitest run src/utils/__tests__/people.spec.js src/components/__tests__/PeoplePanel.spec.js src/components/__tests__/MembersPanel.spec.js
npx playwright test e2e/kenneth.spec.js
```

## Komin — the live operations dashboard

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/utils/__tests__/permissions.spec.js` | gives the whole event to the root and the planners, and everyone else their own group | new |
| 2 | Component | `src/components/__tests__/EventOverview.spec.js` | reads out the status and the counts it was given, and shows the invite code to staff only | new |
| 3 | Component | `src/components/__tests__/EventOverview.spec.js` | will not save an end that is before the start, and saves nothing until something has changed | new |
| 4 | E2E | `e2e/komin.spec.js` | the dashboard counts the event, and a member is shown neither the count nor the invite code | new |
| 5 | E2E | `e2e/komin.spec.js` | the live map keeps working when the OneMap tiles do not load | new |

## Rui — event setup and invite

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/stores/__tests__/eventWizard.spec.js` | names the missing detail at step 1 and the reason at step 3, and nothing on a step that is fine | new |
| 2 | Component | `src/components/__tests__/InvitePanel.spec.js` | shows one code in every place it is offered: the panel, the link and both shares | new |
| 3 | Component | `src/components/__tests__/InvitePanel.spec.js` | copies the code, and still explains itself when the browser refuses the clipboard | new |
| 4 | E2E | `e2e/wizard.spec.js` | root makes an event with people and a group, then deletes it | existed |
| 5 | E2E | `e2e/event-flow.spec.js` | someone outside joins with the code and lands in the event as a member | existed |

## Hazel — the venue's areas on the map

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/utils/__tests__/areaShape.spec.js` | calls a plain square legal, refuses a bow tie, and does not mistake a shared corner for a crossing | new |
| 2 | Component | `src/components/__tests__/AreaListGroups.spec.js` | groups the areas by type in the order of the type dropdown, and says nothing about a type with none | new |
| 3 | Component | `src/components/__tests__/AreaListGroups.spec.js` | keeps a type this build does not know in Other, and changes the name and the code only when they are valid | new |
| 4 | E2E | `e2e/hazel.spec.js` | an area drawn as No-Go is still No-Go after a reload, and is listed under it | new |
| 5 | E2E | `e2e/planning.spec.js` | a locked area lets presses through, and the lock is stored on the shape | existed |

## Linus — the timeline planner

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/utils/__tests__/planWalk.spec.js` | folds the points a group only walks through into the stop it walks on from | existed |
| 2 | Component | `src/components/__tests__/PlanProblems.spec.js` | separates errors from warnings, and keeps a dismissed warning out of the way until it is asked for | new |
| 3 | Component | `src/components/__tests__/PlanProblems.spec.js` | gives the fixes to a planner, and only points a reader at where the problem is | new |
| 4 | E2E | `e2e/planning.spec.js` | a group with no position is placed with "Place on map" and one tap | existed |
| 5 | E2E | `e2e/touch.spec.js` | a finger a little off a frame dot still opens that frame | existed |

## Em — attendance (roll call, by hand and by QR)

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/composables/__tests__/useAttendance.spec.js` | accepts exactly what the IC screen shows, and refuses anything else without guessing | new |
| 2 | Component | `src/components/__tests__/AttendancePanel.spec.js` | by hand: counts who is present, who is not marked yet, and sends the one mark that was asked for | new |
| 3 | Component | `src/components/__tests__/AttendancePanel.spec.js` | by QR: shows the code that changes every 5 seconds, and only a planner may still tick somebody by hand | new |
| 4 | E2E | `e2e/sos-attendance.spec.js` | the IC takes a roll call by hand; the member sees they are marked present | existed |
| 5 | E2E | `e2e/sos-attendance.spec.js` | in QR mode the member checks in with the code on the IC's screen, and an old code is refused | existed |

## Kenneth — groups and users

| # | Level | File | Test | |
|---|---|---|---|---|
| 1 | Unit | `src/utils/__tests__/people.spec.js` | draws initials, escapes a name before it becomes markup, and says how long ago a reading was | new |
| 2 | Component | `src/components/__tests__/PeoplePanel.spec.js` | offers a role change only on the rows this role may change, and only the roles somebody actually has | new |
| 3 | Component | `src/components/__tests__/MembersPanel.spec.js` | opens on my own group and only that one, with no controls for a member who may not change it | new |
| 4 | E2E | `e2e/kenneth.spec.js` | a planner moves a person from one group to another, and the database agrees | new |
| 5 | E2E | `e2e/kenneth.spec.js` | the People page is still usable on a phone, with no sideways scroll | new |

Stress testing is out of scope by agreement: it is not repeatable enough to be one of the five, and it lives on its own
as `npm run stress`.

## Status: what has actually been run

| | State |
|---|---|
| The 17 new unit and component tests | **Run and green**: `npm run test:unit` → 30 files, 131 tests, all passing (was 18 files / 114) |
| The 12 E2E tests behind the six people | **Run and green** against the live backend (desktop Chrome, 20:36–23:35 SGT): 27 passed in the eight-file run, then `sos-attendance.spec.js` and `wizard.spec.js` re-run on their own — 8 passed |
| The 8 existing tests named above | In the suite and green in the same run |

The existing E2E tests are unchanged: `e2e/privacy.spec.js`, `e2e/roles.spec.js`, `e2e/tour.spec.js`,
`e2e/wizard.spec.js` and `e2e/sos-attendance.spec.js` are all as they were committed. They pass against the current
accounts file, whose profiles in Supabase carry the display names the tests expect (`QA Member`, `QA Root`).

## What was deliberately not written

- **API-level or database-only tests for a person's five.** The rubric asks for unit, component and E2E; the SQL suites
  (`npm run test:db`) already cover the rules underneath and are not counted here.
- **A second test of something an existing test already proves.** Each row above says what it proves; where the same
  thing was already covered, the existing test is named instead of a near-copy.
- **Tests that need a phone.** The native tab bar and push notifications exist only in the Capacitor build
  (`isNativeApp`), so a browser E2E cannot reach them; the components behind them are covered where they can be.

## Running the E2E half: two prerequisites

1. **The browsers.** `npx playwright install chromium` (a fresh machine has none; without it every test fails with
   `Executable doesn't exist`).
2. **The accounts.** `e2e/support/session.js` reads `.tmp/qa-accounts.json` — the QA accounts and their shared password,
   git-ignored, made by the team's QA setup. Without it Playwright cannot even list the suite. With both in place,
   `npm run test:e2e` starts the app on `http://localhost:5173` itself, or use `E2E_BASE=` for the deployed site.
