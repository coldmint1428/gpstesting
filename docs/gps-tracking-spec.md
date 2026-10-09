# GPS Tracking – Technical Specification

IS216 G11 · event coordination & live tracking · sandbox repo `gpstesting`
Status as of 2026-10-08. Source of truth for migrating into the team repo / new Supabase project **1:1**.

---

## 1. What it does

- Users sign up (email + password + username), create or join **events**, and are put into **groups**.
- Each group has one or more **ICs** (in-charge). Only ICs share GPS.
- Viewers see a **live map**: root / planners / marshals see every group; everyone else sees only their own group.
- **Browser:** shares while the page is open (`navigator.geolocation`).
- **Phone app (Capacitor + Transistorsoft):** shares in the background — locked, in another app, or swiped away from Recents.
- Phone uploads use a **tracking pass** (not the login token), so tracking runs for hours without the 1-hour login expiry.

```
 Phone app (IC) ──native HTTP every 30 s──►  rpc/report_location (pass)  ─┐
 Browser (IC)  ──supabase-js insert ≤ 5 s──►  table locations (RLS)      ─┤
                                                                          ▼
                                            Postgres  locations  ──Realtime──► Live map (viewers)
```

---

## 2. Stack (exact versions)

| Package | Version | Use |
|---|---|---|
| vue | 3.5.43 | UI (Composition API, `<script setup>`) |
| vue-router | 5.3.1 | routes + login guard |
| pinia | 4.0.3 | auth store |
| bootstrap | 5.3.8 | styling |
| leaflet | 1.9.4 | map (OneMap tiles) |
| @supabase/supabase-js | 2.117.2 | DB, auth, realtime, RPC, edge functions |
| qrcode | 1.5.4 | invite QR code |
| @capacitor/core / android / ios / cli | 8.5.2 | native app shell |
| @transistorsoft/capacitor-background-geolocation | 9.6.0 | background GPS (free in DEBUG builds; release needs paid licence) |
| vite / @vitejs/plugin-vue | 8.3.2 / 6.0.9 | build |

Scripts: `dev`, `build`, `preview`, `cap:sync` (= build + `npx cap sync`), `cap:android` (= build + sync android + open Android Studio).

Tooling: Android Studio **2025.2.1 (Otter) or newer** (Android Gradle Plugin 8.13.0). iOS needs a Mac + Xcode.

---

## 3. Environment variables (`.env`, never committed)

| Key | Example | Notes |
|---|---|---|
| `VITE_SUPABASE_URL` | `https://<ref>.supabase.co` | |
| `VITE_SUPABASE_ANON_KEY` | `sb_publishable_…` (or legacy anon JWT) | public key only – **never** the secret/service key |
| `VITE_PUBLIC_APP_URL` | `https://gpstesting.vercel.app` | base for invite links / QR; no trailing slash. Set in Vercel as type **Config** |

Vite reads `.env` only at start/build → restart `npm run dev`, redeploy Vercel, and re-run `npm run cap:sync` + reinstall the phone app after changes.

---

## 4. Supabase project setup (order matters)

1. **SQL** – run in order: `supabase/migrations/001_locations.sql` → `002_users_events_groups.sql` → `003_stop_sharing.sql` → `004_tracking_passes.sql`. (Verified: these 4 files reproduce the live gpstest schema exactly.)
2. **Auth → Sign In / Providers → Email:** Email provider **on**, **Confirm email OFF**, **Allow anonymous sign-ins OFF**.
3. **Edge Function** `reverse-geocode` (file `supabase/functions/reverse-geocode/index.ts`), **verify JWT = on**:
   `npx supabase functions deploy reverse-geocode`
4. **Edge Function secrets:** `ONEMAP_EMAIL`, `ONEMAP_PASSWORD` (free OneMap account).
5. **Auth → URL Configuration:** only needed if adding password reset / email confirmation / social login.

---

## 5. Database schema (schema `public`)

