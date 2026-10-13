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
- [x] What is being worked on: `null | 'floorplan:<id>' | 'polygons' | 'area:<id>'`
- [x] **The map always pans and always zooms. There is no lock, no unlocked state and no buttons
      for either.** The component moves the view itself and Leaflet's own drag is switched off —
      that is the fix for a real bug: Leaflet binds its drag to the map container and starts it from
      the same press a shape takes, so a shape drag ALSO panned the view, which made a picture slide
      out from under the cursor and an outline look as though it stayed still while the map ran away
      underneath it. A shape is grabbed by its own parts — an outline by its body, a picture by the
      picture — and those stop the press from reaching the map
- [x] **The middle button pans EVERYWHERE** — on the map, on a picture, on an outline, on its dots,
      on a corner handle, on the rotate knob, and **while an area is being drawn**. It is the way to
      hold the map when a picture covers the screen, and it worked in no other mode for the simple
      reason that Leaflet's drag handler is enabled or disabled as a whole and drawing needs it off.
      The press is declined by whatever is underneath and taken by the component instead
- [x] Panning by press needs no modifier and no mode: it moves the view whenever the **middle**
      button is pressed, and with the **left** button wherever there is nothing else for the left
      button to mean. Two details that are easy to get wrong and were checked against Leaflet's own
      source rather than assumed: `panBy(offset)` moves the view's CENTRE by `offset`, so a drag has
      to be handed the NEGATIVE of the pointer's movement (the harness decides the sign by requiring
      the geography under the cursor at the press to still be under it at the end, and picks exactly
      one of the four combinations), and the pointer is CAPTURED for the duration so the view keeps
      following past the edge of the map
- [x] A press that moved the view is not also a click, so panning while drawing an area does not
      leave a point behind it. A wobble below 2 px is not a drag and still places its point
- [x] **The view follows a shape dragged past the edge of the map.** It runs on the animation frame
      rather than on the pointer's move events, which is what keeps it going while the pointer is
      held still against the edge — the case it exists for. The pointer's coordinates are read fresh
      each frame from events outside the map, so the shape keeps up after the cursor has left the map
      rather than only the map moving
- [x] **The further out the pointer is pushed, the faster the view follows.** Nothing for the first
      40 px inside the edge, a ramp to 8 px a frame at the map's own edge, then 2 px a frame faster
      for every 20 px further out, capping at 32 px a frame — so a long distance is one gesture
      rather than a drag, a let-go and a pan. Tabulated from the shipped `panSpeed`, read back out of
      the component rather than restated: 40 px past the inner line 8, 60 px 10, 120 px 16, 200 px
      24, 275 px 32, and 32 for everything beyond. The cap is reached 235 px outside the map, which
      the window has room for on every side; it is there so a pointer parked off the far side of the
      window cannot throw the view across the island in one frame. The climb used to stop AT the
      map's edge — the formula measured the distance past the inner line and capped the result at
      the edge speed — so the whole world outside the map, 60 px out and 600 px out alike, moved at
      one fixed 8 px a frame. Only the shape's grab offset is invariant to how fast the view moves,
      since it is re-based every frame either way, so the faster pan costs no accuracy
- [x] **A dot is dragged by the bench, not by Leaflet.** Leaflet's own marker drag moves the icon by
      the pointer's travel in PIXELS and then reads the geography back out of where that left it
      (`_newPos = _startPos + offset`, then `layerPointToLatLng(getPosition(icon))` — read out of the
      installed Leaflet, not assumed), so it cannot know the view moved: a pan under it leaves the dot
      slipping behind the cursor with its coordinates frozen where the pan began. It also never starts
      the auto-pan, because that only happens for a press this component handles. Both faults are
      structural, so a dot now presses, moves and drops exactly like a picture: same latch, same
      re-anchor in `reanchor`, same speed law. Clicking a dot still takes the point out, which is why
      the follow is armed on the first MOVE rather than at the press — a press that removed a point and
      also scrolled the map would be two answers to one gesture — and why the drop watches for the
      click the browser fires at the end of a drag: Leaflet suppressed that one for its own drags
      (`Map._draggableMoved`, disabled on this map), and acting on it would delete the point just
      placed. The 3 px below which a press is a click rather than a drag is the tolerance Leaflet's own
      drag used. Verified on the real component in headless Firefox with real input: a dot dragged
      750 px out through the right-hand edge, while the view followed it 1867 px, stayed under the
      pointer at every one of 30 samples — worst offset 0.0 px — the ring's own coordinate travelled
      with it, exactly one change was reported and only on the drop, the dot survived the drag, and a
      plain click on a dot still took the point out (4 dots to 3, one change reported)
