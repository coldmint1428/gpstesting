<script setup>
// One event: live map, members & groups, invite. What you see depends on your role.
import { ref, computed } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'
import { useEventData } from '../composables/useEventData'
import { useLocationTracker } from '../composables/useLocationTracker'
import LiveMap from '../components/LiveMap.vue'
import MembersPanel from '../components/MembersPanel.vue'
import InvitePanel from '../components/InvitePanel.vue'

const props = defineProps({ id: { type: String, required: true } })
const auth = useAuthStore()
const router = useRouter()

const { event, groups, members, loading, errorMsg, load, me, myRoles, isRoot, canManage, seesWholeEvent, myGroup } =
  useEventData(props.id)

const tab = ref('map') // 'map' | 'members' | 'invite'

// ---------- One-tap sharing (same tracker as the Share page and navbar) ----------
const tracker = useLocationTracker()
const { isTracking, sharingEventId, errorMsg: shareError } = tracker
const sharingHere = computed(() => isTracking.value && sharingEventId.value === props.id)
const canShare = computed(() => !!(me.value && me.value.isIC && myGroup.value))

function startSharing() {
  tracker.start(props.id, myGroup.value.id) // asks for location permission the first time
}

// Text under the title explaining what this person sees on the map
const viewText = computed(() => {
  if (seesWholeEvent.value) return 'You can see every group in this event.'
  if (myGroup.value) return 'You can see your group: ' + myGroup.value.name + '.'
  return 'You are not in a group yet. Ask the root, a planner or a group admin to add you.'
})

async function leaveEvent() {
  if (!confirm('Leave this event?')) return
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
      <div class="d-flex flex-wrap align-items-start justify-content-between gap-2 mb-2">
        <div>
          <h1 class="h4 mb-1" data-testid="event-name">{{ event.name }}</h1>
          <div>
            <span v-for="r in myRoles" :key="r" class="badge text-bg-secondary me-1 text-capitalize">{{ r }}</span>
            <span v-if="me && me.isAdmin" class="badge text-bg-info me-1">Group admin</span>
            <span v-if="me && me.isIC" class="badge text-bg-success me-1">IC</span>
          </div>
        </div>
        <!-- Only the group's IC shares. One tap starts sharing right here. -->
        <div v-if="canShare" class="d-flex flex-wrap gap-2">
          <button v-if="!sharingHere" class="btn btn-success" data-testid="share-btn" @click="startSharing">
            Share my location
          </button>
          <button v-else class="btn btn-danger" data-testid="stop-share-btn" @click="tracker.stop()">
            Stop sharing
          </button>
          <RouterLink :to="{ name: 'share', params: { id } }" class="btn btn-outline-secondary" data-testid="share-details-link">
            My GPS details
          </RouterLink>
        </div>
      </div>

      <div v-if="sharingHere" class="alert alert-success py-2" role="status" data-testid="sharing-banner">
        You are sharing your live location with this event's planners and your group.
      </div>
      <div v-if="shareError" class="alert alert-danger py-2" role="alert" data-testid="share-error">{{ shareError }}</div>
      <p class="small text-muted mb-3" data-testid="view-scope">{{ viewText }}</p>

      <div v-if="errorMsg" class="alert alert-danger py-2" role="alert">{{ errorMsg }}</div>

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
      </ul>

      <!-- v-show keeps the map alive (and its live connection) when switching tabs -->
      <LiveMap
        v-show="tab === 'map'"
        :active="tab === 'map'"
        :event-id="id"
        :members="members"
        :groups="groups"
        :my-user-id="auth.user ? auth.user.id : null"
      />

      <MembersPanel
        v-if="tab === 'members'"
        :event-id="id"
        :members="members"
        :groups="groups"
        :me="me"
        :is-root="isRoot"
        :can-manage="canManage"
        @changed="load"
      />

      <InvitePanel v-if="tab === 'invite'" :event-name="event.name" :join-code="event.join_code" />

      <button v-if="me && !isRoot" class="btn btn-link text-danger px-0 mt-4" @click="leaveEvent">Leave event</button>
    </template>
  </main>
</template>