### 5.1 `profiles` – one per login account (auto-created by trigger)
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| id | uuid | no | – | PK, FK → `auth.users(id)` ON DELETE CASCADE |
| username | text | no | – | UNIQUE, `^[a-z0-9_]{3,20}$` |
| display_name | text | no | – | length 1–50 |
| created_at | timestamptz | no | `now()` | |

### 5.2 `events`
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| id | uuid | no | `gen_random_uuid()` | PK |
| name | text | no | – | length 1–80 |
| join_code | text | no | `generate_join_code()` | UNIQUE; 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` |
| created_by | uuid | no | – | FK → `profiles(id)` |
| created_at | timestamptz | no | `now()` | |

### 5.3 `event_roles` – event-level roles (one row per role)
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| event_id | uuid | no | – | FK → `events(id)` CASCADE |
| user_id | uuid | no | – | FK → `profiles(id)` CASCADE |
| role | text | no | – | `root` \| `planner` \| `marshal` \| `participant` |
| created_at | timestamptz | no | `now()` | |

PK `(event_id, user_id, role)` · unique index `event_roles_one_root (event_id) WHERE role='root'` · index `(user_id)`.

### 5.4 `groups`
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| id | uuid | no | `gen_random_uuid()` | PK |
| event_id | uuid | no | – | FK → `events(id)` CASCADE |
| name | text | no | – | length 1–50; UNIQUE `(event_id, name)` |
| colour | text | no | `'#0d6efd'` | `^#[0-9a-fA-F]{6}$` |
| created_at | timestamptz | no | `now()` | |

Extra UNIQUE `(id, event_id)` (target of the composite FK below).

### 5.5 `group_members` – group-level roles
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| group_id | uuid | no | – | |
| event_id | uuid | no | – | FK `(group_id, event_id)` → `groups(id, event_id)` CASCADE |
| user_id | uuid | no | – | FK → `profiles(id)` CASCADE |
| is_admin | boolean | no | `false` | group admin |
| is_ic | boolean | no | `false` | shares GPS for the group |
| created_at | timestamptz | no | `now()` | |

PK `(group_id, user_id)` · UNIQUE `(event_id, user_id)` (max one group per person per event).

### 5.6 `locations` – every GPS reading
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| id | bigint | no | identity (always) | PK |
| event_id | uuid | no | – | FK → `events(id)` CASCADE (`NOT VALID` – old sandbox rows kept) |
| group_id | uuid | no | – | FK → `groups(id)` CASCADE (`NOT VALID`) |
| user_id | uuid | no | `auth.uid()` | |
| lat | double precision | no | – | decimal degrees (SG ≈ 1.2–1.5) |
| lng | double precision | no | – | decimal degrees (SG ≈ 103.6–104.1) |
| accuracy | real | yes | – | metres |
| source | text | no | `'gps'` | `gps` \| `marshal` \| `stop` (`stop` = pressed Stop sharing) |
| recorded_at | timestamptz | no | `now()` | time on the phone when taken |

Indexes: `(event_id, recorded_at DESC)`, `(event_id, user_id, recorded_at DESC)`.
On a fresh project the FKs can be created normally (without `NOT VALID`).

### 5.7 `tracking_passes` – phone upload permission
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| token | uuid | no | `gen_random_uuid()` | PK – the secret the phone sends |
| user_id | uuid | no | – | FK → `profiles(id)` CASCADE |
| event_id | uuid | no | – | FK → `events(id)` CASCADE |
| group_id | uuid | no | – | FK → `groups(id)` CASCADE |
| created_at | timestamptz | no | `now()` | |
| expires_at | timestamptz | no | `now() + 24 h` | |
| revoked_at | timestamptz | yes | – | set on Stop / logout / new pass |

Index `(user_id)`. RLS on, **no policies** (only reachable through functions).

### 5.8 Trigger
`on_auth_user_created` AFTER INSERT ON `auth.users` → `handle_new_user()`: inserts `profiles(id, lower(username), display_name)` from sign-up metadata (`raw_user_meta_data.username`, `.display_name`); skips users without a username.