- [x] **While a ring is being drawn the view follows the POINTER, with no button held.** Drawing is the
      one mode where the left button cannot move the view, because there a click is a point — so
      reaching ground that was off screen meant the middle button, with the hand that is busy placing
      points. Now the ground under the pointer keeps being refreshed, so the next click can land on
      somewhere that was off screen a moment ago. It is the same frame loop, the same band, the same
      `panSpeed` and the same reach as a dragged dot, driven by `followCursor` rather than `reanchor`:
      the loose end of the rubber band, the snap and the red crossing warning are re-derived from the
      pointer's geography every frame, so they stay right while the view slides underneath a pointer
      that is not itself moving. It does not move the view while the pointer is over the bench's own
      controls, which sit over the map rather than beside it, and it needs a ring that is under way —
      at least one point placed — because entering drawing mode puts the pointer ON the controls and
      its first move is from there to the map. Measured per animation frame on the map pane (headless
      Firefox, synthetic pointer events on the real handlers): 10 px inside the right-hand edge pans
      6 px a frame, exactly `panSpeed(30)`, and a pointer 200 px outside pans 28, exactly
      `panSpeed(240)`, for as long as it stays there — 20 frames of 28 px each, 560 px of travel —
      while the loose end of the rubber band stayed 0.00 px from the pointer and a click afterwards
      added its point 0.00 px from the pointer. With no point placed yet the same pointer moved the
      view 0 px over 15 frames.
      The reach used to be EDGE_PX outside the map, on the argument that nothing is held, so a pointer
      parked over the controls column is at least as likely to mean "I am reaching for Undo" as "keep
      going". That got the answer wrong where it counts: the map is ONE COLUMN of the page, so a
      pointer pushed past its right-hand edge — the direction a ring most often needs to grow — is
      over the controls immediately, and the follow died exactly where it was wanted.
- [x] **Choosing a shape brings the view to it.** A shape picked from the list of areas, or a floor plan
      picked from its card, can be off the side of the screen or drawn at a zoom where a room is a few
      pixels across: the panel changed to it and the map carried on showing somewhere else, so the
      planner who had just asked for it still had to go and find it. A pick now fits the view to the
      shape — its own points for an area, its four corners for a plan, so a turned picture is framed by
      what is on screen — with 56 px of padding on every side and no animation. The padding is not
      decoration: an area's dots sit ON its outline and a plan's corner handles and rotate knob stick
      OUT beyond the picture, so a shape framed edge to edge would have the handles it was picked for
      off the screen. A floor plan's card is a way of choosing it now as well — a click anywhere on it
      except its own controls (the name field, the show/hide switch, Edit, Copy, Delete, the opacity
      slider), which is what a row in the list of areas has always been. A press ON a shape is a pick
      too, but that one is the beginning of a drag, and moving the ground under it would pull the shape
      away from the cursor holding it — so the bench marks the mode changes its own map gestures make
      and skips the fit for those. A plan that has just been ADDED is left alone for the same kind of
      reason: it was placed at a quarter of the screen it was added on, and fitting it would zoom in on
      a placement nobody saw at the size it was made for. Measured on the real component in headless
      Firefox: a 100 m No-Go quad 1.1 km east of the view, picked from its row, came back framed at
      zoom 19 — 336 px across in a 673x476 map, on the axes it was given to within a pixel, centred to
      within a pixel — when the view had been at zoom 17; a floor plan turned 25 degrees, picked by
      clicking its card, and the same plan picked with its Edit button, were framed the same way at
      zooms 19 and 20; and a press on the middle of a 100 m outline, with a 40x30 m plan overlapping
      it, selected the outline and left the view identical to seven decimal places, release included.
