<script setup>
// The event's Attendance page (037_attendance.sql). The organisers (root / planners) choose how roll calls are taken:
//   manual  the group's IC ticks people present or excused by hand
//   qr      for when ICs are not to be trusted with it: the IC's screen shows a QR code that changes every
//           5 seconds and each person scans it with the app. Only planners and the root can mark anyone by hand.
// Who does what here:
//   Root / planners    : choose the mode; run and close a roll call for any group; every group's history
//   A group's IC/admin : run their own group's roll calls
//   Marshals           : every group's open roll calls and history (read only)
//   Anyone in a group  : scan the QR (QR mode); see whether they were marked; their own history
// This component only shows things: it emits what was asked and the event page (EventView.vue) calls the database.
import { ref, computed, watch, onUnmounted } from 'vue'
import QRCode from 'qrcode'
import { formatDayTime, formatTime } from '../utils/time'
import BenchAlert from './BenchAlert.vue'
import QrScanner from './QrScanner.vue'

const props = defineProps({
  groups: { type: Array, required: true },
  members: { type: Array, required: true },
  me: { type: Object, default: null },
  canManage: { type: Boolean, default: false }, // root or planner
  seesWholeEvent: { type: Boolean, default: false }, // root, planner or marshal
  mode: { type: String, default: 'manual' }, // the event's mode: 'manual' | 'qr'
  rollcalls: { type: Array, required: true }, // useAttendance().rollcalls
  checkins: { type: Array, required: true },
  qr: { type: Object, default: null }, // { rollcallId, text, secondsLeft }
  now: { type: Number, required: true },
  busy: { type: Boolean, default: false },
  errorMsg: { type: String, default: '' },
  scanMessage: { type: String, default: '' }, // an old QR, another group's...
})
const emit = defineEmits(['set-mode', 'open', 'close', 'mark', 'scan', 'show-qr', 'hide-qr', 'dismiss-error'])

const MINUTES = [5, 10, 15, 30, 60]
const MODE_LABEL = { manual: 'By hand', qr: 'QR' }

const groupById = computed(() => Object.fromEntries(props.groups.map((g) => [g.id, g])))
const myGroup = computed(() => (props.me && props.me.groupId ? groupById.value[props.me.groupId] || null : null))
const membersOf = (groupId) => props.members.filter((m) => m.groupId === groupId)

// Groups whose roll calls I run: every group (root / planners), or my own as its IC or admin
const runnable = computed(() => {
  if (props.canManage) return props.groups
  if (myGroup.value && (props.me.isIC || props.me.isAdmin)) return [myGroup.value]
  return []
})
const runsMyGroup = computed(() => !!myGroup.value && runnable.value.some((g) => g.id === myGroup.value.id))
// Groups whose check-ins I see in full
const seesAllOf = (groupId) => props.seesWholeEvent || runnable.value.some((g) => g.id === groupId)

const two = (n) => String(n).padStart(2, '0')
function timeLeft(date) {
  const s = Math.max(0, Math.round((date.getTime() - props.now) / 1000))
  return Math.floor(s / 60) + ':' + two(s % 60)
}

// ---------- The mode (root / planners) ----------
const modeChoice = ref(props.mode)
watch(
  () => props.mode,
  (m) => (modeChoice.value = m),
)

// ---------- Me, in my group's roll call (anyone in a group who does not run it) ----------
const myOpen = computed(() => (myGroup.value ? props.rollcalls.find((r) => r.open && r.groupId === myGroup.value.id) || null : null))
const myCheckin = computed(() =>
  myOpen.value && props.me ? props.checkins.find((c) => c.rollcallId === myOpen.value.id && c.userId === props.me.id) || null : null,
)
const myOpenLeft = computed(() => (myOpen.value ? timeLeft(myOpen.value.closesAt) : ''))
const scanning = ref(false)
const cameraError = ref('')
function startScan() {
  cameraError.value = ''
  scanning.value = true
}
function onCameraError(message) {
  scanning.value = false
  cameraError.value = message
}
// In: put the camera away
watch(myCheckin, (c) => {
  if (c) scanning.value = false
})
// The roll call closed while scanning
watch(myOpen, (r) => {
  if (!r) scanning.value = false
})

