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
