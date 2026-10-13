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

One thing is worked on at a time (`null | 'floorplan:<id>' | 'polygons' | 'area:<id>'`), and
putting it down is what saves — there is no Save button. **The map is never locked**: it pans
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
- **Undo and redo cover the whole canvas**, as arrow buttons next to Start / Stop editing (and
  Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y). Client-side only. Copy and paste a floor plan or an area
  with Ctrl+C / Ctrl+V.
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

The save itself **merges**. `save_bench()` walks the document object by object: what the planner
holds a lock on is taken from them, everything else keeps the stored version and is named in the
reply (so the page re-reads and says what happened), and an object missing from their copy is only
treated as deleted if they hold its lock. A page with a stale copy of somebody else's work can
therefore neither overwrite it nor delete it — with or without a lock, and whether or not the other
planner has already finished. See `supabase/migrations/008_object_locks.sql`.

**Planners can see each other while all of that is going on.** Each open page keeps a row in
`public.layout_presence` — one row per tab, refreshed every 10 seconds and streamed over Realtime
— so the bench shows who else is here, and puts a planner's name on the shape they have open, in
their own colour, both on the map and in the list of areas. A second tab or a second browser of
the *same* account is listed as its own planner, labelled as another window, because that is the
case that used to be invisible. None of it is trusted: presence is a hint for the display, and
what a planner may actually change is decided by the locks and by the merge. The map view is each
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
planner's screen shows is what their *next* save sends. What decides who wins is still the lock, and
what the server actually stores is still the merge. See `src/composables/useBenchFrames.js` and
`src/utils/benchFrame.js`.

Two things a live frame deliberately does not do, both because it only ever patches a shape that is
already on the other screen: a shape that did not exist a moment ago does not appear live, and a
deleted shape does not vanish live. Both arrive with the next save, when the other planner's copy is
overruled and re-read.

The whole canvas — the map view, the floor plans (placement **and** the image itself,
base64) and the areas — lives in one row of `public.layouts`, capped at **4 MB** by
`save_bench()`. Every floor plan image is shrunk in the browser to under 512 KB before it goes
near the database, and a floor plan that would not fit inside Singapore is refused. See
`supabase/migrations/005_layouts.sql` and `006_floor_plan_bounds.sql`.

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