// ---------- Running a roll call ----------
const selectedGroupId = ref('')
// Start on a group that has a roll call open, else my own group, else the first
watch(
  runnable,
  (list) => {
    if (list.some((g) => g.id === selectedGroupId.value)) return
    const withOpen = list.find((g) => props.rollcalls.some((r) => r.open && r.groupId === g.id))
    selectedGroupId.value = (withOpen || (runsMyGroup.value ? myGroup.value : null) || list[0] || { id: '' }).id
  },
  { immediate: true },
)
const selectedGroup = computed(() => groupById.value[selectedGroupId.value] || null)
const running = computed(() => props.rollcalls.find((r) => r.open && r.groupId === selectedGroupId.value) || null)
const runningLeft = computed(() => (running.value ? timeLeft(running.value.closesAt) : ''))
const isQr = computed(() => !!running.value && running.value.mode === 'qr')
// In QR mode only the root and planners mark by hand
const canMark = computed(() => !!running.value && (!isQr.value || props.canManage))

// The QR on screen follows the QR roll call being run
watch(
  () => (isQr.value ? running.value.id : null),
  (id) => emit(id ? 'show-qr' : 'hide-qr', id),
  { immediate: true },
)
onUnmounted(() => emit('hide-qr'))

const qrShown = computed(() => (props.qr && running.value && props.qr.rollcallId === running.value.id ? props.qr : null))
const qrImage = ref('')
watch(
  () => (qrShown.value ? qrShown.value.text : ''),
  async (text) => {
    if (!text) {
      qrImage.value = ''
      return
    }
    try {
      const url = await QRCode.toDataURL(text, { width: 480, margin: 2, errorCorrectionLevel: 'M' })
      if (qrShown.value && qrShown.value.text === text) qrImage.value = url
    } catch (error) {
      console.log(error.message)
    }
  },
)
const qrBar = computed(() => (qrShown.value ? Math.round((qrShown.value.secondsLeft / 5) * 100) : 0))
const big = ref(false) // the QR full screen, easier to scan from a few steps away

const newTitle = ref('')
const newMinutes = ref(10)
function start() {
  emit('open', { groupId: selectedGroupId.value, title: newTitle.value, minutes: newMinutes.value })
  newTitle.value = ''
}

// Everyone in the group, sorted into not yet / present / excused
const roster = computed(() => {
  const out = { waiting: [], present: [], excused: [] }
  if (!running.value) return out
  const byUser = Object.fromEntries(props.checkins.filter((c) => c.rollcallId === running.value.id).map((c) => [c.userId, c]))
  for (const m of membersOf(running.value.groupId)) {
    const c = byUser[m.id]
    const row = { m, at: c ? formatTime(c.at) : '', how: c && c.method === 'scan' ? 'scanned' : 'by hand' }
    if (!c) out.waiting.push(row)
    else if (c.status === 'present') out.present.push(row)
    else out.excused.push(row)
  }
  return out
})
const rosterTotal = computed(() => roster.value.waiting.length + roster.value.present.length + roster.value.excused.length)

function mark(m, status) {
  emit('mark', { id: running.value.id, userId: m.id, status })
}

// ---------- Every group's open roll calls (staff) ----------
function countsOf(r) {
  const list = props.checkins.filter((c) => c.rollcallId === r.id)
  const present = list.filter((c) => c.status === 'present').length
  const excused = list.length - present
  const total = membersOf(r.groupId).length
  return { present, excused, absent: Math.max(total - list.length, 0), total, byHand: list.filter((c) => c.method === 'manual').length }
}
const openAll = computed(() =>
  props.rollcalls
    .filter((r) => r.open)
    .map((r) => ({ r, group: groupById.value[r.groupId], counts: countsOf(r), left: timeLeft(r.closesAt) }))
    .filter((x) => x.group),
)

