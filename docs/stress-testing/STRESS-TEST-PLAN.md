# Stress test plan: ST1–ST12 (draft 3, on the team's `tools/qa` load test)

Draft 3, 1 Nov. Replaces draft 2, which was built on the run-sheet engine. Approved by Kenneth on 1 Nov (Q1: build the stand-ins; Q2: settings in `loadtest.mjs`; Q3: delete `tools/stress`). **Built so far:** 2.1 to 2.4 and the ST1 + ST2 + ST5 + ST12 run. Two changes from the draft while building are marked *Built:* below.

## 0. Why the plan changed

- The team replaced the run-sheet engine with **plans** (migrations 037–067). Migration 061 deleted run sheets, cues, movements, `show_board`, `ops_board`, `switch_live_run_sheet` and the 2 s / 5 s show and movement ticks. That is why `npm run stress -- st1` now fails: `tools/stress` imported a file (`runSheetFile.js`) that is gone, and most of the functions it calls are gone too.
- The team already wrote a load test for the new engine in **`tools/qa`**. It is better than what I would rebuild:
  - `loadtest-seed.mjs` makes a real event ("QA-LOADTEST NDP 2025 NE4", 46 groups), imports and publishes a 1,135-moment NDP plan, and has 1,000 accounts join with the event code (a timed join storm). The first 2 people of each group are ICs.
  - `loadtest.mjs` makes every person a real signed-in client doing what the app does at the app's own intervals. **The ICs send a reading every 5 s to `/rpc/report_location` over the internet**, the same request the phone sends (your "it must really travel over the internet"). 8% of people keep the map open, and it measures how long a reading takes to reach a map. Staff poll `plan_ops` every 5 s. At +360 s the planner shifts the whole plan +5 min and publishes, at +450 s sends a broadcast (70% tap Got it), at +560 s holds one contingent 3 min. Every call is timed into `.tmp/loadtest/result-<time>.json`.
  - `loadtest-signin.mjs` refreshes sign-ins, `loadtest-topup.mjs` adds people, `loadtest-observe.mjs` watches the real website in a browser, `ndp-plan.mjs` builds the plan from the NDP show matrix and map.
- The **simulator still exists** and now walks virtual groups along the published plan. `sim_start` refuses unless a plan is live.
- The cron jobs now are `gps-plan-push` (5 s), `gps-plan-eta` (30 s), `gps-sim-tick` (10 s), plus four housekeeping jobs. These replace "the engine tick" in the Tester Plan.

## 1. What `tools/qa` is missing for our tests

