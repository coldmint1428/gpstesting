# Event Ops merger – build plan

**Polygons (zones) × Live map × Run sheet (timeline)**
IS216 G11 · repo `gpstesting` (main repo from now on) · Supabase project `gpstest` · written 13 Oct 2026

This file is the step-by-step build order. It is meant to be given to Claude one stage at a time:

> "Do **Stage N** of `docs/merger-build-plan.md`. Follow the ground rules in section 2. Stop after the stage's tests and report."

Do not start a stage until the previous stage's **Done when** list is ticked and you (Komin) have confirmed.

> **Updated 14 Oct 2026 (Stage 0 done).** The teammate's polygon bench was rewritten before the merge: the canvas is now one database row per shape, saved per shape with a lock, so `save_bench` / `useBenchClaim` / `layout_claims` no longer exist. His migrations were renumbered to **014–018** and the catch-up fix added **019**, so this plan's own migrations now start at **020** (stage numbers below are updated). Work happens on branch `merge_gps-dev`. The companion Word document `docs/Event-Ops-Merger-Reference.docx` explains *why* each design choice was made; this file says *what to build and how to test it*.

Mock-ups: <https://claude.ai/artifact/CVEyTkTX56yFJY9q5s1tfe> (share it from its Share menu before sending to teammates).
Import template: `docs/templates/run-sheet-template.xlsx`.

---

## 1. What we agreed (summary)

| Topic | Decision |
|---|---|
| Repo | `gpstesting` is the main repo. Teammate's polygon tool is merged in here. |
| Scale | Build and test at demo scale (5–20 real groups), but design for **100+ groups / 300+ IC phones / thousands of people**: server-side engines, one status row per group, clustered map, bulk editing. A **simulator** drives 100+ virtual groups for testing and the demo. Real NDP scale needs the Supabase **Pro** plan (Realtime message quota). |
| Who sees the ops view | Root + planners (everything, can GO / Hold / +30 s) + marshals (their own sector, read-only). Everyone else keeps today's live map. |
| Who calls the show | Root and planners. Every action is logged with the person's name; the server accepts one action per cue (no double-start). |
| Cue start modes | **Auto** (starts by itself at its projected time) · **Auto when ready** (starts by itself if its groups have arrived, otherwise holds and asks planners) · **Manual** (waits for GO). Anchors are always Auto. |
| Cue types | **Normal** · **Flexible** (can shrink by up to N seconds to absorb delay) · **Anchor** (fixed clock time, never moves; e.g. Broadcast 17:30:00, Flypast 19:12:00). |
| Delay | Show delay = actual start − planned start of the running cue. Later cues move by the delay until a Flexible cue absorbs it. An anchor at risk = critical alert with decision options. |
| Arrival | A group has arrived when **all of its sharing ICs** (or "at least N", per movement) have been **inside the zone for 20 s**, before the deadline. ICs with no signal are shown, never block. |
| Deadline | Cue start / cue end (moves with delays) or a fixed time, **minus "arrive early by"**. |
| ETA | now + distance still to go ÷ speed + dwell (20 s). Travel modes: **On foot** (OneMap walking route; planned pace until they move, then real progress), **Vehicle** (OneMap driving route + phone GPS speed), **Fixed route** (checkpoints with planned offsets, ahead/behind like a train timetable – mobile column). |
| Status | Spare = deadline − ETA. 🟢 ≥ 30 s (or arrived) · 🟠 0–29 s · 🔴 late (+mm:ss) · ⚪ no signal > 2 min. A status only changes after 2 readings agree. |
| Leave by | deadline − dwell − route distance ÷ planned pace. ICs get "Get ready" 1 min before and "Leave now" at leave-by (push). |
| Run sheet entry | Manual entry **and** Excel import (download template → fill → upload → preview with row errors → save). Export to Excel too. Versions: draft / published / archived. |
| Zones | Polygons from the teammate's tool become **per-event zones** with a stable **code** (FORMATION_1), a kind and a shape. Circles allowed as a stop-gap. PostGIS does inside / distance checks. |
| Trail | Tap a group → its trail for the current session only (already built). |

