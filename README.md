# gpstesting

Test sandbox for the IS216 G11 event coordination & live tracking app.
Vue 3 + Vite + Bootstrap 5 + Leaflet (OneMap tiles) + Supabase.

| Page | Route | Owner |
|---|---|---|
| Home | `/` | shared |
| Sign in / create account | `/login` | Komin |
| My events (create / join with code) | `/events` | Komin |
| Event: live map, members & groups, invite | `/events/:id` | Komin |
| Share my location (ICs only) | `/events/:id/share` | Komin |
| Invite link / QR target | `/join/:code` | Komin |
| Polygon bench: draw areas over an optional floor plan | `/polygon` | shared |

### The polygon bench (`/polygon`)

A standalone drawing bench, deliberately **not** tied to an event: a planner clicks a floor
plan or an area to work on it, optionally lays a floor plan over the map, and draws areas
(Zone, No-Go, Obstacle, Stage, Entrance) on top. Every area's points are stored as lat/lng,
so everything travels with the map.

One thing is worked on at a time (`null | 'floorplan:<id>' | 'polygons' | 'area:<id>'`), and **a change
is written when it settles**: at the end of a drag, or a moment after an edit that is not one (a typed
name, an opacity slider). There is no Save button, and nothing at all is written while a pointer is
down. **The map is never locked**: it pans
and zooms whenever you ask, and a shape is grabbed by its own parts (an outline by its body, a
picture by the picture), which is what keeps a drag of one from moving the view. A **middle
drag pans** whatever is underneath — on a shape, on a handle, and while an area is being drawn —
which is the way to hold the map when a picture covers the screen. The left button moves the view
wherever there is nothing else for it to mean, and the only thing that narrows that is drawing an
area, where every left click has to be a point. A floor plan is named and edited like a PowerPoint
picture: drag it to slide it, drag a corner to resize it, drag the knob above it to turn it.
Recording an area is click-to-add-a-point, with the ring snapping shut when the cursor comes near
the first point. Clicking a floor plan or an area on the map selects it and highlights its row.
**Dragging a shape past the edge of the map carries the map with it**, so something can be moved
somewhere that is not on screen yet without letting go first.

The rules the bench enforces while you work, all of them in the browser so the answer arrives
before the action rather than at the next save:

- **An outline may never cross itself.** A click that would draw a crossing line is refused
  and the rubber band turns red as the cursor approaches; a dragged dot turns the outline red
  while it would cross and is put back if it is dropped there. The answer is given while the
  dot is still moving, in red rather than in words.
- **"Add point" always finds a legal place for the new dot** (`src/utils/areaGrow.js`), by
  splitting the longest edge if the end of the ring will not do.
- **One message, one place**: a refusal is a single red sentence along the top of the map,
  whether you are drawing or adjusting.
- **Undo and redo cover the whole canvas**, as arrow buttons in the header (and Ctrl+Z /
  Ctrl+Shift+Z / Ctrl+Y). A step is a change to a shape, so putting one back is a write like any
  other — including taking away a shape you made. Copy and paste a floor plan or an area with
  Ctrl+C / Ctrl+V.
- **A floor plan must fit inside Singapore**, not merely start there — see
  `supabase/migrations/014_floor_plan_bounds.sql`.
- **How full the canvas is** is drawn as a ring on the Floor plans card, and an upload that
  would push the canvas over 4 MB is refused before it is added.

There is exactly **one** bench, shared by every signed-in user, and everybody may work on it at
once. Exclusion happens **one shape at a time**: a planner takes a lock on the area or floor plan
they are changing, the database decides who has it, and a change to a shape somebody else holds is
refused rather than obeyed. A lock is held by a *session* — one per browser tab — so two tabs of
the same account are two planners here, which was the bug this replaced: the old one-claim-for-the-
whole-bench model handed a second browser of the same login the *same* token, and both could save.

Nothing has to be pressed to start working: the lock is taken by the first change to a shape and
let go when it is put down, when the tab is hidden, or after 45 seconds of quiet. A planner who is
refused is told who has it and why nothing moved.

**The canvas is rows, and a write is a patch.** `save_object()` lays the fields a planner changed over
the row the database holds and hands the merged shape back — so a page whose copy is behind (a hidden
tab, a screen that missed an event) writes what it changed and cannot undo what it did not. A floor
plan's picture is a row of its own, keyed by the md5 of the image itself, so a copy of a plan costs its
placement and a plan that is only being moved uploads nothing. A write is the SHAPE that changed, which
is why a drag is written in about a second instead of the 19–34 seconds one save of the whole 3.7 MB
document used to take. See `supabase/migrations/017_object_rows.sql`.

**A shape somebody else makes or deletes arrives on its own.** `layout_objects` is published to
Realtime, so an insert, a change and a deletion each reach every other open page as they happen — which
the whole-document bench could not do at all: it had nothing to say about one shape, so a new shape
waited for the other planner's next save. An event is a notification rather than the truth: the row it
carries is checked against the revision this page already holds, and a shape this page is HOLDING is
never taken from an event, because the lock is what decides who may say what.

**Planners can see each other while all of that is going on.** Each open page keeps a row in
`public.layout_presence` — one row per tab, refreshed every 10 seconds and streamed over Realtime
— so the bench shows who else is here, and puts a planner's name on the shape they have open, in
their own colour, both on the map and in the list of areas. A second tab or a second browser of
the *same* account is listed as its own planner, labelled as another window, because that is the
case that used to be invisible. None of it is trusted: presence is a hint for the display, and
what a planner may actually change is decided by the locks, and by the database when a write arrives. The map view is each
planner's **own** (`public.layout_views`), so panning no longer carries anybody else's map along
with it — the copy inside the canvas is only the fallback for a planner who has never panned. See
`supabase/migrations/015_presence_and_views.sql`.

