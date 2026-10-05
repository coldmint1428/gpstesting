# GPS / Location Tracker – Checklist

Owner: Komin · Page: `/gps` (`src/views/GpsTestView.vue`)

## 0. Save readings to Supabase
- [x] Scaffold Vue + Bootstrap + Leaflet/OneMap GPS page
- [x] Create `.env` (Supabase URL + publishable key)
- [x] Create `locations` table, RLS policies, Realtime
- [x] Turn on **Allow anonymous sign-ins** in Supabase
- [x] Confirm rows arrive in `locations` (3 rows, 2026-10-06)
- [x] Add `.claude/` to `.gitignore`
- [ ] Tell teammate about shared files (`package.json`, `App.vue`, router, `main.js`), then commit + push
- [ ] Phone test: needs https – use a tunnel for now (Vercel deploy postponed)

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

## 5. Tracker wrapper + phone app (task 6)
- [ ] Move GPS logic into `src/composables/useLocationTracker.js` (`start`, `stop`, `current`, `readings`)
- [ ] Ask instructor if Transistorsoft is allowed (fallback: `@capgo/background-geolocation`)
- [ ] Tell teammate before adding Capacitor / `android/` / `ios/`
- [ ] Set up Capacitor + background-GPS plugin (check current official docs)
- [ ] Native upload to Supabase with user token + token refresh
- [ ] Heartbeat ~every 60 s when stationary
- [ ] Phone tests: locked 10+ min walking, airplane-mode sync, > 1 hour (no 401s)

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
