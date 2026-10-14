<script setup>
// One event: status (live or not), live map, members & groups, invite, and playback
// (root / planners). What you see depends on your role.
import { ref, computed, watch } from 'vue'
import { RouterLink, useRouter, useRoute } from 'vue-router'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'
import { useEventData } from '../composables/useEventData'
import { useEventSessions } from '../composables/useEventSessions'
import { useLiveLocations } from '../composables/useLiveLocations'
import { useLocationTracker } from '../composables/useLocationTracker'
import {
  syncStartReminders,
  clearStartReminder,
  exactRemindersAllowed,
  allowExactReminders,
} from '../composables/useStartReminders'
import { clearPushReminders } from '../composables/usePushNotifications'
import { askConfirm, toast } from '../composables/useNotify'
import { useZoneActivity } from '../composables/useZoneActivity'
import { formatDayTime, formatTimeSeconds } from '../utils/time'
import { eventRoleLabel, groupRoleLabel } from '../utils/people'
import SharingWarnings from '../components/SharingWarnings.vue'
import EventStatus from '../components/EventStatus.vue'
import LiveMap from '../components/LiveMap.vue'
import MembersPanel from '../components/MembersPanel.vue'
import InvitePanel from '../components/InvitePanel.vue'
import BenchAlert from '../components/BenchAlert.vue'
import PlaybackPanel from '../components/PlaybackPanel.vue'
import PolygonTestView from './PolygonTestView.vue'

const props = defineProps({ id: { type: String, required: true } })
const auth = useAuthStore()
const router = useRouter()
const route = useRoute()

const { event, groups, members, loading, errorMsg, load, me, myRoles, isRoot, canManage, seesWholeEvent, myGroup } =
  useEventData(props.id)

// Is the event live? (ICs can only share while it is)
const sessions = useEventSessions(props.id)
const { isLive, liveSession, scheduledStart } = sessions

// Zones during the live session (merger Stage 2): who is inside which zone, group positions, No-Go alerts.
// A No-Go entry is told to the event's root / planners / marshals (toast) and to the IC who entered it.
const zoneActivity = useZoneActivity(props.id, computed(() => (liveSession.value ? liveSession.value.id : null)), {
  onAlert(alert) {
    const mine = auth.user && alert.userId === auth.user.id
    if (!seesWholeEvent.value && !mine) return
    const member = members.value.find((m) => m.id === alert.userId)
    const who = mine ? 'You' : member ? member.display_name : 'Someone'
    const zoneName = alert.zone ? alert.zone.name + ' (' + alert.zone.code + ')' : 'a No-Go area'
    toast('No-Go: ' + who + ' entered ' + zoneName + ' at ' + formatTimeSeconds(alert.at) + '.', 'danger', 12000)
  },
})

// The No-Go areas I am inside right now (shown to me as a warning until I leave).
const myNoGo = computed(() => {
  const mine = auth.user ? zoneActivity.staysByUser.value[auth.user.id] || [] : []
  return mine.filter((s) => s.zone.kind === 'no_go').map((s) => s.zone)
})

// Latest positions (one connection for the map and the "Not sharing yet" badges)
const live = useLiveLocations(props.id)

const tab = ref('map') // 'map' | 'members' | 'invite' | 'playback' | 'zones'

// ---------- One-tap sharing (same tracker as the Share page and navbar) ----------
const tracker = useLocationTracker()
const { isTracking, sharingEventId, errorMsg: shareError } = tracker
const sharingHere = computed(() => isTracking.value && sharingEventId.value === props.id)
const isIC = computed(() => !!(me.value && me.value.isIC && myGroup.value))

async function startSharing() {
  await tracker.start(props.id, myGroup.value.id) // asks for location permission the first time
  if (tracker.isTracking.value) {
    clearStartReminder(props.id) // the "tap to share" reminders can go
    clearPushReminders()
  }
}

// Planner ended the event while I'm sharing: stop here too (the database already refuses
// my uploads and left a "Stopped sharing" marker, so don't save another one)
watch(isLive, (nowLive, wasLive) => {
  if (wasLive && !nowLive && sharingHere.value) {
    tracker.stop(false).then(() => {
      tracker.errorMsg.value = 'The event has ended, so sharing stopped.'
    })
  }
})

