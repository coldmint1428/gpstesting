<script setup>
// The event's Groups page: a card per group with its summary (people, ICs, admins, details); a card opens the
// group in full (?group=<id>, or ?group=none for people without a group). Which controls appear depends on MY role:
//   Root / planner : create groups, rename / recolour them, group details, assign groups, marshal sectors
//   Group admin    : put people in / take them out of their own group, IC for its members
// IC and marshal switches follow the People page's rules (src/utils/permissions.js).
//   Everyone else  : read-only (ICs and members: their own group only, onlyGroupId)
// Adding people, roles, IC and removing people from the event are on the People page (PeoplePanel.vue).
// The database checks every action again (see 002_users_events_groups.sql).
import { ref, computed, watch } from 'vue'
import { RouterLink, useRoute } from 'vue-router'
import { supabase } from '../lib/supabase'
import { initials } from '../utils/people'
import { ROLE_LABEL, topRole, isMarshal, canSetIC, canSetMarshal } from '../utils/permissions'
import { setGroupIC, setMarshal } from '../services/memberService'
import BenchAlert from './BenchAlert.vue'
import { askConfirm, toast } from '../composables/useNotify'

const props = defineProps({
  eventId: { type: String, required: true },
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  me: { type: Object, default: null },
  isRoot: { type: Boolean, default: false },
  canManage: { type: Boolean, default: false },
  sharingStatus: { type: Object, default: () => ({}) }, // live only: { userId: true (sharing) | false }
  onlyGroupId: { type: String, default: null }, // show only this group ('none': no group at all)
})

// What this page lists: everything, or one group (ICs and members see their own group)
const shownGroups = computed(() => (props.onlyGroupId ? props.groups.filter((g) => g.id === props.onlyGroupId) : props.groups))
const emit = defineEmits(['changed'])

// The group open in full (?group=), or null for the list of cards. Only groups this page lists can open;
// 'none' (people without a group) is for the root and planners.
const route = useRoute()
const openGroup = computed(() => {
  const id = route.query.group
  if (!id) return null
  if (id === 'none') return props.canManage ? { id: 'none', name: 'No group', colour: '#6c757d' } : null
  return shownGroups.value.find((g) => g.id === id) || null
})
// Planners run the whole event and are never in a group (034), so they are not "without a group" either
const isPlanner = (m) => topRole(m) === 'planner'
const membersOf = (groupId) =>
  props.members.filter((m) => (groupId === 'none' ? !m.groupId && !isPlanner(m) : m.groupId === groupId))
const unassigned = computed(() => membersOf('none'))
const openMembers = computed(() => (openGroup.value ? membersOf(openGroup.value.id) : []))

// One line of a group's details: "Contingent · C01 · Sector B · Ch 3"
const detailLine = (g) => [g.category, g.code, g.sector && 'Sector ' + g.sector, g.radio].filter(Boolean).join(' · ')
const names = (list) => list.map((m) => m.display_name).join(', ')
const peopleText = (n) => n + (n === 1 ? ' person' : ' people')

// Every card's summary, worked out once here rather than in the template
const cards = computed(() =>
  shownGroups.value.map((g) => {
    const people = membersOf(g.id)
    const ics = people.filter((m) => m.isIC)
    const admins = people.filter((m) => m.isAdmin)
    const sharing = ics.filter((m) => props.sharingStatus[m.id] === true).length
    return {
      g,
      countText: peopleText(people.length),
      line: detailLine(g),
      icNames: ics.length ? names(ics) : 'None yet',
      adminNames: admins.length ? names(admins) : 'None yet',
      preview: people.slice(0, 6), // initials shown on the card
      more: Math.max(people.length - 6, 0),
      live: ics.some((m) => props.sharingStatus[m.id] !== undefined),
      sharingText: sharing + '/' + ics.length + ' sharing',
      allSharing: sharing === ics.length,
    }
  }),
)
const unassignedText = computed(() => peopleText(unassigned.value.length))
const openCountText = computed(() => peopleText(openMembers.value.length))
const openLine = computed(() => (openGroup.value && openGroup.value.id !== 'none' ? detailLine(openGroup.value) : ''))

