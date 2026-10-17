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

**Status 14 Oct 2026: BUILT** (Komin's phone check for Stages 0 + 1 together still to do). Migration `020_event_zones.sql` applied to gpstest. Decisions: the existing global bench stays as the **demo bench** at `/polygon` (event_id null, editable by any signed-in user as before); each event gets its own bench, made the first time its Zones tab opens. Zone sync is two triggers on `layout_objects` (BEFORE: give every area on an event bench a code; AFTER: upsert / delete its `zones` row). Rolled-back SQL test: 19/19 (codes, rename keeps the zone row and code, duplicate / bad code refused, `FORMATION_1_2` for a second "Formation 1", inside / outside / buffer / distance, delete removes the zone, demo bench makes no zones, member read-only, outsider sees nothing and cannot save). Browser: Zones tab → draw "Formation 1" → code FORMATION_1 → zone row; code edited to FORM_A / FORM_B → zone and live-map label follow live; live map Zones layer + toggle, labels from zoom 16; delete via in-app dialog removes the zone; `/polygon` demo bench unchanged. `npm run test:db` (bench suite, 001–019) still 196/196 – PGlite has no PostGIS, so 020 is covered by the SQL test above instead.

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

**Status 14 Oct 2026: BUILT** (phone walk test with Stages 0–1 still to do). Migration `021_zone_presence.sql` applied. Decisions: the IC who enters a No-Go zone is warned too (red in-app banner + toast now; a push when the app is closed comes with Stage 8's push work); edge buffer = min(accuracy, 15 m). Trigger `locations_zone_update` never blocks an upload (catches its own errors) and ignores late (older) readings. Live map keeps its smooth client-side group marker; the server's `group_positions` feeds the group tooltip ("Moving 1.2 m/s") and later the engines. Rolled-back SQL test 13/13 (enter at first inside reading, one blip does not close, two outside close at the first, 15 m edge buffer vs 5 m, late reading ignored, one alert per No-Go entry, group midpoint / speed / ICs sharing, Stop closes stays, a reading outside any session does not error, RLS root vs outsider, outsider cannot acknowledge). Browser: IC tooltip "Inside Test formation since 10:59:06 am", zone labels "1 IC (1 group)", No-Go entry → toast + IC banner + zone drawn bold red, leaving needs 2 readings then everything clears; no console errors.

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

**Status 15 Oct 2026: BUILT** (Komin's first live run with 120 groups still to do). Migration `022_simulator.sql` applied. Built as SQL functions instead of an Edge Function: `create_simulation_event`, `sim_setup` (virtual groups + ICs, behaviour mix, walks from 200–600 m to the event's zones), `sim_start` (starts the event if needed) / `sim_pause` / `sim_reset`, and `sim_tick` on pg_cron every 10 s (`gps-sim-tick`, a no-op while nothing runs). Virtual ICs are fake Auth accounts (`@simulation.invalid`, no password or identity, `profiles.is_simulated`), deleted by Reset or when the event is deleted (trigger on `sim_ics`). Readings go through the normal `locations` table and the Stage 2 trigger. UI: "Simulation event" checkbox on My events; SIMULATION badge + banner; root-only Simulator tab (status, counts, Add groups, mix, Start / Pause / Reset). Rolled-back test with five existing accounts standing in as ICs (no accounts created): on time arrives and is inside, 2 min late at 216/300 m after 5 min, stops at 150 m, loses signal sends 14 of 30 readings and still arrives, wrong zone inside the No-Go with exactly 1 alert; pause inserts nothing; reset removes readings, groups, run and IC rows; refusals for real events, no zones, outsiders. Browser: create a simulation event, badge / banner / tab, presets listed, Add without zones refused before anything is created.

**First live run 16 Oct 2026: PASSED (S1–S9)**, 120 groups / 303 virtual ICs around the Padang (3 zones + 1 No-Go), 15 min, 91 ticks, 27,336 readings, every tick succeeded (0.51 s average, 1.03 s worst, budget 10 s); all 303 ICs counted into the right zones; late groups 2 min behind; lost-signal groups silent ~150 s then back; one alert per IC per entry, never repeated; Pause stops readings; End leaves it paused; Start again opens a new session; Reset removes all 303 accounts and everything they sent in 1.2 s, zones stay. Fixed during the run: (1) the live map fell to ~8 fps on laptop and phone with 300 markers (every Realtime message rebuilt everything): readings and group positions are now applied in batches every 400 ms and lookups are by id → 115–120 fps; (2) zone and presence reloads cancelled each other on the live map; (3) a group could start inside or walk through a No-Go zone (10 of 28 alerts) → migration `023_sim_routes.sql` (starts 25 m clear, walks 20 m clear except "wrong zone"); (4) 15 No-Go toasts at once → one toast per burst ("6 groups (15 ICs) entered Stage"); (5) markers of deleted people (Reset, removed members) stayed on the map. Still to decide: map clustering (Stage 7) and moving locations / group positions to Realtime Broadcast (see section 9).

**Test day 1 (Tue 20 Oct)**: 2–3 real phones + simulator together on one sim event; check zones, presence, no-go, map performance; note battery and Realtime usage.

### Stage 4 – Run sheet builder, manual entry (1½ days)
**Goal** Planners build named run sheet versions in the app and choose which one each start of the event runs.
**Design agreed 17 Oct**
- A run sheet **version** has a **name** (required, unique in the event, e.g. "Rehearsal 2"; Duplicate suggests the next number) and an optional **date it is for** (Sat 19 Jul). Shown everywhere as *Name · date · status*.
- Status in plain words: **Draft** (being edited) · **Ready** (passed the check, can run; editing it turns it back to Draft) · **Used** (a session ran with it: locked, Duplicate to change). Used is worked out from the sessions, never set by hand.
- Cue times are **time of day** (+1 day for cues after midnight), applied to the date of whichever session runs the version, so one version can run on any date.
- **Start event / Schedule** pick the version (Ready or Used only; preselected: the one dated today, else the latest Ready; or "No run sheet – tracking only"). The session remembers it (`event_sessions.run_sheet_id`); the status line says "Running: Rehearsal 2"; Playback says "Ran with: …". During a live show **Switch live show to this version** asks first.
- Who: root and planners edit; marshals read; ICs and members do not see it yet (Stage 8).
- Category movements: one row for the category ("All Bands"), expanded to every group in it when read; per-group exceptions (skip, or a different zone).
- Movement editor stores every field now; Vehicle and Fixed route are "planned only" until Stages 7 and 9.
**Build**
- Migration 024 (023 went to the simulator route fix, 16 Oct): `run_sheets (event_id, name, for_date, status draft|ready)`, `cues`, `movements` (+ `parent_id` for a category exception), `event_sessions.run_sheet_id`; RLS read for root/planners/marshals, writes only through functions: `run_sheet_list`, `create_run_sheet` (blank or copy), `update_run_sheet`, `delete_run_sheet`, `save_cue`, `delete_cue`, `move_cue`, `save_movement`, `delete_movement`, `check_run_sheet` (errors and warnings per row), `mark_run_sheet_ready`, `switch_live_run_sheet`, `run_sheet_moves` (category expansion), `update_group_details`; `start_event` / `schedule_event_start` take the version.
- New event tab **Run sheet**: version picker and actions, problems list, cue table by section with an inline cue editor, movements list and a **movement editor panel** (who, where, deadline, arrived rule, how they get there, one-sentence summary, category exceptions).
- Groups: code, category, sector, headcount editable in the Members tab.
**Tests** see the test plan page (R1–R…): every function's refusals, Draft/Ready/Used rules, copy, checker rules, concurrency, the Start/Schedule picker, and the UI flows on laptop and phone.
**Done when** a run sheet can be built, checked, marked ready and picked when starting the event, by hand.
**Built and tested 17 Oct** – SQL suite `supabase/tests/run_sheets_test.sql` 101/101 (rolled back); browser (laptop + 375 px) and the phone app (S25, planner account): versions, cues, movements, exceptions, check, Start/Schedule picker, live switch, Playback "Ran with", group details, two planners editing at once, live sync phone ⇄ web. Timing at NDP size (150 cues, 200 groups, 400 expanded movements): check 53 ms, duplicate 115 ms, insert at top 13 ms. Bugs found and fixed while testing:
- "Someone else changed this" used SQLSTATE 40001, which PostgREST retries forever: the save hung. Now `PT409` (HTTP 409), and the editor keeps your text so a second Save replaces theirs.
- Cue/movement codes past 99 looped forever (`lpad` cut C100 to "C10"). Movement list sorted naturally (M99 before M100).
- Switching the live show to another version un-locked the one that had run (it lost its only link to a session). Switches are now recorded in `run_sheet_switches`; Used counts them; Playback shows "Ran with: A, then B from 8:14 pm" (`session_run_sheets`). Switching to the version already running is refused.
- Check messages showed after-midnight times without "next day"; now `rs_clock` adds it, and a cue just after midnight without +1 day gets a hint.
- UI: the cue editor opens under the cue clicked (not below 150 rows); ↑/↓ disabled at the ends; editors close when another version is picked; the version list reloads after a schedule is cancelled (Realtime doesn't announce deleted rows); a draft is never preselected; a scheduled version edited back to Draft is flagged in red in the tab and the status card; group codes show as stored (capitals); category spelling follows the groups; problems list shows errors first, 8 at a time.
- Known, by design: a scheduled start that reaches its time with a version edited back to Draft still runs it (warned in red); the live show engine (Stage 6) will refuse to run cues from a draft.
- Applied as `024_run_sheets` + `024b`–`024e` on the project; the repo file `024_run_sheets.sql` holds the final state.

### Stage 5 – Excel template, import and export (1 day)
**Goal** Upload the team's show matrix as the template and get the same run sheet; export back.
**Build**
- Serve `docs/templates/run-sheet-template.xlsx` from the app (**Download template**).
- Import in the browser with SheetJS (pinned version): read tabs Event, Cues, Groups, Zones, Movements, Checkpoints; validate (IDs link, times `HH:MM:SS`, dropdown values, numbers); **preview screen** listing every problem per row ("Movements row 12: cue C099 not found"); nothing saved until the preview is clean; then save as a new **draft** version. Zones in the file: match existing zone codes; `Circle` zones are created; `Polygon` zones must exist in the bench (else listed as missing).
- Export: current version → same template layout.
**Tests**
- Import the sample template → identical run sheet; import a broken copy (bad time, unknown cue, duplicate code) → errors listed, nothing saved; export → re-import → same data.
**Done when** round-trip import/export works and errors are clear.
**Built and tested 17 Oct** (browser and the phone app: template, import, export and Playback CSV save on the S25 through Android's Save screen; cancelling is clean). Changes from the plan: **ExcelJS 4.4.0** (pinned) instead of SheetJS – it reads and writes .xlsx with the template's styles, notes and dropdowns, and loads only when a file is read or made (its own 256 KB gzip chunk). One list of columns in `src/utils/runSheetFile.js` makes the template (Download template), the export and the import, so they cannot drift; `docs/templates/run-sheet-template.xlsx` is written by `node tools/make_run_sheet_template.mjs` from the same code (the old Python generator is gone). Template additions: Cues **Next day** (or write 24:05:00), Movements **Notes**, Zone code **SKIP** (a group skips its category row). Migration **025** (`025_run_sheet_import.sql`): movement fields Must leave by / Arrival point / Route (planned only, kept by the editor and by Duplicate), and `import_run_sheet` – all or nothing, every error names the tab and row; a missing Circle zone is drawn on the event's bench as a 32-point area (shows and edits in the Zones tab), a missing Polygon zone leaves the movement without a zone (the check flags it); groups matched by code, then name, else created. A one-group row with the same deadline as its category row becomes that row's exception. Phone app: `SaveFilePlugin` ("Save to..." screen, no storage permission) for Export, Template and the Playback CSV (a download link does nothing in the app's WebView).
Tests: `node tools/run_sheet_file_test.mjs` 105/105 (template, times and Excel-mangled lengths, dropdown values typed by hand, codes and references, No-Go destinations, defaults, Event tab, missing tabs and columns, columns moved, rich text / formulas / dates / links in cells, not an Excel file, 503 cues refused, 408 cues + 1,505 movements read, export → import identical); `supabase/tests/run_sheet_import_test.sql` 43/43 (roles, template import, circles on the bench, all or nothing, 16 refusals each naming its row, re-import matches instead of duplicating, planned fields kept and copied, 400 cues + 1,500 movements in 2.4 s); `run_sheets_test.sql` still 101/101. Browser: template download, CSV and corrupt files refused, broken workbook lists both problems with rows, name clash caught, import → new draft selected, export → re-import → identical cues and movements (compared field by field), circles in the Zones tab, phone width. Bugs found and fixed: a big import took 10.6 s (requests stop at 8 s) – every row also updated the version row and opened a sub-transaction; now 2.4 s. The speed fix first broke "an edited Ready version becomes Draft" (a NULL comparison) – caught by re-running the Stage 4 suite, fixed (025c). New groups showed as "A deleted group" until a reload (the page did not reload groups); the template's own example ran Mobile Column 8 minutes into the Flypast anchor; the import panel opened off-screen on a phone; one "already in the app" line per zone (now one line).

### Stage 6 – Live show engine + run sheet beside the map (2 days)
**Goal** The run sheet runs live during a session, beside the live map.
**Build**
- Migration 026 (after the run sheet's 024 and import's 025): `cue_state`, `show_actions`; functions `server_now()`, `show_go(session, cue)`, `show_hold`, `show_resume`, `show_add_time(seconds)`, `show_skip` (root/planners; one action per cue enforced with row locks; actions logged); engine `ops_tick()` via pg_cron every 2–5 s: auto-start Auto cues at projected start, Auto-when-ready cues start if their movements arrived else hold + alert, finish cues at their length, recompute delay/projected times with Flexible absorption and anchor checks.
- A session uses the event's **published** run sheet version (stored on `event_sessions.run_sheet_id` at start).
- Ops layout on the event page for root/planners/marshals: map left, **run sheet panel** right (NOW with progress + GO / Hold / +30 s, UP NEXT planned → projected, anchors) and a **top bar** (server-synced clock, ON TIME / RUNNING BEHIND / CRITICAL with ±mm:ss, next anchor countdown) – as mock-up screen 1. Marshals see the panel without buttons.
**Tests**
- SQL: auto cue starts at its time; manual waits; GO on an already-running cue refused; +30 s shifts later cues; Flexible absorbs; anchor never moves; anchor-at-risk alert when delay > buffer.
- Browser: a 10-minute test version of the sample run sheet (short cues, one Flexible, one Anchor) in the simulation event, in real time; two planners press GO at once → one wins, both see who.
**Done when** a 10-minute test run sheet runs end to end with delays and anchors correct.
**Built and tested 17 Oct.** Migration **026** (`026_live_show.sql`, applied as 026 + 026b + 026c): `show_state` (per session: show day, opened at, held), `show_cues` (pending / running / done / skipped, real start and end, added time, waiting for GO or groups), `show_log` (every action and alert, who and when). One projection, `show_rows()`, gives every cue its planned, due and projected start and end, delay, Flexible absorption and anchor risk; the engine `show_step()` (pg_cron `gps-show-tick` every 2 s via `show_tick()`, 3 ms when idle) and every page use it. Rules: a cue never starts before its plan nor before the cue before it ends; Auto starts at the exact second it is due (not when the tick runs); "Auto when ready" starts when the groups of its movements (deadline = its start) have been inside their zone for "stay inside" s (Stage 2 zone presence; ETAs are Stage 7), else it holds and says who is missing; Manual waits for GO; an anchor keeps its time, is "at risk" (told once) when the show is projected to run into it, starts on its time cutting the running cue and skipping cues that never ran; an anchor whose time passed before the show opened is missed instead; Hold = nothing moves on until Resume (anchors still start). Buttons (root / planners, one lock per show so two GOs cannot both win): `show_go`, `show_hold`, `show_resume`, `show_add_time`, `show_skip` (running cue = end now); `show_board` for root / planners / marshals; `server_now` for the clock. Switching the live version carries cues that ran over by code. Page: on the Live map tab a top bar (server clock, ON TIME / RUNNING BEHIND / CRITICAL / HELD / STARTS IN, next anchor countdown) and the run sheet panel beside the map (above it on a phone): NOW with progress, time left, GO / Hold / +30 s / −30 s / End now; UP NEXT planned → projected with anchors and Skip; Done and the log. Marshals see it without buttons; ICs and members do not see it. Toasts for alerts and other planners' actions.
Tests: `supabase/tests/live_show_test.sql` 53/53 (show clock stepped to the second: exact Auto starts, GO refusals, +30 s, Flexible absorbs 30 s, Manual waits and is told once, two planners' GO, Auto-when-ready waits for 20 s inside then starts, anchor risk told once, anchor cuts, Hold / Resume, finish, roles, catching up after missed ticks, Skip / End now, late session start, live switch carries over, run sheet switched on later, anchor missed before the start, the cron tick); Stage 4 suite 101/101 and Stage 5 import 43/43 still pass. Real time in the browser ("NDP sim run 1", 7 cues, 7 minutes): C1 started at 20:34:00.000 and ended 20:35:00.000 exactly, Manual waited with a toast, GO, +30 s ×3 → RUNNING BEHIND then CRITICAL with the anchor alert, the anchor at 20:39:00 cut C4 27 s short, Hold / Resume, Skip, FINISHED; phone app (S25, testuser1 as planner) and laptop on the same show: same clock, and both pressed GO at 20:51:05 (phone .001, laptop .016): one GO recorded, the other told "already running: started at 20:51:05 by Claude Test". Bugs found and fixed: start times would have included the engine's lag (now the exact due second); catching up could cut a cue that should have ended before an anchor (now the earliest event first); a late first engine run looked like "switched on mid-session" and skipped earlier cues (now decided from the record of switches); a session started after an anchor's time ran that anchor late and skipped every cue before it (now the anchor is missed); the GO dialog called a delayed cue "early"; the map did not resize when the panel appeared.


### Stage 7 – Movements engine + ops view at scale (2½ days)
**Goal** Map, run sheet and zones decide together whether each group is on time.
**Build**
- Migration 027: `movement_status`, `movement_routes`; engine inside `ops_tick()` + location trigger: deadlines, arrival (dwell, required ICs, no-signal exclusion), ETA (route remaining / straight line, speed blend), status with 2-reading hysteresis, leave-by.
- Edge Function `route-eta`: OneMap routing (`walk` / `drive`) to the arrival point, cached in `movement_routes`, refreshed on > 50 m deviation or every 2 min; OneMap token stays server-side (same secrets as reverse-geocode).
- Ops view at scale (mock-up screen 5): **summary bar** (groups on track / at risk / late / no signal – clickable filters), **problem queue** sorted by urgency with **I'll handle it / Acknowledge / Snooze**, map **clusters** per zone/sector showing the worst status, routes + ETA lines only for problem/selected groups, search + filters (category, sector, zone, status, "My groups"), run sheet chips "Bands → Formation 1: 2 ✓ · 1 late" expandable. Marshals: filtered to their sector.
- Decision banner for Auto-when-ready holds and anchor risks (GO anyway / Keep holding / Message group admin).
**Tests**
- SQL: arrival needs dwell; one IC with no signal does not block; deadline moves with delay; status flips only after 2 agreeing evaluations.
- Simulator: 120 groups with mixed presets → statuses match the presets (on-time groups green, 2-min-late groups red with correct +mm:ss, signal-loss grey), Auto-when-ready cue holds then starts when the last band arrives.
- Phone: walk a real route to a zone → ETA and status on the laptop are within ±30 s.
**Done when** the simulated rehearsal shows correct statuses and the problem queue works.
**Built and tested 18 Oct** (the 120-group simulator run and the phone walk are still to do: the simulator's virtual ICs are accounts only Komin creates, and the walk needs the phone). Migration **027** (`027_movements.sql`, applied as 027 + 027b–e): `movement_status` (one row per movement and group per session: waiting / active / done; status pending, on track, at risk, late, no signal, arrived, arrived late, missed, skipped; deadline planned and projected, ETA, spare, late by, leave by, metres to go and how measured, ICs inside / needed / heard / without signal; handled by, acknowledged, snoozed), `movement_routes` (OneMap route per movement and group), `group_messages`, `event_roles.sector` (a marshal's sector). Engine `move_step()` via pg_cron `gps-move-tick` every 5 s (separate from the show's 2 s tick; one show failing never stops another): one movement per group at a time (its earliest unfinished one); deadline = when the cue is due (moves with the show's delay but **not** while the cue waits for GO or for its groups – a group that holds an "Auto when ready" cue is late, not "on time"), or the cue's projected end, or the fixed time, minus "arrive early by"; arrived = the k-th IC inside for "stay inside" s (k = min ICs, else every IC heard in the last 2 min; an IC without signal never blocks); ETA = k-th fastest IC: distance along the OneMap route within 50 m of it, else straight × 1.3 (foot) / 1.4 (vehicle) / × 1 in a simulation, last 50 m straight; speed **per IC** = planned pace until that IC moves (0.5 m/s closer over 50–90 s), then blended towards its real progress; ETA rounded up to 5 s; status changes only when two evaluations agree (arrived / missed at once); leave by = deadline − stay − distance ÷ planned pace (never after the planned "Must leave by"), kept once the IC the group waits for moves; missed = its cue ran without them, or 10 min past the deadline; a skipped cue skips its movements; a live version switch carries arrivals over by code. Edge Function **`route-eta`** (no login; checks the push cron secret from 009): pg_cron `gps-route-eta` every 30 s calls it only when a route is due (`route_due()`), it claims up to 20 (`route_claim`: active, real events, group > 80 m away, no route / older than 2 min / strayed > 50 m), asks OneMap (walk / drive) with the token kept server-side, and saves the path (`route_save`). Ops view: `ops_board(session, since)` (root / planners / marshals; changed rows only after the first read, empty fields left out, a route sent only when new), `ops_handle` (I'll handle it / let go; a second person is told who has it), `ops_ack` (hidden until it gets worse), `ops_snooze` (1–30 min), `message_group` (the group's members see it on the event page; logged), `show_keep_holding`, `set_marshal_sector`, `sim_plan_movements` (simulation events: one movement per virtual group in a Draft version). Simulation: groups with an active movement walk it leg by leg at its pace and leave a minute before their leave-by ("2 min late" a minute after) via `sim_follow_plan`; others walk as before. Page (Live map tab, root / planners / marshals while a show runs): summary bar (groups on track / at risk / late / no signal / done, each a filter; search, category, sector, zone, ★ My groups; a marshal's view opens on their sector), decision banner ("Auto when ready" holding: GO anyway / Keep holding / Message group admins; anchor at risk: −30 s on the running cue / Skip the next cue / OK), problem queue beside the run sheet (most urgent first; I'll handle it, Message admin, Acknowledge, Snooze 2 min; tap a group → the map zooms to it), run sheet chips under each cue ("Bands → HOLD_D4: 1 ✓ · 2 no signal", tap for every group), map clusters below zoom 16 (one bubble per zone a group is inside, else per sector: number of groups, ring = worst status, tap to zoom in; people hidden), zoomed in a status ring + dashed line along the route to the zone + "Group A · +0:28" for groups in trouble and the one picked in the queue; the filters hide other groups' markers. Members tab: "Marshals sector" for marshals. Simulator tab: "Plan their movements (rehearsal)". Status is always a word and a symbol as well as a colour.
Tests: `supabase/tests/movements_test.sql` **53/53** (rolled back; readings with their own times go through the Stage 2 trigger): rows per movement and group, ETA / spare / leave by to the second, moving → planned pace then 50/50 blend, leave by kept once moving, arrival needs 20 s inside, one IC without signal does not block, arrived exactly at entered + 20 s, the next movement takes over, min ICs → no signal, +30 s moves cue-end and cue-start deadlines, projected late told on the 2nd look, arrived late at once (+0:10), on track → at risk → late each after 2 agreeing looks, acknowledge kept until worse, an "Auto when ready" hold does not move the deadline (missed +2:11 after GO), skipped cue → skipped, roles (member reads only their group's rows; routes table and engine functions not callable), handle / let go / taken by someone else, snooze limits, messages (own group only, logged), keep holding refused unless waiting, marshal sector, distance inside / last 50 m / × 1.3 / along a route / off the route, route claimed once and used, simulator leg + departure + plan movements (root only, not twice). Stage 6 suite 53/53, Stage 4 101/101, Stage 5 import 43/43 (its fixture now clears the template's groups and circles left by earlier imports), file tests 105/105, bench 196/196, build OK. Live in the browser on "Playback test (Claude)" (testuser1 and claude_test walking by a scripted feed): leave by / ETA / spare matched the formula, on track → at risk → arrived, the "Auto when ready" cue held and the banner offered GO anyway / Keep holding / Message; GO anyway (confirm), Keep holding (logged for everyone), Message (banner + toast for the group's member), anchor at risk → −30 s took it from 0:37 to 0:07, OK hid it; queue: I'll handle it → "Handled by you" + My groups (1), Message admin, Acknowledge hides it; filters hide the group's markers; clusters at zoom 14 ("1 · 1 late", tooltip) → tap → zoom 18 with ring + "+10:30" label; OneMap routes fetched by the cron (4 calls, 200, 631 m / 133 points) and used; phone width 375 px without sideways scrolling; no console errors. Scale (rolled back, 120 groups / 300 ICs / 240 rows): engine 100–125 ms per tick, ops_board 24–30 ms, 111 KB on a full read and 0.2 KB when nothing changed. Bugs found and fixed while testing: the group's ETA used the average progress of all its ICs, so a standing IC looked as if walking and the leave by froze too early (now per IC); a cue held for a group gave that group more time (deadline now when the cue was due); a group with no ICs read "0 of 1 IC heard"; two toasts for one message (and one per group when messaging many); the board was 200 KB every 4 s per planner (now changed rows only).

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
**Build** Migration 028: `routes`, `checkpoints`, `checkpoint_passes`; route editor (mock-up: draw or pick KML path, drop checkpoints that snap to the route, planned speed → suggested offsets, validation: increasing offsets, within radius, anchor warning, unrealistic speed); "Use as route" from a Playback session; phone upload adds `speed, heading, activity`; engine: passes, delta, next ETA by GPS speed, later checkpoints planned + delta, anchor check; mobile column view (mock-up screen 4).
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
- Realtime messages per minute at 120 simulated groups (16 Oct run, 303 ICs): about 425 database changes per 10 s tick (303 locations + ~120 group positions + presence + run counter) ≈ 2,550 per minute, delivered to EACH open viewer → ~5,100/min with 2 viewers, ~76,000 for a 15-minute run. Free plan includes 2 M/month, Pro 5 M: a real NDP with many planners watching needs Pro, and the high-volume feeds should move to Realtime Broadcast. Database: `sim_tick` 0.51 s average per tick; the heaviest query on the database is Realtime's own change polling (7.4 ms per call, cumulative 214 k calls), which is the Supabase-documented limit of postgres_changes. Read database CPU from the dashboard (Reports) for this window: 18:48–19:04 UTC, 15 Oct.
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
