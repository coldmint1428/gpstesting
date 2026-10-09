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
9. - [x] Laptop real-location test: normal window = `komin`, incognito = `komin2`; make one IC → Start sharing → allow location → other window's Live map shows the marker
10. - [x] Phone real-GPS test: Android app installed, sharing as `testuser1` → marker on the laptop's Live map

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
- [x] Root creates event ("NDP rehearsal 1") + 2 groups; others join by code; members assigned to groups, ICs set (5 members)
- [ ] Join by invite link and QR code; add someone by username
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
- [ ] Phone app: Share → go to other pages → come back → still "Stop sharing" + navbar badge (please confirm)
- [ ] Browser: press F5 while sharing → still sharing

## 1c. Transistorsoft check (real phone: Galaxy S25 Ultra, Android 16)
Fixes made during phone testing:
- [x] `ready()` runs once per app launch (plugin rule); Start applies settings with `reset(config)`
- [x] Android "provider change" record broke uploads (400 `provider` column) → `disableProviderChangeRecord: true`; a 400 now clears the stuck queue
- [x] Listeners were wiped by an un-awaited `removeListeners()` → removed
- [x] Tracking started in "stationary" mode (no readings while standing) → `changePace(true)` after start
- [x] Login token expired after 1 h and the plugin's refresh can't talk to Supabase (form vs JSON) → **tracking pass** + `report_location()` (migration 004); no login token on the phone
- [x] Reopened app showed "Share" while tracking ran → remembers the event, else asks `my_active_tracking_pass()`; old-style tracking is stopped cleanly
- [x] Test sounds off (`debug: false`), log level Info (no token in the phone log)

Tests passed on the phone:
- [x] Android app builds, installs and runs; all permissions present (background location, foreground service, motion, boot, notifications)
- [x] Uploads accepted (201/204) through `report_location` with the tracking pass
- [x] App open: reading every ~30 s
- [x] Home screen + locked: reading every ~30 s (one ~55 s gap only at the moment the app leaves the screen)
- [x] Swiped away from Recents + locked: readings continue every ~30 s, no gaps (`stopOnTerminate: false`)
- [x] Fake / cancelled pass → 403; non-IC can't get a pass (database test)
- [x] Battery saver ON: warning shown in the app (detection works)
- [x] Battery saver ON + locked: reading every ~31 s (same as normal)
- [x] Battery saver ON + swiped away + locked: readings continue every ~31 s (two ~50–57 s gaps, still well inside the 2-min "Live" window)
- [x] Reopen after swipe → event page shows **Stop sharing** (confirmed)
- [x] Long run (6.5 h overnight, 01:13–07:43): swiped away, locked, unplugged, still, battery saver ON → **no upload errors** (tracking pass works for hours – the 1-hour token problem is gone)
- [x] ⚠️ Same run (battery saver ON): readings every 30 s for the first ~40 min, then Android deep sleep (Doze) cut it to short bursts every ~20–36 min (152 readings instead of ~780). Battery 97% → 88% (≈1.4%/h, low because Doze kept GPS off most of the night). Next: repeat with battery saver OFF + battery "Unrestricted" to see what causes it and measure real full-rate battery use; then decide on a fix / IC instructions
- [x] **3.6 h run with battery saver OFF** (07:53–11:32), app Unrestricted, swiped away, locked, unplugged, still: **434 readings, median gap 30 s, longest gap 53 s, no gap over 2 min**, battery 87% → 77% (**≈2.7% per hour** at full 30 s rate) → battery saver caused the overnight gaps; Doze alone does not
- [ ] IC instructions: turn battery saver OFF while sharing (the app already warns); for phones that must keep it on, consider a stronger fix later
- [x] Real outing 7.7 h (16:57–00:38, ~49 km incl. transport), battery saver ON, app in background: **574 readings, median gap 31 s, 0 gaps over 10 min, longest 6 min, 0 upload errors**. Moving hours ≈ full rate (91–97/h); sitting still with battery saver → some 2–6 min gaps (marker fades, never "lost contact"). Battery 84% (18:05) → 47% (00:38) ≈5.6%/h incl. normal phone use, train and mobile data. MRT tunnels: 1.5–4.6 min gaps – no GPS underground and readings worse than 100 m are discarded (no delayed uploads, 0 out of order)
- [ ] Airplane mode mid-walk → queued readings upload afterwards
- [x] Log out in the app → "Stopped" row saved, location services OFF, tracking pass cancelled, no more rows
- [ ] Other Android brands (ideally a Xiaomi or Oppo – most aggressive at killing background apps)

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
- [x] Test: IC presses Stop → viewer sees dashed "Stopped"; closing the tab / phone dying → grey "Lost contact" after 10 min (leaving a page no longer stops sharing – see 1b)
- [ ] Agree final stale / offline thresholds with the team