### 5.9 Realtime publication `supabase_realtime`
`locations`, `group_members`, `event_roles`.

---

## 6. Row Level Security

All 7 tables have RLS **enabled**. Policies (all `TO authenticated`):

| Table | Policy | Command | Rule |
|---|---|---|---|
| profiles | see own profile and people in my events | SELECT | `id = auth.uid() OR shares_event_with(id)` |
| profiles | edit own display name | UPDATE | `id = auth.uid()` (using + check) |
| events | members see their events | SELECT | `is_event_member(id)` |
| event_roles | members see event roles | SELECT | `is_event_member(event_id)` |
| groups | members see groups | SELECT | `is_event_member(event_id)` |
| group_members | members see group members | SELECT | `is_event_member(event_id)` |
| locations | ICs insert own group locations | INSERT | `user_id = auth.uid() AND is_ic_of(event_id, group_id)` |
| locations | see locations by role | SELECT | `has_event_role(event_id, ['root','planner','marshal']) OR group_id = my_group_id(event_id)` |

All other writes go through the functions in §7. Helper functions are `SECURITY DEFINER` + `SET search_path = ''` to avoid RLS recursion.

---

## 7. Database functions (RPC)

All `SECURITY DEFINER`, `SET search_path = ''`. `EXECUTE` revoked from `public`/`anon` unless listed.

### 7.1 Helpers (used by RLS; callable by `authenticated`)
| Function | Returns | Meaning |
|---|---|---|
| `has_event_role(p_event_id uuid, p_roles text[])` | boolean | caller has any of the roles in the event |
| `is_event_member(p_event_id uuid)` | boolean | caller has any role in the event |
| `my_group_id(p_event_id uuid)` | uuid | caller's group in the event |
| `is_group_admin(p_group_id uuid)` | boolean | caller is admin of the group |
| `is_ic_of(p_event_id uuid, p_group_id uuid)` | boolean | caller is IC of that group |
| `shares_event_with(p_user_id uuid)` | boolean | caller and user share an event |
| `generate_join_code()` | text | internal (no grants) |
| `handle_new_user()` | trigger | internal (no grants) |

### 7.2 Actions (called from the app)
| Function | Who | Returns | Behaviour |
|---|---|---|---|
| `username_available(p_username text)` | **anon**, authenticated | boolean | sign-up form check |
| `create_event(p_name text)` | authenticated | uuid | creates event (retries code clash); caller becomes **root** |
| `join_event(p_code text)` | authenticated | uuid | case-insensitive code; adds **participant**; error "No event with that code" |
| `create_group(p_event_id, p_name, p_colour)` | root/planner | uuid | colour defaults `#0d6efd` |
| `add_member_by_username(p_event_id, p_username, p_group_id uuid default null)` | root/planner, or admin of `p_group_id` | uuid | adds participant (+ group); checks group ∈ event |
| `assign_group(p_event_id, p_user_id, p_group_id)` | root/planner: any; group admin: add someone without a group to own group / remove from own group | void | `p_group_id = null` removes; resets admin/IC |
| `set_group_flags(p_group_id, p_user_id, p_is_admin, p_is_ic)` | root/planner: both; group admin: IC only | void | |
| `set_event_role(p_event_id, p_user_id, p_role, p_enabled)` | root only | void | role ∈ planner, marshal |
| `remove_member(p_event_id, p_user_id)` | root/planner, or self (leave) | void | root can't be removed |
| `latest_locations(p_event_id uuid)` | authenticated (**SECURITY INVOKER** → RLS applies) | table(user_id, group_id, lat, lng, accuracy, source, recorded_at) | newest row per user |