- [x] **A drag keeps its own place when the view moves under it** — the bug that made both shapes
      stop following the cursor. A drag is measured as "the shape as it was when the offset was last
      taken, plus how far the pointer has come since", so the two halves of that measurement have to
      move together. Re-anchoring moved only the first half, which threw away every metre the shape
      had already travelled. Measured on the real page (map 550 px wide, headless Firefox, real
      input over WebDriver BiDi): a floor plan had followed the cursor 140 px when the auto-pan
      started, and on the next step it was back at 478 — where it had been picked up — and from
      there it travelled with the map instead of the cursor, ending the drag 565 px away from it
      while the cursor was held still. An area did worse: the anchor written for it was a lat/lng
      where a pixel point belonged, so the next move asked Leaflet for
      `containerPointToLatLng` of a lat/lng and it threw `Invalid LatLng object: (NaN, NaN)` out of
      the pointermove handler — the outline simply stopped. Both drags now re-base the shape by the
      same amount they move the anchor by, and the view is panned **first**, so the shape is
      re-placed from the post-pan geography and ends every frame exactly under the cursor. Verified
      by dragging each shape out through the right-hand edge and then holding the pointer still
      while the map panned 545 px underneath it: the grab offset never changed by more than 0 px
- [x] **One place says no.** Every refusal — a point that would cross, an outline that would cross
      itself, the 200-point ceiling — is one red sentence along the top of the map, for drawing and
      for editing an existing shape alike. It used to come out of two places: the map strip while
      drawing, and a Bootstrap alert in the controls column while editing, which made the same
      message about the same outline look like two different tools. It also used to say more than
      it needed to: while a dot is being dragged the red outline IS the answer, and when **Add
      point** finds nowhere legal the shape plainly does not change, so neither writes a sentence
      now. The strip is two lines at most and anchored at its top edge, so a wrapped sentence grows
      down into the map rather than half off the top of it
- [x] **A floor plan and an area can both be grabbed where they overlap, and the one you last took
      hold of is the one in front.** This was a real bug found by driving the page in a browser:
      Leaflet's SVG renderer sits at `z-index: 200` inside the overlay pane, while a floor plan was
      being given `0` (selected) or `-1` (not), so **every area outline was painted over every floor
      plan** and swallowed the press — `document.elementFromPoint` at the overlap returned a `<path>`
      even with the plan selected, and the plan simply could not be picked up there. The selected
      plan now sits at `300`: above the vector layer, still below the marker and tooltip panes (600
      and 650), so it can never cover the map's controls. Selecting a plan also has to re-lay the
      pictures out, because the layer order is written when a plan is placed and a mode change was
      not re-placing them
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
      highlights; clicking empty map, pressing anywhere off the bench, or pressing Escape puts
      it back down (which saves). Presses that land on a control — the opacity slider, a name
      field — deliberately do not, so an edit is never cut short by reaching for its own UI.
      A press on one of the shape's own dots belongs to the dot, not to the map, so removing a
      point does not also put the shape down
- [x] The cursor says what the press will do: a crosshair while drawing an area, `move` over
      something that can be dragged, nothing clickable when the viewer cannot act
- [x] An area's label travels with it. Leaflet works out a permanent tooltip's position once,
      when it opens, and never again — so the name used to stay behind
- [x] Press and drag moves an area as a whole; dragging a dot reshapes it **live**, instead of
      the outline only catching up when the dot is dropped
- [x] Areas: click to add a point, rubber-band line, **snap closed when the cursor comes
      within 15 px of the first point** (the line turns green and the first dot turns into a
      ring), or press Finish; name + type, vertex drag / click-to-remove to fix a shape, and
      **Add point** for one more corner (it finds its own legal place -- see `areaGrow.js` below)
- [x] The area list draws each area's **own outline** at 30 px, so a row is recognisable as
      the polygon it belongs to instead of a symbol for its type (`src/utils/areaOutline.js`)
