# GPS / Location Tracker – Checklist

Owner: Komin · Pages: `/login`, `/events`, `/events/:id`, `/events/:id/share` (`src/views/GpsTestView.vue`)

## ▶ Your next steps (in order)
1. - [x] Supabase (gpstest) → Authentication → Sign In / Providers → Email → turn **off "Confirm email"** → Save
2. - [ ] Same page → turn **off "Allow anonymous sign-ins"** → Save (Supabase still reports it ON – check it was saved)
3. - [x] Test accounts created: `komin` (Root) and `komin2` (Participant, Test group 1) in "NDP rehearsal 1"
4. - [x] Register a free OneMap account: <https://www.onemap.gov.sg/apidocs/register>
5. - [x] Supabase → Edge Functions → Secrets → add `ONEMAP_EMAIL` and `ONEMAP_PASSWORD` → tell Claude to test place names
6. - [ ] Tell teammate: shared files changed (`App.vue`, `main.js`, `router/index.js`, `package.json` – added pinia, qrcode)
7. - [ ] Run `npm install` after pulling (new packages), restart `npm run dev` (Vite only reads `.env` at start)
8. - [ ] Commit + push (check `.env` is NOT in `git status`)
9. - [ ] Laptop real-location test: normal window = `komin`, incognito = `komin2`; make one IC → Start sharing → allow location → other window's Live map shows the marker
10. - [ ] Phone real-GPS test: install the Android app (section 4), sign in, Start sharing → marker moves on the laptop's Live map

## 0. Save readings to Supabase
- [x] Scaffold Vue + Bootstrap + Leaflet/OneMap GPS page
- [x] Create `.env` (Supabase URL + publishable key)
- [x] Create `locations` table, RLS policies, Realtime
- [x] Turn on **Allow anonymous sign-ins** in Supabase (sandbox only – now replaced by real login, turn it off: next step 2)
- [x] Confirm rows arrive in `locations` (3 rows, 2026-10-06)
- [x] Add `.claude/` to `.gitignore`
- [x] Tell teammate about shared files (`package.json`, `App.vue`, router, `main.js`), then commit + push
- [x] Phone test plan: native app on the phone (no tunnel needed); laptop uses localhost