- [x] Fixed (code): map went blank at the last zoom step (`detectRetina` lowered the tile layer's max zoom) → shared `src/utils/onemap.js`, no detectRetina, `maxNativeZoom: 19` (zoom 20 enlarges zoom-19 tiles)
- [ ] Check the zoom fix on the website (after push/deploy) and in the phone app (next install)
- [x] Smooth live map (`src/utils/markerMotion.js`): markers **glide** (1 s) instead of jumping; big jumps (> 500 m or after > 90 s gap) still jump; **GPS wobble ignored** (moves smaller than the reading's accuracy, 5–25 m)
- [x] Replayed the 7.7 h outing (574 readings): still → marker stays put 94% of the time (no twitching); walking → 63 glides; vehicle → 62 glides + 25 jumps; tunnel gaps → 18 jumps; marker never more than 22 m from the real reading
- [x] Follow mode: tap a person in the list → map zooms in and keeps them centred as they move (pans with the glide); "Following X · Stop" bar on the map; dragging the map stops following
- [ ] Check the smooth map + follow mode on the website (after push/deploy) and in the phone app (next install)

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
Goal: Android + iOS keep tracking with the screen locked / phone asleep / app swiped away.

Done:
- [x] Install Capacitor 8 + `@transistorsoft/capacitor-background-geolocation` v9.6
- [x] `capacitor.config.json` (app "Event Tracker", id `sg.edu.smu.is216.g11`) + `android/` and `ios/` projects
- [x] Tracker wrapper `src/composables/useLocationTracker.js` – browser uses `watchPosition`, app uses Transistorsoft; pages never import the plugin
- [x] One app-wide tracker (singleton): sharing keeps running across pages
- [x] Android: native reading + upload **every 30 s**, moving or standing (`distanceFilter: 0`, `locationUpdateInterval: 30000`, `disableStopDetection: true`)
- [x] iOS (configured, not yet tested): every ~10 m when moving + 60 s heartbeat, never "stationary", `preventSuspend`
- [x] Uploads use a **tracking pass** (`start_tracking_pass` / `report_location` / `revoke_my_tracking_passes`) – no expiring login token; pass cancelled on Stop / logout, expires after 24 h
- [x] Queued offline, uploaded when the connection returns
- [x] Battery saver / restricted battery warnings in the app (+ "Allow unrestricted" button)
- [x] Android: plugin versions in `android/variables.gradle`, licence note in `AndroidManifest.xml`
- [x] iOS: Background Modes (location, fetch, processing) + permission texts in `Info.plist`
- [x] Install Android Studio, run on phone (Galaxy S25 Ultra) – Android Studio updated for AGP 8.13
- [x] Android: location "Allow all the time"; battery Unrestricted
- [x] Test sounds off (`logger.debug: false`)

To do:
- [ ] Tell teammate: `package.json` changed, `android/` + `ios/` folders added
- [ ] iOS: needs a Mac + Xcode – open `ios/App`, set your Apple ID team, run on iPhone; allow location **"Always"**; repeat the 4-phase test
- [ ] Rebuild the app (`npm run cap:sync`) after every `.env` change – keys are baked in at build time
- [ ] Optional: "phone setup check" screen that opens the maker's battery settings (`showPowerManager()`) for Xiaomi / Oppo / Huawei
- [ ] Tidy-up: duplicate rows saved at the moment sharing starts
- [ ] Underground / weak signal: keep coarse readings (accuracy limit 100 → ~500 m) with a "low accuracy" marker style; group midpoint still ignores > 100 m
- [ ] Consider batch upload of queued readings (`batchSync` + bulk `report_location`) for crowd network congestion at NDP
- [ ] Map: two people with the same initials ("TE" + "TE") look identical – show 3 letters or a number when initials clash
- [ ] Install next app update (fixed in code, not yet on the phone): after Stop, a late queued reading got 403 and showed a wrong "IC removed?" message → Stop now uploads the queue first, clears it, then cancels the pass; late 403s are ignored

## 4b. Polygon bench at `/polygon`
A standalone drawing bench: lock a map, lay an optional floor plan over it, draw areas
(Zone / No-Go / Obstacle / Stage / Entrance) on top. Not tied to an event.

Built (Claude):
- [x] `supabase/migrations/005_layouts.sql` – two tables (`layouts`, `layout_claims`), JSON
      validators, RLS, and four commands: `open_bench`, `claim_bench`, `release_bench`, `save_bench`
- [x] Exactly one bench, enforced by a unique index on a constant (it cannot grow a second row)
- [x] One editor at a time: the claim hands out a **token**, every save must present it, and a
      stale token is refused with `PT409` instead of overwriting someone's work
- [x] 5-minute claim expiry, renewed by a heartbeat that only runs while the tab is visible
- [x] `supabase/tests/layouts_rls.sql` – rolled-back checks for all of the above
- [x] `/polygon` needs a login now (it was the only real page reachable signed out)
- [x] One thing unlocked at a time: `null | 'map' | 'floorplan:<id>' | 'polygons' | 'area:<id>'`
- [x] The map must be locked to edit a floor plan or draw (that rule is what keeps it simple)
- [x] Floor plan: upload, shrink under 512 KB in the browser, **name it**, place, drag to
      slide, resize from a corner and **rotate with a PowerPoint-style knob**, opacity
      slider, hide, delete. One card per plan, each with its own show/hide switch; hiding the
      one being edited puts it down first.
- [x] Floor plan stored as centre + width + height + angle, so it follows the map forever
- [x] The picture repaints from the new placement on every drag frame (it used to hold a
      frozen copy of itself, so turning, resizing and fading only showed up after a reload)
- [x] The picture also **eases through a zoom animation** with the tiles, instead of standing
      still and jumping at the end. Leaflet only animates elements it built itself, so the
      pictures are given the same left/top/width/height transition with Leaflet's own curve,
      driven from `zoomanim` (`map.getZoom()` is already the new zoom while it runs)
- [x] Corner handles and the rotate knob are pinned inside the map, so a plan that hangs off
      the edge can still be grabbed
- [x] Clicking a floor plan **or an area** on the map selects it, and its row in the list
      highlights; clicking empty map, clicking away from the bench, or pressing Escape puts
      it back down (which saves). Presses that land on a control — the opacity slider, a name
      field — deliberately do not, so an edit is never cut short by reaching for its own UI.
- [x] The cursor says what the press will do: a crosshair while drawing an area, `move` over
      something that can be dragged, nothing clickable when the viewer cannot act
- [x] An area's label travels with it. Leaflet works out a permanent tooltip's position once,
      when it opens, and never again — so the name used to stay behind
- [x] Press and drag moves an area as a whole; dragging a dot reshapes it **live**, instead of
      the outline only catching up when the dot is dropped
- [x] Areas: click to add a point, rubber-band line, **snap closed when the cursor comes
      within 15 px of the first point** (the line turns green and the first dot turns into a
      ring), or press Finish; name + type, vertex drag / click-to-remove to fix a shape
- [x] The area list draws each area's **own outline** at 30 px, so a row is recognisable as
      the polygon it belongs to instead of a symbol for its type (`src/utils/areaOutline.js`)
- [x] Every lock saves – there is no Save button anywhere
- [x] Claiming, saving and releasing go through **one queue**, in order. Firing two at once
      was how a late release cancelled the claim that replaced it, so the page announced that
      "somebody took the bench over" when the somebody was the planner themselves
- [x] A save **never copies the server's answer back over the local canvas**. The reply
      describes what was sent a moment ago; the planner may have carried on working since,
      and overwriting them is what made a dragged area jump back to where it started
- [x] No decorative copy: the explanatory paragraphs that were not telling the planner
      anything were removed
- [x] Type decides colour and icon, mirrored in `src/utils/areaKinds.js` and the SQL constraint
- [x] Nothing new installed; no Storage bucket (the image lives in the row)

Still to do:
- [ ] `005_layouts.sql` is applied, but `public.floor_plan_ok()` has changed (floor plans can
      now carry a `name`). Re-run just that one function: copy its `create function` block out
      of `005_layouts.sql` and paste it back as `create or replace function`. Skipping this
      makes **every save fail**, because the check constraint re-validates on each write
- [ ] Re-run `supabase/tests/layouts_rls.sql` (checks 15 and 17 now cover the plan name, and
      17c covers a plan saved before names existed)
- [ ] Two-browser test: A starts editing, B sees "A is editing this bench" and cannot start;
      A's save after B takes over must be refused, not applied
- [ ] Check the whole page at 375px and 575px (the handles and the rotate knob on a phone)
- [ ] Agree whether non-owners should be able to claim the bench at all (currently anyone can,
      one at a time)
- [ ] Decide if a forgotten tab's 5-minute hold needs a "take over" button
- [ ] Drawn areas are not yet usable anywhere else — a no-go warning on the live map was
      discussed and shelved

## 5. Progress pitch (due Week 8 Sunday 22:00)
- [x] One feature working end to end (login → join event → IC shares from phone → others see it live on the laptop map)
- [ ] Fill progress tracker (do by / vet by per task)
- [ ] Be ready to explain: roles + RLS, join codes, Realtime, weighted midpoint, 5 s save limit, background GPS

## 6. Moving to the teammate's new Supabase project
- [ ] Teammate adds you to their Supabase organisation
- [ ] Run every file in `supabase/migrations/` in order (001 → 005)
- [ ] Repeat dashboard settings: Confirm email off, anonymous sign-ins off (URL Configuration only needed for password reset / email confirmation / social login)
- [ ] Deploy `reverse-geocode` Edge Function + add OneMap secrets there
- [ ] New URL + public key in `.env` (and Vercel later); rebuild the phone app
- [ ] Re-create test accounts, update README

## Later
- [ ] Deploy to Vercel + add the `VITE_*` env vars there
- [ ] Email invites (needs a custom email sender, e.g. Resend / Brevo – Supabase's built-in email only reaches org members)
- [ ] Delete old location rows after an event (privacy)

## Team decisions to confirm
- [ ] Leaflet + OneMap vs Google Maps (polygon page must match) → **decided: Leaflet + OneMap**, the bench reuses `src/utils/onemap.js`
- [ ] Update frequency (time and/or distance)
- [ ] Full history vs latest position only
- [ ] When tracking starts/stops during an event
- [x] Replace anonymous sign-in with real login