**And a drag is visible while it is happening.** The planner moving a shape publishes its geometry
to the other open pages about twenty times a second over the same Realtime socket, so an outline
follows a finger across everybody's screen instead of jumping to its new place when it is put down,
and its row in the list of areas moves with it. Frames are broadcasts rather than rows: they never
reach the database, so a drag costs no writes and a lost frame costs nothing (the next one is more
current). They are not trusted either — a frame may only change the fields a drag changes (never an
`id`, never a floor plan's image) and never into geometry the database would refuse, because what a
planner's screen shows is in the patch of that shape's *next* write. The lock decides who may say what,
and the database checks the merged shape before it stores it. See `src/composables/useBenchFrames.js`
and `src/utils/benchFrame.js`.

A live frame only ever patches a shape that is already on the other screen — it is a drawing hint, not a
row. A shape that is created or deleted arrives as a row event instead (see above), so both are seen as
they happen rather than at somebody's next save.

**How big the bench is** is counted over the rows by `layout_bytes()` and capped at **4 MB** by
`save_object()`: the ring on the Floor plans card shows the database's own number (byte for byte, since
the page has no way to know what is really stored), and a picture that would push the bench past the cap
is refused before it is added. Every floor plan image is shrunk in the browser to under 512 KB before it
goes near the database, and a floor plan that would not fit inside Singapore is refused (see
`supabase/migrations/014_floor_plan_bounds.sql`).

**The old whole-canvas column is gone.** `017_object_rows.sql` left it frozen in the bench's own row —
3.7 MB that every read of the bench detoasted to get at the 200 bytes beside it — and
`018_drop_frozen_canvas.sql` drops it, after moving the one thing still living inside it into a column of
its own: the bench's **home view**, where a planner who has never panned opens the map (see
`015_presence_and_views.sql`, which moved a planner's camera into a row of its own). The drop refuses to
run if the document holds a shape with no row, because there is no second copy of a shape: a migration
that cannot account for one stops with a sentence rather than tidying it away.

## Roles (per event, from the project spec)

| Role | Can do |
|---|---|
| Root | Creator. Everything, incl. making planners / marshals. Cannot be removed. |
| Planner | Create groups, add people by username, assign groups, make group admins / ICs. Sees every group. |
| Marshal | Sees every group (manual position marking comes later). |
| Group admin | Add / remove people in their own group, promote ICs. |
| IC | The device that shares GPS for its group. Only ICs can send locations. |
| Participant (spec: "User") | Sees their own group on the map. |

Every rule is enforced in the database (Row Level Security + functions in
`supabase/migrations/002_users_events_groups.sql`), not only by hiding buttons.

## Setup

```bash
npm install
cp .env.example .env   # then fill in your Supabase URL + public key
npm run dev            # http://localhost:5173
```

### Checking the bench with two browsers (`tools/bench_harness.mjs`)

`npm run build` cannot tell you whether two planners get on: it passed while `/polygon` threw on
load (a missing import is a legal reference to a global), and every rule that matters here is decided
by two sessions, a lock answered while a finger is down, or a frame from somebody else's browser. So
the bench has a harness that drives the real page in two real browsers — the same account in two
profiles, which is the case all of this started from — and reports what happened:

```bash
# two headless Firefox instances, each with its own profile and its own debug port
firefox --headless -no-remote -profile %TEMP%\bench-harness\ff1 --remote-debugging-port 9222 about:blank
firefox --headless -no-remote -profile %TEMP%\bench-harness\ff2 --remote-debugging-port 9223 about:blank
npm run dev
BENCH_EMAIL=... BENCH_PASSWORD=... node tools/bench_harness.mjs http://localhost:5174
```

The account comes from the environment, with no default: this file is in the repository, and a test
account's password in a repository is a password in a repository.

It makes its own area, watches it appear on the other screen **with no reload**, drags it, watches the
drag arrive, presses it from the losing side, undoes it, redoes it, deletes it and checks the other
screen loses it on its own and that the bench was left as it found it. `tools/probe.mjs` asks one
question of a page that is already open (`node tools/probe.mjs 9222 @question.js`), which is how most of
the above was diagnosed. Nothing here runs in CI: it needs the browsers, a dev server and a login.

Note: a write is one shape now, so it takes about a **second** rather than the tens of seconds one save
of the whole 3.7 MB document took — the harness reports what each write actually cost, which is the
measurement that says whether that is true.

### Driving a page from a script (`tools/run.mjs`)

`tools/shot.mjs` takes a picture and can press one button. That is not enough to check a screen where the
thing being built is a drag, a keystroke and a second tab, so `tools/run.mjs` runs a small script that
does all of it against a real browser and fails with what the page actually said:

```bash
npm run dev -- --port 5178 --strictPort    # in one terminal
npm run check:board                        # in another
```

A check module default-exports `{ name, run }` and is handed `{ browser, newTab, base, session }`; each tab
has `goto`, `click`, `type`, `press`, `drag`, `reload`, `waitFor`, `text`, `assertText`, `assertContains`,
`assertCount`, `assertThat`, `shot`. Input goes in as **trusted** events through the DevTools protocol, so a
handler listening on `pointerdown` sees a drag and a handler that only listens for `click` does not. There is
no puppeteer and no driver binary. The browser is a Chromium in headless mode — Edge on this machine, and any
installed Chrome is picked up without a change — started by the runner if nothing is listening on the debugging
port. `dev/checks/board-lies.mjs` is an assertion that is wrong on purpose: it is how the runner is proved to fail
loudly rather than pass quietly.

`click` scrolls its target into view before pressing. That scroll needs a frame to reach the input pipeline:
read the rect in the same breath and the first click after a big scroll lands where the element *was*, which is
how step 4's first clicks hit the page background and did nothing. `rect()` therefore scrolls, waits for the
scroll to commit, then measures — and because a background tab never gets an animation frame, the wait falls back
to a timer. Anything measured in CSS pixels should be measured **inside its container** (a map, a panel) rather
than against the viewport: clicking a frame at the bottom of a tall page scrolls the page, and every viewport
coordinate moves with it while the thing being measured has not moved at all.

