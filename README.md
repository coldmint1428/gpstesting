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
  `supabase/migrations/006_floor_plan_bounds.sql`.
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
document used to take. See `supabase/migrations/009_object_rows.sql`.

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
`supabase/migrations/007_presence_and_views.sql`.

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
`supabase/migrations/006_floor_plan_bounds.sql`).

**The old whole-canvas column is gone.** `009_object_rows.sql` left it frozen in the bench's own row —
3.7 MB that every read of the bench detoasted to get at the 200 bytes beside it — and
`010_drop_frozen_canvas.sql` drops it, after moving the one thing still living inside it into a column of
its own: the bench's **home view**, where a planner who has never panned opens the map (see
`007_presence_and_views.sql`, which moved a planner's camera into a row of its own). The drop refuses to
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

### Checking the schema without a database (`npm run test:db`)

The bench's rules are decided in SQL, and until round 4 the only way to find out whether a migration was
even valid was to paste it into the Supabase SQL Editor against the real project. `npm run test:db`
applies every file in `supabase/migrations/` **in order** to a Postgres that starts empty and is thrown
away — PGlite, which is Postgres compiled to WebAssembly, running in this process — and then runs the
bench's own SQL suites:

- `supabase/tests/objects_rls.sql` — the rules 009 added: what a shape may be, who may write one, what a
  refused write hands back, the patch that merges, the 4 MB cap and what a refused write leaves behind;
- `supabase/tests/layouts_rls.sql` — the suites for 005–008, run against the schema they were written
  for;
- plus the migrations themselves, which is where the guards are checked: an empty database; a bench that
  already holds a canvas (the split is checked shape by shape, re-running 009 must change nothing, and
  then 010 drops the frozen document leaving the home view and every row); a canvas the split must
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