### 7.3 Tracking pass (phone app)
| Function | Who | Returns | Behaviour |
|---|---|---|---|
| `start_tracking_pass(p_event_id uuid, p_group_id uuid)` | authenticated IC | uuid (pass) | error 42501 if not IC; revokes caller's older passes for the event; new pass valid 24 h |
| `report_location(p_token uuid, p_lat double precision, p_lng double precision, p_accuracy real, p_recorded_at timestamptz)` | **anon**, authenticated | void → HTTP **204** | valid pass + still IC → inserts `locations` (user/event/group from the pass, `source='gps'`). Invalid/revoked/expired pass or no longer IC → `errcode 'PT403'` → **HTTP 403**. Bad coordinates → 22023 → 400 |
| `revoke_my_tracking_passes()` | authenticated | void | cancels all caller's active passes |
| `my_active_tracking_pass()` | authenticated | table(event_id, group_id) | newest active pass (app reopen) |

---

## 8. Roles

| Role | Scope | Stored in | Can |
|---|---|---|---|
| Root | event (exactly 1) | `event_roles` | everything; make planners/marshals; can't be removed |
| Planner | event | `event_roles` | create groups, add by username, assign groups, set admin/IC; sees all groups |
| Marshal | event | `event_roles` | sees all groups (manual marks = future, `source='marshal'`) |
| Participant ("User") | event | `event_roles` | sees own group |
| Group admin | group | `group_members.is_admin` | add/remove people in own group, set IC |
| IC | group | `group_members.is_ic` | **only role that can share GPS** |

---

## 9. GPS sharing flow

All logic in **`src/composables/useLocationTracker.js`** – one app-wide tracker (singleton). Pages never import the plugin.

### 9.1 Start (event page "Share my location", one tap)
1. `start(eventId, groupId)`; if already sharing another event/group → `stop()` first.
2. Remember `{eventId, groupId}` in `localStorage` key **`gps-sharing`**.
3. **Browser:** `watchPosition({ enableHighAccuracy: true, timeout: 15000, maximumAge: 0 })`; insert into `locations` via supabase-js at most **every 5 s**; RLS error `42501` → stop + message.
4. **Phone app:** `rpc('start_tracking_pass')` → pass → `bg.reset(nativeConfig(pass))` → `bg.start()` → **`bg.changePace(true)`** (start in moving mode) → check battery saver / battery optimisation.

### 9.2 While sharing
- Phone records natively and POSTs each reading to `rpc/report_location` (works with JS paused / app swiped away). No network → queued in the plugin's SQLite (max 3 days) and sent when back online.
- Navigating between pages does **not** stop sharing. Navbar shows "● Sharing location".
- Browser refresh/reopen: `resume()` restarts from `localStorage` if logged in.
- Phone app reopen: `resume()` → `bg.ready({ reset: false })` (once per launch) → if tracking: event from `localStorage`, else `my_active_tracking_pass()`; old-style config (not `/rpc/report_location`) → `clearNative()`.

### 9.3 Stop (button, leave event, or logout)
1. Phone: `bg.stop()` → `bg.sync()` (send queue while pass valid) → `bg.destroyLocations()`.
2. Insert one `locations` row with `source='stop'` at the last position (viewers see "Stopped sharing").
3. Phone: `rpc('revoke_my_tracking_passes')`.
4. Forget `localStorage['gps-sharing']`.
5. **Logout** runs stop() *before* `signOut()`, then `clearNative()` (stop, clear queue, empty upload URL/params).

### 9.4 Upload error handling (phone, `onHttp`)
| Status | Meaning | Action |
|---|---|---|
| 2xx (204) | saved | count + "Saving" |
| 400 | unreadable record | log, `destroyLocations()` (a bad record would block the queue forever) |
| 401 / 403 while sharing | pass invalid/expired or no longer IC | stop, clear queue, forget, message "Sharing stopped: your tracking pass is no longer valid…" |
| 401 / 403 after Stop | late queued upload | ignore |
| other | network/server | keep queued, retry |

---

## 10. Transistorsoft configuration (exact)

Applied with `bg.reset(config)` on every Start; `bg.ready({ reset: false })` once per app launch; listeners added once before `ready()`.