`type` clicks the box, waits until `document.activeElement` **is** that box, and repeats Ctrl+A + Backspace until
the field is empty before inserting the text. A click focuses on mousedown, but the renderer can still be busy when
the first key arrives — on a page that re-reads the plan in the background it sometimes was, so nothing was selected,
nothing was deleted, and the text was appended to what was already there ("+5:00" + "+0:10"). The app then refused
the *format* instead of the edit, and a check waiting for the refusal never saw it. Keys are not proof that they
landed; the field is.

A real Ctrl+C or Ctrl+V through `press()` wedges the sandbox's headless browser: the browser's copy command
reaches for the OS clipboard and the renderer blocks, so every later CDP call times out. A check that needs a
keyboard shortcut sends a DOM `KeyboardEvent` to the focused element instead and asserts `defaultPrevented`
(`dev/checks/shortcuts.mjs`); trusted clicks and drags still prove the actions themselves. That trap is specific to
the clipboard commands: `dev/checks/step13-undo.mjs` presses a real Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z, which arrive
and do not hang anything, so undo is proved through the platform's own key delivery. Any Chromium works —
Chrome is picked up if installed, and `BROWSER` points at a binary elsewhere; Edge is only the one this machine
has.

Tabs of one browser share the origin's `localStorage`, and a seeded session lives there. A check that opens a
second tab **as a different person** therefore overwrites the token the first tab would use next: finish the
first person's work before seeding the second, and close the first tab, as `dev/checks/step16-schedule.mjs` does
(three identities, one after another) and `dev/checks/step17-fork.mjs` does twice (the member before the copy, the
planner, the member after it). Two tabs of the same person are unaffected — which is what
`dev/checks/step18-publish.mjs` needs: two tabs on one plan, so one planner can publish over the other, and what
`dev/checks/step19-realtime.mjs` needs: three tabs of one planner, one of which is never touched and has to hear the
other two. The second *planner* is a different person only in `dev/checks/step18-publish.sql`, where it is an
identity rather than a tab.

### Which migrations have been applied (`tools/migrate.mjs`)

The numbered files used to be pasted into the SQL Editor by hand and nothing recorded what the database had
seen. They are now applied through the Management API with a ledger in `ops.schema_migrations`:

```bash
npm run db:status          # pending, applied, and any file that changed after it was applied
npm run db:up              # apply what is pending, one transaction per file
node tools/migrate.mjs up --to 040 --dry
node tools/migrate.mjs adopt --to 038   # record hand-applied files without running them
```

The ledger is not reachable from the app: the schema is revoked from `anon` and `authenticated`, RLS is on
with no policy, and the only way in is a personal access token.

### A bench with a plan in it (`supabase/fixtures/plan_bench.sql`)

```bash
node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
```

One fixed event id, four groups, three participants and two planners, a no-go zone sitting exactly between
two positions 20 m apart, a deliberately invalid plan (a 200 m jump across two frame steps — which is over the
budget of 25 m a step, step 12 — and a 20 m walk straight through that zone, both ends outside it — decoration
until step 11 made the crossing an error of its own, and a red row on the board as soon as the plan is opened), a
deliberately valid one, a two-frame "Copy bench" (one frame states three groups, the next states one and
inherits the other two) for the copy/paste check, a two-frame "Twin gap" where the same stretch is broken
for two groups at once, for the fill check, and a four-frame "Push bench" at 0/60/120/180 — the strip the
chunk-shift check is about, with one note per frame and every step legal, so after a push any red dot is
caused by the push and nothing else. Its plan's T+0 is 18:00 and the event is stated to start at 18:45, so a check
that confuses "when the session started" with "when the plan's clock starts" has something to fail on.
Re-running the file rebuilds the event and touches nothing else.