// Root / planners, or this group's admin, may put people into it: root / planners anyone not in it (moving them from
// another group), the group's admin only people without a group (assign_group, 002)
const canFillOpenGroup = computed(
  () => !!openGroup.value && openGroup.value.id !== 'none' && (props.canManage || openGroup.value.id === myAdminGroupId.value),
)
const addCandidates = computed(() => {
  if (!canFillOpenGroup.value) return []
  const list = props.canManage
    ? props.members.filter((m) => !isPlanner(m) && m.groupId !== openGroup.value.id)
    : unassigned.value
  // people without a group first
  return [...list].sort((a, b) => !!a.groupId - !!b.groupId || a.display_name.localeCompare(b.display_name))
})
const groupNameOf = (id) => (props.groups.find((g) => g.id === id) || { name: 'No group' }).name
const addToGroupId = ref('')
async function addToOpenGroup() {
  const m = props.members.find((x) => x.id === addToGroupId.value)
  if (!m) return
  if (m.groupId) {
    const ok = await askConfirm({
      title: 'Move ' + m.display_name + ' to ' + openGroup.value.name + '?',
      message: 'They leave ' + groupNameOf(m.groupId) + '.' + (m.isIC || m.isAdmin ? ' They are no longer its IC or admin.' : ''),
      confirmText: 'Move',
    })
    if (!ok) return
  }
  if (await assignGroup(m, openGroup.value.id)) {
    toast(m.display_name + ' is now in ' + openGroup.value.name + '.', 'success', 3000)
    addToGroupId.value = ''
  }
}

// ---------- IC and marshal on / off (031): the same calls as the People page ----------
async function toggleIC(m, box) {
  const isIC = box.checked
  const name = groupNameOf(m.groupId)
  errorMsg.value = ''
  busy.value = true
  const message = await setGroupIC(m.groupId, m.id, isIC)
  busy.value = false
  if (message) {
    errorMsg.value = message
    box.checked = !isIC
  } else toast(m.display_name + (isIC ? ' is now an IC of ' : ' is no longer an IC of ') + name + '.', 'success', 3000)
  emit('changed')
}
async function toggleMarshal(m, box) {
  const on = box.checked
  errorMsg.value = ''
  busy.value = true
  const message = await setMarshal(props.eventId, m.id, on)
  busy.value = false
  if (message) {
    errorMsg.value = message
    box.checked = !on
  } else toast(m.display_name + (on ? ' is now a marshal.' : ' is no longer a marshal.'), 'success', 3000)
  emit('changed')
}

// ---------- Rename / recolour the open group (root / planners, update_group 035) ----------
const editingGroup = ref(false)
const editName = ref('')
const editColour = ref('#0d6efd')
function startEditGroup() {
  editName.value = openGroup.value.name
  editColour.value = openGroup.value.colour
  editingGroup.value = true
}
const groupEdited = computed(
  () =>
    !!openGroup.value &&
    (editName.value.trim() !== openGroup.value.name || editColour.value.toLowerCase() !== openGroup.value.colour.toLowerCase()),
)
async function saveGroup() {
  if (await run('update_group', { p_group: openGroup.value.id, p_name: editName.value, p_colour: editColour.value })) {
    toast('Saved ' + editName.value.trim() + '.', 'success', 3000)
    editingGroup.value = false
  }
}
// Another group opened (or back to the list): close the form
watch(
  () => openGroup.value && openGroup.value.id,
  () => (editingGroup.value = false),
)

const errorMsg = ref('')
const busy = ref(false)

const newGroupName = ref('')
const newGroupColour = ref('#0d6efd')

