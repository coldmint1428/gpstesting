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
| Polygon test | `/polygon` | teammate |

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
3. Authentication → URL Configuration: add `http://localhost:5173` (and the Vercel link later).
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