---

## 2. Ground rules for every stage

**Code**
- Vue 3 `<script setup>`, Bootstrap 5, Leaflet + OneMap. Match the surrounding code: plain-English comments explaining *why*, no frameworks added without a reason.
- Never break what works: live map, sharing (web + phone, background, notification Stop), Start/End/scheduled end, playback, CSV, push reminders, polygon bench.
- No secrets in the front end. Service-role keys only in Edge Functions / Supabase secrets.
- Times shown in Singapore time with seconds where they matter (`HH:MM:SS`, tabular numbers). The show clock uses **server time** (see Stage 6).
- Status is never colour alone: always a word or number too (accessibility, colour-blind planners).

**Database**
- New migrations continue from `020_…` in `supabase/migrations/` (001–013 event app, 014–019 polygon bench), one file per stage, applied to `gpstest` with the Supabase connection and committed as a file.
- Functions: `security definer`, `set search_path = ''`, role checks inside (`has_event_role(...)`), **explicit grants per function** – never "grant on all functions" (that broke uploads once).
- RLS on every new table; writes only through functions unless a policy says otherwise.
- Every migration gets a **rolled-back SQL test** (a `do $$ … raise exception 'RESULTS: …' $$` block, as used for 007–013) covering the allowed and the refused cases.
- Realtime: subscribe to small **status rows** (one per group / cue), not raw location rows, for anything that scales with group count.

**Testing at the end of every stage**
1. SQL test (rolled back) – paste the result in the report.
2. `npm run build` passes.
3. Browser check on localhost (`gps-dev` preview) with the test account `claude_test` (README) on the event "Playback test (Claude)" – or the simulator event from Stage 3 on.
4. Phone check when the stage touches the app: `npm run cap:sync`, then Komin runs Android Studio ▶ (never an emulator).
5. Update `docs/gps-checklist.md` (new section per stage) and `docs/gps-tracking-spec.md` (tables, functions, flows).
6. Report: what changed, test results, anything not tested. Komin commits and pushes.

---

## 3. Architecture (how the pieces talk)

```
 IC phones (Transistorsoft, every 10 s) ──► rpc/report_location (tracking pass)
 Web sharers ──────────────────────────────► locations (insert, RLS)
 Simulator (sim events only) ──────────────►      │
                                                   ▼  trigger: after insert on locations
                                    zone_presence   (who is inside which zone, since when)  [PostGIS]
                                    group_positions (one row per group: midpoint, speed, last seen)
                                                   │
             pg_cron "ops tick" every 2–5 s ───────┤  engine: cue states, delay, movement status, ETA
                                                   ▼
                              cue_state  ·  movement_status  ·  ops_alerts      ◄── Realtime ──► Ops view, IC phone
                                                   │
               Edge Functions: route-eta (OneMap routing, cached) · send-reminders (FCM: Leave now / Remind)
```

- **Engines run on the server**, not in a planner's browser: every planner sees the same numbers, and nothing depends on one laptop staying open.
- **Event-driven + timed**: a new reading updates presence and that group's status immediately (trigger); a short cron tick handles time passing (cues auto-starting, deadlines passing, no signal).
- **OneMap routing** is called by an Edge Function only when a movement becomes active, when a group strays > 50 m off its route, or every 2 min – cached in a table.

---

## 4. Data model (target)

Existing: `events, event_roles, groups, group_members, profiles, locations, tracking_passes, event_sessions (+ scheduled_end), push_tokens, push_reminders` and the polygon bench: `layouts` (one global bench: `id, rev, home`), `layout_objects` (one row per area / floor plan: `object_id, kind area|plan, data jsonb, image_id, rev`), `layout_images` (floor-plan pictures, keyed by md5), `layout_locks` (one lock per shape, per tab session), `layout_presence`, `layout_views`. Writes go through `save_object`, `delete_object`, `lock_object`, `unlock_object`, `open_bench`, `bench_head`.