// Group I am admin of (null if none)
const myAdminGroupId = computed(() => (props.me && props.me.isAdmin ? props.me.groupId : null))

function groupColour(groupId) {
  const g = props.groups.find((x) => x.id === groupId)
  return g ? g.colour : '#6c757d'
}

// Run one database action, show its error, then tell the parent to reload
async function run(fnName, params) {
  errorMsg.value = ''
  busy.value = true
  const { error } = await supabase.rpc(fnName, params)
  busy.value = false
  if (error) {
    errorMsg.value = error.message
    return false
  }
  emit('changed')
  return true
}

// ---------- Group details for the run sheet (merger Stage 4): code, category, sector, radio ----------
// A movement can be for a whole category ("every Contingent group"), so groups need one.
// Headcount is not typed in: the database keeps it at the number of people in the group (036).
const showDetails = ref(false)
const details = ref({}) // groupId -> { code, category, sector, radio }
const detailSaved = ref('') // groupId just saved
const justSaved = new Set() // rows to refresh from the next reload
function detailsOf(g) {
  return {
    code: g.code || '',
    category: g.category || '',
    sector: g.sector || '',
    radio: g.radio || '',
  }
}
function openDetails() {
  showDetails.value = !showDetails.value
  details.value = Object.fromEntries(props.groups.map((g) => [g.id, detailsOf(g)]))
}
// Groups reloaded (a save, or someone else): refresh rows that are not being edited, add new groups
watch(
  () => props.groups,
  (list, old) => {
    if (!showDetails.value && !openGroup.value) return
    const before = Object.fromEntries((old || []).map((g) => [g.id, g]))
    for (const g of list) {
      const d = details.value[g.id]
      const prev = before[g.id]
      const untouched = d && prev && JSON.stringify(d) === JSON.stringify(detailsOf(prev))
      // just saved: show what the database stored (codes are stored in capitals, spaces as _)
      if (!d || untouched || justSaved.has(g.id)) details.value[g.id] = detailsOf(g)
      justSaved.delete(g.id)
    }
  },
)
// A group opened in full shows its details form (root / planners)
watch(
  () => openGroup.value && openGroup.value.id,
  (id) => {
    if (id && id !== 'none' && !details.value[id]) {
      const g = props.groups.find((x) => x.id === id)
      if (g) details.value = { ...details.value, [id]: detailsOf(g) }
    }
  },
  { immediate: true },
)
const groupCategories = computed(() => [...new Set(props.groups.map((g) => g.category).filter(Boolean))].sort())
function detailsChanged(g) {
  const d = details.value[g.id]
  if (!d) return false
  return (
    d.code !== (g.code || '') ||
    d.category !== (g.category || '') ||
    d.sector !== (g.sector || '') ||
    d.radio !== (g.radio || '')
  )
}
async function saveDetails(g) {
  const d = details.value[g.id]
  const ok = await run('update_group_details', {
    p_group: g.id,
    p_code: d.code,
    p_category: d.category,
    p_sector: d.sector,
    p_headcount: null, // the database counts it (036)
  })
  // the radio channel / call sign (029) has its own call
  const okRadio = ok && d.radio !== (g.radio || '') ? await run('set_group_radio', { p_group: g.id, p_radio: d.radio }) : ok
  if (ok && okRadio) {
    justSaved.add(g.id)
    detailSaved.value = g.id
    setTimeout(() => (detailSaved.value === g.id ? (detailSaved.value = '') : null), 2500)
  }
}

async function createGroup() {
  const ok = await run('create_group', {
    p_event_id: props.eventId,
    p_name: newGroupName.value,
    p_colour: newGroupColour.value,
  })
  if (ok) newGroupName.value = ''
}

function assignGroup(member, groupId) {
  return run('assign_group', { p_event_id: props.eventId, p_user_id: member.id, p_group_id: groupId || null })
}