1. **Three inputs that are not in the repo.** `.tmp/qa-accounts.json` (the QA accounts `qa_root`, `qa_planner`, `qa_marshal`… and the password of the `loadtest-NNNN@planova.test` accounts, made by a "QA setup" that is not in the repo either), the **NDP show matrix `.xlsx`** and the **NDP map `.kml`** that `ndp-plan.mjs` reads. Your folder has no `.tmp` at all. See Q1.
2. **Sizes made for a paid project.** It defaults to 1,000 people. Your project is the free Nano one that went Unhealthy on 25 Oct, so we start at **60 people** (3 in each of the stand-in plan's 20 groups, 2 of them ICs) and step up.
3. **It never ends the event.** It ends the previous run's session at the start, but leaves its own session live afterwards, so the 5 s / 30 s plan jobs keep working on it. If it crashes, nothing stops anything.
4. **Results only as JSON in `.tmp`**: no pass/fail against the Tester Plan, no cron timing (engine tick), no database size before/after.
5. **No token refresh.** Sign-ins last an hour and `loadtest.mjs` does not refresh them, so a 3-hour ST7 would go silent after 60 minutes.
6. Nothing for ST4 (lots of late groups), ST8 (two planners pressing at once), ST9 (a broken sheet), ST10 (big bench) or ST11 (field).

## 2. What I will build

Everything stays plain Node scripts, like `tools/qa`. Our passwords stay in `.env.stress` (git-ignored), never in code.

### 2.1 Retire `tools/stress`

Delete the `tools/stress` folder and replace the `"stress"` line in `package.json` (see 2.4). Keep three SQL files, moved to **`tools/qa/sql/`**: `db_size.sql`, `cleanup_demo_sim.sql` (for the record) and `tick_timing.sql` (updated to the new job names). Results still go to `docs/stress-testing/results/`.

### 2.2 New files in `tools/qa` (only if Q1 says we must make our own inputs)

*Built:* the accounts part lives in `stress.mjs` (`npm run stress -- setup`) rather than its own file, and it makes its own staff accounts (`stress_root`, `stress_planner`, `stress_marshal`) because the team's scripts give every QA account the same password. testuser2 and testuser3 join the event as planners, and kayken as a member, so A, B and C can watch on the website.

- **`stress-accounts.mjs`** writes `.tmp/qa-accounts.json` from `.env.stress`: `root` = testuser2, `planner` = testuser3, `member` = kayken, `marshal` = one new throwaway account. It creates only as many `loadtest-NNNN@planova.test` people as the run needs (`USERS=50` makes 50), with `STRESS_PHONE_PASSWORD`. Running it again creates nothing that already exists.
- **`stress-plan.mjs`** writes `.tmp/ndp/plan.json` in exactly the shape `ndp-plan.mjs` writes, without the xlsx / KML: 10 groups around the Padang, about 120 moments over 2 hours, walks under the 25 m rule. A stand-in until we have the real files.

### 2.3 Small additions to the team's scripts (off unless you set them)

Each one is an environment setting that is off by default, so the team's own runs behave exactly as today:

| Setting | In | What it does |
|---|---|---|
| `END_AT_FINISH=1` | `loadtest.mjs` | Ends the event when the run finishes, and on Ctrl+C, a crash or the window closing (pauses the simulator too). Always on for our runs, through the wrapper below. |
| ~~`SIM_GROUPS=50`~~ | — | *Built:* dropped. The simulator only runs in a simulation event (`sim_check`), and the load-test event is a normal one. ST1's volume comes from the internet phones instead: the stand-in plan has 20 groups, so 40 ICs send a reading every 5 s. The simulator returns for ST4, in "NDP sim". |
| `REPUBLISH_EVERY_S=240` | `loadtest.mjs` | ST12: shifts and republishes every N s, and times how long until every phone's `session_timetable` shows the new revision. |
| `REFRESH_TOKENS=1` | `loadtest.mjs` | Refreshes each person's sign-in before it expires (needed for ST7). |

### 2.4 The wrapper: `tools/qa/stress.mjs` (still `npm run stress -- st1`)

So you still type one command per test. It:

1. checks `.env.stress`, the functions it needs, and the **database size** (stops above 300 MB);
2. runs the team scripts in order with the test's settings (seed if needed, then sign-in, then `loadtest.mjs`);
3. after the run, reads the result JSON and writes `docs/stress-testing/results/STn-<date>.md` with each Tester Plan line marked pass / fail / record-only, plus the SQL Editor query with the run's times filled in.

`GUIDE.md` is rewritten to match (setup, then ST1 + ST2 + ST5 + ST12 step by step).

## 3. The twelve tests on the new engine

"Size" is where we start; we step up only after a clean run.

| Test | Tester Plan expects | How, on `tools/qa` | Size |
|---|---|---|---|
| **ST1 Volume** | engine tick on time; Needs attention updates within 10 s | `loadtest.mjs` for 30 min with internet phones. Engine tick: `gps-plan-push` p95 under 2 s and none failed (`tick_timing.sql`). "Within 10 s": time from a reading to `plan_ops` showing it. | 60 people (40 ICs) |
| **ST2 Many viewers** | map smooth; record Realtime and CPU | Already in `loadtest.mjs`: "location reached a map" delay, channel joins and drops. Pass: p95 under 10 s, no drops. People: A's fps, B/C smooth / slow / stuck, as before. | with ST1 |
| **ST3 Start spike** | all heard in 30 s, no backlog | `RAMP_S=0`, every phone starts in the same second. Waves of 10, 30, 100 people; stop at the first wave with errors or `report_location` over 5 s. | 10 → 100 |
| **ST4 Everyone late** | list usable, banner not buried | Simulator with mix `stops_halfway 70 / late_2min 20 / on_time 10` until `plan_ops` lists 200+. Time `plan_ops` at 50 / 100 / 200. A checks search, filter, order and banner by hand. | 250 virtual groups |
| **ST5 Push burst** | B and C get theirs within 10 s | Already in `loadtest.mjs` (the +450 s broadcast and ack storm). B and C's real phones note the arrival time. | with ST1 |
| **ST6 Breaking point** | the number, and what slowed first | `loadtest.mjs` at 50, 100, 200, 300 people, 5 min each. Stops at the first step with errors, `report_location` p95 over 3 s, map delay over 10 s, or database over 400 MB. | up to 300 |
| **ST7 Long show** | no slow-down; B shares all along; battery under 25% | 3 hours with `REFRESH_TOKENS=1`. First 15 min vs last 15 min within 20%. B's real phone shares the whole time. | 50 people + 100 virtual groups |
| **ST8 Rapid presses** | no double changes; same on every screen; all in the log | New `stress-presses.mjs`: testuser2 and testuser3 fire `frame_shift`, `frame_hold` and `plan_publish` at the same time for 60 s. Check every success is in `plan_log_list`, both read the same revision, no negative times in `session_timetable`. | 10 people |
| **ST9 Big sheet** | import under 30 s, every problem listed by row | Time `plan_import` of the full plan (1,135 moments if we have the NDP files). A broken copy with 10 known mistakes, imported through the website: each one named with its row. | one plan |
| **ST10 Big bench** | smooth dragging, warning before 4 MB, map loads under 3 s | As in draft 2 (100 zones, 3 floor plans near 4 MB), after I check the zone and floor-plan functions still exist. | — |
| **ST11 Crowded network** | late but in order, no false "No signal" | Field test as in draft 2, with a small watch script. | B and C |
| **ST12 Many switches** | every switch lands for all groups | Run-sheet versions no longer exist. The new equivalent is a **republished plan**: 5 republishes during ST1. Pass: every phone shows the new revision within 30 s. | with ST1 |

**Every run ends the event and pauses the simulator**, even on a crash, and the results file says if anything could not be stopped.

Build order: 2.1 to 2.4, then ST1 + ST2 + ST5 + ST12 as one run, and stop for you to run it. Then ST3, ST4, ST8, ST9, ST10, ST6, ST7 and ST11, one at a time.

## 4. Questions for you

- **Q1. The team's inputs.** Does whoever wrote `tools/qa` have `.tmp/qa-accounts.json`, the NDP show matrix `.xlsx` and the NDP `.kml`, and did they run it against **your** Supabase project? If yes, copy those three into your folder and I use them as they are. If no, I build `stress-accounts.mjs` and `stress-plan.mjs` (2.2). *Suggestion: ask them, and I build the stand-ins meanwhile so you are not blocked.*
- **Q2. Changing the team's file.** OK to add the off-by-default settings in 2.3 to `loadtest.mjs`? The alternative is a copy (`loadtest-stress.mjs`), which drifts whenever they change theirs. *Suggestion: the settings.*
- **Q3. Deleting `tools/stress`.** OK to delete the folder (the SQL files move to `tools/qa/sql/`)? You will need to allow deleting once.