A browser check that writes leaves the bench changed — `dev/checks/step4-copy-paste.mjs` pastes a frame into
"Copy bench", `step5-fill-gap.mjs` fills "Walkthrough" and "Twin gap", `step6-push-chunk.mjs` pushes "Push
bench" to 0/5/7/8, `step7-hold-group.mjs` holds a group on "Copy bench" (0/1/5), `step8-drag-together.mjs`
drags three groups on "Copy bench" (a 71 m hop), `step9-off-site.mjs` reads "Off-site twin" (and needs
`dev/checks/step9-off-site-prep.sql` first — it adds that sixth plan, Twin gap's coordinates with one group's
arrival flagged off site, and it is idempotent), `step10-flags.mjs` flags groups on "Flags bench" (and needs
`dev/checks/step10-verify-prep.sql` first — a seventh plan, three frames, the last one stating only Sound),
`step11-geometry.mjs` finds the crossing on "Walkthrough" while planning, then tries to publish it and is
refused (the refusal names "Stores (no-go)"), then deletes the frame the crossing ends on — the only write in
that check — to prove the board asks again after an edit, `step12-stretch.mjs` drags one badge 200 m on the
ten-frame "Stretch bench" (and needs `dev/checks/step12-stretch-prep.sql` first — an eighth plan, ten frames 15 s
apart, Gate Crew standing still for all of them and Sound 100 m east as the map's ruler), `step13-undo.mjs` drags a
badge 40 m on the four-frame "Undo bench" and then takes it back with Ctrl+Z, reloads, puts it back with Ctrl+Y,
pushes a pair past a frame that stays put and takes that back too, and ends by publishing (and needs
`dev/checks/step13-undo-prep.sql` first — a ninth plan, four frames a minute apart with Gate Crew standing still and
Sound 100 m east), `step15-staleness.mjs` publishes "Clean walk" again after adding a frame, then deletes the frame,
publishes the four-frame shape again and ends the event (it counts frames, so it refuses to start unless that plan
is the fixture's four), `step16-schedule.mjs` works on an event of its own (see below) and ends it,
`step17-fork.mjs` works on another event of its own and republishes a copy of its plan, `step18-publish.mjs`
works on a third one and publishes the same copy from two tabs, `step19-realtime.mjs` works on a fourth and
edits one plan from three tabs, `step20-ops.mjs` works on a fifth and lets the clock be the thing that changes it,
`step21-ops.mjs` works on a sixth, where the deployed 5 s tick closes one group's moment while the page watches and a
person closes the other's, `step22-play.mjs` works on a seventh, where the strip plays the plan's run and one group
is told its times changed while the other is not, and `step23-csv.mjs` works on an eighth, where a plan is exported,
thrown away and imported back from the file the browser wrote, and a sheet with a 100 m step is refused in the strip's
own words (see below). Rebuild the
bench before a check that expects the fixture's own state; each check says so in its header and refuses to start
otherwise.

Most SQL checks build everything they need inside a transaction that rolls back, so the bench is untouched by them.
`dev/checks/step14-actuals.sql` creates an "Actuals bench" plan, publishes it, starts a session on it with its
clock 50 minutes after the plan's T+0, records an arrival and a miss, and rolls the lot back. Actuals have no screen
of their own, so that file is the whole proof of the record: what a row is, what lateness is measured from, and who
may write one. `dev/checks/step15-timetable.sql` builds a "Timetable bench", starts a session on it with T+0 ten
minutes ago, and asks the one read the timetable screen uses — proving that the plan's printed date and time can be
moved under a running session without moving the read, that publishing moves the revision the session follows, and
that the read is scoped to the caller's own group. `dev/checks/step16-schedule.sql` does the same for the member's
schedule: five moments carrying all five words, the plan's frames and the other group's outcomes closed to the
member and still open to ops staff, an outsider refused, and `anon` shut out of the tables as well as the functions.
`dev/checks/step17-fork.sql` builds a "Fork bench" plan, publishes it, starts a session seven minutes into its walk
and **copies it mid-walk**: the copy's first frame is the cut and holds every group's *interpolated* position there
(strictly between two dots, checked against arithmetic), the frames before it are not in the copy, every write that
would put one back is refused through six doors, publishing carries the session onto the copy with the same clock
and an arrival at the cut, the original keeps its own walk, and a second publish rewrites no record. Its plan ids are
`…b71`/`…b72` on purpose: a uuid is global, so a bench may not reuse another bench's plan id (finding 54).
`dev/checks/step18-publish.sql` publishes the same plan from two planners: a missing revision and a stale one are
refused without touching the plan or writing a version, the revision the caller holds publishes, and every publish
leaves a `plan_versions` row — the frames and positions as JSON, ordered, with the plan's name and printed T+0 — that
editing the plan afterwards cannot change. It also proves the read rule (ops staff only), the missing write grants,
the one-read-policy shape of the table, and that deleting a plan takes its versions while only nulling the link on a
copy's version. `dev/checks/step19-realtime.sql` proves the realtime channel: `plans` is in the `supabase_realtime`
publication with its three operations and `replica identity full`, the plan content tables are deliberately not
published, and every write to a plan — frame create, note, move, shift, hold, fill, verify patch, rename, delete —
touches the plan row, while the same verify flag written twice does not. It is the change log the subscription is
built on, so it is asserted as one. `dev/checks/step20-ops.sql` proves the ops read: one row per group per moment with
`pending`/`active`/`done` flipping at the frame and one second either side of it, the strip's travel time (60 s where
lateness would say 30, 3420 s across an hour, 120 s for a group whose two statements are the same place), the
accuracy-weighted midpoint of two ICs 20 m apart (1.18 m from the accurate one, 18.8 m when the accuracies are
swapped, `group_positions` answering the same numbers), the 040 scope, and no distance for an off-site group.
`dev/checks/step21-push-handover.sql` builds its own event (four groups, three zones, a session) and proves the other
half of the night: an `auto` moment closes itself when an IC of its group is inside a zone containing its drawn point —
dated from the plan when the IC was already there and from the IC's entry when it walked in late — while a `manual` one,
an off-site one, and one whose point is outside every zone do not; the 5 s tick still collects No-Go pushes and nudges
once per moment and person; the forecast queues leave-now and running-behind from the database's own metres and the
group's measured speed, and nothing at all for a group with no fix or one standing at its next moment; and the hand-back
chain reads who had the board off the previous row, copies the session's revision on, refuses a plain member and an ended
show, and leaves the table unwritable to `authenticated`. `dev/checks/step22-log-targeting.sql` builds its own event (four
groups, a plan, a session, four publishes) and proves the plan's log: a message writes one `plan_log` row, its recipients
and one push each, and **zero** `show_log` rows; "every group" reaches the members of the groups the plan places and
nobody else; "ops" reaches the root; a member sees only their own rows, the tally is hidden from them, one tap acks it and
a second tap cannot move the instant; a group the plan never places cannot be messaged; a republish that changes nothing
writes no row and queues no push; moving one group's point writes one `timeline` row addressed to that group alone;
moving a **frame's time** names the groups the move carries as well as the one that states it; and a copy's first publish
compares against the plan it was cut from, from the cut onward, so editing one group on the copy tells that group and not
the others. `dev/checks/step23-import.sql` builds its own event, two groups, a plan at revision 7 and a session, and
proves the sheet's other half: one call replaces every moment, note, place and both flags (an omitted flag takes its
default, a moment nobody stands at survives, every old frame id is gone, the revision stays 7 and `updated_at` moves);
seven refusals — two frames at one time, a time that is not one, positions that are not a map, a group from another
event, a state word that is not a state, a sheet that is not a list, a plan that is not there — each leave the plan
exactly as it was, two of them failing *after* the delete; a planner may import but a participant, a stranger and
`anon` may not; a sheet with a 100 m step imports and `plan_check` then reports it, because that refusal is the
client's; and once a session has marked one arrival, an import is refused with the count and the instruction to copy,
the moments untouched and the mark surviving.