// A marshal's sector (merger Stage 7): the ops view opens filtered to it
const sectorChoices = computed(() => [...new Set(props.groups.map((g) => g.sector).filter(Boolean))].sort())
async function setSector(member, value) {
  if ((value || '') === (member.sector || '')) return
  if (await run('set_marshal_sector', { p_event: props.eventId, p_user: member.id, p_sector: value })) {
    toast(member.display_name + (value.trim() ? ' now marshals sector ' + value.trim() + '.' : ' now marshals all sectors.'), 'success', 3000)
  }
}


// Stop an IC's phone sharing remotely (e.g. they forgot after a rehearsal).
// Cancels their tracking pass: the phone's next upload is refused and the map shows "Stopped sharing".
async function stopSharing(member) {
  const ok = await askConfirm({
    title: 'Stop ' + member.display_name + "'s location sharing?",
    message: 'Their phone stops sending its location. The map shows "Stopped sharing".',
    confirmText: 'Stop sharing',
    danger: true,
  })
  if (!ok) return
  errorMsg.value = ''
  busy.value = true
  const { data: wasSharing, error } = await supabase.rpc('stop_member_sharing', {
    p_event_id: props.eventId,
    p_user_id: member.id,
  })
  busy.value = false
  if (error) errorMsg.value = error.message
  else if (wasSharing) toast('Stopped ' + member.display_name + "'s location sharing.")
  else toast(member.display_name + ' was not sharing from the app.', 'warning')
}


// ---------- Per-member permission checks (decide which controls to show) ----------
const managesGroupOf = (m) => m.groupId && (props.canManage || m.groupId === myAdminGroupId.value)
// The root, planners and the group's admin may stop an IC's sharing (not yourself: use your own Stop button)
const canStopSharing = (m) => m.isIC && managesGroupOf(m) && (!props.me || m.id !== props.me.id)
const adminCanAdd = (m) => !props.canManage && myAdminGroupId.value && !m.groupId
const adminCanRemove = (m) => !props.canManage && myAdminGroupId.value && m.groupId === myAdminGroupId.value
</script>

