# gpstesting

Test sandbox for the IS216 G11 event coordination & live tracking app.
Vue 3 + Vite + Bootstrap 5 + Leaflet (OneMap tiles) + Supabase.

| Page | Route | Owner |
|---|---|---|
| Home | `/` | shared |
| GPS test | `/gps` | Komin |
| Polygon test | `/polygon` | teammate |

## Setup

```bash
npm install
cp .env.example .env   # then fill in your Supabase URL + anon key
npm run dev            # http://localhost:5173
```

The app runs without `.env`; the GPS page then just shows "Database: Off".

### Supabase (one-time)

1. Supabase → SQL Editor → run `supabase/migrations/001_locations.sql`.
2. Authentication → Sign In / Providers → enable **Allow anonymous sign-ins**
   (the sandbox signs each device in anonymously so RLS can check `user_id = auth.uid()`).
3. Put the project URL and **anon** key in `.env`. Never use the service-role key in the frontend.

## Testing GPS

- **Laptop:** `npm run dev`, open `/gps`, press **Start sharing**. Chrome DevTools → More tools →
  Sensors lets you fake a location.
- **Phone:** GPS needs https, so use the Vercel deployment link (`localhost` only counts as secure on
  the laptop itself).
- Check rows arriving in Supabase → Table Editor → `locations` (about one row every 5 s while sharing).

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
- [Capacitor](https://capacitorjs.com) (MIT)
- [Transistorsoft Background Geolocation](https://docs.transistorsoft.com/capacitor/) (free for debug builds)
