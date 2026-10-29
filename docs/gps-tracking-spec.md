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
 Phone app (IC) ──native HTTP every 10 s──►  rpc/report_location (pass)  ─┐
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

1. **SQL** – run in order: `supabase/migrations/001_locations.sql` → `002_users_events_groups.sql` → `003_stop_sharing.sql` → `004_tracking_passes.sql` → `005_layouts.sql` (teammate's polygon bench, on `main`) → `006_self_renewing_pass.sql` → `007_event_sessions.sql` → `008_playback.sql` → `009_push_reminders.sql` → `010_stop_with_pass.sql` → `011_scheduled_end.sql` → `012_close_expired_first.sql` → `013_delete_recording.sql` (`delete_recording(p_event_id, p_session_id, p_day)`, root/planner, not while live) (each start/end action first runs `end_scheduled_sessions()`) (column `event_sessions.scheduled_end`, `schedule_event_end` / `cancel_scheduled_end`, pg_cron `gps-end-scheduled-sessions` every minute; live also requires `scheduled_end > now()`). 007 switches on **pg_cron**, 009 **pg_net** (scheduled jobs, see §5.11). After 009, once per project: `select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');` **006 must run after 005**: 005 ends with a blanket `revoke execute on all functions ... from anon`, which blocks phone uploads (`report_location`) and the sign-up username check; 006 grants them back.
2. **Auth → Sign In / Providers → Email:** Email provider **on**, **Confirm email OFF**, **Allow anonymous sign-ins OFF**.
3. **Edge Function** `reverse-geocode` (file `supabase/functions/reverse-geocode/index.ts`), **verify JWT = on**:
   `npx supabase functions deploy reverse-geocode`
4. **Edge Function secrets:** `ONEMAP_EMAIL`, `ONEMAP_PASSWORD` (free OneMap account); `FCM_SERVICE_ACCOUNT` (Firebase service-account JSON, for push reminders). Deploy `send-reminders` with **verify JWT = off** (it checks callers itself).
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
| expires_at | timestamptz | no | `now() + 24 h` | self-renewing: every accepted upload sets it to `least(now() + 24 h, created_at + 7 days)` |
| revoked_at | timestamptz | yes | – | set on Stop / logout / new pass |

Index `(user_id)`. RLS on, **no policies** (only reachable through functions).

### 5.10 `event_sessions` – Start event → End event (007)
| Column | Type | Null | Default | Rules |
|---|---|---|---|---|
| id | uuid | no | `gen_random_uuid()` | PK |
| event_id | uuid | no | – | FK → `events(id)` CASCADE |
| starts_at | timestamptz | no | – | future = scheduled start; ≤ now() = started |
| ended_at | timestamptz | yes | – | null = scheduled or live; check `ended_at >= starts_at` |
| started_by / ended_by | uuid | yes | – | FK → `profiles(id)` SET NULL |
| end_reason | text | yes | – | `'ended'` (End button) \| `'auto'` (24 h without uploads) |
| created_at | timestamptz | no | `now()` | |

Unique index `(event_id) where ended_at is null` = at most one scheduled-or-live session per event. Index `(event_id, starts_at desc)`. RLS: members `select`; writes only through functions. **Live** = `ended_at is null and starts_at <= now()`.

### 5.11 Scheduled jobs (pg_cron)
| Job | Schedule (UTC) | Runs |
|---|---|---|
| `gps-auto-close-sessions` | `*/15 * * * *` | `auto_close_idle_sessions()` – live sessions with no upload for 24 h end at their last upload |
| `gps-cleanup-expired-locations` | `5 16 * * *` (00:05 SGT) | `cleanup_expired_locations()` – deletes readings past "available until" + passes older than 8 days |
| `gps-push-reminders` | `* * * * *` | only while a session is live: `net.http_post` to Edge Function `send-reminders` with header `x-cron-secret` (Vault `push_cron_secret`, URL from Vault `project_url`) |

**Retention rule:** `playback_available_until(end) = midnight SGT at the start of (end's SGT date + 8 days)` – shown as "until 23:59, 7 days after the day it ended". Readings inside a session use the session's end; readings outside any session use their own day.

### 5.12 Push reminders (009)
`push_tokens(token text PK, user_id uuid FK profiles CASCADE, platform text 'android'|'ios', updated_at timestamptz)` and `push_reminders(session_id uuid FK event_sessions CASCADE, user_id uuid FK profiles CASCADE, sent_count int, last_sent_at timestamptz, PK (session_id, user_id))`. RLS on, no policies (functions only).

| Function | Who | Behaviour |
|---|---|---|
| `register_push_token(p_token, p_platform)` / `unregister_push_token(p_token)` | authenticated | save / remove this phone for the caller (a phone belongs to whoever logged in last) |
| `claim_push_reminders(p_event_id default null, p_force default false)` | service_role | ICs in a live session with no reading and no new pass since the start; first reminder at once, then every 10 min, max 6; forced (planner button) at most once a minute; records each reminder; returns their tokens |
| `delete_push_token(p_token)`, `check_push_cron_secret(p_secret)` | service_role | invalid tokens / caller check |

Edge Function `supabase/functions/send-reminders/index.ts`: caller = pg_cron (`x-cron-secret`) or a root/planner (login token + `{ eventId }`); signs a Google JWT with the service account → FCM HTTP v1 `messages:send`; Android channel `event-start`, tag `event-start-<eventId>` (newer reminder replaces older), data `{ kind: 'event-start', eventId }`; deletes tokens FCM reports as UNREGISTERED. App side: `composables/usePushNotifications.js` (`@capacitor/push-notifications` 8.1.2); `android/app/google-services.json` from Firebase (git-ignored); manifest meta-data `default_notification_icon` = `ic_stat_location`, `default_notification_channel_id` = `event-start`.

### 5.8 Trigger
`on_auth_user_created` AFTER INSERT ON `auth.users` → `handle_new_user()`: inserts `profiles(id, lower(username), display_name)` from sign-up metadata (`raw_user_meta_data.username`, `.display_name`); skips users without a username.

### 5.9 Realtime publication `supabase_realtime`
`locations`, `group_members`, `event_roles`, `event_sessions`.

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
| `report_location(p_token uuid, p_lat double precision, p_lng double precision, p_accuracy real, p_recorded_at timestamptz)` | **anon**, authenticated | void → HTTP **204** | valid pass + still IC → inserts `locations` (user/event/group from the pass, `source='gps'`). Invalid/revoked/expired pass or no longer IC → `errcode 'PT403'` → **HTTP 403**. Bad coordinates → 22023 → 400. Each accepted upload renews the pass (24 h after the last upload, max 7 days after Share) |
| `stop_member_sharing(p_event_id uuid, p_user_id uuid)` | authenticated: self, root/planner, or admin of the member's group (else 42501) | boolean | revokes the member's active passes; adds a `source='stop'` row at their last position; `false` if they weren't sharing from the phone. Members tab "Stop sharing" button |
| `revoke_my_tracking_passes()` | authenticated | void | cancels all caller's active passes |
| `my_active_tracking_pass()` | authenticated | table(event_id, group_id) | newest active pass (app reopen) |
| `stop_sharing_with_pass(p_token uuid)` (010) | **anon**, authenticated | void | revokes that pass + `source='stop'` row at the last position; called by `BackgroundGeolocationHeadlessTask.java` when "Stop sharing" is pressed in the notification with the app closed |

Since 007, `start_tracking_pass` also refuses when the event isn't live, and `report_location` answers PT403 (HTTP 403) once it isn't. Website inserts: policy **"ICs insert own group locations while live"** = `user_id = auth.uid() and is_ic_of(event_id, group_id) and event_is_live(event_id)`.

### 7.4 Event sessions (007)
| Function | Who | Returns | Behaviour |
|---|---|---|---|
| `live_session_id(p_event_id)` / `event_is_live(p_event_id)` | authenticated (helpers) | uuid / boolean | the live session, if any |
| `start_event(p_event_id)` | root/planner (else 42501) | uuid | starts now; a scheduled start is moved to now; error if already live |
| `schedule_event_start(p_event_id, p_starts_at timestamptz)` | root/planner | uuid | future time (≤ 1 year); moves an existing scheduled start; error if live |
| `cancel_scheduled_start(p_event_id)` | root/planner | void | deletes the not-yet-started session |
| `end_event(p_event_id)` | root/planner | integer | ends the live session, revokes every pass of the event, adds `source='stop'` rows for people whose newest reading in the session is GPS; returns how many |
| `close_session_sharing(p_session_id, p_end)` / `auto_close_idle_sessions()` | internal / pg_cron | integer | – |

### 7.5 Playback (008) – root / planners only (else 42501)
| Function | Returns | Behaviour |
|---|---|---|
| `playback_list(p_event_id)` | table(kind 'session'\|'day', session_id, starts_at, ended_at, end_reason, available_until, readings, people) | started sessions + days with readings outside any session, newest first |
| `location_history(p_event_id, p_from, p_to, p_after_id bigint default 0)` | jsonb `{rows: [[id, user_id, group_id, lat, lng, accuracy, source, epoch_ms]], next_after_id, people, groups}` | pages of 10 000 by id; `people` / `groups` on the first page only (names of people who left still work) |
| `playback_available_until(timestamptz)` | timestamptz | retention rule (§5.11) |
| `cleanup_expired_locations()` | integer | pg_cron only |

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
    // ANDROID: timer-based, every 10 s, moving or still (was 30 s until 13 Oct; tests below used 30 s)
    distanceFilter: 0, locationUpdateInterval: 10000, fastestLocationUpdateInterval: 10000,
    // iOS instead: distanceFilter: 10   (+ 60 s heartbeat below)
  },
  activity: { disableStopDetection: true },                   // never go "stationary"
  app: {
    stopOnTerminate: false, startOnBoot: true,
    heartbeatInterval: 60,                                     // iOS: onHeartbeat → getCurrentPosition({samples:1, persist:true, timeout:30}); ignored on Android
    preventSuspend: true,                                      // iOS
    showsBackgroundLocationIndicator: true,                    // iOS blue pill
    notification: {                                            // Android: always shown while sharing
      title: 'Sharing your location', text: 'Event planners can see you. Tap to open.',
      sticky: true, priority: bg.NotificationPriority.Default,
      layout: 'notification_sharing',                          // android/app/src/main/res/layout/notification_sharing.xml
      actions: ['notificationButtonStop'],                     // onNotificationAction → stop()
    },
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

Files: `components/LiveMap.vue`, `composables/useLiveLocations.js`, `utils/liveMotion.js`, `utils/groupPosition.js`, `utils/people.js`, `utils/onemap.js`, `composables/useReverseGeocode.js`.

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

### 12.1 Smooth movement + trail (13 Oct)
- `utils/liveMotion.js` (14 Oct, replaces markerMotion.js): each person has a track of recent readings and a **playhead** drawn ~12 s in the past (+ that phone's measured delivery delay), sliding between two real readings, so the marker follows the real path. Out of readings: it waits at the newest one. Readings late (tunnel, battery saver, slow upload): they slot into the track and the playhead fast-forwards (up to 6x) until on time, so no jumps. Map off screen (tab hidden) and 30+ s behind: jumps to the present instead of replaying. Real gap (> 2 min or after Stop): no sliding across it. Noise: moves < half the accuracy (4–15 m) flattened; one bad fix (> 100 m after ≤ 50 m) and impossible jumps (> 70 m/s) skipped. One animation loop for all markers, only while the map is on screen.
- Trail (selected person): drawn only up to the marker; dashed only over real gaps; tap the trail or a dot = popup with time + place; first tap on the empty map closes the popup, the next hides the trail. Group diamond only for groups with 2+ ICs, placed from the drawn IC positions.
- `composables/useLiveLocations.js`: on page shown again / back online / every minute: rebuild a dead Realtime channel, fetch readings missed (last 3 min, else just the latest positions). Network errors show "Reconnecting…" on the map and retry (2 s → 30 s), never a red error.
- Trail: tap a marker (or a person in the list) → their readings **since the live session started** (`locations` via RLS, pages of 1000) + new ones from Realtime (`useLiveLocations().onReading`). Solid line, dashed over gaps > 2 min or after a Stop, dot every 2 min, green start dot; the last piece follows the gliding marker. Hover / tap the trail → nearest reading's time + place name (OneMap, cached). Tap the empty map or the marker again → hidden. New session / event ended → cleared.

### 12.2 Zones layer (merger Stage 1, 14 Oct)

- Data: `zones` (one row per area on an event's bench: `code` unique per event, `name`, `kind` zone / stage / entrance / no_go / obstacle, `shape geography(Polygon,4326)` with a GiST index, `source_area_id` = the bench area). Written only by triggers on `layout_objects` (migration 020); read by event members (RLS).
- Codes: an area on an event bench always carries `data.code`. Typed by a planner (A–Z 0–9 _, max 40, unique on the bench – `save_object` refuses a duplicate with a sentence) or made once from the name (`Formation 1` → `FORMATION_1`, then `_2`, `_3` …) and kept through renames.
- Benches: `layouts.event_id` – one bench per event (made on first open of the Zones tab), plus the demo bench (event_id null) at `/polygon`. All bench functions take `p_layout` (null = demo). Event bench: members read, root / planners edit (`bench_can_read` / `bench_can_edit`).
- Live map: `event_zones(event)` returns GeoJSON; drawn under markers and trails, not clickable; labels from zoom 16; Realtime on `zones` (filter `event_id`) triggers a redraw.
- Helpers for Stage 2+: `zone_contains(zone, lat, lng, buffer_m)` (PostGIS `ST_DWithin`), `zone_distance_m(zone, lat, lng)` (0 inside).

### 12.3 Zone presence, No-Go alerts, group positions (merger Stage 2, 14 Oct)

- Trigger `locations_zone_update` (after insert on `locations`): finds the session the reading belongs to (by `recorded_at`); skips a late reading if a newer one of that person exists; `stop` closes every open stay; else finds the zones within min(accuracy, 15 m) of the point (PostGIS `ST_DWithin`), opens a stay at the first inside reading (and a `zone_alerts` row if the zone is `no_go`, one per entry), resets a blip, and closes a stay after 2 readings in a row outside (exited_at = the first of them); then refreshes `group_positions`. Errors are caught and logged as warnings – the reading is always stored.
- `group_positions` (one row per group per session): accuracy-weighted midpoint of the ICs' newest readings (≤ 2 min old, ≤ 100 m), average speed from each IC's reading 30–90 s earlier, ICs sharing, last seen.
- RLS: presence and group positions like `locations` (root / planner / marshal everything, others their group); alerts to ops roles and the IC concerned. All three published to Realtime (presence changes only on enter / blip / exit).
- Client: `composables/useZoneActivity.js` (event page) loads + subscribes; `LiveMap` gets `zoneStays`, `zoneCounts`, `noGoOccupied`, `groupPositions`.

### 12.4 Simulator (merger Stage 3, 15 Oct)

- Only in simulation events (`events.is_simulation`, set by `create_simulation_event`, never on a real event). Root only (`sim_check`).
- `sim_setup(event, groups, ics_min, ics_max, mix)`: groups `SIM-001…` (category "Simulated"), 1–3 virtual ICs each (fake Auth users, `@simulation.invalid`, no password / identity, username `sim_<event6>_<n>`, `profiles.is_simulated`), event role participant, group IC. Each group walks from a random point 200–600 m from a zone's centre to it (a No-Go zone for `wrong_zone`), 1.0–1.5 m/s. Behaviours: on_time, late_2min (+120 s), stops_halfway, loses_signal (silent 150 s from 40 % of the way), wrong_zone.
- `sim_tick()` (pg_cron `gps-sim-tick`, 10 s): for running simulations whose event is live, advances each group (`active_s`, `travelled_m`), then inserts one reading per virtual IC at the interpolated point + 5–15 m noise, accuracy 5–15 m, `recorded_at = now()`. An ended event pauses its simulation.
- `sim_reset(event)`: deletes the virtual ICs' readings, the `sim_ics` rows (trigger deletes the Auth users → profiles, memberships, presence cascade), the SIM groups and the run.

### 12.5 Movements engine and ops view (merger Stage 7, 18 Oct)

> **Deleted in step 25 (061).** This whole section describes the run-sheet movements engine as it was: its tables
> (`movement_status`, `movement_routes`, `group_messages`), its functions (`move_step`, `ops_board`, `my_moves`,
> `route_*`, `message_group`, `mark_in_position`), its Edge Function (`route-eta`) and its components (`useOps`,
> `useGroupMessages`, `opsStatus`, `OpsSummary`, `OpsQueue`, `OpsDecision`, `CueChips`, and `LiveMap`'s clusters and
> rings) are gone from the database and the repository. A plan session's staff view of the walk is `plan_ops` /
> `PlanOps`, a table of moments rather than a drawing — see `docs/design/planning-implementation-plan.md`. The section
> is kept as the record of what the plan replaced.

- Tables (027): `movement_status` (PK session + movement + group; `state` waiting / active / done; `status` pending, on_track, at_risk, late, no_signal, arrived, arrived_late, missed, skipped; `cand_status` for the two-look rule; `planned_deadline`, `deadline`, `eta`, `spare_s`, `late_s`, `leave_by`, `remaining_m`, `speed_mps`, `basis` route / straight / inside, `moving_since`, `ics_inside / required / sharing / no_signal`, `arrived_at`, `handled_by`, `acked_status`, `snoozed_until`, `updated_at`), `movement_routes` (OneMap path per movement + group; no RLS policy: only `ops_board` hands routes out), `group_messages` (Realtime; the group's members and ops roles read), `event_roles.sector`.
- Engine `move_step(session, now)` (pg_cron `gps-move-tick`, 5 s, via `move_tick`; needs the show of Stage 6): rows from `rs_moves`; per group the earliest unfinished movement is active. Deadline: cue start = when the cue is due (`due_at`; for a started cue `least(started, when the cue before ended)`), cue end = projected / real end, or the fixed time; minus `early_s`. Per IC (group members with `is_ic`): newest reading of the session, open presence in the zone, distance (`move_dist`: inside 0, < 50 m straight, within 50 m of the route along it, else straight × 1.3 / 1.4 / 1 in simulations), progress from the IC's earliest reading 50–90 s before. ETA k-th fastest (k = `min_ics` or ICs heard in 2 min), rounded up to 5 s. Arrived at the k-th (entered + `dwell_s`). Two looks must agree before a status changes (arrived, arrived late, missed and the first look apply at once).
- Routes: `gps-route-eta` (30 s) posts to the Edge Function `route-eta` only when `route_due()`; the function claims up to 20 (`route_claim`), calls OneMap routing (`walk` / `drive`, polyline precision 5, else 6) and saves (`route_save`); an error is saved too (the straight line is used).
- Ops view reads `ops_board(session, since)` every 4 s (full read first, then rows changed since the last read with a 10 s overlap; full read every minute and when the version changes). Buttons: `ops_handle`, `ops_ack`, `ops_snooze`, `message_group`, `show_keep_holding`; `set_marshal_sector` (Members). Client: `composables/useOps.js`, `useGroupMessages.js`, `utils/opsStatus.js`, `components/OpsSummary.vue`, `OpsQueue.vue`, `OpsDecision.vue`, `CueChips.vue`; `LiveMap` gets `opsActive` and `opsVisible` (clusters below zoom 16, rings + route lines).
- Simulation: `sim_follow_plan` (called by `move_step` in simulation events) gives a virtual group with an active movement a new leg from where it stands to the zone's middle at the movement's pace, leaving 60 s before its leave by (`late_2min` +120 s); `wrong_zone` groups are left alone. `sim_plan_movements(event, sheet, cue)` adds one movement per virtual group to a Draft. **Retired in step 24 (060):** `sim_follow_plan` is called by `sim_tick` and aims each group at its next on-site plan moment, `sim_plan_movements` is gone, and `move_step`/`move_tick` no longer exist.

### 12.6 IC phone: next move and pushes (merger Stage 8, 18 Oct)

> **Partly deleted in step 25 (061).** The next-move half of this section (`my_moves`, `NextMoveCard`,
> `useMyMoves`, `report_delay`, `mark_in_position`, `push_collect_moves`) went with the run-sheet engine; a member's
> own moments are the Schedule page (`session_timetable`, step 16) and a plan push still opens `?next=1`, which now
> lands there. The push *delivery* half (`push_queue`, `push_kick`, `send-reminders`, `claim_push_queue`,
> `usePushNotifications`) is unchanged and is what the plan's pushes ride on.

- Tables (028): `push_queue` (`user_id`, `event_id`, `session_id`, `kind` get_ready / leave_now / late / message / nogo, unique `dedup`, `title`, `body`, `data`, `sent_at`; RLS on, no policy, kept 2 days); `movement_status.delay_note / delay_at / delay_by`.
- Queueing: `move_tick` → `move_step` → `push_collect_moves(session, now)` for real events. Recipients: members of the group with `is_ic` or `is_admin`. Dedup `kind:session:movement:group:user`. Get ready: `leave_by − 60 s ≤ now < leave_by`; Leave now: `leave_by ≤ now < leave_by + 5 min`; both only while not moving and nobody inside. Late: status `late` and (moving, or no leave by, or 60 s past it). `message_group` queues `message`; `push_collect_nogo()` (cron) queues `nogo` for zone alerts of the last 2 min in real events.
- Sending: `push_kick()` (pg_net, straight after queueing) and pg_cron `gps-push-send` every 5 s post `{"queue": true}` with `x-cron-secret` to `send-reminders`; it calls `claim_push_queue(200)` (service role; marks sent with `skip locked`, joins `push_tokens`) and sends FCM v1 notification messages: `android.priority HIGH`, `ttl 600s`, `notification.channel_id 'moves'`, `tag move-<movement>-<group>`; data `{kind, eventId, movementId, groupId}` as strings. Dead tokens are forgotten.
- Phone: `usePushNotifications` creates channel `moves`; a tap on kind move / message / nogo opens `/events/:id?next=1`; a foreground `move` push shows a toast (message and No-Go already have their own).
- Page: `my_moves(session)` polled every 5 s by `composables/useMyMoves.js` (server clock offset); `components/NextMoveCard.vue` on the event page for group members during a show. `report_delay` (once a minute) logs `delay_report`, puts the row in the planners' queue (`ops_board` returns `delay_at / delay_note / delay_by`; `problem` includes it) and `move_step` keeps acknowledge / snooze while it stands.

### 12.7 Field hardening and radio (029, 18 Oct)

- Readings: `report_location` stores a time more than 30 s in the future as now; trigger `locations_clamp_time` does the same for the website's own inserts (signed in). `locations_zone_update` ignores readings with accuracy over 100 m; `move_step` uses only readings of 100 m or better as a position.
- `show_add_time`: refused (PT409, "<who> added +30 s … (2 s ago)") when someone else changed the same cue's time in the last 5 s.
- Pushes (`push_collect_moves`): while `show_state.held_since` is set nothing about moves; 20 s into a hold kind `hold` ("Show on hold"); within 2 min after a resume kind `resume` to everyone told on hold (Leave now / Keep going / Leave at …); kind `next` when the group's previous movement arrived in the last 2 min; Get ready / Leave now keyed by code + leave-by + zone, not repeated when the leave-by moved less than 2 min, the zone is the same, or `next` / `resume` / `change` already said it; late once per code, a minute after `next` / `resume` / `change`. Push data has `code`, `zoneId`, `leaveBy`, `at`; tag `move-<code>-<group>`; kind `show` for hold / resume.
- Version switch (`move_step` section 1): handled_by, acked_status, snoozed_until and the delay carry over by code + group; kind `change` "Change of plan" to ICs / admins of a group whose active movement is gone ("cancelled, wait for instructions") or goes to another zone.
- `zones_guard_live` (before delete): refused while a live session's unfinished movement uses the zone. **Dropped in
  step 25 (061)** with the movement it pointed at: a plan states positions as lat/lng, so a plan pins no zone, and
  deleting a zone mid-event is no longer refused.
- Radio: `groups.radio` (≤ 40 chars, `set_group_radio`, root / planner); `mark_in_position(session, movement, group, undo)` (ops or the group's IC / admin; basis `reported`, logged as kind `radio`; undo within 5 min, which also pushes "Correction: not in position yet" if a `next` went out); `show_missing_groups` counts an arrived movement; `report_delay` open to ops ("radio, <who>"). `ops_board` rows and `my_moves` have `radio`; `my_moves` also `can_report`, `is_ic`, `held_since`.
- Phone: `ReminderMessagingService` draws kinds move / message / nogo / show itself when the app is open; `usePushNotifications` routes kind `show` to the card.

## 13. App structure

| Route | View | Notes |
|---|---|---|
| `/login` | LoginView | sign in / create account |
| `/events` | EventsView | my events (with date / venue), Create an event (→ wizard), simulation event by name, join with code |
| `/events/new` | CreateEventView | 4-step wizard: details, people (`search_people`), groups with IC / Admin, preview; one call `create_event_with_setup` (030); draft kept on the device |
| `/events/:id` | EventView | status card (Start / Schedule / End), tabs Live map · Members · Invite · Playback (root/planner); one-tap Share/Stop (locked until live) |
| `/events/:id/share` | GpsTestView | "My GPS details" (raw readings, save status) |
| `/join/:code` | JoinView | invite link / QR target |
| `/gps` | redirect → `/events` | |

`meta.requiresAuth` routes → login guard (Pinia `stores/auth.js`; sign-out stops sharing first). Other files: `components/MembersPanel.vue`, `InvitePanel.vue` (code, link, QR, WhatsApp `https://wa.me/?text=`, Telegram `https://t.me/share/url?url=&text=`), `SharingWarnings.vue`, `EventStatus.vue`, `PlaybackPanel.vue`, `PlaybackPlayer.vue`, `composables/useEventData.js`, `useEventSessions.js`, `usePlaybackHistory.js`, `useStartReminders.js` (phone reminders, `@capacitor/local-notifications` 8.3.0, icon `res/drawable/ic_stat_location.xml`), `utils/playback.js` (tracks, position at time t, trails, CSV), `utils/time.js` (SGT formatting), `assets/map-markers.css`, `lib/supabase.js` (exports `supabase`, `supabaseUrl`, `supabaseAnonKey`; `null` client if `.env` missing).

### 13.1 Playback CSV format (v1)
Line 1: `# Event Tracker playback,v1,<event name>,<from>,<to>` · line 2 = header · then one row per reading, oldest first. UTF-8 with BOM, CRLF.

| Column | Example | Notes |
|---|---|---|
| time_sgt | `2026-08-09T17:00:05+08:00` | text, so Excel doesn't round it; the reader also accepts `9/8/2026 17:00` and `2026-08-09 17:00:05` (= SGT) |
| name, username | `Komin Chow`, `komin` | |
| group, group_colour | `Contingent A`, `#0d6efd` | |
| lat, lng | `1.293000`, `103.852000` | 6 decimals |
| accuracy_m | `8` | |
| source | `gps` \| `stop` | |
| user_id, group_id | uuid | identify people/groups; name is the fallback |

Required to replay: `time_sgt`, `name`, `lat`, `lng`. Rows that can't be read are skipped and counted.

---

## 14. Migration checklist (to the teammate's project / repo)

1. Teammate adds you to their Supabase organisation.
2. §4 steps 1–4: run migrations 001 → 009 (006 after 005; 007 enables pg_cron; after 009 add the Vault `project_url`), Firebase project + `google-services.json` + `FCM_SERVICE_ACCOUNT` secret, deploy `send-reminders`, auth settings, deploy the edge function, add OneMap secrets.
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