<template>
  <div>
    <BenchAlert v-if="errorMsg" data-testid="members-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <datalist :id="'sectors-' + eventId">
      <option v-for="s in sectorChoices" :key="s" :value="s"></option>
    </datalist>

    <!-- ========== One group in full (?group=) ========== -->
    <template v-if="openGroup">
      <RouterLink :to="{ query: {} }" class="btn btn-sm btn-link px-0 mb-2" data-testid="group-back">‹ All groups</RouterLink>
      <!-- Name and colour (root / planner) -->
      <form v-if="editingGroup" class="card mb-3" data-testid="group-edit" @submit.prevent="saveGroup">
        <div class="card-body">
          <h2 class="h6">Name and colour</h2>
          <div class="input-group">
            <input
              v-model="editColour"
              type="color"
              class="form-control form-control-color flex-grow-0"
              title="Group colour"
              aria-label="Group colour"
              data-testid="group-edit-colour"
            />
            <input v-model="editName" class="form-control" maxlength="50" required aria-label="Group name" data-testid="group-edit-name" />
          </div>
          <div class="d-flex gap-2 mt-2">
            <button type="submit" class="btn btn-sm btn-primary" :disabled="busy || !editName.trim() || !groupEdited" data-testid="group-edit-save">
              Save
            </button>
            <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="busy" @click="editingGroup = false">Cancel</button>
          </div>
        </div>
      </form>
      <div v-else class="d-flex align-items-center gap-2 mb-3" :data-testid="'group-view-' + openGroup.name">
        <span class="dot" :style="{ backgroundColor: openGroup.colour }" aria-hidden="true"></span>
        <h2 class="h5 mb-0 text-truncate">{{ openGroup.name }}</h2>
        <span class="text-muted text-nowrap">· {{ openCountText }}</span>
        <button
          v-if="canManage && openGroup.id !== 'none'"
          type="button"
          class="btn btn-sm btn-outline-secondary ms-auto flex-shrink-0"
          data-testid="group-edit-btn"
          @click="startEditGroup"
        >
          Edit name and colour
        </button>
      </div>

      <!-- Details (root / planner): used by the run sheet's category movements -->
      <form
        v-if="canManage && details[openGroup.id]"
        class="card mb-3"
        data-testid="group-view-details"
        @submit.prevent="saveDetails(openGroup)"
      >
        <div class="card-body">
          <h3 class="h6">Details</h3>
          <datalist id="group-categories-one"><option v-for="c in groupCategories" :key="c" :value="c" /></datalist>
          <div class="row g-2">
            <div class="col-6 col-md">
              <label class="form-label small mb-0" for="gv-category">Category</label>
              <input id="gv-category" v-model="details[openGroup.id].category" class="form-control form-control-sm" list="group-categories-one" maxlength="50" />
            </div>
            <div class="col-6 col-md">
              <label class="form-label small mb-0" for="gv-code">Code</label>
              <input id="gv-code" v-model="details[openGroup.id].code" class="form-control form-control-sm" maxlength="40" />
            </div>
            <div class="col-6 col-md">
              <label class="form-label small mb-0" for="gv-sector">Sector</label>
              <input id="gv-sector" v-model="details[openGroup.id].sector" class="form-control form-control-sm" maxlength="50" />
            </div>
            <div class="col-6 col-md">
              <label class="form-label small mb-0" for="gv-radio">Radio</label>
              <input id="gv-radio" v-model="details[openGroup.id].radio" class="form-control form-control-sm" maxlength="40" placeholder="Ch 3 · BRAVO" />
            </div>
            <div class="col-12 col-md-auto d-flex align-items-end">
              <span v-if="detailSaved === openGroup.id" class="small text-success">Saved ✓</span>
              <button v-else type="submit" class="btn btn-sm btn-outline-primary w-100" :disabled="busy || !detailsChanged(openGroup)">Save</button>
            </div>
          </div>
        </div>
      </form>
      <p v-else-if="openLine" class="small text-muted">{{ openLine }}</p>

      <!-- Put someone in (root / planners: anyone not in it; this group's admin: people without a group) -->
      <form v-if="addCandidates.length" class="card mb-3" @submit.prevent="addToOpenGroup">
        <div class="card-body">
          <label class="h6 d-block" for="gv-add">{{ canManage ? 'Add a person to this group' : 'Add someone without a group' }}</label>
          <div class="input-group">
            <select id="gv-add" v-model="addToGroupId" class="form-select" data-testid="group-view-add">
              <option value="" disabled>Choose a person</option>
              <option v-for="m in addCandidates" :key="m.id" :value="m.id">
                {{ m.display_name }}{{ m.groupId ? ' (now in ' + groupNameOf(m.groupId) + ')' : '' }}
              </option>
            </select>
            <button class="btn btn-primary" type="submit" :disabled="busy || !addToGroupId">Add</button>
          </div>
        </div>
      </form>

      <p v-if="!openMembers.length" class="text-muted">No one {{ openGroup.id === 'none' ? 'without a group' : 'in this group yet' }}.</p>
      <div class="row g-2" data-testid="member-list">
        <div v-for="m in openMembers" :key="m.id" class="col-12 col-md-6">
            <div class="card h-100" :data-testid="'member-' + m.username">
              <div class="card-body py-2">
                <div class="d-flex align-items-center gap-2 mb-1">
                  <span class="avatar" :style="{ backgroundColor: groupColour(m.groupId) }">
                    {{ initials(m.display_name) }}
                  </span>
                  <div class="flex-grow-1 text-truncate">
                    <strong>{{ m.display_name }}</strong>
                    <span v-if="me && m.id === me.id" class="text-muted small"> (you)</span>
                  </div>
                </div>

                <div class="mb-2">
                  <span class="badge text-bg-secondary me-1" :data-testid="'role-badge-' + m.username">{{ ROLE_LABEL[topRole(m)] }}</span>
                  <span v-if="m.isAdmin && topRole(m) !== 'admin'" class="badge text-bg-info me-1">Group admin</span>
                  <span v-if="isMarshal(m)" class="badge text-bg-dark me-1">Marshal</span>
                  <span v-if="m.isIC" class="badge text-bg-success me-1">IC</span>
                  <span v-if="sharingStatus[m.id] === true" class="badge text-bg-light border border-success text-success me-1" data-testid="badge-sharing">
                    ● Sharing
                  </span>
                  <span v-else-if="sharingStatus[m.id] === false" class="badge text-bg-warning me-1" :data-testid="'badge-not-sharing-' + m.username">
                    Not sharing yet
                  </span>
                </div>

                <!-- Group (root / planner); planners are never in a group -->
                <p v-if="canManage && isPlanner(m)" class="small text-muted mb-2">Planners are not in a group.</p>
                <select
                  v-else-if="canManage"
                  class="form-select form-select-sm mb-2"
                  :value="m.groupId || ''"
                  :disabled="busy"
                  aria-label="Group"
                  :data-testid="'group-select-' + m.username"
                  @change="assignGroup(m, $event.target.value)"
                >
                  <option value="">No group</option>
                  <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
                </select>
                <!-- Group admin: add to / remove from own group -->
                <button v-if="adminCanAdd(m)" class="btn btn-sm btn-outline-primary mb-2 me-1" :disabled="busy" @click="assignGroup(m, myAdminGroupId)">
                  Add to my group
                </button>
                <button v-if="adminCanRemove(m) && m.id !== me.id" class="btn btn-sm btn-outline-secondary mb-2 me-1" :disabled="busy" @click="assignGroup(m, null)">
                  Remove from my group
                </button>

                <!-- IC (shares GPS) and marshal duties -->
                <div v-if="canSetIC(me, m) || canSetMarshal(me, m)" class="d-flex flex-wrap gap-3 mb-2">
                  <div v-if="canSetIC(me, m)" class="form-check form-switch mb-0">
                    <input
                      :id="'gv-ic-' + m.id"
                      class="form-check-input"
                      type="checkbox"
                      :checked="m.isIC"
                      :disabled="busy"
                      :data-testid="'group-ic-toggle-' + m.username"
                      @change="toggleIC(m, $event.target)"
                    />
                    <label class="form-check-label small" :for="'gv-ic-' + m.id">IC (shares GPS)</label>
                  </div>
                  <div v-if="canSetMarshal(me, m)" class="form-check form-switch mb-0">
                    <input
                      :id="'gv-marshal-' + m.id"
                      class="form-check-input"
                      type="checkbox"
                      :checked="isMarshal(m)"
                      :disabled="busy"
                      :data-testid="'group-marshal-toggle-' + m.username"
                      @change="toggleMarshal(m, $event.target)"
                    />
                    <label class="form-check-label small" :for="'gv-marshal-' + m.id">Marshal</label>
                  </div>
                </div>

                <!-- A marshal's sector (root / planners): the ops view opens filtered to it -->
                <div v-if="canManage && m.roles.includes('marshal')" class="input-group input-group-sm mt-2 sector-input">
                  <span class="input-group-text">Sector</span>
                  <input
                    class="form-control"
                    :value="m.sector || ''"
                    :list="'sectors-' + eventId"
                    maxlength="50"
                    placeholder="All sectors"
                    :disabled="busy"
                    :aria-label="'Sector that ' + m.display_name + ' marshals'"
                    :data-testid="'sector-' + m.username"
                    @change="setSector(m, $event.target.value)"
                  />
                </div>
                <div v-else-if="m.roles.includes('marshal') && m.sector" class="small text-muted mt-1">Sector: {{ m.sector }}</div>

                <button
                  v-if="canStopSharing(m)"
                  class="btn btn-sm btn-outline-danger mt-2 me-2"
                  :disabled="busy"
                  :data-testid="'stop-sharing-' + m.username"
                  @click="stopSharing(m)"
                >
                  Stop sharing
                </button>
              </div>
            </div>
        </div>
      </div>
    </template>

    <!-- ========== Every group, one card each ========== -->
    <template v-else>
      <!-- Create group (root / planner) -->
      <form v-if="canManage" class="card mb-3" @submit.prevent="createGroup">
        <div class="card-body">
          <h2 class="h6">Create a group</h2>
          <div class="input-group">
            <input
              v-model="newGroupColour"
              type="color"
              class="form-control form-control-color flex-grow-0"
              title="Group colour"
              aria-label="Group colour"
            />
            <input
              v-model="newGroupName"
              class="form-control"
              placeholder="e.g. Contingent A"
              maxlength="50"
              required
              aria-label="Group name"
              data-testid="new-group-name"
            />
            <button class="btn btn-success" type="submit" :disabled="busy" data-testid="create-group-btn">Add</button>
          </div>
        </div>
      </form>

      <p v-if="onlyGroupId === 'none'" class="text-muted" data-testid="no-group">
        You are not in a group. Ask a planner or a group admin to add you.
      </p>
      <p v-else-if="!shownGroups.length" class="text-muted">No groups yet.</p>

      <div v-if="canManage && groups.length" class="text-end mb-2">
        <button class="btn btn-sm btn-link" data-testid="group-details-btn" @click="openDetails">
          {{ showDetails ? 'Hide group details' : 'Edit all group details' }}
        </button>
      </div>
      <!-- Group details (root / planner): used by the run sheet's category movements -->
      <div v-if="canManage && showDetails && groups.length" class="card mb-3" data-testid="group-details">
        <div class="card-body">
          <p class="small text-muted mb-2">
            A run sheet movement can apply to a whole <strong>category</strong>, for example all "Contingent" groups.
            Code and sector are for reference only. Headcount is counted automatically.
          </p>
          <datalist id="group-categories"><option v-for="c in groupCategories" :key="c" :value="c" /></datalist>
          <div class="table-responsive">
            <table class="table table-sm align-middle mb-0 pv-stack">
              <thead>
                <tr>
                  <th scope="col">Group</th>
                  <th scope="col">Category</th>
                  <th scope="col">Code</th>
                  <th scope="col">Sector</th>
                  <th scope="col">Headcount</th>
                  <th scope="col">Radio</th>
                  <th scope="col"><span class="visually-hidden">Save</span></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="g in groups.filter((x) => details[x.id])" :key="g.id" :data-testid="'group-details-' + g.name">
                  <td class="text-nowrap"><span class="dot-sm" :style="{ backgroundColor: g.colour }"></span>{{ g.name }}</td>
                  <td data-label="Category"><input v-model="details[g.id].category" class="form-control form-control-sm" list="group-categories" maxlength="50" :aria-label="'Category of ' + g.name" data-testid="gd-category" /></td>
                  <td data-label="Code"><input v-model="details[g.id].code" class="form-control form-control-sm" maxlength="40" :aria-label="'Code of ' + g.name" data-testid="gd-code" /></td>
                  <td data-label="Sector"><input v-model="details[g.id].sector" class="form-control form-control-sm" maxlength="50" :aria-label="'Sector of ' + g.name" /></td>
                  <td data-label="Headcount" class="headcount-cell" data-testid="gd-headcount">{{ membersOf(g.id).length }}</td>
                  <td data-label="Radio"><input v-model="details[g.id].radio" class="form-control form-control-sm" maxlength="40" placeholder="Ch 3 · BRAVO" :aria-label="'Radio channel or call sign of ' + g.name" data-testid="gd-radio" /></td>
                  <td class="text-nowrap">
                    <span v-if="detailSaved === g.id" class="small text-success">Saved ✓</span>
                    <button v-else class="btn btn-sm btn-outline-primary" :disabled="busy || !detailsChanged(g)" data-testid="gd-save" @click="saveDetails(g)">Save</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="row g-2" data-testid="group-list">
        <div v-for="c in cards" :key="c.g.id" class="col-12 col-md-6 col-xl-4">
          <RouterLink
            :to="{ query: { group: c.g.id } }"
            class="card h-100 group-card text-reset text-decoration-none"
            :style="{ borderLeftColor: c.g.colour }"
            :data-testid="'group-card-' + c.g.name"
          >
            <div class="card-body">
              <div class="d-flex align-items-center gap-2">
                <strong class="text-truncate me-auto">{{ c.g.name }}</strong>
                <span class="badge text-bg-light border text-nowrap">{{ c.countText }}</span>
              </div>
              <div v-if="c.line" class="small text-muted text-truncate">{{ c.line }}</div>
              <dl class="summary small mt-2 mb-2">
                <dt>IC</dt>
                <dd class="text-truncate">{{ c.icNames }}</dd>
                <dt>Admin</dt>
                <dd class="text-truncate">{{ c.adminNames }}</dd>
              </dl>
              <div class="d-flex align-items-center gap-1">
                <span
                  v-for="m in c.preview"
                  :key="m.id"
                  class="avatar avatar-sm"
                  :style="{ backgroundColor: c.g.colour }"
                  :title="m.display_name"
                  aria-hidden="true"
                >{{ initials(m.display_name) }}</span>
                <span v-if="c.more" class="small text-muted">+{{ c.more }}</span>
                <span v-if="c.live" class="small ms-auto" :class="c.allSharing ? 'text-success' : 'text-warning'">● {{ c.sharingText }}</span>
              </div>
            </div>
          </RouterLink>
        </div>

        <!-- People without a group (root / planners) -->
        <div v-if="canManage && unassigned.length" class="col-12 col-md-6 col-xl-4">
          <RouterLink :to="{ query: { group: 'none' } }" class="card h-100 group-card text-reset text-decoration-none border-dashed" data-testid="group-card-none">
            <div class="card-body">
              <div class="d-flex align-items-center gap-2">
                <strong class="me-auto">No group</strong>
                <span class="badge text-bg-light border">{{ unassignedText }}</span>
              </div>
              <p class="small text-muted mb-0 mt-1">People in the event without a group. Open this to add them to a group.</p>
            </div>
          </RouterLink>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.dot-sm {
  display: inline-block;
  width: 0.6rem;
  height: 0.6rem;
  border-radius: 50%;
  margin-right: 0.35rem;
}
.sector-input {
  max-width: 18rem;
}
.headcount-cell {
  max-width: 6rem;
}
.dot {
  display: inline-block;
  width: 1rem;
  height: 1rem;
  border-radius: 50%;
  flex-shrink: 0;
}
.group-card {
  border-left-width: 0.35rem;
  transition: box-shadow 0.15s;
}
.group-card:hover,
.group-card:focus-visible {
  box-shadow: 0 0.25rem 0.75rem rgba(0, 0, 0, 0.12);
}
.border-dashed {
  border-style: dashed;
}
.summary {
  display: grid;
  grid-template-columns: auto 1fr;
  column-gap: 0.75rem;
  row-gap: 0.1rem;
}
.summary dt {
  font-weight: 500;
  color: var(--bs-secondary-color);
}
.summary dd {
  margin: 0;
  min-width: 0;
}
.avatar.avatar-sm {
  width: 1.6rem;
  height: 1.6rem;
  font-size: 0.65rem;
}
.avatar {
  width: 2rem;
  height: 2rem;
  border-radius: 50%;
  color: #fff;
  font-size: 0.75rem;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
</style>