- [x] **How full the canvas is, drawn as a ring** on the Floor plans card heading, next to the
      thing that spends it: the pictures are stored inside the 4 MB document, so that is the one
      place the number means anything. The ring is green, amber past 75%, red past 90%, and it
      moves as a plan is added or deleted rather than jumping at the next save — the page measures
      the very string a save would send, on every change
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
- [x] **No crossing lines while drawing** (`src/utils/areaShape.js`). An hourglass is not a
      shape, so a click that would make the outline cross a line already drawn is refused -- and
      the rubber band turns red as the cursor approaches, so the refusal is visible before the
      click rather than after it. The check is on the edge the click would ADD, which is what
      makes it safe to be strict: the edges of a legal ring never cross each other, so no part
      of drawing one can either, and it can never refuse a point of a shape that is legal once
      it closes.
- [x] Closing is a **separate** check (`closingCrosses`), because a shape can be legal as a
      drawn path and still be impossible to close -- an inward spiral is the plain example. When
      the closing line would cross, the first dot stops promising a snap, Finish is disabled,
      and the hint says which line is the problem. A click on the first dot with only two points
      down is answered with "an area needs at least 3 points", instead of adding a second point
      on top of the first and leaving a ring with no area in it.
- [x] The same rule guards an area that already exists: dragging a dot onto the outline,
      clicking a dot away, or adding a point is refused with a sentence that says so. There is
      **no exception for a shape that already crosses itself**. An earlier version had one --
      "it is broken, so anything goes" -- and that exception WAS the way round the rule: every
      drag on a broken outline was accepted, crossings and all. What makes the strict rule safe
      is that only the DROPPED position is judged, never the path the dot travelled to get
      there: one drag that lands on a legal shape repairs a broken outline, and the outline
      follows the dot the whole way, so the planner watches the lines come apart before letting
      go. A stored outline that crosses says so in the panel, with both ways out (drag it
      straight, or delete it and draw it again).
- [x] **An edit says "no" while the dot is still moving**, the same way drawing does. Dragging a
      vertex re-checks the ring on every frame, and while it would cross itself the outline is
      drawn in the same red as a refused rubber band with a sentence naming the red line as the
      one that overlaps. Dragging back inside turns it back at once. Nothing is committed until
      the drop, so the red is a LOOK and never a second source of truth -- the area's own points
      are untouched until the dot lands somewhere legal. (The old build only judged the drop, so
      an edit could be dragged through an illegal position and then silently snap back, which
      read as the shape moving on its own.)
- [x] **"Add point" always finds a legal place for the new dot** (`src/utils/areaGrow.js`).
      Appending it to the end of the ring -- which is what the bench used to do, one short step
      east of the last dot -- is joined to TWO neighbours, because the ring closes: the dot that
      was last and the dot that was first. For a three-point ring that often leaves no legal spot
      at all, and the planner was told their point would cross something no matter where they
      asked for it. `growRing` tries the end of the ring first, next to the dot they were last
      looking at, and otherwise **splits the longest edge**, which cannot fail: a node on an
      existing edge divides it in two and leaves every other edge alone. It sits a hair OFF the
      line rather than exactly on it, because exactly on it is a node with three edges meeting at
      it, which the crossing rule reads as a crossing -- so the "safe" placement is the one that
      fails. A ring that already crosses itself is refused rather than made worse. Verified
      against 2000 random triangles and 4000 random rings up to 5 km across: not one refusal, and
      every result a legal ring.
- [x] **"Two edges that meet at an END do not cross"** is the one rule the whole module is built
      on (`edgesCross`), and it is decided by COORDINATE rather than by position in the list.
      One rule therefore covers both the neighbouring edges of every ring (which always share an
      end) and a point drawn twice, which an older build could produce with a double-click and
      which must not read as a crossing -- the shape carrying one would refuse every drag and
      could never be repaired. A vertex landing in the MIDDLE of another edge is still a pinch
      and still refused.