New / changed (built across the stages below):

| Table | Key columns | Stage |
|---|---|---|
| `groups` (+columns) | `code` (unique per event), `category`, `sector`, `headcount` | 1 |
| `zones` | `id, event_id, code (unique per event), name, kind (zone, stage, entrance, no_go, obstacle), shape geography(Polygon), capacity, source_area_id, is_circle, radius_m` | 1 |
| `layouts` (+column) | `event_id` – one bench per event (teammate's editor, made event-scoped); `layout_objects`, locks and presence follow via `layout_id` | 1 |
| `zone_presence` | `session_id, user_id, zone_id, entered_at, last_inside_at, exited_at` | 2 |
| `group_positions` | `session_id, group_id, lat, lng, accuracy, speed_mps, activity, last_seen, ics_sharing` | 2 |
| `zone_alerts` | `session_id, zone_id, user_id, kind (no_go_entered, over_capacity), at, ack_by` | 2 |
| `sim_groups`, `sim_scripts` | simulator definitions (sim events only) | 3 |
| `run_sheets` | `id, event_id, version_label, status (draft, published, archived), published_at` | 4 |
| `cues` | `id, run_sheet_id, code, section, position, planned_start timestamptz, length_s, type, can_shorten_s, start_mode, area, department, notes` | 4 |
| `movements` | `id, run_sheet_id, code, group_id or category, zone_id, deadline_kind, cue_id, fixed_time, early_s, min_ics, dwell_s, amber_s, leave_by_cue_end, travel_mode, pace_mps, arrival_zone_id, route_id` | 4 |
| `routes`, `checkpoints` | `routes(id, event_id, code, name, path geography(LineString))`, `checkpoints(route_id, position, name, point, radius_m, offset_s, start_cue_id)` | 9 |
| `cue_state` | `session_id, cue_id, status (pending, running, held, done, skipped), projected_start, actual_start, actual_end, by` | 6 |
| `show_actions` | `session_id, cue_id, action (go, hold, add_time, skip, resume), seconds, by, at` | 6 |
| `movement_status` | `session_id, movement_id, status (pending, on_track, at_risk, late, arrived, arrived_late, no_signal), eta, spare_s, ics_inside, ics_sharing, arrived_at, leave_by, updated_at` | 7 |
| `movement_routes` | cached OneMap route per movement + start point: `distance_m, duration_s, path, fetched_at` | 7 |
| `checkpoint_passes` | `session_id, checkpoint_id, user_id, passed_at, delta_s` | 9 |

`locations` gains optional `speed`, `heading`, `activity` (Stage 9; phone upload template + `report_location` params with defaults so old phones keep working).

---

## 5. Core logic (formulas – full explanation in the Word document)

- **Server time**: client offset = `server_now() − (t_sent + t_received)/2`; all countdowns use `Date.now() + offset`.
- **Projected start** of cue *i* = planned start + current delay, where delay shrinks by each Flexible cue's `can_shorten_s` that lies before it; **Anchor** cues: projected = planned, always. Anchor at risk when the projected end of the cue before it > anchor time.
- **Auto when ready**: at projected start, if every linked movement is `arrived` → start; else `held` + alert "Waiting for X". Planners: **GO anyway / Keep holding**.
- **Deadline** = (cue start or end, projected) or fixed time − `early_s`.
- **Arrived** = `count(ICs inside ≥ dwell_s) ≥ required` where required = `min_ics` or all ICs that reported in the last 2 min.
- **ETA** (per IC) = now + remaining distance ÷ speed + dwell; group ETA = the k-th fastest IC (k = required count).
  - remaining distance: OneMap route length still ahead (project position onto the cached route) → else straight line to the arrival point × 1.3 (foot) / 1.4 (vehicle); last 50 m = straight line to the zone edge.
  - speed (on foot): planned pace until moving; then weighted towards real *progress towards the zone* over the last 60–90 s (≈50/50 after 30 s, mostly real after 90 s). Vehicle: GPS speed (smoothed). Fixed route: checkpoint plan + current delta.
- **Status** from spare = deadline − ETA, changed only when 2 consecutive evaluations agree; ETA rounded to 5 s.
- **Leave by** = deadline − dwell − route distance ÷ planned pace. Push "Get ready" at −60 s, "Leave now" at 0; recomputed when the show delay changes.
- **Fixed route**: delta = actual pass time − planned (offset from the route's start cue, projected); next checkpoint ETA = route distance left ÷ GPS speed; later checkpoints = planned + current delta.

---

## 6. Timeline (minimum, with testing)

Building is fast; **testing with real phones and the simulator is what takes time**. The minimum to a demo-ready system is about **3 weeks**. Start: Wed 14 Oct 2026 (polygon tool arrives).

| When | Stages | Result |
|---|---|---|
| Wed 14 – Fri 16 Oct | 0 Baseline · 1 Polygon merge → per-event zones | Zones per event, shown on the live map |
| Sat 17 – Mon 19 Oct | 2 Zones in the live map (presence, no-go, group positions) · 3 Simulator | Arrivals detected; 100+ virtual groups move on the map |
| Tue 20 Oct | **Test day 1**: real phones + simulator on zones | Sign-off of stages 0–3 |
| Wed 21 – Fri 23 Oct | 4 Run sheet builder (manual) · 5 Excel import / export | Planners can build the run sheet both ways |
| Sat 24 – Mon 26 Oct | 6 Live show engine (clock, cue states, GO / Hold, delay, anchors) | Run sheet runs beside the live map |
| Tue 27 – Thu 29 Oct | 7 Movements engine (arrival, ETA, statuses, ops view at scale) | Map + run sheet + zones work together |
| Fri 30 – Sat 31 Oct | 8 IC phone (next move, Leave now push) | ICs guided by the app |
| Sun 1 – Mon 2 Nov | **Test day 2 + 3**: full simulated rehearsal (120 groups) + live walk test | **MVP demo-ready** |
| Tue 3 – Fri 6 Nov (stretch) | 9 Fixed routes / mobile column · 10 Scale tools (movement grid, conflicts, marshal sectors, wall mode) · 11 Post-event analysis | Full feature set |
| Sat 7 – Sun 8 Nov | Final rehearsal + demo script dry run | Demo |

If time runs short, drop in this order: 11 → 10 (keep marshal sector filter) → 9 (mobile column becomes an On foot/Vehicle movement).

---

## 7. Stages

### Stage 0 – Baseline and merge the polygon tool (½ day)
**Goal** A clean starting point with the teammate's latest polygon tool merged and nothing broken.
**Build**
- Pull `main`, merge the teammate's polygon branch into `komintestbr` (resolve conflicts keeping both sides; docs conflicts as before). Keep `pnpm-lock.yaml` and `package-lock.json` in sync (`npx pnpm@10 install --lockfile-only`).
- Read the teammate's code end to end (`AreaBench.vue`, `AreaList.vue`, `useBenchClaim.js`, utils, any new migration). Write down in this file (section 9) the exact JSON shape of an area and floor plan, and any changes since `005_layouts.sql`.
**Tests**
- `npm run build`; open `/polygon`: draw, save, reload; open an event: live map, sharing, playback still work.
- Vercel deploy is green (pnpm frozen lockfile).
**Done when** baseline works and the area JSON shape is recorded.

**Status 14 Oct 2026: DONE** (except the phone check, Komin). Merge on `merge_gps-dev` (komintestbr merged into the teammate's branch); migrations renumbered 014–018; lockfiles regenerated (Vercel frozen-lockfile build green on `4a1ca49`); full review of the bench (18 issues: 17 fixed and tested in the browser, the role check left for Stage 1); `npm run test:db` 196 assertions pass; `/polygon` draw → save → reload → delete works; event page Start → readings → End → Playback works. Shape format recorded in section 9.

### Stage 1 – Per-event zones from polygons (1½ days)
**Goal** Polygons drawn in the bench belong to an event and become `zones` rows the server can test positions against.
**Build**
- Migration 020: `create extension if not exists postgis;` `layouts.event_id` (one bench per event; existing bench row → assign to "NDP rehearsal 1" or keep as template); `zones` table (section 4) with GiST index on `shape`; `groups` + `code, category, sector, headcount`.
- Area → zone sync: the bench saves **one shape at a time** (`save_object` / `delete_object` on `layout_objects`), so a trigger on `layout_objects` (insert / update / delete of `kind = 'area'`) upserts or deletes the matching `zones` row (object_id → `source_area_id`; `code` = the area's code field, else generated from the name: `Formation 1` → `FORMATION_1`, unique per event). Points `[lat, lng]` → PostGIS polygon (`ST_MakePolygon`, lng/lat order!). Floor plans (`kind = 'plan'`) are not zones.
- Role check (review issue 16): today any signed-in account can edit the bench. With `layouts.event_id`, `open_bench`, `lock_object`, `save_object`, `delete_object` and the table policies must require root/planner of that event (read: event members); `/polygon` keeps a demo bench or redirects.
- Editor: add a **Code** field per area (prefilled, editable, unique check) – the **kind** list already exists (zone, no_go, obstacle, stage, entrance); replace the bench's native `confirm()` boxes with the app's in-app dialog (`askConfirm`); open the bench from an event (**Zones** tab for root/planners) instead of the global `/polygon` page (keep `/polygon` working as a redirect or test page).
- Live map: a **Zones** layer (toggle) drawing zones per kind (zone/stage outline, entrance dot, no-go red hatch), with name + code labels at higher zoom.
- Helper SQL functions: `zone_contains(zone_id, lat, lng, buffer_m)` and `zone_distance_m(zone_id, lat, lng)` (0 inside).
**Tests**
- SQL: save 3 areas (`save_object`) → 3 zones with correct codes; rename → same zone row; delete area → zone gone; `zone_contains` true inside / false outside / true within buffer; other event's planner cannot read or save.
- Browser: draw Formation 1 on the test event → appears on the live map Zones layer.
**Done when** zones are per event, stable codes, shown on the live map.

### Stage 2 – Zones in the live map: presence, no-go, group positions (1 day)
**Goal** The server knows which IC is inside which zone, live, and each group has one position row.
**Build**
- Migration 021: `zone_presence`, `group_positions`, `zone_alerts`.
- Trigger `after insert on locations` (cheap, indexed): for the reading's event + live session, find zones containing the point (accuracy buffer = min(accuracy, 15 m)); open / extend / close presence rows (exit after 2 consecutive outside readings); upsert `group_positions` (weighted midpoint, speed from last 60 s, ICs sharing).
- No-go: entering a `no_go` zone → `zone_alerts` row → Realtime → red toast + map highlight for ops users.
- Live map: group rings use `group_positions`; zone tooltip "3 groups inside · 2 ICs"; IC marker tooltip shows "Inside Formation 1 since 18:03:41".
**Tests**
- SQL: insert readings outside → inside → inside (presence opens with `entered_at` of the first inside reading) → outside ×2 (closes); no-go entry creates one alert (not one per reading).
- Phone: walk into a circle/polygon on the test event → "Inside … since" appears on the laptop within ~10–20 s.
**Done when** presence, group positions and no-go alerts work with a real phone.

### Stage 3 – Simulator (1½ days)
**Goal** Test and demo 100+ groups without 100 phones. Simulated data is clearly labelled and only in simulation events.
**Build**
- Migration 022: `events.is_simulation`; `sim_groups (event_id, group_id, route geography, pace_mps, start_at, script)`; `sim_scripts` presets: on time / 2 min late / stops halfway / loses signal / wrong zone (no-go).
- Edge Function `simulate` (service role, root of a simulation event only): creates N simulated accounts + groups + ICs (marked `profiles.is_simulated`), and a pg_cron job (every 10 s, only while the sim event is live) that inserts readings for each simulated IC along its route at its pace with GPS noise (±5–15 m).
- UI: "SIMULATION" badge on every page of a sim event; a Simulator panel (root only): number of groups, preset mix, start / pause / reset.
**Tests**
- Start a sim with 120 groups × 2–3 ICs: map clusters stay smooth (≥ 30 fps on a laptop), presence and group positions update, database CPU fine (Supabase dashboard), Realtime messages per minute noted.
- Reset removes all sim readings and accounts.
**Done when** a 120-group simulation runs for 15 minutes with correct presence/no-go behaviour.

**Test day 1 (Tue 20 Oct)**: 2–3 real phones + simulator together on one sim event; check zones, presence, no-go, map performance; note battery and Realtime usage.

### Stage 4 – Run sheet builder, manual entry (1½ days)
**Goal** Planners build a versioned run sheet in the app.
**Build**
- Migration 023: `run_sheets`, `cues`, `movements` (section 4), RLS: event members read published; root/planners edit drafts; functions `create_run_sheet_version`, `publish_run_sheet` (one published per event), `save_cue`, `save_movement`, `delete_*`, validation function `check_run_sheet(id)` returning row errors.
- New event tab **Run sheet** (root/planners edit, marshals read): sections, table (start `HH:MM:SS`, length, cue, type, start mode, movements chips), inline edit, add/move/delete cue, **movement editor panel** exactly as mock-up screen 2 (How they get there · Deadline · Arrived rule · Colours · one-sentence summary).
- Category rules: a movement row can target a **category** ("All Bands") → expands to one movement per group, with per-group overrides.
- Groups: category, sector, headcount, code editable in the Members tab.
**Tests**
- SQL: draft edits by planner OK, participant refused; publish makes previous version archived; `check_run_sheet` catches: cue overlap warnings, anchor inside another cue, movement without zone, unknown cue, impossible pace (> 3 m/s on foot).
- Browser: build 5 cues + 4 movements for the test event from the mock-up example.
**Done when** a run sheet can be built, validated and published by hand.

### Stage 5 – Excel template, import and export (1 day)
**Goal** Upload the team's show matrix as the template and get the same run sheet; export back.
**Build**
- Serve `docs/templates/run-sheet-template.xlsx` from the app (**Download template**).
- Import in the browser with SheetJS (pinned version): read tabs Event, Cues, Groups, Zones, Movements, Checkpoints; validate (IDs link, times `HH:MM:SS`, dropdown values, numbers); **preview screen** listing every problem per row ("Movements row 12: cue C099 not found"); nothing saved until the preview is clean; then save as a new **draft** version. Zones in the file: match existing zone codes; `Circle` zones are created; `Polygon` zones must exist in the bench (else listed as missing).
- Export: current version → same template layout.
**Tests**
- Import the sample template → identical run sheet; import a broken copy (bad time, unknown cue, duplicate code) → errors listed, nothing saved; export → re-import → same data.
**Done when** round-trip import/export works and errors are clear.

### Stage 6 – Live show engine + run sheet beside the map (2 days)
**Goal** The run sheet runs live during a session, beside the live map.
**Build**
- Migration 024: `cue_state`, `show_actions`; functions `server_now()`, `show_go(session, cue)`, `show_hold`, `show_resume`, `show_add_time(seconds)`, `show_skip` (root/planners; one action per cue enforced with row locks; actions logged); engine `ops_tick()` via pg_cron every 2–5 s: auto-start Auto cues at projected start, Auto-when-ready cues start if their movements arrived else hold + alert, finish cues at their length, recompute delay/projected times with Flexible absorption and anchor checks.
- A session uses the event's **published** run sheet version (stored on `event_sessions.run_sheet_id` at start).
- Ops layout on the event page for root/planners/marshals: map left, **run sheet panel** right (NOW with progress + GO / Hold / +30 s, UP NEXT planned → projected, anchors) and a **top bar** (server-synced clock, ON TIME / RUNNING BEHIND / CRITICAL with ±mm:ss, next anchor countdown) – as mock-up screen 1. Marshals see the panel without buttons.
**Tests**
- SQL: auto cue starts at its time; manual waits; GO on an already-running cue refused; +30 s shifts later cues; Flexible absorbs; anchor never moves; anchor-at-risk alert when delay > buffer.
- Browser: a 10-minute test version of the sample run sheet (short cues, one Flexible, one Anchor) in the simulation event, in real time; two planners press GO at once → one wins, both see who.
**Done when** a 10-minute test run sheet runs end to end with delays and anchors correct.

### Stage 7 – Movements engine + ops view at scale (2½ days)
**Goal** Map, run sheet and zones decide together whether each group is on time.
**Build**
- Migration 025: `movement_status`, `movement_routes`; engine inside `ops_tick()` + location trigger: deadlines, arrival (dwell, required ICs, no-signal exclusion), ETA (route remaining / straight line, speed blend), status with 2-reading hysteresis, leave-by.
- Edge Function `route-eta`: OneMap routing (`walk` / `drive`) to the arrival point, cached in `movement_routes`, refreshed on > 50 m deviation or every 2 min; OneMap token stays server-side (same secrets as reverse-geocode).
- Ops view at scale (mock-up screen 5): **summary bar** (groups on track / at risk / late / no signal – clickable filters), **problem queue** sorted by urgency with **I'll handle it / Acknowledge / Snooze**, map **clusters** per zone/sector showing the worst status, routes + ETA lines only for problem/selected groups, search + filters (category, sector, zone, status, "My groups"), run sheet chips "Bands → Formation 1: 2 ✓ · 1 late" expandable. Marshals: filtered to their sector.
- Decision banner for Auto-when-ready holds and anchor risks (GO anyway / Keep holding / Message group admin).
**Tests**
- SQL: arrival needs dwell; one IC with no signal does not block; deadline moves with delay; status flips only after 2 agreeing evaluations.
- Simulator: 120 groups with mixed presets → statuses match the presets (on-time groups green, 2-min-late groups red with correct +mm:ss, signal-loss grey), Auto-when-ready cue holds then starts when the last band arrives.
- Phone: walk a real route to a zone → ETA and status on the laptop are within ±30 s.
**Done when** the simulated rehearsal shows correct statuses and the problem queue works.

### Stage 8 – IC phone: my next move + Leave now (1 day)
**Goal** ICs know where to be, when, and when to leave – without watching a clock.
**Build**
- IC home on the event page (phone): next movement card (zone, deadline as projected, time left, distance, "at your pace you arrive … / +28 s late"), mini map with route, "After that" list, **Tell planner: delayed** (creates an ops alert), **Stop sharing**.
- Push via `send-reminders`: "Get ready" (−60 s), "Leave now" (leave-by), "You are running late" (status turns red); deduplicated per movement; tap → opens the card.
**Tests**
- Phone with app closed: Leave now arrives at the leave-by time ±15 s; delaying the show by +30 s moves it; Tell planner → alert on the laptop.
**Done when** an IC can follow a 3-movement test plan from notifications alone.

**Test days 2–3 (Sun 1 – Mon 2 Nov)**: full simulated rehearsal of the NDP sample (120 groups, 30–40 cues) for 30 min + a live walk test with 2–3 phones in the same session; run the demo script (section 8). **MVP done.**

### Stage 9 – Fixed routes / mobile column (1½ days, stretch)
**Build** Migration 026: `routes`, `checkpoints`, `checkpoint_passes`; route editor (mock-up: draw or pick KML path, drop checkpoints that snap to the route, planned speed → suggested offsets, validation: increasing offsets, within radius, anchor warning, unrealistic speed); "Use as route" from a Playback session; phone upload adds `speed, heading, activity`; engine: passes, delta, next ETA by GPS speed, later checkpoints planned + delta, anchor check; mobile column view (mock-up screen 4).
**Tests** Simulated column on the sample route with a +25 s delay at C2 → later checkpoints +25 s, anchor amber; a real car or bus test with one phone.

### Stage 10 – Scale tools (2 days, stretch)
**Build** Movement grid (groups × cues, cells = zone, copy/paste, fill down; mock-up screen 6); per-group Gantt with conflict checks (two places at once, impossible travel, zone/door capacity using headcounts); marshal "My sector" defaults; wall-screen mode (map + summary + top 5 problems, large type).
**Tests** Import 120 groups and 300 movements; grid edits save; conflicts found in a seeded bad file.

### Stage 11 – Post-event analysis (1 day, stretch)
**Build** Playback adds a **Run sheet report**: planned vs actual per cue, delay chart, per-group punctuality (arrived early/late per movement), average walking times per route → "suggest pace" for the next rehearsal; CSV export.
**Tests** After a simulated rehearsal, the report matches the simulator presets.

---

## 8. Demo script (5 minutes)

1. Builder: download template → import the NDP sample → preview → publish.
2. Start the simulation event (120 groups, presets: most on time, 3 late, 1 signal loss, 1 no-go breach).
3. Ops view: show clock + ON TIME; zoom out → clusters; summary bar.
4. A band runs late → amber then red, problem queue, "I'll handle it", message group admin; band cue (Auto when ready) holds → GO anyway.
5. +30 s and a Flexible cue absorbing it; anchor countdown stays fixed.
6. Real phone (IC): Leave now notification → walk into a zone → arrived on the laptop.
7. Mobile column (if built): checkpoint +25 s.
8. End event → Playback → run sheet report.

---

## 9. Notes filled in during the build

- Stage 0 (14 Oct): shapes are rows in `layout_objects` (`object_id`, `kind` = `area` | `plan`, `data` jsonb, `image_id`, `rev`). `data` is exactly what the canvas holds:
  - **Area:** `{ id, name, kind, points }` – `name` 1–50 chars; `kind` ∈ `zone, no_go, obstacle, stage, entrance`; `points` = `[[lat, lng], …]`, 3–200 points, every point inside Singapore (lat 1.1–1.5, lng 103.5–104.2), ring not closed (first point not repeated). Checked by `shape_problem()` / `area_ok()` in 017.
  - **Floor plan:** `{ id, name, centre: [lat, lng], widthM, heightM, angleDeg, opacity (0–1), visible }` – size 0–20 km, whole plan inside Singapore (`floor_plan_in_sg`, 014). The picture is not in `data`: it is a row in `layout_images` (`image_id` = md5 of the data URL), shared by plans that use the same file.
  - Changes since `005_layouts.sql`: one-row JSON canvas → rows (017), whole-canvas claim → lock per shape per tab (016), presence + own map view (015), plan must fit Singapore (014), frozen canvas dropped (018), `bench_head()` for catch-up (019). Bench capped at 4 MB (`layout_bytes`).
- Realtime messages per minute at 120 simulated groups: _(to fill in)_
- Battery per hour on phones at 10 s: _(to fill in)_

## 10. Risks and how we handle them

| Risk | Mitigation |
|---|---|
| Crowd networks drop uploads | Phones queue and upload later; "no signal" state; statuses never guess beyond 2 min |
| GPS jitter at zone edges | 20 s dwell, accuracy buffer, 2 outside readings to exit |
| One dead phone blocks a cue | No-signal ICs never block; planners can GO anyway |
| Two planners act at once | One action per cue (row lock), every action named in the log |
| OneMap limits or outage | Cached routes; fallback straight line × 1.3 / 1.4 |
| Free-plan Realtime quota | One status row per group; simulator measures usage; real NDP → Pro plan |
| Clock differences between devices | Server-synced show clock |
| Planner confusion | Numbers instead of words, one-sentence rule summaries, colours always with text |