The member's schedule has a bench of its own, because a timetable is judged against the real clock and the plan
bench's T+0 is often still ahead. `dev/checks/step16-schedule-prep.sql` rebuilds one event, one live plan whose T+0
is fifteen minutes in the past, and a session whose five moments carry arrived, not required, late, missed and
pending — then `dev/checks/step16-schedule.mjs` reads them as a plain member (the planner's board, then the member's
schedule, then a marshal's timetable). Three sessions are needed: `.tmp/session.json` (testuser1),
`.tmp/session3.json` (testuser3, Sound) and `.tmp/session5.json` (testuser5, marshal); the check names the mint
command if one is missing, and the prep file if the bench is stale.

A copy taken mid-walk has a bench of its own too, for the same reason: it is about a clock that is already running.
`dev/checks/step17-fork-prep.sql` rebuilds one event, one live plan whose T+0 is ninety seconds in the past and a
session on it, and `dev/checks/step17-fork.mjs` reads the member's schedule, copies the plan from the planner's board
(the copy starts at the cut, with a ring on its first dot and its time field disabled), edits a moment ahead of the
cut, publishes, is refused an edit before it, and reopens the member's page to the copy's timetable — starting at
the cut, the first moment *arrived* rather than late. Two sessions are needed: `.tmp/session.json` (testuser1) and
`.tmp/session3.json` (testuser3, Sound).

Publishing has a bench of its own as well, because the case it is about is two tabs on one plan.
`dev/checks/step18-publish-prep.sql` rebuilds one event, one live plan whose T+0 is ninety seconds in the past and a
session on it, and `dev/checks/step18-publish.mjs` copies the plan in one tab, publishes the copy from a second tab
(a draft is opened for nobody, so tab B picks it from the plan list), and then tries to publish the same copy from
the first tab, which is still holding revision 1: the strip has already warned, the database refuses with HTTP 409
naming both revisions, the page re-reads itself so the button becomes "Publish again", and the second press publishes
revision 3 with the other tab's label intact. One session is needed: `.tmp/session.json` (testuser1). (Since step 19
the label may already be on the first tab before the refusal — content travels live and a publish is the moment the
board stops adopting it — so the check measures the revision it is holding, which is the claim that has to hold.)

Live changes have a bench too, because the case is about three tabs and one of them must never be touched.
`dev/checks/step19-realtime-prep.sql` rebuilds one event, one live plan whose T+0 is two minutes in the past and a
session on it, and `dev/checks/step19-realtime.mjs` opens it in tab A and leaves tab A alone: a second tab renames
the call moment's note and tab A's field says the new words, the same tab adds a frame and tab A's bar counts one
more, then it publishes and tab A's strip says the version moved while its picture stays — and a tab opened for the
deletion deletes the plan, which empties tab A's board. It is the one check that proves a change arrived *without a
reload*: the board has no timer, so nothing but the channel could have told it. One session is needed:
`.tmp/session.json` (testuser1).

The ops board has a bench too, because what it proves is a clock passing a frame. `dev/checks/step20-ops-prep.sql`
rebuilds one event two seconds into its walk — three groups, one walking, one waiting to start, one not due for two
minutes, and two ICs of the walking group 20 m apart (one 5 m accurate on the walk's own point, one 20 m accurate and
20 m north) — and `dev/checks/step20-ops.mjs` opens the Live page: Gate Crew is under way on its +0:00 moment with a
45 s leg and "1 m from the walk · 2 ICs", Sound waits for +0:45 and Backstage for +1:45, and then, with nothing
clicked, the clock passes +0:45 and the board says Sound is under way on +0:45 with a minute of travel, Gate Crew is
done on its last moment and the header has moved to one under way, one not started and one done. Waiting for that flip
is waiting for the plan's own clock: the screen wakes at the moment the read gave it (and polls every five seconds for
the midpoint, which moves with the readings). One session is needed: `.tmp/session.json` (testuser1).

Arrival marking has a bench of its own, and its check is the only one that waits for the **server** rather than for the
screen. `dev/checks/step21-ops-prep.sql` rebuilds one event whose plan is 40 seconds into its walk, so the +1:00 moment
is twenty seconds away: Gate Crew's position is `auto` and its IC is already inside the zone that moment's point stands
in, Sound's is `manual` and its IC is inside its zone too. `dev/checks/step21-ops.mjs` opens the Live page and finds
both groups unrecorded, offering *Arrived* / *Missed*; then, with nothing clicked on Gate Crew, the deployed
`gps-plan-push` job (every 5 s) closes its moment and the chip reads "Arrived 6:30 pm · the phone was there". Sound's
manual moment is still open, the check presses *Arrived* and the chip reads "· by hand", and the board — which said
nobody held it — records "Board with testuser1 since 6:30 pm" on one press. A reload proves both marks and the hand-back
are in the database and not on the screen. One session is needed: `.tmp/session.json` (testuser1). Run the prep
immediately before the check: the twenty seconds are the point, and a page opened after the moment has passed cannot
watch it close.

Playing the run, and the log that tells one group and not the other, have a bench of their own because both are about a
clock that is moving and a record that is this check's. `dev/checks/step22-play-prep.sql` rebuilds one event, one live plan
three moments long whose T+0 is thirty seconds in the past, a session on it, and one **published change** that moved Gate
Crew's last moment and left Sound's walk alone — so the log already holds a timeline row addressed to Gate Crew's two
people and nobody else. `dev/checks/step22-play.mjs` then opens the planner's strip and plays the run: the clock goes from
near +0:00 to the end at 60×, the cursor and the badge move, the run stops itself at +2:00 and Stop reopens that moment.
On the Live page the planner sees the publish's own row, sends one message to every group ("0 of 3 got it · waiting on
Gate Crew, Sound"), and then the Gate Crew IC's schedule shows **both** rows while the Sound admin's shows **only** the
message; each presses Got it once, and a fresh planner tab reads "2 of 3 · waiting on Gate Crew". Three sessions are
needed: `.tmp/session.json` (testuser1), `.tmp/session4.json` (testuser4, Gate Crew IC) and `.tmp/session3.json`
(testuser3, Sound). The check opens each identity's tab only while it is the newest one: the harness shares one browser
profile, so a tab that reads again after another identity is seeded can answer as the newest person (finding 86).