- [x] **Undo / redo is GLOBAL and lives on the page, not on the map or in a panel**
      (`src/composables/useDocHistory.js`, one stack for the whole document): Ctrl+Z,
      Ctrl+Shift+Z (and Ctrl+Y), plus a pair of **arrow buttons** and a "N changes" badge in the
      page header next to Start / Stop editing. Inline SVG arrows rather than an icon font,
      because the project has none and two glyphs are not worth a download; a `title` and an
      `aria-label` carry the word. **They are on the page rather than over the map because a step
      is not a property of the map either** -- over the map they covered the corner of the very
      thing they changed. A step can be a dot, a whole area, a floor plan or a rename: adding an
      area, deleting a floor plan, dragging a dot, moving or turning a plan, renaming, retyping
      and pasting a copy are all on the same timeline.
      **This replaced a stack per thing being edited, which reset whenever the planner looked
      somewhere else** -- so undo stopped working exactly when they clicked away from a shape and
      came back to it, which read as a broken button. Snapshots, not diffs, and the plan objects
      are shared by reference, so a hundred steps cost a hundred small arrays and ONE copy of each
      image. One gesture is one step: a drag reports a change per mousemove, so a run of changes
      is held open until the pointer comes up (or goes quiet for 150 ms) and becomes a single
      step. A run that changed nothing -- a refused edit, a drag that ended where it began --
      leaves no step, so "Nothing to undo" stays honest.
      The ring being DRAWN is the one thing still on its own small stack (`useHistory.js`): it is
      not part of the document until Save, and while a ring is open every press belongs to it.
      Inside a text field Ctrl+Z is left to the browser, so a mistyped area name is still undone
      as text. Clear / Cancel / Escape are recorded like any other change, so pressing them is
      safe. Client-side only: nothing here is written to the database and no other planner sees
      it. **The stack itself is in memory and does not survive a reload** -- persisting it would
      mean writing every floor plan image into the browser a second time (up to 4 MB against a
      ~5 MB localStorage quota) to reproduce a history whose every step the server already has
      after the next lock.
- [x] **Copy and paste a floor plan or an area** (`src/composables/useBenchClipboard.js`): Copy
      on a plan card or an area row (and Ctrl+C while one is open), Paste at the top of the floor
      plans card or on the areas card and the list (and Ctrl+V). A paste is a NEW thing -- a fresh
      id, a name that is not already taken (`Trees copy`, then `Trees copy 2`), and a position
      25 m away so the copy is not hidden under the original -- and it is recorded like any other
      change, so Undo takes it back. Deliberately NOT the system clipboard: a shape is coordinates
      and a name, and the system clipboard only carries text, which any other application could
      clobber between the copy and the paste.
- [x] **The view moves whenever the planner asks it to** -- pan, wheel, pinch, double-click. There
      is no lock state at all, and the only thing that narrows panning is drawing an area, where the
      LEFT button has to place a point rather than move the view; the middle button still pans there.
      Box zoom is off everywhere: it is a left-drag that draws a rectangle, which is the same gesture
      as moving the view, and the wheel already zooms. Zooming never moves a point: the wheel zooms
      around the cursor, so whatever is under it stays under it, and the corner handles and the rotate
      knob are re-placed on `zoomend`. A wheel listener on the map container that is attached once and
      never toggled
      keeps the PAGE from scrolling and the browser from zooming when the cursor is over the map --
      which is what the planner was reaching for when they zoomed the browser by accident. While an
      area is being DRAWN the double-click zoom is off too, because there a double-click is how a
      run of quick clicks to place points looks.
- [x] Both lists are **capped at 20 rem and scroll inside their cards** -- the floor plans, and
      the list of areas (`AreaList.vue`) -- instead of growing the column until the drawing card
      is off the bottom of the screen. A scrollbar grab is exempt from "clicking away puts the
      edit down", which would otherwise have ended a drawing session for reaching for it.
- [x] The area list is **grouped by type** (`AreaList.vue`), in the same order as the type
      dropdown, with a swatch and a count per group and a heading that sticks to the top of the
      card while its own rows scroll past. A type with no areas is left out; a type this build
      does not know (saved by a newer one) keeps its rows in an "Other" group rather than losing
      them, and the card title carries the total. A flat list stopped being scannable at a dozen
      areas: the question is "where are my No-Go areas", and the answer should not be "somewhere
      in this list".