// Opened from the "Event started - tap to share" reminder: start sharing straight away
watch(
  [() => route.query.share, isLive, isIC],
  ([share, nowLive, ic]) => {
    if (share === '1' && nowLive && ic && !sharingHere.value) {
      router.replace({ query: {} })
      startSharing()
    }
  },
  { immediate: true },
)

// Phone app: keep the start reminders in step with this event's schedule
const exactAllowed = ref(true)
watch(
  [() => sessions.openSession.value && sessions.openSession.value.startsAt.getTime(), isIC],
  async () => {
    if (!auth.user) return
    await syncStartReminders(auth.user.id, sharingEventId.value)
    exactAllowed.value = await exactRemindersAllowed()
  },
)
async function allowExact() {
  exactAllowed.value = await allowExactReminders()
  syncStartReminders(auth.user.id, sharingEventId.value)
}

// ---------- Who is sharing (for planners while live) ----------
// An IC counts as sharing if their newest reading is GPS from this session
const sharingStatus = computed(() => {
  const status = {}
  if (!liveSession.value) return status
  const since = liveSession.value.startsAt.getTime()
  for (const m of members.value) {
    if (!m.isIC) continue
    const p = live.positions.value[m.id]
    status[m.id] = !!(p && p.source === 'gps' && p.time.getTime() >= since)
  }
  return status
})
const icCount = computed(() => Object.keys(sharingStatus.value).length)
const sharingCount = computed(() => Object.values(sharingStatus.value).filter(Boolean).length)

// Text under the title explaining what this person sees on the map
const viewText = computed(() => {
  if (seesWholeEvent.value) return 'You can see every group in this event.'
  if (myGroup.value) return 'You can see your group: ' + myGroup.value.name + '.'
  return 'You are not in a group yet. Ask the root, a planner or a group admin to add you.'
})

function goLive() {
  tab.value = 'map'
}

async function leaveEvent() {
  if (!(await askConfirm({ title: 'Leave this event?', confirmText: 'Leave', danger: true }))) return
  if (sharingHere.value) await tracker.stop() // stop sharing before leaving
  const { error } = await supabase.rpc('remove_member', { p_event_id: props.id, p_user_id: auth.user.id })
  if (error) errorMsg.value = error.message
  else router.push('/events')
}
</script>