```js
{
  logger: { debug: false, logLevel: LogLevel.Info },          // debug:true = test sounds; Verbose prints tokens – don't
  geolocation: {
    desiredAccuracy: DesiredAccuracy.High,
    locationAuthorizationRequest: 'Always',
    pausesLocationUpdatesAutomatically: false,
    allowIdenticalLocations: true,
    // ANDROID: timer-based, every 30 s, moving or still
    distanceFilter: 0, locationUpdateInterval: 30000, fastestLocationUpdateInterval: 30000,
    // iOS instead: distanceFilter: 10   (+ 60 s heartbeat below)
  },
  activity: { disableStopDetection: true },                   // never go "stationary"
  app: {
    stopOnTerminate: false, startOnBoot: true,
    heartbeatInterval: 60,                                     // iOS: onHeartbeat → getCurrentPosition({samples:1, persist:true, timeout:30}); ignored on Android
    preventSuspend: true,                                      // iOS
    notification: { title: 'Event Tracker', text: 'Sharing your location with event planners' },
  },
  persistence: {
    locationTemplate: '{"p_lat":<%= latitude %>,"p_lng":<%= longitude %>,"p_accuracy":<%= accuracy %>,"p_recorded_at":"<%= timestamp %>"}',
    maxDaysToPersist: 3,
    disableProviderChangeRecord: true,                         // Android permission-change records broke uploads (400)
  },
  http: {                                                       // only when a pass exists
    url: SUPABASE_URL + '/rest/v1/rpc/report_location',
    method: 'POST', autoSync: true, rootProperty: '.',
    params: { p_token: '<pass uuid>' },
    headers: { apikey: '<public key>' },                       // no Authorization header
  },
}
```
Listeners: `onLocation` (UI), `onHttp` (§9.4), `onHeartbeat` (iOS only), `onPowerSaveChange` (warning).
Phone settings checks: `bg.isPowerSaveMode()` and Android `bg.deviceSettings.isIgnoringBatteryOptimizations()`; button → `showIgnoreBatteryOptimizations()` + `show()`.

---

## 11. Native project files

| File | Content |
|---|---|
| `capacitor.config.json` | `{ "appId": "sg.edu.smu.is216.g11", "appName": "Event Tracker", "webDir": "dist" }` |
| `android/variables.gradle` | add `playServicesLocationVersion = '21.3.0'`, `tslocationmanagerVersion = '4.6.+'` (minSdk 24, compile/target 36 from Capacitor) |
| `android/build.gradle` | AGP `8.13.0`, Gradle `8.14.3` (Capacitor default) |
| `android/app/src/main/AndroidManifest.xml` | commented-out `com.transistorsoft.locationmanager.license` meta-data (release builds only). All location / foreground-service / activity-recognition / boot / notification permissions are merged in by the plugin |
| `android/.gitignore` | `.idea/` added (Android Studio personal settings) |
| `ios/App/App/Info.plist` | `UIBackgroundModes`: location, fetch, processing · `BGTaskSchedulerPermittedIdentifiers`: `com.transistorsoft.fetch` · `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription` |

---

## 12. Live map (viewers)

Files: `components/LiveMap.vue`, `composables/useLiveLocations.js`, `utils/markerMotion.js`, `utils/groupPosition.js`, `utils/people.js`, `utils/onemap.js`, `composables/useReverseGeocode.js`.

| Topic | Rule |
|---|---|
| Data | first load `rpc('latest_locations')`; then Realtime `postgres_changes` INSERT on `locations` filtered `event_id=eq.<id>`; reload on (re)subscribe; ignore readings older than the one shown |
| Channel names | must be unique per page (`'event-locations-' + id + '-' + random`) – Supabase reuses same-name channels and throws |
| Freshness | live < 2 min · stale 2–10 min (faded) · offline > 10 min (grey, "Lost contact") · `source='stop'` → white dashed "Stopped sharing" |
| Marker | initials of display name in group colour; tooltip: name, @username, group, place name, coords, ±accuracy, last seen / stopped at |
| Group position | weighted midpoint, weight = 1/accuracy², ignores readings > 2 min old or > 100 m accuracy, ignores stopped people |
| Smooth movement | glide 1000 ms (ease-in-out); **jump** if > 500 m or gap > 90 s; **ignore wobble** if within `clamp(accuracy, 5, 25)` m of the shown position |
| Follow mode | tap person in list → zoom 18 + keep centred (`panTo` each update); "Following X · Stop" bar; map drag stops following |
| Basemap | OneMap `https://www.onemap.gov.sg/maps/tiles/Default/{z}/{x}/{y}.png`, minZoom 11, maxZoom 20, **maxNativeZoom 19**, no `detectRetina`; SLA attribution required |
| Place names | Edge Function `reverse-geocode` (OneMap `/api/auth/post/getToken` + `/api/public/revgeocode?location=lat,lng&buffer=50&addressType=All&otherFeatures=N`, header `Authorization: <token>`); looked up only when a tooltip opens; cached per 4-decimal lat/lng (~11 m); failures not cached |
| Security | user-typed names HTML-escaped before Leaflet HTML |