// ---------- History: closed roll calls ----------
const history = computed(() =>
  props.rollcalls
    .filter((r) => !r.open && groupById.value[r.groupId])
    .slice(0, 20)
    .map((r) => {
      const group = groupById.value[r.groupId]
      const all = seesAllOf(r.groupId)
      const list = props.checkins.filter((c) => c.rollcallId === r.id)
      const mine = props.me ? list.find((c) => c.userId === props.me.id) : null
      const absentNames = all
        ? membersOf(r.groupId)
            .filter((m) => !list.some((c) => c.userId === m.id))
            .map((m) => m.display_name)
        : []
      return {
        r,
        group,
        when: formatDayTime(r.openedAt),
        all,
        counts: all ? countsOf(r) : null,
        absentNames,
        mine: mine ? (mine.status === 'present' ? 'Present' : 'Excused') : 'Absent',
      }
    }),
)
</script>

<template>
  <div>
    <BenchAlert v-if="errorMsg" data-testid="attendance-error" @dismiss="$emit('dismiss-error')">{{ errorMsg }}</BenchAlert>

    <!-- ========== How attendance is taken (root / planners) ========== -->
    <section v-if="canManage" class="card mb-3" data-testid="attendance-mode">
      <div class="card-body">
        <h2 class="h6">How attendance is taken</h2>
        <div class="form-check">
          <input id="att-mode-manual" v-model="modeChoice" class="form-check-input" type="radio" value="manual" :disabled="busy" @change="$emit('set-mode', 'manual')" />
          <label class="form-check-label" for="att-mode-manual">
            <strong>By hand.</strong> <span class="text-muted small">The IC ticks who is there.</span>
          </label>
        </div>
        <div class="form-check">
          <input id="att-mode-qr" v-model="modeChoice" class="form-check-input" type="radio" value="qr" :disabled="busy" data-testid="attendance-mode-qr" @change="$emit('set-mode', 'qr')" />
          <label class="form-check-label" for="att-mode-qr">
            <strong>QR.</strong>
            <span class="text-muted small">
              Everyone scans the QR code on the IC's screen. The code changes every 5 seconds, so a copy sent to someone else
              stops working. Only planners can mark people by hand.
            </span>
          </label>
        </div>
        <p class="form-text mb-0">Changes apply to new roll calls.</p>
      </div>
    </section>

    <!-- ========== My group's roll call (anyone in a group who does not run it) ========== -->
    <section v-if="myGroup && !runsMyGroup" class="card mb-3" data-testid="attendance-me">
      <div class="card-body">
        <h2 class="h6 mb-1">Roll call · {{ myGroup.name }}</h2>
        <p v-if="!myOpen" class="text-muted small mb-0" data-testid="attendance-none-open">
          No roll call is open for your group.
        </p>
        <p v-else-if="myCheckin" class="mb-0" :class="myCheckin.status === 'present' ? 'text-success' : 'text-secondary'" data-testid="attendance-done">
          <strong>{{ myCheckin.status === 'present' ? '✓ You are marked present' : 'You are marked excused' }}</strong>
          for {{ myOpen.title }} at {{ formatTime(myCheckin.at) }}.
        </p>
        <p v-else-if="myOpen.mode === 'manual'" class="small mb-0" data-testid="attendance-wait">
          <strong>{{ myOpen.title }}</strong> is open · closes in {{ myOpenLeft }}. Your IC is marking attendance. Let them see
          you.
        </p>
        <template v-else>
          <p class="small mb-2">
            <strong>{{ myOpen.title }}</strong> is open · closes in {{ myOpenLeft }}. Scan the QR code on your IC's screen.
          </p>
          <template v-if="scanning">
            <QrScanner :paused="busy" @scan="$emit('scan', $event)" @error="onCameraError" />
            <p v-if="busy" class="small text-center mt-2 mb-0">Checking…</p>
            <p v-else-if="scanMessage" class="text-danger small text-center mt-2 mb-0" role="alert" data-testid="attendance-scan-error">{{ scanMessage }}</p>
            <p v-else class="small text-muted text-center mt-2 mb-0">Point the camera at the QR code.</p>
            <div class="text-center mt-2">
              <button type="button" class="btn btn-sm btn-outline-secondary" @click="scanning = false">Cancel</button>
            </div>
          </template>
          <template v-else>
            <button type="button" class="btn btn-primary btn-lg w-100 scan-btn" data-testid="attendance-scan" @click="startScan">Scan QR code</button>
            <p v-if="cameraError" class="text-danger small mt-2 mb-0" role="alert">{{ cameraError }}</p>
            <p v-else class="form-text mb-0">If you cannot scan, tell your IC. A planner can mark you present.</p>
          </template>
        </template>
      </div>
    </section>
    <p v-else-if="!myGroup && !runnable.length && !seesWholeEvent" class="text-muted">
      You are not in a group. Roll calls are taken by group.
    </p>

    <!-- ========== Take attendance (root / planners, a group's IC or admin) ========== -->
    <section v-if="runnable.length" class="card mb-3" data-testid="attendance-run">
      <div class="card-body">
        <div class="d-flex flex-wrap align-items-center gap-2 mb-2">
          <h2 class="h6 mb-0 me-auto">Take attendance</h2>
          <select
            v-if="runnable.length > 1"
            v-model="selectedGroupId"
            class="form-select form-select-sm w-auto"
            aria-label="Group"
            data-testid="attendance-group"
          >
            <option v-for="g in runnable" :key="g.id" :value="g.id">{{ g.name }}</option>
          </select>
          <span v-else-if="selectedGroup" class="text-muted small">{{ selectedGroup.name }}</span>
        </div>

        <!-- Nothing open: start one -->
        <form v-if="!running && selectedGroup" class="row g-2 align-items-end" @submit.prevent="start">
          <div class="col-12 col-sm">
            <label class="form-label small mb-0" for="att-title">Name (optional)</label>
            <input id="att-title" v-model.trim="newTitle" class="form-control" maxlength="60" placeholder="e.g. Morning muster" data-testid="attendance-title" />
          </div>
          <div class="col-6 col-sm-auto">
            <label class="form-label small mb-0" for="att-minutes">Stays open for</label>
            <select id="att-minutes" v-model.number="newMinutes" class="form-select">
              <option v-for="n in MINUTES" :key="n" :value="n">{{ n }} min</option>
            </select>
          </div>
          <div class="col-6 col-sm-auto">
            <button type="submit" class="btn btn-success w-100" :disabled="busy" data-testid="attendance-start">Start roll call</button>
          </div>
          <p class="form-text col-12 mb-0">
            Mode: <strong>{{ MODE_LABEL[mode] }}</strong> (set by the planners).
            {{ mode === 'qr' ? 'Your screen shows a QR code. Your group scans it.' : 'You tick who is there.' }}
          </p>
        </form>

        <!-- Running -->
        <template v-else-if="running">
          <div class="small text-muted mb-2">
            {{ running.title }} · {{ MODE_LABEL[running.mode] }} · closes in {{ runningLeft }}
          </div>

          <!-- QR mode: the QR -->
          <div v-if="isQr" class="text-center qr-box" :class="{ 'qr-big': big }" data-testid="attendance-qr-box">
            <div v-if="big" class="small text-muted mb-2">{{ running.title }} · {{ selectedGroup.name }}</div>
            <img v-if="qrImage" :src="qrImage" alt="Attendance QR code: scan it with the app" class="qr-img" data-testid="attendance-qr" />
            <div v-else class="qr-img qr-wait">Loading…</div>
            <div class="progress qr-bar mx-auto mt-2" role="progressbar" :aria-valuenow="qrShown ? qrShown.secondsLeft : 0" aria-valuemin="0" aria-valuemax="5" aria-label="Seconds until the QR code changes">
              <div class="progress-bar" :style="{ width: qrBar + '%' }"></div>
            </div>
            <div class="small text-muted mt-1">Changes every 5 seconds · {{ roster.present.length }} of {{ rosterTotal }} present</div>
            <div class="d-flex justify-content-center gap-2 mt-2">
              <button type="button" class="btn btn-sm btn-outline-secondary" @click="big = !big">{{ big ? 'Smaller' : 'Show big' }}</button>
              <button v-if="!big" type="button" class="btn btn-sm btn-outline-danger" :disabled="busy" data-testid="attendance-close" @click="$emit('close', running.id)">
                Close roll call
              </button>
            </div>
          </div>
          <div v-else class="d-flex justify-content-end">
            <button type="button" class="btn btn-sm btn-outline-danger" :disabled="busy" data-testid="attendance-close" @click="$emit('close', running.id)">
              Close roll call
            </button>
          </div>

          <p class="mt-3 mb-2" data-testid="attendance-count">
            <strong>{{ roster.present.length }} of {{ rosterTotal }}</strong> present<span v-if="roster.excused.length"> · {{ roster.excused.length }} excused</span>
            · {{ roster.waiting.length }} not yet
          </p>
          <p v-if="isQr && !canMark" class="small text-muted">
            Only planners can mark people by hand in a QR roll call. Anyone who cannot scan should tell a planner.
          </p>
          <div class="row g-3">
            <div class="col-12 col-md-6">
              <h3 class="h6 small text-uppercase text-muted">Not yet</h3>
              <p v-if="!roster.waiting.length" class="small text-success">Everyone is marked.</p>
              <ul class="list-group list-group-flush">
                <li v-for="w in roster.waiting" :key="w.m.id" class="list-group-item px-0 d-flex align-items-center gap-2" :data-testid="'att-waiting-' + w.m.username">
                  <span class="me-auto text-truncate">{{ w.m.display_name }}</span>
                  <template v-if="canMark">
                    <button type="button" class="btn btn-sm btn-outline-success" :disabled="busy" :data-testid="'att-mark-' + w.m.username" @click="mark(w.m, 'present')">Present</button>
                    <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" @click="mark(w.m, 'excused')">Excused</button>
                  </template>
                </li>
              </ul>
            </div>
            <div class="col-12 col-md-6">
              <h3 class="h6 small text-uppercase text-muted">Present</h3>
              <ul class="list-group list-group-flush">
                <li v-for="p in roster.present" :key="p.m.id" class="list-group-item px-0 d-flex align-items-center gap-2" :data-testid="'att-present-' + p.m.username">
                  <span class="text-success" aria-hidden="true">✓</span>
                  <span class="me-auto text-truncate">{{ p.m.display_name }}</span>
                  <span class="small text-muted text-nowrap">{{ p.at }} · {{ p.how }}</span>
                  <button v-if="canMark" type="button" class="btn btn-sm btn-link text-muted p-0" :disabled="busy" @click="mark(p.m, null)">Undo</button>
                </li>
              </ul>
              <template v-if="roster.excused.length">
                <h3 class="h6 small text-uppercase text-muted mt-3">Excused</h3>
                <ul class="list-group list-group-flush">
                  <li v-for="x in roster.excused" :key="x.m.id" class="list-group-item px-0 d-flex align-items-center gap-2">
                    <span class="me-auto text-truncate">{{ x.m.display_name }}</span>
                    <button v-if="canMark" type="button" class="btn btn-sm btn-link text-muted p-0" :disabled="busy" @click="mark(x.m, null)">Undo</button>
                  </li>
                </ul>
              </template>
            </div>
          </div>
        </template>
      </div>
    </section>

    <!-- ========== Every group's open roll calls (root, planners, marshals) ========== -->
    <section v-if="seesWholeEvent" class="card mb-3" data-testid="attendance-open-all">
      <div class="card-body">
        <h2 class="h6">Open now</h2>
        <p v-if="!openAll.length" class="text-muted small mb-0">No roll call is open in any group.</p>
        <ul v-else class="list-group list-group-flush">
          <li v-for="x in openAll" :key="x.r.id" class="list-group-item px-0 d-flex flex-wrap align-items-center gap-2">
            <span class="dot" :style="{ backgroundColor: x.group.colour }" aria-hidden="true"></span>
            <span class="me-auto">
              <strong>{{ x.group.name }}</strong> · {{ x.r.title }}
              <span class="small text-muted d-block">{{ x.r.mode === 'qr' ? 'QR' : 'By hand' }} · closes in {{ x.left }}</span>
            </span>
            <span class="badge text-bg-light border">{{ x.counts.present }}/{{ x.counts.total }} present</span>
            <span v-if="x.r.mode === 'qr' && x.counts.byHand" class="badge text-bg-warning" title="Marked by hand, not scanned">{{ x.counts.byHand }} by hand</span>
            <button v-if="canManage && x.r.groupId !== selectedGroupId" type="button" class="btn btn-sm btn-outline-primary" @click="selectedGroupId = x.r.groupId">
              Open
            </button>
          </li>
        </ul>
      </div>
    </section>

    <!-- ========== History ========== -->
    <section class="card" data-testid="attendance-history">
      <div class="card-body">
        <h2 class="h6">Past roll calls</h2>
        <p v-if="!history.length" class="text-muted small mb-0">None yet.</p>
        <ul v-else class="list-group list-group-flush">
          <li v-for="h in history" :key="h.r.id" class="list-group-item px-0">
            <div class="d-flex flex-wrap align-items-center gap-2">
              <span class="dot" :style="{ backgroundColor: h.group.colour }" aria-hidden="true"></span>
              <span class="me-auto">
                <strong>{{ h.r.title }}</strong> · {{ h.group.name }}
                <span class="small text-muted d-block">{{ h.when }} · {{ h.r.mode === 'qr' ? 'QR' : 'by hand' }}</span>
              </span>
              <template v-if="h.all">
                <span class="badge text-bg-success">{{ h.counts.present }} present</span>
                <span v-if="h.counts.excused" class="badge text-bg-secondary">{{ h.counts.excused }} excused</span>
                <span class="badge" :class="h.counts.absent ? 'text-bg-danger' : 'text-bg-light border'">{{ h.counts.absent }} absent</span>
              </template>
              <span v-else class="badge" :class="h.mine === 'Present' ? 'text-bg-success' : h.mine === 'Excused' ? 'text-bg-secondary' : 'text-bg-danger'">
                {{ h.mine }}
              </span>
            </div>
            <details v-if="h.all && h.absentNames.length" class="small mt-1">
              <summary>Who was absent</summary>
              {{ h.absentNames.join(', ') }}
            </details>
          </li>
        </ul>
        <p class="form-text mb-0 mt-2">Absent: people in the group now who were not marked.</p>
      </div>
    </section>
  </div>
</template>

<style scoped>
.scan-btn {
  max-width: 22rem;
}
.qr-box {
  border: 1px solid var(--bs-border-color);
  border-radius: 0.75rem;
  padding: 1rem;
  background: #fff; /* a QR reads best dark on white, also in dark mode */
  color: var(--ink);
}
.qr-img {
  width: min(100%, 18rem);
  aspect-ratio: 1;
  image-rendering: pixelated;
}
.qr-wait {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--muted);
}
.qr-bar {
  height: 0.4rem;
  max-width: 16rem;
}
.qr-bar .progress-bar {
  transition: width 1s linear;
}
/* "Show big": the QR fills the screen, easier to scan from a few steps away */
.qr-big {
  position: fixed;
  inset: 0;
  z-index: 1080;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  border-radius: 0;
}
.qr-big .qr-img {
  width: min(90vw, 70vh);
}
.qr-big .qr-bar {
  width: min(90vw, 70vh);
  max-width: none;
  height: 0.75rem;
}
.dot {
  display: inline-block;
  width: 0.7rem;
  height: 0.7rem;
  border-radius: 50%;
  flex-shrink: 0;
}
</style>