- [x] **Layout**: at lg (992 px) and up the map takes the left half and the controls take the
      right half, split into two columns -- the areas (drawing controls, then the list of them)
      on the left, the floor plans on the right. Below lg the split collapses and everything
      stacks in that same order, areas first, because the areas are what the bench is for.
      Rows in both lists wrap instead of crushing the name input in a quarter-width column.
      The page uses the full width either way; nothing is left to the browser's default.
- [x] Nothing new installed; no Storage bucket (the image lives in the row)

Still to do:
- [ ] The undo stack does not survive a page reload, and that is deliberately not attempted yet.
      Persisting it means writing every floor plan image into the browser a second time -- up to
      4 MB against a localStorage quota of about 5 MB, so it would fail on exactly the benches
      that need it most -- to reproduce a history whose every step the server already holds after
      the next lock. If it is ever wanted, IndexedDB is the place for it (structured values, a
      quota in the hundreds of megabytes, and a silent fall back to memory).
- [ ] The no-crossing rule is enforced in the **browser only**: `public.area_ok()` still accepts
      a ring that crosses itself. Making it a CHECK constraint would be retroactive in the way
      `006` was -- the constraint re-validates the row on every write, and adding it fails
      outright if any stored bench already holds an hourglass -- which is exactly why `006`
      needed its pre-flight audit. Not added: the bench is the only thing that writes areas, and
      it no longer draws one. If a constraint is ever wanted, run an audit over
      `public.layouts` first (a `ringCrossing`-style check in SQL, or a one-off query here).
- [x] `006_floor_plan_bounds.sql` **written here, run in Supabase, and verified** (this item
      used to be the "run it" warning, kept below because the warning is the interesting part):
      the step 0 audit query returned no rows, so the retroactive rule had nothing to reject,
      and the migration then applied cleanly. Checked in the database afterwards: the old
      `floor_plan_corners()` helper is gone, a legitimate 1200x800 m plan inside Singapore is
      accepted, and the same plan hanging outside it is refused.
      The warning it used to carry: the rule is retroactive (the CHECK constraint re-validates
      the row on every write), so an existing bench holding a plan that hangs outside Singapore
      would make every save fail until that plan is removed — and removing it is itself a save,
      so the editor would be stuck. No rows = safe to apply.
- [x] Correction to an earlier note here: `public.floor_plan_ok()` did **not** need re-running
      when floor plans gained a `name`. It only ever checked the fields it knows about, so a
      plan carrying `name` was accepted before and after — test 17c (`layouts_rls.sql`) proves
      a plan with no name still saves. The note had the risk backwards: making `name`
      *required* there would have been the real hazard, because the constraint re-validates
      the whole document on every write, so one old plan without a name would have turned the
      bench into one nobody could save again.
- [x] `006_floor_plan_bounds.sql` — a floor plan must FIT inside Singapore, not just start
      there. `floor_plan_ok()` checked only the plan's centre against `point_in_sg()` and its
      size against a separate 20 km sanity limit, so a plan centred just inside the box could
      extend kilometres outside it: floor area where the basemap has no tiles, the
      reverse-geocode function refuses, and every drawn area point is rejected. Corners are
      now checked using the **same trigonometry as `cornersOf()`** in `src/utils/floorPlan.js`
      (`floor_plan_in_sg()`), and `layout_problem()` names the
      offending plan so the page can say which one to fix
- [ ] Re-run `supabase/tests/layouts_rls.sql` — checks 17d/17e/17f/17g are the new ones
      (out-of-bounds plan refused, a large *rotated* plan still accepted, `layout_problem()`
      naming the plan, and an empty floor-plan name still saving), and check 15 no longer
      expects an empty floor-plan name to be rejected — that contradicted check 17c, which
      saves a plan with no name precisely so one old plan cannot make the bench unsaveable
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
- [ ] Be ready to explain: roles + RLS, join codes, Realtime, weighted midpoint, 5 s save limit,
      background GPS, and **why the no-crossing rule lives in the browser and not in
      `area_ok()`** (a CHECK constraint is retroactive and would fail to apply over an existing
      hourglass — same trap `006` had to audit for)

## 6. Moving to the teammate's new Supabase project
- [ ] Teammate adds you to their Supabase organisation
- [ ] Run every file in `supabase/migrations/` in order (001 → 006)
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