The plan as a spreadsheet has a bench of its own, because what it proves is a file on disk and a board reading it.
`dev/checks/step23-sheet-prep.sql` rebuilds one event with two plans: "Sheet bench" (four moments — a note with a comma
and quotation marks, a group carried through a moment that does not state it, an off-site position confirmed by hand, a
13-decimal latitude, and a moment nobody stands at) and "Sheet gap" (two moments with Sound 100 m from where it stood a
minute earlier). `dev/checks/step23-csv.mjs` then clicks **Export CSV** and reads the file **the browser wrote** into
`.tmp/step23-downloads` — a BOM, a `#` title, seven columns, six rows, the note quoted the CSV way — deletes the plan,
makes a new empty one with the same name, and hands the file to the board's hidden input the way the picker would
(`DOM.setFileInputFiles`). The confirmation's counts are the file's, the import reports what went in, and the second
export is the first file **byte for byte**. On "Sheet gap" the strip says `Sound: 100 m between +0:00 and +1:00
(limit 25 m)`, importing its untouched sheet is refused with **that same sentence** as the dialog's list line (nothing
is written: the frame ids are unchanged), and the same sheet with the one longitude typed over imports — the warning
goes out and the export carries the written number. One session is needed: `.tmp/session.json` (testuser1). The format
itself has a test with no browser in it: `npm run test:sheet` (58 assertions — quoting, a note with a newline, a
semicolon-separated file from a comma-decimal Excel, "Off-Site" read as off_site, the times a planner types, the
refusals with their row numbers, and the 25 m sentence).

