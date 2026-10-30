<script setup>
// The front door (Planova 2). Visitors: what Planova is, the two jobs people come for (create an event, join one with
// a code) and why their location is safe -- a Z-pattern landing page. Signed in: "Home", with the live event first.
// The phone app never shows this page (the router sends it to My events).
import { ref, computed, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { getMyEvents, getLiveEventIds, joinEventByCode } from '../services/eventService'
import { ROLE_LABEL, topRole, isMarshal, viewRole } from '../utils/permissions'
import BenchAlert from '../components/BenchAlert.vue'

const auth = useAuthStore()
const router = useRouter()
const isDev = import.meta.env.DEV // the demo bench is only reachable on local dev

// ---------- Join with a code (both views) ----------
// Six boxes show how long a code is and which box is next; only letters and digits get in; paste fills all six.
const code = ref('')
const joinBusy = ref(false)
const joinError = ref('')
const boxes = computed(() => Array.from({ length: 6 }, (_, i) => ({ ch: code.value[i] || '', next: i === Math.min(code.value.length, 5) && code.value.length < 6 })))
const codeFull = computed(() => code.value.length === 6)
function onCode(event) {
  code.value = (event.target.value || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6)
  event.target.value = code.value
  joinError.value = ''
}
async function join() {
  if (!codeFull.value || joinBusy.value) return
  // Not signed in: the join page needs an account, and sends you back here once you have one
  if (!auth.isLoggedIn) {
    router.push({ name: 'join', params: { code: code.value } })
    return
  }
  joinBusy.value = true
  joinError.value = ''
  try {
    const id = await joinEventByCode(code.value)
    router.push({ name: 'event', params: { id } })
  } catch (error) {
    joinError.value = error.message
  } finally {
    joinBusy.value = false
  }
}

// ---------- Signed in: my events, the live one first ----------
const events = ref([])
const liveIds = ref([])
const loading = ref(false)
const errorMsg = ref('')
async function load() {
  if (!auth.isLoggedIn) return
  loading.value = true
  try {
    events.value = await getMyEvents(auth.user.id)
    liveIds.value = await getLiveEventIds(events.value.map((e) => e.id)).catch(() => [])
  } catch (error) {
    errorMsg.value = error.message
  } finally {
    loading.value = false
  }
}
onMounted(load)

const roleLabel = (ev) => ROLE_LABEL[viewRole({ role: topRole(ev), is_ic: ev.isIC, is_marshal: isMarshal(ev) })]
const liveEvents = computed(() => events.value.filter((e) => liveIds.value.includes(e.id)))
const upcoming = computed(() =>
  events.value
    .filter((e) => !liveIds.value.includes(e.id) && (!e.startsAt || new Date(e.startsAt).getTime() > Date.now() - 12 * 3600 * 1000))
    .sort((a, b) => new Date(a.startsAt || 8.64e15) - new Date(b.startsAt || 8.64e15))
    .slice(0, 5),
)
const firstName = computed(() => {
  const p = auth.profile || {}
  return p.first_name || (p.display_name || p.username || '').split(' ')[0] || ''
})
const greeting = computed(() => {
  const h = Number(new Date().toLocaleString('en-SG', { hour: 'numeric', hour12: false, timeZone: 'Asia/Singapore' }))
  return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening'
})
const SG = { timeZone: 'Asia/Singapore' }
const tile = (iso) =>
  iso
    ? {
        dow: new Date(iso).toLocaleDateString('en-SG', { weekday: 'short', ...SG }).toUpperCase(),
        day: new Date(iso).toLocaleDateString('en-SG', { day: '2-digit', ...SG }),
        mon: new Date(iso).toLocaleDateString('en-SG', { month: 'short', ...SG }).toUpperCase(),
      }
    : { dow: 'NO', day: '—', mon: 'DATE' }
const timeOf = (iso) => (iso ? new Date(iso).toLocaleTimeString('en-SG', { hour: 'numeric', minute: '2-digit', ...SG }) : '')

// ---------- Visitor: the live plan preview (drag the clock, hover a dot) ----------
// An illustration of the mental model (groups as dots, zones, one clock), not live data.
const t = ref(46)
const picked = ref('GC')
const DEMO = [
  { code: 'GC', name: 'Gate Crew · 12 people', colour: '#0072B2', ink: false, pts: [[18, 82], [38, 50], [78, 38]], next: 'Next: F1 Formation by 21:45', lateAfter: 2 },
  { code: 'BS', name: 'Backstage · 8 people', colour: '#56B4E9', ink: true, pts: [[14, 22], [56, 30], [77, 39]], next: 'Next: F1 Formation by 21:50', lateAfter: 0.55 },
  { code: 'SD', name: 'Sound · 5 people', colour: '#009E73', ink: true, pts: [[20, 86], [24, 62], [34, 52]], next: 'Next: H2 Holding by 21:40', lateAfter: 2 },
  { code: 'MD', name: 'Medics · 6 people', colour: '#CC79A7', ink: true, pts: [[90, 88], [88, 80], [70, 76]], next: 'First moment 22:00 · Gate 3', lateAfter: 2 },
]
function along(pts, f) {
  const n = pts.length - 1
  const x = Math.min(n - 1e-6, f * n)
  const i = Math.floor(x)
  const k = x - i
  return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k]
}
const dots = computed(() => {
  const f = t.value / 100
  return DEMO.map((g) => {
    const [x, y] = along(g.pts, f)
    return { ...g, x, y, late: f > g.lateAfter }
  })
})
const card = computed(() => dots.value.find((d) => d.code === picked.value))
const clock = computed(() => {
  const mins = Math.round((t.value / 100) * 90)
  return 21 + Math.floor(mins / 60) + ':' + String(mins % 60).padStart(2, '0')
})
</script>