---

## 13. App structure

| Route | View | Notes |
|---|---|---|
| `/login` | LoginView | sign in / create account |
| `/events` | EventsView | my events, create, join with code |
| `/events/:id` | EventView | tabs Live map · Members · Invite; one-tap Share/Stop |
| `/events/:id/share` | GpsTestView | "My GPS details" (raw readings, save status) |
| `/join/:code` | JoinView | invite link / QR target |
| `/gps` | redirect → `/events` | |

`meta.requiresAuth` routes → login guard (Pinia `stores/auth.js`; sign-out stops sharing first). Other files: `components/MembersPanel.vue`, `InvitePanel.vue` (code, link, QR, WhatsApp `https://wa.me/?text=`, Telegram `https://t.me/share/url?url=&text=`), `SharingWarnings.vue`, `composables/useEventData.js`, `lib/supabase.js` (exports `supabase`, `supabaseUrl`, `supabaseAnonKey`; `null` client if `.env` missing).

---

## 14. Migration checklist (to the teammate's project / repo)

1. Teammate adds you to their Supabase organisation.
2. §4 steps 1–4: run migrations 001 → 004, auth settings, deploy the edge function, add OneMap secrets.
3. Copy into the team repo: `src/` files listed in §12–13, `supabase/`, `capacitor.config.json`, `android/` + `ios/` (or regenerate with `npx cap add android|ios` and re-apply §11), package versions §2, scripts §2.
4. `.env` with the new URL + public key; Vercel env vars (`VITE_*`, type Config); redeploy.
5. `npm install` → `npm run cap:sync` → Android Studio ▶ Run; reinstall the phone app (keys are baked in at build).
6. Re-create test accounts; record logins in the README.
7. Re-run the tests in §15.

---

## 15. Verified results (Galaxy S25 Ultra, Android 16)

| Test | Result |
|---|---|
| Access rules (5 simulated users) | 15/15 pass; tracking-pass checks 6/6 pass |
| App open / background + locked / swiped away | reading every ~30 s (one ~55 s gap when the app leaves the screen) |
| 3.6 h still, locked, unplugged, swiped away, battery saver **off** | 434 readings, median 30 s, max gap 53 s, 0 upload errors, **≈2.7 %/h** battery |
| 6.5 h overnight, battery saver **on** | 0 upload errors, but Doze cut readings to bursts every 20–36 min after ~40 min |
| 7.7 h outing (~49 km, train/bus/walk), battery saver **on** | 574 readings, median 31 s, 0 gaps > 10 min, max 6 min, 0 upload errors, ≈5.6 %/h incl. normal use |
| MRT tunnels | 1.5–4.6 min gaps (no GPS; readings worse than 100 m discarded); no delayed uploads |
| Logout | stop row saved, location services OFF, pass revoked, 0 rows after |

**Known limits:** battery saver + long stillness → gaps (app warns; tell ICs to turn it off) · aggressive Android brands (Xiaomi/Oppo/Huawei) need their own battery settings · iOS configured but untested (needs Mac) · swiping the app away on iOS stops tracking until the phone moves ~500 m · Transistorsoft release builds need a paid licence.