Retiring the last callers has a check with no fixture at all, because what it proves is the **catalogue**.
`dev/checks/step24-retire.sql` builds a simulation event, five virtual groups (one per behaviour), a plan with four
moments and a running simulation inside one transaction, and rolls the lot back — then asks the catalogue what is
left: `start_event(event, plan)` exists and the three-argument one does not, no function anywhere has a parameter
called `p_run_sheet`, no body in `public` names `show_tick`/`move_tick`/`zz_walk_tick`/`sim_plan_movements`, and
`cron.job` holds exactly **seven** jobs, **each asserted by name, schedule, command and the age of its last
successful run** (five minutes for the tick jobs, three quarters of an hour for the quarter-hour one, two days for
the daily one — "all jobs succeeded recently" is the assertion finding 7 warned would fail on the hourly ones).
Before that it proves the simulator walks the strip: `sim_follow_plan` aims a group at its own next on-site moment,
times the departure to arrive a minute early (`late_2min` two minutes later), halves the leg for `stops_halfway` and
then leaves it stopped, opens a 2.5-minute silent window for `loses_signal`, does not touch `wrong_zone` — and the
plan has **no zones at all**, so a leg pointing at a plan point cannot be the old movement-to-zone walk. Then the
next moment takes over, a moment that repeats a position is not a new leg, a session with no plan is left alone, and
one `sim_tick()` re-aims a group before it steps it. `sim_start` refuses with no groups, refuses with no published
plan, and starts the event **on** the published plan otherwise. `dev/checks/step2-session-plan.sql` was rewritten in
the same step: its "both at once is refused" case is now "the run-sheet door is gone" (no three-argument function, and
a run-sheet id handed in as the plan is refused because it is not one), its tracking-only case proves a session with
no clock and no sheet, and its positive control (the old ticks still drive a run-sheet session) is replaced by the
absence of those ticks and by `push_collect_moves` still finding nothing to say about a plan. The client's half is
two screens: the Start dialog offers plans and nothing else (`dev/checks/step2-start-on-a-plan.mjs`, 12 assertions,
including that the dialog's copy no longer mentions a run sheet), and the Simulator panel loses its "Plan their
movements" card and says which plan the virtual groups walk.

Deleting the stack is `061_drop_run_sheet_stack.sql`, and its own proof is a **guard inside the migration** rather than
a check afterwards, because the failure it exists to prevent is a `drop table` that succeeds against a plpgsql body
that still reads the table. The migration first fills a list of what it removes (from the catalogue, not the plan:
ten tables, sixty-two functions, a trigger, and two columns on tables that survive), then refuses to run if any object
outside that list depends on anything inside it (`pg_depend`, walked through indexes and row types and then one step
along normal dependencies, so a foreign key, a view, a trigger or a function's return type is caught), if any surviving
body or `cron.job` command names any of it (the half `pg_depend` cannot see at all), or if the list is not
seventy-five objects long. Then it drops — without `CASCADE` anywhere, which would "succeed" by removing whatever was
in the way — and re-runs the same walk as a post-check, by oid, plus the seven-job cron inventory and a sweep that
every remaining table still has RLS on. Three surviving functions were rewritten rather than dropped:
`start_event`/`schedule_event_start` (they set the dropped column to null) and `broadcast_send` (it wrote a `show_log`
line when a show was running). `dev/checks/step25-drop.sql` then proves the outcome: the inventory is absent by name,
no body or job names it, the survivors still answer (a tracking-only start, a dry-run message, `plan_frames_list`), the
cron list is still the seven of step 24, and every table still has RLS. **Five bites**: a foreign key from `events` to
`run_sheets`, a view over `cues`, a function that reads `movements`, a cron job running `move_step`, and the file
applied twice — each refused with the offending object named. `dev/checks/step25-gone.mjs` is the screen half: ten
assertions over four tabs, every one of them about something that must not come back (the Timeline mentions no run sheet
and shows the plan board; the Live page has no show bar, no ops queue, no cluster hint or toggle; Playback has no "Ran
with" line; the Zones card counts no movements), each paired with the thing that is there instead (the map, `plan_ops`
with all three of step 20's groups on it, the recording, the zones). The client half went in the same change: the
Run sheet tab and its editor, the Excel import, the cue/movement editor, the show bar and panel, the ops queue, the
member's next-move card, the group-message banner, the workbook (`runSheetFile.js` and `npm run test:runsheet`), the
`route-eta` Edge Function and the six legacy PGlite suites that tested the dropped functions; the map lost its ops
clusters, the Playback tab lost its "Ran with" line, and the Zones card lost its per-zone movement count.

A timetable row now says **where** the moment is. A moment is a point: inside a zone it is a *place* ("be at Main
Gate by 7:40"), outside every zone it is only the route, and nothing is refused for standing in open ground.
`session_timetable` gained a trailing `place` column — the name of the zone the moment's own drawn point stands in —
by being dropped and re-created (the return type changed, so `create or replace` cannot do it), with 057's body and
its deleted-plan guard kept. The lookup is 057's own rule (stage, then an entrance, then any other, then the name),
copied rather than reinvented, with two exclusions: a **no-go area** and an obstacle are zones but never places, and
an **off-site** moment is not a place either. A frame that only carries a group forward has no point, so it has no
place. The schedule prints it between the state word and the detail, so a row reads `7:40 · due · Main Gate`.
`dev/checks/step26-place.sql` proves the column at the database (twelve assertions, including that the route point
really stands in no zone and that the stage point really stands in two zones before the tie-break is asked), and its
two bites are recorded in the plan document; `dev/checks/step26-place.mjs` proves it on the screen for a member and a
marshal, and asserts the page still makes no request for the plan's frames. `dev/checks/step16-schedule-prep.sql`
gained three zones so the fixture has somewhere for a moment to be. Screenshots: `shots/step26-member-place.png`,
`shots/step26-marshal-place.png`.

A moment also closes itself when the IC's **phone is close enough**, not only when it is inside the polygon the point
was drawn in. The radius is the IC's own: `group_members.ic_tolerance_m` (5–100 m, default 30) lives on the membership
row — one number per person per event, no new table, and 002's read policy already covers it. `group_members` has no
write policy, so the only writer is `set_arrival_tolerance(p_event, p_metres, p_user default null)`, a security-definer
function with the same three doors `progress_mark` uses (the person themself, root/planner, the group's own admin); it
refuses anybody who is not an IC, because only an IC shares a phone. `plan_auto_close` was re-created from 057's body
with two changes: the moment's point must still stand in a place (a route point never closes itself, and a cordon is
not a place — the same kinds step 26 calls one), and the evidence is now "an IC inside a zone containing the point **or**
within that IC's own radius of it", using the live map's own rules from 021 (a reading no older than two minutes, none
worse than 100 m, widened by `min(accuracy, 15)`), with the window also bounded by the session's `t0_at` because
`locations` carries no session id. The earliest evidence dates the arrival and `marked_at` is still `greatest(planned,
first)`. The IC sets the number on **My GPS details**; the planner sets it on the event's **People** page, where only
ICs get the box. `dev/checks/step27-tolerance.sql` proves it at the database (41 assertions, four recorded bites:
per-IC numbers, the session-start bound, the kind filter on the place gate, and 057's zone branch) and
`dev/checks/step27-radius.mjs` proves it on the screen (17 assertions over three tabs: the IC's own card saving and
surviving a reload, a 4 m refusal in the server's own words, the planner's list, and a group admin with no card at
all). Screenshots: `shots/step27-ic-radius.png`, `shots/step27-ic-refused.png`, `shots/step27-planner-radius.png`.

A mark also belongs to the person who made it, and the IC can make one from their own timetable. `PlanSchedule` gives
the group's IC a **We're here** press on the moment the clock is on — and only that moment: the ones ahead have not
happened and the off-site ones have nothing to arrive at. Pressing calls `progress_mark` and re-reads, so the row the
database reports is the one shown. `progress_mark` was re-created from 050's body with one guard: a mark made by one
person is not replaced by another IC or the group's admin — the refusal names who marked it and when — while the
maker may correct their own, the event's ops may correct anything, and the tick's automatic close may be corrected by
any hand. `plan_progress` gained `marked_auto` so "the phone was there" is a fact about the writer rather than a
missing name (deleting a profile used to turn a person's mark into the tick's), and `plan_ops` answers it, so the ops
board says **by hand** for a press and **the phone was there** for the tick. The same pass fixed two screen bugs the
audit found: the ops board's five-second poll wiped a refused write's sentence before anyone could read it (a write's
error is sticky now, on both screens), and a refused mark left the stale row's buttons in place (the board re-reads
after a refusal). `dev/checks/step28-mark-guard.sql` proves the door (32 assertions, four recorded bites: no guard, a
null name treated as the tick, no ops bypass, the tick not flagged), `dev/checks/step28-here.mjs` proves the press on
the screen (23 assertions over four tabs: one press, the write, a reload, the group's second IC, and the two writers
side by side on the ops board). Screenshots: `shots/step28-here.png`, `shots/step28-arrived.png`,
`shots/step28-ops.png`.

A follower also has a map of their own walk now. The Map tab is `PlanRoute` for everyone the plan board is not for (a
member, an IC, a group admin, a marshal); root and planner keep the zone editor there. It draws the venue's zones from
`event_zones` with the Live map's own colours, then one dashed line per group in the group's colour through the moments
that group **stated** — an off-site moment breaks the line rather than being drawn through, and a carried frame does not
break it — a dot on each of those moments labelled with its clock time and its place, the moment the clock is on ringed,
the next one flagged, and a card over the map ("Next 7:40 pm · Main Gate · in 12 min") that centres on the moment it
names. Nothing here is live position (that stays on the Live page) and nothing here is routing: the line is the plan.
`session_timetable` gained trailing `lat` and `lng` — the moment's own drawn point, dropped and re-created because the
return type changed, with 062's body kept — so the map reads the call the schedule already polls rather than a second
door, and the coordinates are null exactly where 062's join finds no point (a carried frame, an off-site moment); a route
point in open ground has a point and no place. The schedule's place is now a **link** to the map on that moment
(`/events/:id/map?t=300`), so the timetable stays a list and step 16's "this page asks for nothing but the timetable"
still holds. `dev/checks/step29-route.sql` proves the read at the database (32 assertions, three recorded bites: the
engine's scope, the carried point, the off-site point), `dev/checks/step29-route.mjs` proves the screen (51 assertions
over seven tabs: Gate Crew's member, the schedule's link and the same address opened cold, Sound's member, two events
with nothing to draw — never started, and running without a plan — and the planner's board of the same walk for
comparison). Screenshots: `shots/step29-route-gate.png`, `shots/step29-route-sound.png`,
`shots/step29-schedule-link.png`, `shots/step29-route-empty.png`, `shots/step29-board.png`.

### Checking the schema without a database (`npm run test:db`)

The bench's rules are decided in SQL, and until round 4 the only way to find out whether a migration was
even valid was to paste it into the Supabase SQL Editor against the real project. `npm run test:db`
applies every file in `supabase/migrations/` **in order** to a Postgres that starts empty and is thrown
away — PGlite, which is Postgres compiled to WebAssembly, running in this process — and then runs the
bench's own SQL suites:

- `supabase/tests/objects_rls.sql` — the rules 017 added: what a shape may be, who may write one, what a
  refused write hands back, the patch that merges, the 4 MB cap and what a refused write leaves behind;
- `supabase/tests/layouts_rls.sql` — the suites for 005 and 014–016, run against the schema they were written
  for;
- plus the migrations themselves, which is where the guards are checked: an empty database; a bench that
  already holds a canvas (the split is checked shape by shape, re-running 017 must change nothing, and
  then 018 drops the frozen document leaving the home view and every row); a canvas the split must
  REFUSE rather than lose a shape to; and a bench whose rows do not account for a shape in the document,
  which the drop must refuse rather than tidy away.

What it cannot cover is Supabase's own parts — the roles, the `auth` schema and the Realtime publication
are stubbed by `supabase/tests/stub_supabase.sql` — so it checks the schema and the rules, and the
browser harness above checks what a page does with them. Both suites are also still runnable in the SQL
Editor, in one transaction that rolls back.

### Supabase (one-time, for a new project)

1. SQL Editor → run every file in `supabase/migrations/` **in order** (001, 002, ...).
2. Authentication → Sign In / Providers → Email: **turn off "Confirm email"** (Supabase's built-in
   email only reaches members of your Supabase organisation, so classmates would never get it).
   Turn **off** "Allow anonymous sign-ins" (no longer used).
3. (Only if you add password reset, email confirmation or social login) Authentication → URL Configuration:
   set Site URL / Redirect URLs to the Vercel link, so email links don't point to localhost.
4. Place names (OneMap reverse geocode): create a free account at
   <https://www.onemap.gov.sg/apidocs/register>, then Edge Functions → Secrets: add `ONEMAP_EMAIL` and
   `ONEMAP_PASSWORD`, and deploy `supabase/functions/reverse-geocode`
   (`npx supabase functions deploy reverse-geocode`). Without it the map shows "Place name unavailable".
5. Put the project URL and **public** key in `.env`. Never use the secret / service-role key in the app.

### Test accounts

| Email | Password | Username | Role in "Test Event" |
|---|---|---|---|
| _(fill in after creating them)_ | | | Root |
| claude.playback.test@example.com | Pb-Test-48217q! | claude_test | Root of "Playback test (Claude)" - throwaway account used to test Start/End + playback |

## Testing with several users

1. Each test user needs their **own browser profile or incognito window** (one browser = one login).
2. User A: **Events → Create an event** → Members tab → create a group → put yourself in it → turn on **IC**.
3. Invite tab: share the code / link / QR (WhatsApp, Telegram). User B signs up, then joins with the code.
4. User A adds User B to the group (or adds them by username straight into a group).
5. User A: **Share my location → Start sharing** on their own device and allow location.
   User B's **Live map** shows A's initials; hover (or tap) for name, place name, coordinates and last seen.

### Real devices

- **Laptop:** `npm run dev`, open `http://localhost:5173` (localhost counts as secure, so the browser
  uses the laptop's real location, found from Wi-Fi: about 20-100 m).
- **Phone:** install the native app (see "Phone app" below). It uses the phone's real GPS and keeps
  tracking when the screen is locked.

## Phone app (background GPS)

The same Vue app is wrapped as an Android/iOS app with [Capacitor](https://capacitorjs.com) and uses
[Transistorsoft Background Geolocation](https://docs.transistorsoft.com/capacitor/) so tracking keeps
working when the phone is locked. The browser version still works without it.
All GPS logic is in `src/composables/useLocationTracker.js`.

- **Android** (needs Android Studio): `npm run cap:android`, then press Run with your phone plugged in
  (USB debugging on). Allow location "All the time".
- **iOS** (needs a Mac + Xcode): `npm run cap:sync`, then `npx cap open ios`, choose your Apple ID team
  under Signing & Capabilities, and run on your iPhone. Allow location "Always".
- After changing Vue code, run `npm run cap:sync` again before rebuilding the app.
- Transistorsoft is free in **debug** builds (what we use for testing and the demo); release builds
  need a paid licence key.

## Deploying (Vercel)

Import the repo in Vercel, framework preset **Vite**, and add the same `VITE_*` variables from `.env`
under Project Settings → Environment Variables. `vercel.json` sends every route to `index.html` so
refreshing `/gps` works.

## Credits

- [Vue](https://vuejs.org) (MIT), [Vue Router](https://router.vuejs.org) (MIT), [Vite](https://vite.dev) (MIT)
- [Bootstrap](https://getbootstrap.com) (MIT)
- [Leaflet](https://leafletjs.com) (BSD-2-Clause)
- [OneMap](https://www.onemap.gov.sg) basemap tiles © Singapore Land Authority
- [supabase-js](https://github.com/supabase/supabase-js) (MIT)
- [Pinia](https://pinia.vuejs.org) (MIT)
- [qrcode](https://github.com/soldair/node-qrcode) (MIT)
- [OneMap API](https://www.onemap.gov.sg/apidocs/) - reverse geocoding (place names)
- [Capacitor](https://capacitorjs.com) (MIT)
- [Transistorsoft Background Geolocation](https://docs.transistorsoft.com/capacitor/) (free for debug builds)