<template>
  <!-- ================= Signed in: Home ================= -->
  <main v-if="auth.isLoggedIn" class="hm">
    <div class="hm-wrap">
      <div class="hm-head">
        <div>
          <h1 class="hm-h1">{{ greeting }}<template v-if="firstName">, {{ firstName }}</template></h1>
          <p class="hm-muted mb-0">
            <template v-if="loading">Loading your events…</template>
            <template v-else-if="liveEvents.length">{{ liveEvents.length === 1 ? 'One event is live.' : liveEvents.length + ' events are live.' }}</template>
            <template v-else-if="events.length">Nothing is live right now.</template>
            <template v-else>You are not in any event yet — create one or join with a code.</template>
          </p>
        </div>
        <RouterLink :to="{ name: 'event-new' }" class="btn btn-primary" data-testid="home-create-event">+ Create an event</RouterLink>
      </div>

      <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <!-- Live first: one card, the live colour, ONE main action -->
      <section v-for="ev in liveEvents.slice(0, 1)" :key="ev.id" class="hm-live" aria-label="Live now" data-testid="home-live">
        <div class="hm-live-main">
          <div class="d-flex align-items-center gap-2 flex-wrap">
            <span class="ev-chip ev-chip-live">LIVE</span>
            <span class="hm-muted small">You: {{ roleLabel(ev) }}</span>
          </div>
          <h2 class="hm-h2">{{ ev.name }}<template v-if="ev.venue"> · {{ ev.venue }}</template></h2>
          <p class="hm-muted mb-0">Open the event for the live map, the plan and who is sharing.</p>
        </div>
        <RouterLink :to="{ name: 'event', params: { id: ev.id, page: 'live' } }" class="btn btn-live btn-lg">Open live map →</RouterLink>
      </section>

      <!-- More than one live at once: the first gets the big card, the rest a compact list (one loud thing per screen) -->
      <section v-if="liveEvents.length > 1" class="hm-card hm-also" aria-label="Also live" data-testid="home-also-live">
        <h2 class="hm-h3 mb-1">Also live · {{ liveEvents.length - 1 }}</h2>
        <RouterLink v-for="ev in liveEvents.slice(1)" :key="ev.id" :to="{ name: 'event', params: { id: ev.id, page: 'live' } }" class="hm-row">
          <span class="ev-chip ev-chip-live">LIVE</span>
          <span class="flex-grow-1" style="min-width: 0">
            <strong class="d-block text-truncate">{{ ev.name }}</strong>
            <span class="hm-muted small">{{ [ev.venue, roleLabel(ev)].filter(Boolean).join(' · ') }}</span>
          </span>
          <span class="small fw-semibold" style="color: var(--brand-primary)">Open →</span>
        </RouterLink>
      </section>

      <div class="hm-cols">
        <section class="hm-card hm-grow" aria-label="Coming up">
          <div class="d-flex justify-content-between align-items-baseline mb-1">
            <h2 class="hm-h3 mb-0">Coming up</h2>
            <RouterLink to="/events" class="small">All events →</RouterLink>
          </div>
          <p v-if="!loading && !upcoming.length" class="hm-muted mb-0 py-2">No upcoming events. Events you create or join show here.</p>
          <RouterLink v-for="ev in upcoming" :key="ev.id" :to="{ name: 'event', params: { id: ev.id } }" class="hm-row">
            <span class="hm-tile">
              <span>{{ tile(ev.startsAt).dow }}</span><strong>{{ tile(ev.startsAt).day }}</strong><span>{{ tile(ev.startsAt).mon }}</span>
            </span>
            <span class="flex-grow-1" style="min-width: 0">
              <strong class="d-block text-truncate">{{ ev.name }}</strong>
              <span class="hm-muted small">{{ [ev.venue, timeOf(ev.startsAt), roleLabel(ev)].filter(Boolean).join(' · ') }}</span>
            </span>
            <span v-if="ev.isSimulation" class="hm-chip hm-chip-info">Simulation</span>
          </RouterLink>
        </section>

        <section class="hm-join" aria-label="Join an event">
          <h2 class="hm-h3 text-white">Join an event</h2>
          <label for="home-code" class="small hm-on-dark">Type the 6-character code your planner sent you.</label>
          <div class="d-flex gap-2 flex-wrap">
            <input id="home-code" :value="code" class="form-control hm-code-input" autocomplete="off" placeholder="9Z8GGZ" data-testid="home-join-code" @input="onCode" @keydown.enter="join" />
            <button type="button" class="btn" :class="codeFull ? 'btn-light' : 'btn-outline-light'" :disabled="!codeFull || joinBusy" data-testid="home-join-btn" @click="join">
              {{ joinBusy ? 'Joining…' : 'Join' }}
            </button>
          </div>
          <span class="small hm-on-dark">{{ joinError || (codeFull ? 'Looks good — press Join.' : code ? 6 - code.length + ' more to go · letters and digits only' : 'Paste works.') }}</span>
        </section>
      </div>
    </div>
  </main>

  <!-- ================= Visitor: the landing page ================= -->
  <main v-else class="hm">
    <section class="hm-wrap hm-hero">
      <div class="hm-hero-text">
        <span class="hm-kicker"><span class="hm-kicker-badge">NEW</span>Plans now run on one clock — every group, every moment</span>
        <h1 class="hm-display">Every group in the right place, right on time.</h1>
        <p class="hm-lead">Planova turns your run sheet into a live plan. Planners see where every group is. ICs and members get one clear next move on their phone — and a nudge when it is time to go.</p>
        <div class="d-flex gap-2 flex-wrap">
          <RouterLink :to="{ name: 'signup' }" class="btn btn-primary btn-lg">Create an event →</RouterLink>
          <RouterLink :to="{ name: 'login' }" class="btn btn-outline-primary btn-lg">Log in</RouterLink>
        </div>
        <div class="hm-join-light">
          <label for="visitor-code" class="fw-semibold">Got an event code from your planner?</label>
          <div class="d-flex gap-2 align-items-center flex-wrap">
            <div class="hm-boxes">
              <span v-for="(b, i) in boxes" :key="i" class="hm-box" :class="{ 'hm-box-filled': b.ch, 'hm-box-next': b.next }">{{ b.ch }}</span>
              <input id="visitor-code" :value="code" class="hm-box-input" autocomplete="off" aria-describedby="visitor-code-help" data-testid="visitor-join-code" @input="onCode" @keydown.enter="join" />
            </div>
            <button type="button" class="btn" :class="codeFull ? 'btn-primary' : 'btn-outline-primary'" :disabled="!codeFull" @click="join">Join</button>
          </div>
          <span id="visitor-code-help" class="small hm-muted">{{ codeFull ? 'Looks good — you’ll sign in or make an account next.' : 'Paste works · only letters and digits · ' + (6 - code.length) + ' to go' }}</span>
        </div>
      </div>

      <div class="hm-demo" aria-label="Example of a live plan">
        <div class="hm-demo-head">
          <span class="ev-chip ev-chip-live">LIVE · {{ clock }}</span>
          <strong>Show night · example</strong>
        </div>
        <div class="hm-map">
          <svg viewBox="0 0 600 360" preserveAspectRatio="none" aria-hidden="true">
            <path d="M0 280 C110 240 200 300 300 280 S500 220 600 240 V360 H0Z" fill="#CFE6EE" />
            <path d="M50 0 L120 360 M0 110 L600 70 M260 0 L330 360 M450 0 L520 360 M0 200 L600 170" stroke="#FFFFFF" stroke-width="10" />
            <rect x="390" y="84" width="130" height="86" rx="14" fill="#DCEFEA" stroke="#2E8A7A" stroke-width="2" stroke-dasharray="7 5" />
            <rect x="150" y="150" width="110" height="74" rx="14" fill="#DCEFEA" stroke="#2E8A7A" stroke-width="2" stroke-dasharray="7 5" />
            <rect x="490" y="214" width="90" height="56" rx="12" fill="#FBE5E1" stroke="#C4321F" stroke-width="2" stroke-dasharray="4 4" />
            <path d="M108 295 C170 230 200 200 228 180 S380 140 470 136" stroke="#0072B2" stroke-width="4" stroke-linecap="round" stroke-dasharray="1 10" fill="none" />
            <path d="M84 80 C200 100 300 95 340 110 S430 140 466 140" stroke="#14201B" stroke-width="8" stroke-linecap="round" stroke-dasharray="1 10" fill="none" opacity=".55" />
            <path d="M84 80 C200 100 300 95 340 110 S430 140 466 140" stroke="#56B4E9" stroke-width="4" stroke-linecap="round" stroke-dasharray="1 10" fill="none" />
          </svg>
          <span class="hm-zone" style="left: 66%; top: 25%">F1 · Formation</span>
          <span class="hm-zone" style="left: 26%; top: 43%">H2 · Holding</span>
          <span class="hm-zone hm-zone-nogo" style="left: 82%; top: 61%">No-Go</span>
          <button
            v-for="d in dots"
            :key="d.code"
            type="button"
            class="hm-dot"
            :class="{ 'hm-dot-late': d.late }"
            :style="{ left: d.x + '%', top: d.y + '%', background: d.colour, color: d.ink ? '#14201B' : '#FFFFFF' }"
            :aria-label="d.name + (d.late ? ', late' : ', on time')"
            @mouseenter="picked = d.code"
            @focus="picked = d.code"
            @click="picked = d.code"
          >
            {{ d.code }}
          </button>
          <div v-if="card" class="hm-pop" :style="{ left: Math.min(card.x + 4, 62) + '%', top: Math.min(card.y + 6, 62) + '%' }">
            <strong>{{ card.name }}</strong>
            <span class="hm-muted small">{{ card.next }}</span>
            <span class="hm-chip" :class="card.late ? 'hm-chip-late' : 'hm-chip-ok'">{{ card.late ? '3 min late' : 'On time' }}</span>
          </div>
        </div>
        <div class="hm-scrub">
          <p v-if="card" class="hm-pop-line" aria-live="polite">
            <strong>{{ card.name }}</strong> · {{ card.next }} · <span :class="card.late ? 'text-warning-emphasis' : 'text-success'">{{ card.late ? '3 min late' : 'On time' }}</span>
          </p>
          <label for="hm-scrub" class="small hm-muted">Drag the clock to replay the night</label>
          <input id="hm-scrub" v-model.number="t" type="range" min="0" max="100" class="form-range" />
        </div>
      </div>
    </section>

    <section class="hm-band">
      <div class="hm-wrap">
        <span class="hm-eyebrow">HOW IT WORKS</span>
        <h2 class="hm-h2b">Plan it once. Run it live. Replay it after.</h2>
        <div class="hm-grid3">
          <div class="hm-step"><span class="hm-num" style="background: #0f5c50">1</span><h3>Plan</h3><p>Draw your zones, place every group’s moments on one clock and publish. Import the run sheet you already have (Excel or CSV).</p></div>
          <div class="hm-step"><span class="hm-num" style="background: #f2a541; color: #14201b">2</span><h3>Run</h3><p>Press Start. ICs share their location with one tap; everyone gets their next move, and a “leave now” push at the right time.</p></div>
          <div class="hm-step"><span class="hm-num" style="background: #0b3d35">3</span><h3>Replay</h3><p>Scrub through the night, see who was late and why, and export it for the debrief.</p></div>
        </div>
      </div>
    </section>

    <section class="hm-wrap hm-section">
      <span class="hm-eyebrow">ONE EVENT, THREE VIEWS</span>
      <h2 class="hm-h2b">Everyone sees exactly what they need — and nothing else.</h2>
      <div class="hm-grid3">
        <div class="hm-role hm-role-dark">
          <span class="hm-eyebrow" style="color: #8fd3bf">CONTROL ROOM ON A BIG SCREEN</span>
          <h3>Planners &amp; root</h3>
          <ul><li>Every group on one live map</li><li>Late or off-route groups rise to the top</li><li>Message everyone, or one group</li></ul>
        </div>
        <div class="hm-role">
          <span class="hm-eyebrow">YOUR GROUP’S PHONE</span>
          <h3>ICs (in-charge)</h3>
          <ul><li>One tap to start sharing</li><li>Your next move: where, and by when</li><li>A push when it is time to leave</li></ul>
        </div>
        <div class="hm-role">
          <span class="hm-eyebrow">JUST FOLLOW ALONG</span>
          <h3>Members</h3>
          <ul><li>Your group’s timetable</li><li>Where to be, on a simple map</li><li>Messages from planners</li></ul>
        </div>
      </div>
    </section>

    <section class="hm-privacy">
      <div class="hm-wrap hm-privacy-in">
        <div style="flex: 1 1 280px">
          <span class="hm-eyebrow">YOUR LOCATION, YOUR RULES</span>
          <h2 class="hm-h2">Shared only while it matters.</h2>
        </div>
        <div class="hm-grid3" style="flex: 3 1 560px">
          <div><strong>Only during the event</strong><p>Sharing opens when the planner starts and stops by itself when it ends.</p></div>
          <div><strong>Only with your people</strong><p>Your planners and your own group — no one else, no public map.</p></div>
          <div><strong>Stop any time</strong><p>One tap ends sharing, and your planners see that you stopped.</p></div>
        </div>
      </div>
    </section>

    <section class="hm-cta">
      <div class="hm-wrap text-center">
        <h2 class="hm-h2b text-white">Your next event, calmer.</h2>
        <p class="hm-on-dark">Set up in about ten minutes. Bring the run sheet you already have.</p>
        <div class="d-flex gap-2 justify-content-center flex-wrap">
          <RouterLink :to="{ name: 'signup' }" class="btn btn-light btn-lg">Create an event</RouterLink>
          <RouterLink :to="{ name: 'login' }" class="btn btn-outline-light btn-lg">Log in</RouterLink>
        </div>
        <p v-if="isDev" class="small mt-4 mb-0"><RouterLink to="/polygon" class="hm-on-dark">Demo bench (local dev only)</RouterLink></p>
      </div>
    </section>
  </main>
