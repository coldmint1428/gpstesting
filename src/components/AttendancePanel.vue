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
  <div class="kp-stack">
    <BenchAlert v-if="errorMsg" data-testid="attendance-error" @dismiss="$emit('dismiss-error')">{{ errorMsg }}</BenchAlert>

    <!-- ========== How attendance is taken (root / planners) ========== -->
    <section v-if="canManage" class="kp-inline" style="flex-wrap: wrap" data-testid="attendance-mode">
      <h2 class="kp-label mb-0">New roll calls</h2>
      <div class="kp-seg" role="radiogroup" aria-label="How attendance is taken">
        <input id="att-mode-manual" v-model="modeChoice" type="radio" value="manual" :disabled="busy" @change="$emit('set-mode', 'manual')" />
        <label for="att-mode-manual">By hand</label>
        <input id="att-mode-qr" v-model="modeChoice" type="radio" value="qr" :disabled="busy" data-testid="attendance-mode-qr" @change="$emit('set-mode', 'qr')" />
        <label for="att-mode-qr">QR code</label>
      </div>
      <span class="small text-muted">{{ modeChoice === 'qr' ? 'Everyone scans the IC’s screen. The code changes every 5 s.' : 'The IC ticks who is there.' }}</span>
    </section>

    <!-- ========== My group's roll call (anyone in a group who does not run it) ========== -->
    <section v-if="myGroup && !runsMyGroup" class="kp-card" data-testid="attendance-me">
      <h2 class="kp-title mb-2">{{ myGroup.name }}</h2>
      <p v-if="!myOpen" class="text-muted mb-0" data-testid="attendance-none-open">No roll call is open.</p>
      <p v-else-if="myCheckin" class="mb-0" :class="myCheckin.status === 'present' ? 'text-success' : 'text-secondary'" data-testid="attendance-done">
        <strong>{{ myCheckin.status === 'present' ? '✓ You are marked present' : 'You are marked excused' }}</strong>
        for {{ myOpen.title }} at {{ formatTime(myCheckin.at) }}.
      </p>
      <p v-else-if="myOpen.mode === 'manual'" class="mb-0" data-testid="attendance-wait">
        <strong>{{ myOpen.title }}</strong> · closes in {{ myOpenLeft }}. Your IC is marking attendance.
      </p>
      <template v-else>
        <p class="mb-2"><strong>{{ myOpen.title }}</strong> · closes in {{ myOpenLeft }}</p>
        <template v-if="scanning">
          <QrScanner :paused="busy" @scan="$emit('scan', $event)" @error="onCameraError" />
          <p v-if="busy" class="small text-center mt-2 mb-0">Checking…</p>
          <p v-else-if="scanMessage" class="text-danger small text-center mt-2 mb-0" role="alert" data-testid="attendance-scan-error">{{ scanMessage }}</p>
          <p v-else class="small text-muted text-center mt-2 mb-0">Point the camera at the QR code.</p>
          <div class="text-center mt-2">
            <button type="button" class="btn btn-sm btn-ghost" @click="scanning = false">Cancel</button>
          </div>
        </template>
        <template v-else>
          <button type="button" class="btn btn-success btn-lg w-100" style="max-width: 22rem" data-testid="attendance-scan" @click="startScan">Scan QR code</button>
          <p v-if="cameraError" class="text-danger small mt-2 mb-0" role="alert">{{ cameraError }}</p>
          <p v-else class="kp-note mb-0">Can't scan? Tell your IC.</p>
        </template>
      </template>
    </section>
    <p v-else-if="!myGroup && !runnable.length && !seesWholeEvent" class="kp-empty">Roll calls are taken by group, and you are not in one yet.</p>

    <!-- ========== Take attendance (root / planners, a group's IC or admin) ========== -->
    <section v-if="runnable.length" class="kp-card" data-testid="attendance-run">
      <div class="kp-card-head">
        <h2 class="kp-title">Take attendance</h2>
        <select v-if="runnable.length > 1" v-model="selectedGroupId" class="form-select form-select-sm kp-stepped" aria-label="Group" data-testid="attendance-group">
          <option v-for="g in runnable" :key="g.id" :value="g.id">{{ g.name }}</option>
        </select>
        <span v-else-if="selectedGroup" class="kp-chip">{{ selectedGroup.name }}</span>
      </div>

      <!-- Nothing open: start one -->
      <form v-if="!running && selectedGroup" class="row g-2 align-items-end" @submit.prevent="start">
        <div class="col-12 col-sm">
          <label class="form-label" for="att-title">Name (optional)</label>
          <input id="att-title" v-model.trim="newTitle" class="form-control" maxlength="60" placeholder="e.g. Morning muster" data-testid="attendance-title" />
        </div>
        <div class="col-6 col-sm-auto">
          <label class="form-label" for="att-minutes">Open for</label>
          <select id="att-minutes" v-model.number="newMinutes" class="form-select">
            <option v-for="n in MINUTES" :key="n" :value="n">{{ n }} min</option>
          </select>
        </div>
        <div class="col-6 col-sm-auto">
          <button type="submit" class="btn btn-success w-100" :disabled="busy" data-testid="attendance-start">Start</button>
        </div>
        <p class="kp-note col-12 mb-0">Mode: <strong>{{ MODE_LABEL[mode] }}</strong></p>
      </form>

      <!-- Running -->
      <template v-else-if="running">
        <div class="kp-inline mb-3" style="flex-wrap: wrap">
          <span class="kp-chip kp-chip-ink"><span class="kp-dot kp-pulse"></span>{{ running.title }}</span>
          <span class="small text-muted">{{ MODE_LABEL[running.mode] }} · closes in {{ runningLeft }}</span>
          <span class="kp-spacer"></span>
          <button v-if="!isQr" type="button" class="btn btn-sm btn-outline-danger" :disabled="busy" data-testid="attendance-close" @click="$emit('close', running.id)">Close roll call</button>
        </div>

        <!-- QR mode: the QR -->
        <div v-if="isQr" class="kp-qr" :class="{ 'kp-qr-big': big }" data-testid="attendance-qr-box">
          <div v-if="big" class="small text-muted">{{ running.title }} · {{ selectedGroup.name }}</div>
          <img v-if="qrImage" :src="qrImage" alt="Attendance QR code: scan it with the app" class="kp-qr-img" data-testid="attendance-qr" />
          <div v-else class="kp-qr-img kp-qr-wait">Loading…</div>
          <div class="progress kp-qr-bar" role="progressbar" :aria-valuenow="qrShown ? qrShown.secondsLeft : 0" aria-valuemin="0" aria-valuemax="5" aria-label="Seconds until the QR code changes">
            <div class="progress-bar" :style="{ width: qrBar + '%' }"></div>
          </div>
          <div class="small text-muted">{{ roster.present.length }} of {{ rosterTotal }} present</div>
          <div class="kp-actions">
            <button type="button" class="btn btn-sm btn-outline-secondary" @click="big = !big">{{ big ? 'Smaller' : 'Show big' }}</button>
            <button v-if="!big" type="button" class="btn btn-sm btn-outline-danger" :disabled="busy" data-testid="attendance-close" @click="$emit('close', running.id)">Close roll call</button>
          </div>
        </div>

        <p class="mt-3 mb-0" data-testid="attendance-count">
          <strong>{{ roster.present.length }} of {{ rosterTotal }}</strong> present<span v-if="roster.excused.length"> · {{ roster.excused.length }} excused</span>
          · {{ roster.waiting.length }} not yet
        </p>
        <p v-if="isQr && !canMark" class="kp-note mb-0">Only planners can mark people by hand here.</p>
        <div class="kp-roster">
          <div>
            <h3 class="kp-label">Not yet</h3>
            <p v-if="!roster.waiting.length" class="small text-success">Everyone is marked.</p>
            <ul class="kp-list">
              <li v-for="w in roster.waiting" :key="w.m.id" class="kp-row py-2" :data-testid="'att-waiting-' + w.m.username">
                <span class="me-auto text-truncate">{{ w.m.display_name }}</span>
                <template v-if="canMark">
                  <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" :data-testid="'att-mark-' + w.m.username" @click="mark(w.m, 'present')">Present</button>
                  <button type="button" class="btn btn-sm btn-ghost" :disabled="busy" @click="mark(w.m, 'excused')">Excused</button>
                </template>
              </li>
            </ul>
          </div>
          <div>
            <h3 class="kp-label">Present</h3>
            <ul class="kp-list">
              <li v-for="p in roster.present" :key="p.m.id" class="kp-row py-2" :data-testid="'att-present-' + p.m.username">
                <span class="text-success" aria-hidden="true">✓</span>
                <span class="me-auto text-truncate">{{ p.m.display_name }}</span>
                <span class="small text-muted text-nowrap">{{ p.at }} · {{ p.how }}</span>
                <button v-if="canMark" type="button" class="btn btn-sm btn-ghost" :disabled="busy" @click="mark(p.m, null)">Undo</button>
              </li>
            </ul>
            <template v-if="roster.excused.length">
              <h3 class="kp-label mt-3">Excused</h3>
              <ul class="kp-list">
                <li v-for="x in roster.excused" :key="x.m.id" class="kp-row py-2">
                  <span class="me-auto text-truncate">{{ x.m.display_name }}</span>
                  <button v-if="canMark" type="button" class="btn btn-sm btn-ghost" :disabled="busy" @click="mark(x.m, null)">Undo</button>
                </li>
              </ul>
            </template>
          </div>
        </div>
      </template>
    </section>

    <!-- ========== Every group's open roll calls (root, planners, marshals) ========== -->
    <section v-if="seesWholeEvent" class="kp-card" data-testid="attendance-open-all">
      <h2 class="kp-title mb-2">Open now</h2>
      <p v-if="!openAll.length" class="text-muted mb-0">None open.</p>
      <ul v-else class="kp-list">
        <li v-for="x in openAll" :key="x.r.id" class="kp-row">
          <span class="kp-dot" :style="{ backgroundColor: x.group.colour }" aria-hidden="true"></span>
          <div class="kp-row-main">
            <strong>{{ x.group.name }} · {{ x.r.title }}</strong>
            <span>{{ x.r.mode === 'qr' ? 'QR' : 'By hand' }} · closes in {{ x.left }}</span>
          </div>
          <span class="kp-chip">{{ x.counts.present }}/{{ x.counts.total }} present</span>
          <span v-if="x.r.mode === 'qr' && x.counts.byHand" class="kp-chip kp-chip-warn" title="Marked by hand, not scanned">{{ x.counts.byHand }} by hand</span>
          <button v-if="canManage && x.r.groupId !== selectedGroupId" type="button" class="btn btn-sm btn-outline-secondary" @click="selectedGroupId = x.r.groupId">Open</button>
        </li>
      </ul>
    </section>

    <!-- ========== History ========== -->
    <section class="kp-card" data-testid="attendance-history">
      <h2 class="kp-title mb-2">Past roll calls</h2>
      <p v-if="!history.length" class="text-muted mb-0">None yet.</p>
      <ul v-else class="kp-list">
        <li v-for="h in history" :key="h.r.id" class="kp-row">
          <span class="kp-dot" :style="{ backgroundColor: h.group.colour }" aria-hidden="true"></span>
          <div class="kp-row-main">
            <strong>{{ h.r.title }} · {{ h.group.name }}</strong>
            <span>{{ h.when }} · {{ h.r.mode === 'qr' ? 'QR' : 'by hand' }}</span>
          </div>
          <div class="kp-chips">
            <template v-if="h.all">
              <span class="kp-chip kp-chip-mint">{{ h.counts.present }} present</span>
              <span v-if="h.counts.excused" class="kp-chip">{{ h.counts.excused }} excused</span>
              <span class="kp-chip" :class="{ 'kp-chip-warn': h.counts.absent }">{{ h.counts.absent }} absent</span>
            </template>
            <span v-else class="kp-chip" :class="h.mine === 'Present' ? 'kp-chip-mint' : h.mine === 'Excused' ? '' : 'kp-chip-warn'">{{ h.mine }}</span>
          </div>
          <details v-if="h.all && h.absentNames.length" class="small" style="flex-basis: 100%">
            <summary>Who was absent</summary>
            {{ h.absentNames.join(', ') }}
          </details>
        </li>
      </ul>
    </section>
  </div>
</template>
