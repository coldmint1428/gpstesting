# GPS / Location Tracker – Checklist

Owner: Komin · Page: `/gps` (`src/views/GpsTestView.vue`)

## 0. Save readings to Supabase
- [x] Scaffold Vue + Bootstrap + Leaflet/OneMap GPS page
- [x] Create `.env` (Supabase URL + publishable key)
- [x] Create `locations` table, RLS policies, Realtime
- [x] Turn on **Allow anonymous sign-ins** in Supabase
- [x] Confirm rows arrive in `locations` (3 rows, 2026-10-06)
- [x] Add `.claude/` to `.gitignore`
- [x] Tell teammate about shared files (`package.json`, `App.vue`, router, `main.js`), then commit + push
- [x] Phone test: needs https – use a tunnel for now (Vercel deploy postponed)

## 1. Live viewer (task 2)
- [ ] Load latest reading per user for the test event
- [ ] Subscribe to Supabase Realtime for new `locations` rows
- [ ] One marker per IC, moves on each new reading
- [ ] Hover/tap marker shows name (user id for now)
- [ ] Test with two devices sharing at once

## 2. Group position (task 3)
- [ ] Weighted midpoint, weight = 1 / accuracy²
- [ ] Ignore stale (e.g. > 2 min) and inaccurate (e.g. > 100 m) readings
- [ ] One group marker in the group's colour
- [ ] Keep the formula in its own small function (testable, easy to explain)

## 3. "Last seen" + stale styling (task 4)
- [ ] "Last seen X min ago" on each marker, refreshed by a timer
- [ ] Fade/grey markers that stop updating
- [ ] Agree thresholds (e.g. < 1 min live, 1–5 min stale, > 5 min offline)

## 4. Playwright E2E tests (task 5 – 10% of grade)
- [ ] Install Playwright, add `npm run test:e2e`
- [ ] Fake GPS with `context.setGeolocation` + `geolocation` permission
- [ ] Test: Start shows position, accuracy and table rows
- [ ] Test: Stop stops tracking
- [ ] Test: permission denied shows error message
- [ ] Test at 375px and 575px widths
- [ ] Select elements only by `data-testid`
- [ ] README: how to run the tests

## 5. Background GPS on phones (Capacitor + Transistorsoft)
Goal: Android + iOS keep tracking with the screen locked / phone asleep.

Done:
- [x] Install Capacitor 8 + `@transistorsoft/capacitor-background-geolocation` v9.6
- [x] `capacitor.config.json` (app "Event Tracker", id `sg.edu.smu.is216.g11`) + `android/` and `ios/` projects
- [x] Tracker wrapper `src/composables/useLocationTracker.js` – browser uses `watchPosition`, app uses Transistorsoft; page never imports the plugin
- [x] Native upload straight to Supabase `locations` (works while JS is paused; queued offline)
- [x] Token refresh via Supabase `/auth/v1/token?grant_type=refresh_token` on 401, synced with supabase-js
- [x] Heartbeat every 60 s while stationary
- [x] Android: plugin versions in `android/variables.gradle`, licence note in `AndroidManifest.xml`
- [x] iOS: Background Modes (location, fetch, processing) + permission texts in `Info.plist`
- [x] Browser mode re-tested (readings, 5 s save limit, Stop)

To do:
- [ ] Tell teammate: `package.json` changed, `android/` + `ios/` folders added
- [ ] Install Android Studio, then `npm run cap:android` → Run on phone (USB debugging on)
- [ ] Android: allow location **"Allow all the time"**; turn off battery optimisation for the app (Xiaomi/Oppo/Samsung)
- [ ] iOS: needs a Mac + Xcode – open `ios/App`, set your Apple ID team, run on iPhone; allow location **"Always"**
- [ ] Test: lock phone, walk 10+ min in pocket → rows keep arriving in Supabase (check `recorded_at` gaps)
- [ ] Test: airplane mode mid-walk → queued rows sync afterwards
- [ ] Test: run > 1 hour → no 401 errors (token refresh works)
- [ ] Test: stand still 5 min → heartbeat rows about every 60 s
- [ ] Before final demo: set `logger.debug: false` (turns off the test sounds)

## 6. Progress pitch (due Week 8 Sunday 22:00)
- [ ] One feature working end to end (steps 0 + 1 is a strong demo)
- [ ] Fill progress tracker (do by / vet by per task)
- [ ] Be ready to explain: 5 s save limit, sign-in + RLS, Realtime

## Later
- [ ] Deploy to Vercel + add the four `VITE_*` env vars there

## Team decisions to confirm
- [ ] Leaflet + OneMap vs Google Maps (polygon page must match)
- [ ] Update frequency (time and/or distance)
- [ ] Full history vs latest position only
- [ ] When tracking starts/stops during an event
- [ ] Replace anonymous sign-in with real login before final submission