## 1. Real users, events & groups (role-based, per spec)
Done (Claude):
- [x] Database: `profiles`, `events` (6-char join code), `event_roles`, `groups`, `group_members` (admin / IC) – `supabase/migrations/002_users_events_groups.sql`, applied to gpstest
- [x] Sign-up trigger creates a profile (username + display name) for every new account
- [x] RLS: only ICs insert locations, only for their own group; root/planner/marshal see all groups; others see own group only
- [x] RLS: names (profiles) only visible to people who share an event with you
- [x] Database actions: create event, join by code, add by username, create group, assign group, set admin/IC, planner/marshal, remove/leave (root can't be removed)
- [x] RLS tested with 5 simulated users – 15/15 checks passed (test rolled back, nothing left behind)
- [x] Supabase security advisor run; internal functions locked down
- [x] Login / sign-up page (email, password, username, display name) + username-taken check
- [x] Pinia auth store + router guard (logged-out users → `/login` → back to the page they wanted)
- [x] Navbar: Events link, `@username`, Log out
- [x] Events page: my events with role badges, create event (you = Root), join with code
- [x] Event page tabs: Live map · Members · Invite
- [x] Members tab: create groups (with colour), add by username, assign group, IC / Group admin / Planner / Marshal switches, remove – each shown only to roles allowed to use it
- [x] Invite tab: code, invite link + copy, QR code, Share on WhatsApp, Share on Telegram (warns if link is localhost)
- [x] `/join/:code` link / QR → login if needed → joins event
- [x] Share page tied to my event + group; Start only enabled for ICs; "you are sharing" banner
- [x] Sharing stops automatically if IC is removed (browser: RLS error, app: HTTP 403 + queue cleared)
- [x] Logout stops phone background tracking and clears its queue
- [x] OneMap reverse-geocode Edge Function written + deployed (`supabase/functions/reverse-geocode`), OneMap secrets added
- [x] `.env.example` + README updated (setup for a new project, roles table, multi-user testing steps, credits)
- [x] Checked: pages load, login redirect works, logged-out users can't create events or read locations

Tested:
- [x] Sign up / sign in in the browser (2 accounts)
- [x] Create event (komin = Root), create group, join / add komin2, assign to Test group 1
- [x] Members tab + "You can see your group" text for a participant

Not yet tested:
- [ ] Invite tab (QR, WhatsApp, Telegram, `/join/:code` link)
- [x] Live map with someone sharing: root sees `testuser3` (Test group 2) marker, people list, "last seen"
- [x] OneMap place names: secrets added, lookup returns 200 (2026-10-06)

To do (test together, after your steps 1–3):
- [ ] Record test account emails/passwords in the README "Test accounts" table (course requirement)
- [ ] Optional: a 3rd account in a second group, to check groups can't see each other
- [ ] Root creates event + 2 groups; others join by code, link and QR; add one by username
- [x] IC shares from their real device (laptop) → root sees the initials marker
- [x] Hover / tap marker: name, place name, coordinates, accuracy, last seen
- [ ] Group member sees only own group; planner / root sees all groups
- [ ] Group admin can add/remove in own group and set IC, but can't make admins
- [ ] Remove IC while sharing → sharing stops with a message
- [ ] Check every page at 375px and 575px (DevTools device toolbar)

## 1b. One-tap sharing that keeps running
- [x] Event page: **Share my location** starts sharing immediately (no second page / second button)
- [x] One app-wide tracker: sharing continues while moving between pages; navbar shows "● Sharing location"
- [x] Browser: sharing restarts by itself after a refresh / reopened tab (remembered until Stop or logout)
- [x] Only **Stop sharing**, logout, leaving the event, or losing IC stops it
- [x] Logic tested in the browser: same tracker on every page, survives navigation + refresh, Stop clears it
- [ ] Test with your accounts: Share → go to Members / Events / Polygons → come back → still "Stop sharing"; press F5 → still sharing

## 1c. Transistorsoft check
- [x] Fixed: `ready()` now runs once per app launch (plugin rule); Start uses `setConfig()`
- [x] Android debug app builds with the plugin (`android/app/build/outputs/apk/debug/app-debug.apk`)
- [x] Built app contains background location, foreground location service, motion detection, boot restart, notification permissions
- [ ] Run on a real phone (or emulator) and confirm tracking + uploads while locked

## 2. Live map extras
- [x] One marker per person with initials in group colour (you have a dark ring)
- [x] Hover / tap tooltip: name, @username, group, place name, coordinates, accuracy, last seen
- [x] Place names cached (~11 m) so repeated hovers don't call OneMap again
- [x] User-typed names escaped before showing on the map (prevents script injection)
- [x] Group position = weighted midpoint (1 / accuracy²), ignores readings > 2 min old or > 100 m
- [x] "Last seen" text + stale (faded, 2–10 min) / offline (grey, > 10 min) styling
- [x] People list under the map (tap to zoom to a person)
- [x] Live updates via Supabase Realtime; reloads after reconnecting so nothing is missed
- [x] "Stopped sharing" state: pressing Stop saves a `source = 'stop'` row → white dashed marker + "Stopped 3:05 pm"; grey now means "lost contact" (migration 003)
- [x] Map legend: Live / no update 2–10 min / lost contact / stopped sharing
- [ ] Test: IC presses Stop (or leaves the share page) → viewer sees dashed "Stopped"; closing the tab / phone dying → grey "Lost contact" after 10 min
- [ ] Agree final stale / offline thresholds with the team

## 3. Playwright E2E tests (task 5 – 10% of grade)
- [ ] Two-user test: user A (IC) shares faked GPS → user B sees A's marker (separate browser contexts)
- [ ] Test accounts created by a setup script (service-role key only in a local test file, never in the app)
- [ ] Install Playwright, add `npm run test:e2e`
- [ ] Fake GPS with `context.setGeolocation` + `geolocation` permission
- [ ] Test: login redirect, create event, join with code
- [ ] Test: Start shows position, accuracy and table rows; Stop stops tracking
- [ ] Test: non-IC sees "Only your group's IC shares location"
- [ ] Test: permission denied shows error message
- [ ] Test at 375px and 575px widths
- [ ] Select elements only by `data-testid`
- [ ] README: how to run the tests

## 4. Background GPS on phones (Capacitor + Transistorsoft)
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
- [x] Uses the logged-in user's real event + group (no more test IDs)

To do:
- [ ] Tell teammate: `package.json` changed, `android/` + `ios/` folders added
- [ ] Install Android Studio, then `npm run cap:android` → Run on phone (USB debugging on)
- [ ] Android: allow location **"Allow all the time"**; turn off battery optimisation for the app (Xiaomi/Oppo/Samsung)
- [ ] iOS: needs a Mac + Xcode – open `ios/App`, set your Apple ID team, run on iPhone; allow location **"Always"**
- [ ] Rebuild the app (`npm run cap:sync`) after every `.env` change – keys are baked in at build time
- [ ] Test: lock phone, walk 10+ min in pocket → rows keep arriving in Supabase (check `recorded_at` gaps)
- [ ] Test: airplane mode mid-walk → queued rows sync afterwards
- [ ] Test: run > 1 hour → no 401 errors (token refresh works)
- [ ] Test: stand still 5 min → heartbeat rows about every 60 s
- [ ] Test: log out in the app → tracking stops, no more rows
- [ ] Before final demo: set `logger.debug: false` (turns off the test sounds)

## 5. Progress pitch (due Week 8 Sunday 22:00)
- [ ] One feature working end to end (login → join event → IC shares → others see it live)
- [ ] Fill progress tracker (do by / vet by per task)
- [ ] Be ready to explain: roles + RLS, join codes, Realtime, weighted midpoint, 5 s save limit, background GPS

## 6. Moving to the teammate's new Supabase project
- [ ] Teammate adds you to their Supabase organisation
- [ ] Run every file in `supabase/migrations/` in order (001, 002, …)
- [ ] Repeat dashboard settings: Confirm email off, anonymous sign-ins off, URL Configuration (localhost + https links)
- [ ] Deploy `reverse-geocode` Edge Function + add OneMap secrets there
- [ ] New URL + public key in `.env` (and Vercel later); rebuild the phone app
- [ ] Re-create test accounts, update README

## Later
- [ ] Deploy to Vercel + add the `VITE_*` env vars there
- [ ] Email invites (needs a custom email sender, e.g. Resend / Brevo – Supabase's built-in email only reaches org members)
- [ ] Delete old location rows after an event (privacy)

## Team decisions to confirm
- [ ] Leaflet + OneMap vs Google Maps (polygon page must match)
- [ ] Update frequency (time and/or distance)
- [ ] Full history vs latest position only
- [ ] When tracking starts/stops during an event
- [x] Replace anonymous sign-in with real login
