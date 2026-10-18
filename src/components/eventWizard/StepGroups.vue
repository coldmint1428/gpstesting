<script setup>
// Wizard step 3: make groups, put people in them (one group each), tick Admin / IC
import { ref, computed } from 'vue'
import { useEventWizardStore } from '../../stores/eventWizard'
import { askConfirm } from '../../composables/useNotify'

const props = defineProps({
  errors: { type: Object, default: () => ({}) },
  everyone: { type: Array, required: true }, // [{ id, username, display_name, role }] incl. the creator
})
const wizard = useEventWizardStore()

const newName = ref('')
const newColour = ref(wizard.suggestedColour())
const addError = ref('')
const editingKey = ref(null) // the group whose editor is open
const filter = ref('')

const byId = computed(() => Object.fromEntries(props.everyone.map((p) => [p.id, p])))
const unassigned = computed(() => props.everyone.filter((p) => !wizard.groupOf[p.id]))

// Unassigned people matching the filter, for the open group's "Add" list
const addable = computed(() => {
  const f = filter.value.trim().toLowerCase().replace(/^@/, '')
  return unassigned.value.filter(
    (p) => !f || p.username.includes(f) || p.display_name.toLowerCase().includes(f),
  )
})

function addGroup() {
  addError.value = wizard.addGroup(newName.value, newColour.value)
  if (addError.value) return
  editingKey.value = wizard.groups[wizard.groups.length - 1].key // open the new group straight away
  newName.value = ''
  newColour.value = wizard.suggestedColour()
}

function toggleEdit(key) {
  editingKey.value = editingKey.value === key ? null : key
  filter.value = ''
}

function addAllUnassigned(key) {
  for (const p of addable.value) wizard.addToGroup(key, p.id)
}

async function removeGroup(group) {
  if (group.members.length) {
    const ok = await askConfirm({
      title: 'Delete "' + group.name + '"?',
      message: 'Its ' + group.members.length + ' people will have no group.',
      confirmText: 'Delete group',
      danger: true,
    })
    if (!ok) return
  }
  wizard.removeGroup(group.key)
}
</script>

