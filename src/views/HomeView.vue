<script setup>
// The front door (Planova 2). Visitors: what Planova is, the two jobs people come for (create an event, join one with
// a code) and why their location is safe -- a Z-pattern landing page. Signed in: "Home", with the live event first.
// The phone app never shows this page (the router sends it to My events).
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { getMyEvents, getLiveEventIds, joinEventByCode } from '../services/eventService'
import { ROLE_LABEL, topRole, isMarshal, viewRole } from '../utils/permissions'
import BenchAlert from '../components/BenchAlert.vue'
import SkeletonLoader from '../components/SkeletonLoader.vue'
import KLogo from '../components/kinetic/KLogo.vue'
import KVenueMap from '../components/kinetic/KVenueMap.vue'
import { cachedMyEvents, saveMyEvents } from '../lib/myEventsCache'
import { toast } from '../composables/useNotify'

const auth = useAuthStore()
const router = useRouter()
const isDev = import.meta.env.DEV // the demo bench is only reachable on local dev

// ---------- Join with a code (both views) ----------
// Only letters and digits get in; paste keeps all six.
const code = ref('')
const joinBusy = ref(false)
const joinError = ref('')
const codeFull = computed(() => code.value.length === 6)
function onCode(event) {
  code.value = (event.target.value || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6)
  event.target.value = code.value
  joinError.value = ''
}
async function join() {
  if (!codeFull.value) {
    if (!auth.isLoggedIn) toast('Codes have 6 letters or numbers', 'warning', 2400)
    return
  }
  if (joinBusy.value) return
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
// Opens with the list from the last visit (myEventsCache) and reads a fresh one quietly; the skeleton is only for the
// first load. Signed in with no copy yet: loading from the first paint, or "not in any event yet" flashed first.
const cached = cachedMyEvents(auth.user && auth.user.id)
const events = ref(cached ? cached.events : [])
const liveIds = ref(cached ? cached.liveIds : [])
const loading = ref(auth.isLoggedIn && !cached)
const errorMsg = ref('')
async function load() {
  if (!auth.isLoggedIn) return
  if (!cached) loading.value = true
  try {
    // Both answers first, then the page: the events alone would draw the list while the skeleton is still up, and the
    // list would then jump when the skeleton went away a moment later.
    const mine = await getMyEvents(auth.user.id)
    const live = await getLiveEventIds(mine.map((e) => e.id)).catch(() => [])
    events.value = mine
    liveIds.value = live
    saveMyEvents(auth.user.id, mine, live)
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

// ---------- Visitor: the landing page's small demos (illustrations, not live data) ----------
const navOpen = ref(false)

// The hero map turns by itself; dragging takes over and it carries on from where it was let go.
const spin = ref({ drag: false, angle: 0, since: Date.now() })
let dragStart = null
const spinStyle = computed(() => (spin.value.drag ? { '--a': spin.value.angle.toFixed(1) } : { animationDelay: '-' + ((spin.value.angle / 360) * 30).toFixed(2) + 's' }))
function spinDown(e) {
  try {
    e.currentTarget.setPointerCapture(e.pointerId)
  } catch {
    // the pointer has already gone
  }
  const now = (spin.value.angle + ((Date.now() - spin.value.since) / 30000) * 360) % 360
  dragStart = { x: e.clientX, angle: now }
  spin.value = { drag: true, angle: now, since: 0 }
}
function spinMove(e) {
  if (!dragStart) return
  let angle = (dragStart.angle + (e.clientX - dragStart.x) * 0.6) % 360
  if (angle < 0) angle += 360
  spin.value = { ...spin.value, angle }
}
function spinUp() {
  if (!dragStart) return
  dragStart = null
  spin.value = { drag: false, angle: spin.value.angle, since: Date.now() }
}
onBeforeUnmount(() => (dragStart = null))

const MARQUEE = ['PARADES', 'CAMPUS ORIENTATIONS', 'CONCERTS', 'FUN RUNS', 'FESTIVALS', 'NDP REHEARSALS', 'SCHOOL TRIPS']
const RING = 'PLAN ✦ RUN ✦ REPLAY ✦ PLANOVA ✦ '.split('').map((ch, i, all) => ({ ch: ch === ' ' ? ' ' : ch, turn: (360 / all.length) * i }))

const ROLE_TABS = [
  { id: 'planner', label: 'Planner' },
  { id: 'ic', label: 'In-Charge' },
  { id: 'member', label: 'Member' },
]
const VIEWS = {
  planner: { title: 'Planners & root', pts: ['Every group on one live map', 'Late or off-route groups rise to the top', 'Message everyone, or one group'], note: '' },
  ic: { title: 'In-Charges', pts: ['One tap to start sharing', 'Your next move: where and by when', 'A nudge when it’s time to leave'], note: 'Location is shared only during the event. Stop anytime.' },
  member: { title: 'Members', pts: ['Your group’s timetable', 'Where to be, on a simple map', 'Messages from planners'], note: 'Members are never tracked.' },
}
const role = ref('planner')

// The timeline demo: 10:55 to 11:30, "+5 min" pushes everything after now
const T0 = 655
const T1 = 690
const NOW = 662
const pct = (m) => ((m - T0) / (T1 - T0)) * 100
const shift = ref(0)
const DEMO_PLAN = [
  { name: 'Banana Gang', colour: '#facc15', segs: [[657, 661, 'Mother Ernqi'], [661, 665, 'Walk'], [665, 680, 'Komin Zone']] },
  { name: 'Monkey Party', colour: '#d946ef', segs: [[657, 663, 'Mother Ernqi'], [663, 668, 'Walk'], [668, 682, 'Komin Zone']] },
]
const timeline = computed(() =>
  DEMO_PLAN.map((g) => ({
    name: g.name,
    colour: g.colour,
    bars: g.segs.map(([from, to, label], i) => {
      let a = from
      let b = to
      if (a >= NOW) {
        a += shift.value
        b += shift.value
      } else if (b > NOW) b += shift.value
      const left = pct(a)
      const background = i === 1 ? 'repeating-linear-gradient(45deg,#fff 0 6px,' + g.colour + '55 6px 10px)' : i === 2 ? g.colour : g.colour + '66'
      return { label, style: { left: left.toFixed(2) + '%', width: Math.max(Math.min(pct(b), 100) - left, 0).toFixed(2) + '%', background } }
    }),
  })),
)
const TICKS = [655, 665, 675, 685].map((m) => ({ label: Math.floor(m / 60) + ':' + String(m % 60).padStart(2, '0'), left: pct(m).toFixed(2) + '%' }))
const nowLeft = pct(NOW).toFixed(2) + '%'
function shiftPlan() {
  shift.value = shift.value >= 10 ? 0 : shift.value + 5
}

const FAQ = [
  ['Who is tracked?', 'Only In-Charges, and only while the event is live. They can stop sharing at any time. Members are never on the map.'],
  ['How do people join?', 'Share the 6-character event code or the invite link. Planners can also add people by email or CSV.'],
  ['Can I bring my existing run sheet?', 'Yes. Import a CSV and each row becomes a moment on the plan. You can adjust it on the map.'],
  ['What happens after the event?', 'A replay is kept for 7 days. Scrub through it to compare planned and actual routes, or export it as CSV.'],
]
const faqOpen = ref(0)
const year = new Date().getFullYear()
</script>

<template>
  <!-- ================= Signed in: Home ================= -->
  <div v-if="auth.isLoggedIn" class="k kq">
    <main class="ke2-main hm-in">
      <div class="ke2-greet">
        <div>
          <span class="ey">
            <span v-if="loading" class="skeleton skeleton-line d-inline-block align-middle" style="width: 220px" aria-hidden="true"></span>
            <template v-else-if="liveEvents.length">{{ liveEvents.length === 1 ? 'One event is live' : liveEvents.length + ' events are live' }}</template>
            <template v-else-if="events.length">Nothing is live right now</template>
            <template v-else>You are not in any event yet</template>
          </span>
          <h1>{{ greeting }}<template v-if="firstName">, {{ firstName }}</template></h1>
        </div>
        <span class="sp"></span>
        <RouterLink :to="{ name: 'event-new' }" class="kb kb-ink" data-testid="home-create-event">
          <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>Create event
        </RouterLink>
      </div>

      <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <!-- Live first: one band, ONE main action -->
      <section v-for="ev in liveEvents.slice(0, 1)" :key="ev.id" class="ke2-next hm-live data-in" aria-label="Live now" data-testid="home-live">
        <div class="txt">
          <span class="chip chip-lime"><i class="dot pulse" style="background: var(--ink)"></i>Live now</span>
          <span class="ey hm-role" style="color: var(--lime)">You’re {{ roleLabel(ev) }}</span>
          <h2>{{ ev.name }}</h2>
          <div v-if="ev.venue" class="hm-where">{{ ev.venue }}</div>
          <RouterLink :to="{ name: 'event', params: { id: ev.id, page: 'live' } }" class="kb kb-lime kb-lg hm-open">
            Open live map <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg>
          </RouterLink>
        </div>
        <div class="kl-stage kl-spin" aria-hidden="true"><KVenueMap /></div>
      </section>

      <!-- More than one live at once: the first gets the band, the rest a compact list (one loud thing per screen) -->
      <section v-if="liveEvents.length > 1" class="ke2-list data-in" aria-label="Also live" data-testid="home-also-live">
        <div class="ke2-lh"><h2>Also live · {{ liveEvents.length - 1 }}</h2></div>
        <RouterLink v-for="ev in liveEvents.slice(1)" :key="ev.id" :to="{ name: 'event', params: { id: ev.id, page: 'live' } }" class="ke2-row hm-row">
          <span class="ke2-dt"><b>On</b><span>LIVE</span></span>
          <span style="min-width: 0"><span class="nm text-truncate">{{ ev.name }}</span><span class="mt">{{ [ev.venue, roleLabel(ev)].filter(Boolean).join(' · ') }}</span></span>
          <span><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg></span>
        </RouterLink>
      </section>

      <div class="hm-cols">
        <section class="ke2-list hm-grow" aria-label="Coming up">
          <div class="ke2-lh">
            <h2>Coming up</h2>
            <span class="sp"></span>
            <RouterLink to="/events" class="link">All events</RouterLink>
          </div>
          <SkeletonLoader v-if="loading" :rows="3" label="Loading your events…" />
          <p v-else-if="!upcoming.length" class="mut hm-empty data-in">No upcoming events. Events you create or join show here.</p>
          <template v-else>
            <RouterLink v-for="ev in upcoming" :key="ev.id" :to="{ name: 'event', params: { id: ev.id } }" class="ke2-row hm-row data-in">
              <span class="ke2-dt" :class="{ tbc: !ev.startsAt }"><b>{{ ev.startsAt ? tile(ev.startsAt).day : 'TBC' }}</b><span>{{ ev.startsAt ? tile(ev.startsAt).mon : 'DATE' }}</span></span>
              <span style="min-width: 0">
                <span class="nm text-truncate">{{ ev.name }}</span>
                <span class="mt">{{ [ev.venue, timeOf(ev.startsAt), roleLabel(ev)].filter(Boolean).join(' · ') }}</span>
              </span>
              <span class="hm-trail"><span v-if="ev.isSimulation" class="chip rl-sim">Sim</span><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg></span>
            </RouterLink>
          </template>
        </section>

        <section class="ke2-list hm-join" aria-label="Join an event">
          <div class="ke2-lh"><h2>Join an event</h2></div>
          <label for="home-code" class="lab">Event code</label>
          <div class="row">
            <input id="home-code" :value="code" class="kin hm-code" autocomplete="off" placeholder="e.g. 3MF5Y5" data-testid="home-join-code" @input="onCode" @keydown.enter="join" />
            <button type="button" class="kb kb-ink" :disabled="!codeFull || joinBusy" data-testid="home-join-btn" @click="join">{{ joinBusy ? 'Joining…' : 'Join' }}</button>
          </div>
          <p class="hint" :class="{ 'hm-error': joinError }">{{ joinError || (codeFull ? 'Looks good. Press Join.' : code ? 6 - code.length + ' more to go · letters and digits only' : 'Type the 6-character code your planner sent you.') }}</p>
        </section>
      </div>
    </main>
  </div>

  <!-- ================= Visitor: the landing page ================= -->
  <div v-else class="k kq kl">
    <div class="kl-in">
      <header class="kl-nav2">
        <RouterLink class="kl-brand" to="/" aria-label="Planova home"><KLogo /><span>planova</span></RouterLink>
        <nav class="kl-links" :class="{ open: navOpen }" aria-label="Main">
          <a href="#how" @click="navOpen = false">How it works</a><a href="#features" @click="navOpen = false">Features</a><a href="#faq" @click="navOpen = false">FAQ</a>
        </nav>
        <span class="sp"></span>
        <RouterLink class="kb kb-ghost" :to="{ name: 'login' }">Log in</RouterLink>
        <RouterLink class="kb kb-lime kb-sm" :to="{ name: 'signup' }">Create an event</RouterLink>
        <button type="button" class="ib kl-burger" aria-label="Menu" :aria-expanded="navOpen ? 'true' : 'false'" @click="navOpen = !navOpen">
          <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"></path></svg>
        </button>
      </header>

      
      <h1 class="kl-h1 U">Right place.<br /><span class="hl">Right time.</span></h1>

      <section class="kl-hero">
        <div class="kl-copy">
          <p>Plan where every group should be. Run it live. Everyone sees their next move.</p>
          <div>
            <RouterLink class="kb kb-lime kb-lg" :to="{ name: 'signup' }">Create an event <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg></RouterLink>
          </div>
          <div class="sp"></div>
          <form class="kl-join" aria-label="Join with a code" @submit.prevent="join">
            <input :value="code" placeholder="Have a code?" autocomplete="off" aria-label="Event code" data-testid="visitor-join-code" @input="onCode" @keydown.enter.prevent="join" />
            <button class="ib" type="submit" aria-label="Join event" style="background: var(--ink); color: var(--lime)">
              <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"></path></svg>
            </button>
          </form>
        </div>
        <div class="kl-stage kl-spin" :class="{ drag: spin.drag }" :style="spinStyle" aria-label="3D venue preview. Drag to turn." @pointerdown="spinDown" @pointermove="spinMove" @pointerup="spinUp" @pointercancel="spinUp">
          <KVenueMap labels />
          
        </div>
        <div class="kl-deckw" aria-label="What each person sees">
          <span class="ey">What each person sees</span>
          <div class="kl-deck">
            <div class="kl-card"><span class="ey">Planner · big screen</span><b>2 of 2 groups on plan</b><p>Banana Gang reached Komin Zone</p><span class="chip chip-mint">● On plan</span></div>
            <div class="kl-card"><span class="ey">In-Charge · phone</span><b>Leave now</b><p>Next: Komin Zone by 11:05 · 4 min walk</p><span class="chip chip-ink">Sharing location</span></div>
            <div class="kl-card"><span class="ey">Member · phone</span><b>11:05 · Komin Zone</b><p>Stay with your In-Charge</p><span class="chip" style="background: #fff">You’re on time</span></div>
          </div>
        </div>
      </section>
    </div>

    <section class="kl-band" aria-label="Made for parades, orientations, concerts, fun runs and festivals">
      <div>
        <template v-for="pass in 2" :key="pass">
          <template v-for="word in MARQUEE" :key="pass + word"><span>{{ word }}</span><i>✦</i></template>
        </template>
      </div>
    </section>

    <div class="kl-in">
      <section id="how" class="kl-block">
        <span class="ey">How it works</span>
        <h2 class="kl-h2">Plan it once. Run it live.<br />Replay it after.</h2>
        <div class="kl-steps">
          <article class="kl-step"><div class="big">01</div><h3>Plan</h3><p>Draw zones, place every group on one timeline and publish. Bring your run sheet as a CSV.</p><div class="who"><span class="rlp" style="background: var(--mint)">Planner</span></div></article>
          <article class="kl-step lime"><div class="big">02</div><h3>Run</h3><p>Press Start. In-Charges share location with one tap. Every member gets their next move and a “leave now” nudge.</p><div class="who"><span class="rlp" style="background: #fff">In-Charge</span><span class="rlp" style="background: #fff">Member</span></div></article>
          <article class="kl-step dark"><div class="big">03</div><h3>Replay</h3><p>Scrub through the event, see who was late and why, and export it for the debrief.</p><div class="who"><span class="rlp" style="background: var(--lime); color: var(--ink)">Planner</span></div></article>
        </div>

        <div id="roles" class="kl-views">
          <div>
            <span class="ey" style="color: var(--lime); padding-right: 10px">One event, three views</span>
            <div class="seg" role="tablist" aria-label="Role" style="margin-top: 16px">
              <button v-for="r in ROLE_TABS" :key="r.id" type="button" role="tab" :aria-pressed="role === r.id ? 'true' : 'false'" :aria-selected="role === r.id ? 'true' : 'false'" @click="role = r.id">{{ r.label }}</button>
            </div>
            <h3>{{ VIEWS[role].title }}</h3>
            <ul><li v-for="p in VIEWS[role].pts" :key="p">{{ p }}</li></ul>
            <div v-if="VIEWS[role].note" class="kl-note"><i class="dot" style="background: var(--mint)"></i>{{ VIEWS[role].note }}</div>
          </div>
          <div class="kl-vis">
            <div v-if="role === 'planner'" class="kl-board">
              <div class="row" style="margin-bottom: 8px"><b class="U" style="font-size: 16px">Banana Party</b><span class="sp"></span><span class="chip chip-ink"><i class="dot pulse" style="background: var(--lime)"></i>Live 11:03</span></div>
              <div class="kl-brow"><i class="dot" style="background: #facc15; width: 12px; height: 12px"></i><b style="flex: 1">Banana Gang</b><span class="mut">Komin Zone</span><span class="chip chip-mint">On plan</span></div>
              <div class="kl-brow"><i class="dot" style="background: #d946ef; width: 12px; height: 12px"></i><b style="flex: 1">Monkey Party</b><span class="mut">Neil Rd</span><span class="chip chip-warn">3 min late</span></div>
              <div class="kl-brow"><span class="mut" style="flex: 1">Next frame · +0:06</span><span class="kb kb-ink kb-sm" style="height: 32px">+5 min</span></div>
            </div>
            <div v-else-if="role === 'ic'" class="kl-phone">
              <div class="notch"></div>
              <span class="ey">Next move</span>
              <div class="U" style="font-size: 30px; font-weight: 800; margin: 8px 0 4px">Leave now</div>
              <div class="mut" style="font-size: 14px">Komin Zone by 11:05 · 4 min</div>
              <div class="row" style="margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line)"><b style="flex: 1; font-size: 14px">Sharing location</b><span class="tog" aria-pressed="true" style="display: inline-block"></span></div>
            </div>
            <div v-else class="kl-phone" style="background: var(--lime)">
              <div class="notch" style="background: rgba(10, 31, 23, 0.15)"></div>
              <span class="ey">Banana Gang · today</span>
              <div class="kl-sched" style="margin-top: 10px">
                <div><b>10:57</b><span>Mother Ernqi</span><span>✓</span></div>
                <div><b>11:05</b><span><b>Komin Zone</b></span><span class="chip chip-ink" style="height: 22px">Now</span></div>
                <div><b>11:20</b><span>Free time</span><span></span></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section id="features" class="kl-block">
        <div class="kl-feat">
          <div>
            <span class="ey">The live timeline</span>
            <h2 class="kl-h2">Running late?<br />Shift once.</h2>
            <p class="lead">Push the plan by a few minutes and every group’s times update on every phone. No group chats, no re-sending run sheets.</p>
            <div class="kl-pts"><span><i>✓</i>New times reach each group instantly</span><span><i>✓</i>Late or off-route groups rise to the top</span><span><i>✓</i>Undo in one tap</span></div>
          </div>
          <div class="kl-tl" aria-label="Timeline demo">
            <div class="kl-tl-ax"><span v-for="t in TICKS" :key="t.label" :style="{ left: t.left }">{{ t.label }}</span></div>
            <div v-for="r in timeline" :key="r.name" class="kl-tl-row">
              <b><i class="dot" :style="{ background: r.colour }"></i>{{ r.name }}</b>
              <div class="kl-tl-tr"><span class="kl-now" :style="{ left: nowLeft }"></span><span v-for="b in r.bars" :key="b.label" class="kl-bar" :style="b.style">{{ b.label }}</span></div>
            </div>
            <div class="kl-tl-bot">
              <button type="button" class="kb kb-ink" @click="shiftPlan">{{ shift >= 10 ? 'Undo' : '+5 min' }}</button>
              <span v-if="shift > 0" class="kl-sent">✓ New times sent to 2 groups · +{{ shift }} min</span>
            </div>
          </div>
        </div>
      </section>

      <section class="kl-block">
        <div class="kl-feat kl-feat--rev">
          <div class="kl-lmap" aria-label="Live map demo">
            <svg viewBox="0 0 400 300" aria-hidden="true">
              <rect width="400" height="300" fill="#f3f1ea"></rect>
              <path d="M-10 214 C 90 196, 210 176, 410 140" stroke="#fff" stroke-width="16" fill="none"></path>
              <path d="M168 -10 C 176 90, 182 190, 194 310" stroke="#fff" stroke-width="12" fill="none"></path>
              <path d="M308 -10 C 302 100, 294 200, 282 310" stroke="#fff" stroke-width="13" fill="none"></path>
              <polygon points="66,58 146,54 152,122 76,128" fill="#9be7c4" fill-opacity=".65" stroke="#0b3d2e" stroke-width="2"></polygon>
              <polygon points="216,142 282,138 286,204 224,208" fill="#c6f36b" fill-opacity=".8" stroke="#0a1f17" stroke-width="2.5"></polygon>
              <polygon points="276,38 352,44 346,92 282,88" fill="#ff8a65" fill-opacity=".35" stroke="#c2410c" stroke-width="2" stroke-dasharray="6 4"></polygon>
              <path d="M100 92 C 140 120, 170 150, 248 172" stroke="#a16207" stroke-width="2.5" stroke-dasharray="2 7" stroke-linecap="round" fill="none"></path>
              <path d="M124 110 C 160 150, 200 190, 258 186" stroke="#a21caf" stroke-width="2.5" stroke-dasharray="2 7" stroke-linecap="round" fill="none"></path>
              <g font-family="Manrope, sans-serif" font-size="9" font-weight="800" fill="#0a1f17"><text x="74" y="70">HOLDING</text><text x="230" y="200">STAGE</text><text x="286" y="56" fill="#c2410c">NO-GO</text></g>
            </svg>
            <span class="kl-gd g1"><i></i><b>Banana Gang</b></span>
            <span class="kl-gd g2"><i></i><b>Monkey Party</b></span>
            <span class="kl-alert">Monkey Party is off route</span>
            <div class="kl-tools"><span class="chip chip-mint">Zone</span><span class="chip chip-lime">Stage</span><span class="chip chip-warn">No-go</span></div>
          </div>
          <div>
            <span class="ey">Zones &amp; live map</span>
            <h2 class="kl-h2">Draw the venue.<br />Watch it move.</h2>
            <p class="lead">Mark stages, holding areas and no-go zones right on the map. Once you’re live, every group moves on the same map in real time.</p>
            <div class="kl-pts"><span><i>✓</i>Draw zones in a few taps, or add a floor plan</span><span><i>✓</i>Live positions from each group’s In-Charge</span><span><i>✓</i>Alerts when a group goes off route</span></div>
          </div>
        </div>
      </section>

      <section id="faq" class="kl-block" style="border-bottom: 0">
        <div class="kl-faq">
          <div><span class="ey">FAQ</span><h2 class="kl-h2">Good to know</h2></div>
          <div>
            <div v-for="([q, a], i) in FAQ" :key="q" class="kl-q">
              <button type="button" :aria-expanded="faqOpen === i ? 'true' : 'false'" @click="faqOpen = faqOpen === i ? -1 : i">{{ q }}<i>+</i></button>
              <p v-if="faqOpen === i">{{ a }}</p>
            </div>
          </div>
        </div>
      </section>

      <section class="kl-cta2">
        <h2>Plan your <br /> next event<br /></h2>
        <div class="row" style="margin-top: 34px; flex-wrap: wrap">
          <RouterLink class="kb kb-lime kb-lg" :to="{ name: 'signup' }">Create an event <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg></RouterLink>
          <RouterLink class="kb kb-lg" :to="{ name: 'login' }" style="color: #fff; box-shadow: 0 0 0 1.5px rgba(255, 255, 255, 0.5) inset">Log in</RouterLink>
        </div>
        <div class="kl-ring2" aria-hidden="true"><span v-for="(g, i) in RING" :key="i" :style="{ transform: 'rotate(' + g.turn + 'deg)' }">{{ g.ch }}</span></div>
      </section>
      <footer class="kl-foot2">
        <span class="row"><KLogo /> © {{ year }} Planova</span>
        <nav aria-label="Footer"><a href="#how">How it works</a><a href="#features">Features</a><a href="#faq">FAQ</a><RouterLink v-if="isDev" to="/polygon">Demo bench (local dev only)</RouterLink></nav>
        <span>Map data © OneMap</span>
      </footer>
    </div>
  </div>
</template>

<style scoped>
/* The signed-in Home uses the Events page's blocks; these only cover what that page does not have */
.hm-in { overflow: visible; max-width: 1440px; margin: 0 auto; padding-top: 22px; }
.hm-live { margin-bottom: 16px; }
.hm-role { display: block; margin-top: 16px; }
.hm-where { color: var(--on-forest-body); font-size: 15px; }
.hm-open { margin-top: 24px; }
.hm-cols { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
.hm-grow { flex: 999 1 520px; min-width: 0; }
.hm-join { flex: 1 1 320px; padding-bottom: 24px; }
.hm-row { grid-template-columns: 72px minmax(0, 1fr) auto; }
.hm-trail { display: flex; align-items: center; gap: 10px; }
.hm-empty { padding: 20px 0; margin: 0; }
.hm-code { font: 700 16px Unbounded, sans-serif; letter-spacing: 0.14em; text-transform: uppercase; min-width: 0; }
.hm-code::placeholder { font: 600 15px Manrope, sans-serif; letter-spacing: 0; text-transform: none; }
.hm-error { color: var(--danger); font-weight: 700; }
</style>