<template>
  <main class="container py-3">
    <p v-if="loading" class="text-muted">Loading...</p>
    <div v-else-if="!event" class="alert alert-danger" role="alert">
      {{ errorMsg || 'Event not found.' }}
      <div class="mt-2"><RouterLink to="/events">Back to my events</RouterLink></div>
    </div>

    <template v-else>
      <div class="mb-3">
        <h1 class="h4 mb-1" data-testid="event-name">{{ event.name }}</h1>
        <!-- One event badge (highest role) + one group badge ("Group A: Admin, IC") -->
        <span class="badge text-bg-secondary me-1" data-testid="event-role-badge">{{ eventRoleLabel(myRoles) }}</span>
        <span v-if="myGroup" class="badge text-bg-info me-1" data-testid="group-role-badge">
          {{ groupRoleLabel(myGroup.name, me && me.isAdmin, me && me.isIC) }}
        </span>
      </div>

      <EventStatus :sessions="sessions" :event-id="id" :can-manage="canManage" :ic-count="icCount" :sharing-count="sharingCount">
        <!-- Only the group's IC shares, and only while the event is live. One tap starts sharing. -->
        <template v-if="isIC" #sharing>
          <div class="d-flex flex-wrap align-items-center gap-2">
            <span class="small flex-grow-1">
              <strong>Your location:</strong>
              <span v-if="sharingHere" class="text-success" data-testid="sharing-banner">
                ● Sharing with this event's planners and your group.
              </span>
              <span v-else-if="isLive" class="text-muted"> not shared yet.</span>
              <span v-else class="text-muted" data-testid="share-locked-text">
                <template v-if="scheduledStart"> sharing opens at {{ formatDayTime(scheduledStart) }}.</template>
                <template v-else> sharing opens when a planner starts the event.</template>
              </span>
            </span>
            <button v-if="sharingHere" class="btn btn-sm btn-danger" data-testid="stop-share-btn" @click="tracker.stop()">
              Stop sharing
            </button>
            <button v-else-if="isLive" class="btn btn-sm btn-success" data-testid="share-btn" @click="startSharing">
              Share my location
            </button>
            <button v-else class="btn btn-sm btn-success" disabled data-testid="share-btn-locked">Share my location</button>
            <RouterLink :to="{ name: 'share', params: { id } }" class="btn btn-sm btn-outline-secondary" data-testid="share-details-link">
              My GPS details
            </RouterLink>
          </div>
        </template>
      </EventStatus>

      <div v-if="isIC && scheduledStart && tracker.isNative && !exactAllowed" class="alert alert-light border py-2 small">
        We'll remind you to share at the start time. For an on-time reminder, allow alarms for this app.
        <button class="btn btn-sm btn-outline-primary ms-1" @click="allowExact">Allow alarms</button>
      </div>

      <!-- I (an IC) am inside a No-Go area right now -->
      <div v-if="myNoGo.length" class="alert alert-danger py-2" role="alert" data-testid="my-no-go">
        <strong>You are inside a No-Go area:</strong> {{ myNoGo.map((z) => z.name).join(', ') }}. Please leave it now.
      </div>

      <SharingWarnings v-if="sharingHere" />
      <BenchAlert v-if="shareError" data-testid="share-error" @dismiss="shareError = ''">{{ shareError }}</BenchAlert>
      <p class="small text-muted mb-3" data-testid="view-scope">{{ viewText }}</p>

      <BenchAlert v-if="errorMsg" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <ul class="nav nav-tabs mb-3">
        <li class="nav-item">
          <button class="nav-link" :class="{ active: tab === 'map' }" data-testid="tab-map" @click="tab = 'map'">Live map</button>
        </li>
        <li class="nav-item">
          <button class="nav-link" :class="{ active: tab === 'members' }" data-testid="tab-members" @click="tab = 'members'">
            Members <span class="badge text-bg-light">{{ members.length }}</span>
          </button>
        </li>
        <li class="nav-item">
          <button class="nav-link" :class="{ active: tab === 'invite' }" data-testid="tab-invite" @click="tab = 'invite'">Invite</button>
        </li>
        <li v-if="canManage" class="nav-item">
          <button class="nav-link" :class="{ active: tab === 'playback' }" data-testid="tab-playback" @click="tab = 'playback'">
            Playback
          </button>
        </li>
        <!-- The event's zones (merger Stage 1): the polygon bench, for this event only -->
        <li v-if="canManage" class="nav-item">
          <button class="nav-link" :class="{ active: tab === 'zones' }" data-testid="tab-zones" @click="tab = 'zones'">
            Zones
          </button>
        </li>
      </ul>

      <!-- v-show keeps the map alive (and its live connection) when switching tabs -->
      <LiveMap
        v-show="tab === 'map'"
        :active="tab === 'map'"
        :event-id="id"
        :positions="live.positions.value"
        :live-since="liveSession ? liveSession.startsAt.getTime() : null"
        :on-reading="live.onReading"
        :now="live.now.value"
        :live-error="live.errorMsg.value"
        :reconnecting="live.reconnecting.value"
        :members="members"
        :groups="groups"
        :my-user-id="auth.user ? auth.user.id : null"
        :zone-stays="zoneActivity.staysByUser.value"
        :zone-counts="zoneActivity.countsByZone.value"
        :no-go-occupied="zoneActivity.noGoOccupied.value"
        :group-positions="zoneActivity.groupPositions.value"
      />

      <MembersPanel
        v-if="tab === 'members'"
        :event-id="id"
        :members="members"
        :groups="groups"
        :me="me"
        :is-root="isRoot"
        :can-manage="canManage"
        :sharing-status="sharingStatus"
        @changed="load"
      />

      <InvitePanel v-if="tab === 'invite'" :event-name="event.name" :join-code="event.join_code" />

      <!-- v-show keeps an open replay when peeking at another tab -->
      <PlaybackPanel
        v-if="canManage"
        v-show="tab === 'playback'"
        :active="tab === 'playback'"
        :event-id="id"
        :event-name="event.name"
        :members="members"
        @go-live="goLive"
      />

      <!-- v-if: the bench holds locks and a presence row only while it is open -->
      <PolygonTestView v-if="canManage && tab === 'zones'" :event-id="id" embedded />

      <button v-if="me && !isRoot" class="btn btn-link text-danger px-0 mt-4" @click="leaveEvent">Leave event</button>
    </template>
  </main>
</template>