<template>
  <section>
    <h2 class="h5 mb-1">Create groups &amp; assign people</h2>
    <p class="text-muted small mb-3">
      Each person can be in one group. Every group with people needs at least one <strong>IC</strong>
      (the phone that shares the group's location). An <strong>Admin</strong> manages their group's members.
    </p>

    <form class="row g-2 align-items-end mb-3" @submit.prevent="addGroup">
      <div class="col-12 col-sm">
        <label for="new-group-name" class="form-label">New group</label>
        <input
          id="new-group-name"
          v-model="newName"
          class="form-control"
          :class="{ 'is-invalid': addError }"
          maxlength="50"
          placeholder="e.g. Scouts"
          data-testid="wiz-group-name"
        />
        <div v-if="addError" class="invalid-feedback">{{ addError }}</div>
      </div>
      <div class="col-auto">
        <label for="new-group-colour" class="form-label">Colour</label>
        <input id="new-group-colour" v-model="newColour" type="color" class="form-control form-control-color" />
      </div>
      <div class="col-auto">
        <button type="submit" class="btn btn-success" data-testid="wiz-add-group">Add group</button>
      </div>
    </form>

    <p v-if="wizard.groups.length === 0" class="text-muted small">No groups yet. You can also add them later.</p>

    <ul class="list-unstyled d-grid gap-2 mb-3" data-testid="wiz-groups">
      <li v-for="g in wizard.groups" :key="g.key" class="card" :class="{ 'border-danger': errors['group-' + g.key] }">
        <div class="card-body p-2 p-sm-3">
          <div class="d-flex align-items-center gap-2">
            <span class="group-dot flex-shrink-0" :style="{ background: g.colour }" aria-hidden="true"></span>
            <strong class="me-auto text-truncate">{{ g.name || '(no name)' }}</strong>
            <span class="text-muted small flex-shrink-0">{{ g.members.length }} {{ g.members.length === 1 ? 'person' : 'people' }}</span>
            <button type="button" class="btn btn-sm btn-outline-primary" :aria-expanded="editingKey === g.key" @click="toggleEdit(g.key)">
              {{ editingKey === g.key ? 'Done' : 'Edit' }}
            </button>
          </div>
          <p v-if="errors['group-' + g.key]" class="text-danger small mb-0 mt-2">{{ errors['group-' + g.key] }}</p>

          <!-- Editor -->
          <div v-if="editingKey === g.key" class="mt-3">
            <div class="row g-2 align-items-end mb-3">
              <div class="col">
                <label :for="'group-name-' + g.key" class="form-label small">Name</label>
                <input :id="'group-name-' + g.key" v-model="g.name" class="form-control form-control-sm" maxlength="50" />
              </div>
              <div class="col-auto">
                <label :for="'group-colour-' + g.key" class="form-label small">Colour</label>
                <input :id="'group-colour-' + g.key" v-model="g.colour" type="color" class="form-control form-control-sm form-control-color" />
              </div>
              <div class="col-auto">
                <button type="button" class="btn btn-sm btn-outline-danger" @click="removeGroup(g)">Delete group</button>
              </div>
            </div>

            <p v-if="g.members.length === 0" class="text-muted small">No one in this group yet.</p>
            <ul v-else class="list-group list-group-flush mb-3">
              <li v-for="m in g.members" :key="m.userId" class="list-group-item px-0 d-flex flex-wrap align-items-center gap-2">
                <span class="me-auto text-truncate">
                  {{ byId[m.userId].display_name }}
                  <span class="text-muted small">@{{ byId[m.userId].username }}</span>
                </span>
                <div class="form-check form-check-inline m-0">
                  <input :id="'ic-' + m.userId" v-model="m.isIC" class="form-check-input" type="checkbox" />
                  <label class="form-check-label small" :for="'ic-' + m.userId">IC</label>
                </div>
                <div class="form-check form-check-inline m-0">
                  <input :id="'admin-' + m.userId" v-model="m.isAdmin" class="form-check-input" type="checkbox" />
                  <label class="form-check-label small" :for="'admin-' + m.userId">Admin</label>
                </div>
                <button type="button" class="btn btn-sm btn-outline-secondary" @click="wizard.removeFromGroups(m.userId)">Remove</button>
              </li>
            </ul>

            <label :for="'group-filter-' + g.key" class="form-label small">Add people without a group</label>
            <input
              :id="'group-filter-' + g.key"
              v-model="filter"
              type="search"
              class="form-control form-control-sm mb-2"
              placeholder="Filter by name or username"
              autocomplete="off"
            />
            <p v-if="unassigned.length === 0" class="text-muted small mb-0">Everyone is in a group. Add more people in step 2.</p>
            <template v-else>
              <ul class="list-group addable mb-2">
                <li v-for="p in addable" :key="p.id" class="list-group-item d-flex align-items-center gap-2 py-1">
                  <span class="me-auto text-truncate small">
                    {{ p.display_name }} <span class="text-muted">@{{ p.username }}</span>
                    <span v-if="p.role === 'root'" class="badge text-bg-dark ms-1">You</span>
                  </span>
                  <button type="button" class="btn btn-sm btn-primary" @click="wizard.addToGroup(g.key, p.id)">Add</button>
                </li>
                <li v-if="addable.length === 0" class="list-group-item text-muted small">No match.</li>
              </ul>
              <button v-if="addable.length > 1" type="button" class="btn btn-sm btn-outline-primary" @click="addAllUnassigned(g.key)">
                Add all {{ addable.length }} shown
              </button>
            </template>
          </div>
        </div>
      </li>
    </ul>

    <h3 class="h6">Not in a group ({{ unassigned.length }})</h3>
    <p v-if="unassigned.length === 0" class="text-muted small">Everyone has a group.</p>
    <p v-else class="small text-muted mb-0" data-testid="wiz-unassigned">
      {{ unassigned.map((p) => p.display_name).join(', ') }}
    </p>
  </section>
</template>

<style scoped>
.group-dot {
  width: 1rem;
  height: 1rem;
  border-radius: 50%;
}
.addable {
  max-height: 14rem;
  overflow-y: auto;
}
</style>