</template>

<style scoped>
.hm { background: var(--bg-canvas); color: var(--text-primary); }
.hm-wrap { max-width: 1200px; margin: 0 auto; padding: 0 24px; }
.hm-muted { color: var(--text-tertiary); }
.hm-on-dark { color: #b9d4cc; }
.hm-eyebrow { display: block; font-size: 13px; font-weight: 600; letter-spacing: 0.08em; color: var(--brand-primary); margin-bottom: 8px; }
.hm-h1 { font-family: var(--font-display); font-weight: 700; font-size: clamp(32px, 4vw, 44px); letter-spacing: -0.02em; margin: 0 0 4px; }
.hm-h2 { font-family: var(--font-display); font-weight: 700; font-size: 28px; margin: 6px 0; }
.hm-h2b { font-family: var(--font-display); font-weight: 700; font-size: clamp(30px, 3.6vw, 44px); letter-spacing: -0.02em; margin: 0 0 32px; max-width: 820px; }
.hm-h3 { font-size: 18px; font-weight: 600; }

/* signed in */
.hm-head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap; padding: 40px 0 24px; }
.hm-live { display: flex; flex-wrap: wrap; gap: 20px; align-items: center; background: var(--bg-surface); border: 2px solid var(--signal); border-radius: 24px; padding: 24px 28px; margin-bottom: 20px; box-shadow: 0 12px 36px -8px rgba(242, 165, 65, 0.28); }
.hm-live-main { flex: 999 1 420px; min-width: 0; display: flex; flex-direction: column; gap: 6px; }
.hm-also { margin-bottom: 20px; }
.hm-cols { display: flex; flex-wrap: wrap; gap: 24px; align-items: flex-start; padding-bottom: 64px; }
.hm-card { background: var(--bg-surface); border: 1px solid var(--border-subtle); border-radius: 20px; padding: 22px 24px; }
.hm-grow { flex: 999 1 520px; min-width: 0; }
.hm-row { display: flex; align-items: center; gap: 16px; padding: 12px 0; border-top: 1px solid var(--border-subtle); color: inherit; text-decoration: none; }
.hm-row:hover strong { color: var(--brand-primary); }
.hm-tile { width: 64px; flex: none; display: flex; flex-direction: column; align-items: center; padding: 6px 0; border-radius: 14px; background: var(--brand-primary-subtle); color: var(--brand-primary); font-size: 12px; font-weight: 600; }
.hm-tile strong { font-family: var(--font-display); font-size: 24px; color: #0b3d35; line-height: 1.1; }
.hm-join { flex: 1 1 320px; background: #0b3d35; border-radius: 20px; padding: 22px 24px; display: flex; flex-direction: column; gap: 10px; }
.hm-code-input { flex: 1 1 150px; min-width: 0; background: rgba(255, 255, 255, 0.08); border: 1.5px solid #2e8a7a; color: #fff; font-family: var(--font-mono); font-size: 20px; letter-spacing: 0.3em; text-transform: uppercase; }
.hm-code-input::placeholder { color: #7fa79c; }
.hm-chip { display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; white-space: nowrap; align-self: flex-start; }
.hm-chip-info { background: var(--status-info-bg); color: var(--status-info-fg); }
.hm-chip-ok { background: var(--status-success-bg); color: var(--status-success-fg); }
.hm-chip-late { background: var(--status-warning-bg); color: var(--status-warning-fg); }

/* visitor */
.hm-hero { display: flex; flex-wrap: wrap; gap: 48px; align-items: center; padding-top: 48px; padding-bottom: 80px; }
.hm-hero-text { flex: 1 1 420px; min-width: 0; display: flex; flex-direction: column; gap: 24px; }
.hm-kicker { align-self: flex-start; display: inline-flex; align-items: center; gap: 10px; padding: 5px 14px 5px 5px; border-radius: 999px; background: var(--brand-primary-subtle); border: 1px solid #bfe0d8; font-size: 13px; font-weight: 500; color: #0b3d35; }
.hm-kicker-badge { padding: 3px 10px; border-radius: 999px; background: var(--brand-primary); color: #fff; font-size: 12px; }
.hm-display { font-family: var(--font-display); font-weight: 700; font-size: clamp(40px, 5.2vw, 66px); line-height: 1.03; letter-spacing: -0.03em; margin: 0; }
.hm-lead { font-size: 18px; line-height: 1.55; color: var(--text-secondary); max-width: 520px; margin: 0; }
.hm-join-light { background: var(--bg-surface); border: 1px solid var(--border-subtle); border-radius: 16px; padding: 16px 18px 18px; display: flex; flex-direction: column; gap: 10px; }
.hm-boxes { position: relative; display: flex; gap: 8px; }
.hm-box { width: 46px; height: 54px; border-radius: 10px; display: inline-flex; align-items: center; justify-content: center; font-family: var(--font-display); font-weight: 700; font-size: 26px; color: #0b3d35; background: #fff; box-shadow: inset 0 0 0 1px #bfe0d8; }
.hm-box-filled { background: var(--brand-primary-subtle); }
.hm-box-next { box-shadow: inset 0 0 0 2px var(--brand-primary); }
.hm-box-input { position: absolute; inset: 0; opacity: 0; width: 100%; font-size: 16px; }
.hm-box-input:focus-visible + * , .hm-boxes:focus-within { outline: 3px solid #2e8a7a; outline-offset: 4px; border-radius: 12px; }
.hm-demo { flex: 1 1 520px; min-width: 0; background: var(--bg-surface); border: 1px solid var(--border-subtle); border-radius: 28px; overflow: hidden; box-shadow: 0 24px 60px -12px rgba(11, 61, 53, 0.18); }
.hm-demo-head { display: flex; align-items: center; gap: 12px; padding: 16px 20px; flex-wrap: wrap; }
.hm-map { position: relative; aspect-ratio: 600 / 360; background: #efede6; }
.hm-map svg { position: absolute; inset: 0; width: 100%; height: 100%; }
.hm-zone { position: absolute; padding: 3px 8px; border-radius: 6px; background: #fff; font-size: 12px; font-weight: 600; color: var(--brand-primary); }
.hm-zone-nogo { color: var(--status-error-fg); }
.hm-dot { position: absolute; transform: translate(-50%, -50%); width: 36px; height: 36px; padding: 0; border-radius: 999px; border: 3px solid #fff; font-size: 11px; font-weight: 700; box-shadow: 0 2px 6px rgba(0, 0, 0, 0.2); }
.hm-dot-late { box-shadow: 0 0 0 3px #fff, 0 0 0 6px var(--attention-ring); }
.hm-pop { position: absolute; background: #fff; border: 1px solid var(--border-subtle); border-radius: 14px; padding: 12px 14px; display: flex; flex-direction: column; gap: 6px; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12); min-width: 190px; pointer-events: none; }
.hm-scrub { padding: 12px 20px 16px; }
.hm-band { background: var(--bg-surface); padding: 80px 0; }
.hm-section { padding-top: 80px; padding-bottom: 80px; }
.hm-grid3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 24px; }
.hm-step { background: var(--bg-canvas); border-radius: 22px; padding: 28px; }
.hm-step h3, .hm-role h3 { font-family: var(--font-display); font-size: 26px; margin: 14px 0 10px; }
.hm-step p { color: var(--text-secondary); margin: 0; line-height: 1.5; }
.hm-num { width: 44px; height: 44px; border-radius: 999px; color: #fff; display: inline-flex; align-items: center; justify-content: center; font-weight: 600; }
.hm-role { background: var(--bg-surface); border: 1px solid var(--border-subtle); border-radius: 22px; padding: 28px; }
.hm-role ul { padding-left: 20px; margin: 0; color: var(--text-secondary); line-height: 1.7; }
.hm-role-dark { background: #0b3d35; border-color: #0b3d35; color: #fff; }
.hm-role-dark ul { color: #b9d4cc; }
.hm-privacy { background: var(--brand-primary-subtle); padding: 56px 0; }
.hm-privacy-in { display: flex; flex-wrap: wrap; gap: 32px; align-items: center; }
.hm-privacy p { color: var(--text-secondary); margin: 4px 0 0; font-size: 15px; }
.hm-privacy strong { color: #0b3d35; }
.hm-cta { background: #0b3d35; padding: 80px 0; }
.hm-cta .hm-h2b { margin: 0 auto 12px; }
.hm-pop-line { display: none; margin: 0 0 8px; font-size: 14px; }
/* Phone width: the six boxes and Join share one row, and the group card becomes a line under the map */
@media (max-width: 600px) {
  .hm-boxes { gap: 4px; }
  .hm-box { width: 33px; height: 46px; font-size: 20px; }
  .hm-pop { display: none; }
  .hm-pop-line { display: block; }
}
</style>
