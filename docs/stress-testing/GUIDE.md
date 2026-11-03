# Stress testing guide

Step by step, for the people at the screens. The plan behind it is [STRESS-TEST-PLAN.md](STRESS-TEST-PLAN.md) (draft 3: the tests run on the team's load test in `tools/qa`). This part covers the one-time setup and **ST1 + ST2 + ST5 + ST12**, which run together in one ~35-minute run. The other tests are added here as they are built.

Who is who (as in the Tester Plan):

- **A**: ops desk, laptop. Runs the scripts and watches the website, signed in as `testuser2`.
- **B**: phone, signed in as `kayken`.
- **C**: second laptop or phone, signed in as `testuser3`.

---

## 0. Before the first run (once)

1. **Pull and install.** In the `gpstesting` folder: `npm install`.
2. **`.env.stress`**, next to `.env` (git ignores it). You already have it from before; it needs these lines:

   ```
   STRESS_PLANNER_LOGIN=testuser2@gmail.com
   STRESS_PLANNER_PASSWORD=
   STRESS_PLANNER2_LOGIN=testuser3@gmail.com
   STRESS_PLANNER2_PASSWORD=
   STRESS_MEMBER_LOGIN=kayken
   STRESS_MEMBER_PASSWORD=
   # any new password: every throwaway test account (stress_*, loadtest-NNNN) is made with it
   STRESS_PHONE_PASSWORD=
   ```

   `STRESS_CENTRE` is no longer used and can stay or go.
3. **Let one laptop sign in many people.** Supabase → **Authentication** → **Rate Limits** → "Rate limit for sign-ups and sign-ins": set it to **300** per 5 minutes and Save. (With the default, 30, setup waits a long time and the event ends up with people missing.) You can set it back after the tests.
4. **Check "Confirm email" is off.** Supabase → Authentication → Sign In / Providers → Email. It was off for the `stress_phone` accounts, so it should still be.
5. **Check the free-plan space.** Supabase → **SQL Editor**, paste [`tools/qa/sql/db_size.sql`](../../tools/qa/sql/db_size.sql), Run. Write down `database_mb`. If it is over 300, stop and ask.
6. **Make the test event:**

   ```
   npm run stress -- setup
   ```

   It shows what it will do and waits for Enter. Then it:
   - makes 3 staff accounts (`stress_root`, `stress_planner`, `stress_marshal`) and 60 people (`loadtest-0001` … `loadtest-0060@planova.test`), all with `STRESS_PHONE_PASSWORD`, so they can never be confused with real people;
   - writes a stand-in NDP plan: 20 groups around the Padang over 2 hours (`.tmp/ndp/plan.json`). If the team later gives you the real show matrix, theirs is used instead;
   - runs the team's `loadtest-seed.mjs`: it makes the event **"QA-LOADTEST NDP 2025 NE4"**, imports and publishes the plan, and the 60 people sign in and join with the code, 3 per group, the first 2 of each group as ICs (40 ICs);
   - adds testuser2 and testuser3 as planners, and kayken as a member of P&C Contingent 1.

   It takes a few minutes. Running it again is safe: what exists is left alone. Everything it writes on the laptop is in `.tmp/` (git-ignored).

---

## 1. ST1 + ST2 + ST5 + ST12: one run, about 35 minutes

### Before you press Enter

- [ ] **Tell the team** the shared Supabase project will be busy for the next 40 minutes.
- [ ] **A:** laptop plugged in, sleep turned off. Open the website as `testuser2`, Events → **QA-LOADTEST NDP 2025 NE4** → **Live map**.
- [ ] **A:** in Chrome, DevTools (F12) → ⋮ → More tools → **Rendering** → tick **Frame rendering stats** (an fps box appears).
- [ ] **B:** the website (not the app) on the phone as `kayken`, same event, Live map. If the phone app is installed with notifications on, keep it closed: B is one of the ST5 phones.
- [ ] **C:** the website as `testuser3`, same event, Live map. A second laptop is best.
- [ ] **A:** the Supabase dashboard open in another tab, ready for screenshots at the end.

### Start it

```
npm run stress -- st1
```

It shows the plan and waits for Enter. Then, by itself:

1. gets fresh sign-ins for the 60 people and the staff (they last an hour; it renews them during the run);
2. runs the team's load test for **30 minutes**. The event starts with the plan's T+0 = now. People arrive over 2 minutes. Each of the **40 ICs sends a reading every 5 s over the internet**, exactly the request the phone app sends, walking their group's route. About 8% of the people and the 3 staff keep the live map open; the staff read the ops board every 5 s;
3. plays the planner, as on the night:
   - every 5 minutes (5 times): pushes the rest of the night +30 s and **publishes** (ST12);
   - at ~16 min: the whole night +5 min, published;
   - at ~21 min: a **message to everyone** (ST5); 70% of the people tap Got it;
   - at ~25 min: holds P&C Contingent 3 for 3 minutes, published;
4. **ends the event** when it finishes, and also if you press Ctrl+C, it crashes, or the window is closed. Afterwards it checks again that nothing is left live;
5. writes the results to `docs/stress-testing/results/ST1-ST2-ST5-ST12-<date>T<time>.md` (and the raw `.json` next to it).

A status line prints every 10 s. **Ctrl+C once** stops early and still writes the results; Ctrl+C twice leaves at once (the event is still ended). If the laptop itself dies mid-run, open the event on the website and **End event** as soon as you can, or run `npm run stress -- end`.

### What each person does while it runs

Every 5 minutes (+5, +10, … +30), note on paper:

- **A:** the **fps** number on the live map, and anything that freezes, jumps, or a Needs attention list that gets stuck.
- **B and C:** pan and zoom the live map for 10 seconds: **smooth / slow / stuck**.
- **Everyone:** at each publish (every 5 minutes), does the page follow by itself, without a reload?
- **B and C at ~21 min:** when the message to everyone arrives, note the time it shows (a screenshot of the notification with the clock is best).

### After it finishes

1. **A:** Supabase → **Reports** → **Database** (CPU, memory) and **Realtime** (messages, connections). Set the time range to the run and take screenshots; put them next to the results file.
2. **A:** open the new results `.md`. Copy its SQL into **Supabase → SQL Editor**, Run, and paste the result table under "Result". That is the **"engine tick on time"** check: row `gps-plan-push`, column `p95_s`, must be under 2, and `failed` must be 0.
3. **A:** run [`db_size.sql`](../../tools/qa/sql/db_size.sql) again and write before/after `database_mb` in the file.
4. Fill in the hand tables (fps, smooth/slow/stuck, B and C's message times) and the notes from A, B and C.
5. Send the results file back to Claude in the project thread.

### How to read the results

| Test | Passes when |
|---|---|
| ST1 | every reading accepted; ops board read p95 under 5 s (so a change shows within 10 s); `gps-plan-push` p95 under 2 s and none failed (SQL Editor) |
| ST2 | a reading reaches an open map within 10 s (p95); no viewer dropped; laptop map 30+ fps; phones smooth or slow, never stuck |
| ST5 | the message is sent; B and C get it within 10 s |
| ST12 | 5 of 5 publishes accepted, and every phone open at the time heard each one within 30 s |

If it stops with an error, the message says what to do: a missing function (a migration is not applied: `npm run db:status`), a sign-in problem (check `.env.stress`), or an account that needs its email confirmed (step 0.4).

### Options

```
npm run stress -- st1 --minutes 10            a short trial run first (recommended the first time)
npm run stress -- st1 --switches 0            no extra publishes (ST12 off)
npm run stress -- st1 --users 30              only the first 30 people
npm run stress -- setup --users 120 --fresh   a bigger crowd: a new event with 120 people (for later tests)
npm run stress -- end                         end the load-test event by hand
```

### Cleaning up for good

- The event "QA-LOADTEST NDP 2025 NE4" can stay: about 15,000 readings per 30-minute run, under 5 MB. Its root is `stress_root`, so ask Claude for a cleanup query when you want it gone.
- The accounts: Supabase → Authentication → Users, search `loadtest-` and `stress-`, delete.
- The rate limit: set "sign-ups and sign-ins" back to what it was.

The old `tools/stress` scripts were retired on 1 Nov (they ran on the run-sheet engine, which the team replaced). The "NDP sim" event and its virtual groups are left as they are; ST4 will use them again.
