// The "Create an event" wizard's answers (Pinia store). Kept in the browser until Confirm, so going
// Back / Next (or to another page and back) never loses anything. Nothing is saved before Confirm.
// The draft is also kept on this device (localStorage), so a reload - or Android closing the app in the
// background - does not lose it either; Confirm and Start over clear it.
//
// Roles follow the database (002): everyone added is a participant ("Member"), optionally also a
// planner or marshal. Inside a group a person can be Admin and/or IC. The creator is root.
import { defineStore } from 'pinia'
import { ref, computed, watch } from 'vue'

export const ROLE_OPTIONS = [
  { value: 'participant', label: 'Member' },
  { value: 'planner', label: 'Planner' },
  { value: 'marshal', label: 'Marshal' },
]

// Colours the next new group gets (it can be changed)
const GROUP_COLOURS = ['#0d6efd', '#d63384', '#198754', '#fd7e14', '#6f42c1', '#0dcaf0', '#b02a37', '#20c997']

function emptyDetails() {
  return { name: '', description: '', venue: '', startsAt: '', endsAt: '' } // times: <input type="datetime-local"> values
}

export const useEventWizardStore = defineStore('eventWizard', () => {
  const ownerId = ref(null) // whose answers these are (cleared if someone else signs in)
  const step = ref(1)
  const details = ref(emptyDetails())
  const people = ref([]) // [{ id, display_name, email, role }]  (not the creator)
  const groups = ref([]) // [{ key, name, colour, members: [{ userId, isAdmin, isIC }] }]
  let nextKey = 1

  function reset(userId = null) {
    ownerId.value = userId
    step.value = 1
    details.value = emptyDetails()
    people.value = []
    groups.value = []
  }

  // ---------- The draft on this device ----------
  const DRAFT_KEY = 'eventWizardDraft'
  try {
    const saved = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null')
    if (saved && saved.ownerId) {
      ownerId.value = saved.ownerId
      step.value = Math.min(Math.max(Number(saved.step) || 1, 1), 4)
      details.value = { ...emptyDetails(), ...(saved.details || {}) }
      people.value = Array.isArray(saved.people) ? saved.people : []
      groups.value = Array.isArray(saved.groups) ? saved.groups : []
      nextKey = groups.value.reduce((k, g) => Math.max(k, (g.key || 0) + 1), 1)
    }
  } catch {
    // no storage (private window) or a broken draft: start empty
  }
  watch(
    [ownerId, step, details, people, groups],
    () => {
      try {
        const empty = !details.value.name && !people.value.length && !groups.value.length && step.value === 1
        if (!ownerId.value || empty) localStorage.removeItem(DRAFT_KEY)
        else localStorage.setItem(DRAFT_KEY, JSON.stringify({ ownerId: ownerId.value, step: step.value, details: details.value, people: people.value, groups: groups.value }))
      } catch {
        // storage full or blocked: the draft just isn't kept
      }
    },
    { deep: true },
  )

  // ---------- Step 2: people ----------
  function addPerson(profile) {
    if (people.value.some((p) => p.id === profile.id)) return
    people.value.push({ id: profile.id, display_name: profile.display_name, email: profile.email, role: 'participant' })
  }

  // Removing someone also takes them out of their group
  function removePerson(userId) {
    people.value = people.value.filter((p) => p.id !== userId)
    removeFromGroups(userId)
  }

  // ---------- Step 3: groups ----------
  // Which group each person is in: { userId: groupKey }
  const groupOf = computed(() => {
    const map = {}
    for (const g of groups.value) for (const m of g.members) map[m.userId] = g.key
    return map
  })

  // Returns an error message, or '' when the group was added
  function addGroup(name, colour) {
    const trimmed = name.trim()
    if (!trimmed) return 'Give the group a name'
    if (trimmed.length > 50) return 'Group names can be at most 50 characters'
    if (groups.value.some((g) => g.name.trim().toLowerCase() === trimmed.toLowerCase())) {
      return 'There is already a group called "' + trimmed + '"'
    }
    groups.value.push({ key: nextKey++, name: trimmed, colour, members: [] })
    return ''
  }

  function suggestedColour() {
    return GROUP_COLOURS[groups.value.length % GROUP_COLOURS.length]
  }

  function removeGroup(key) {
    groups.value = groups.value.filter((g) => g.key !== key)
  }

  // A person can be in at most one group, so only people without one can be added
  function addToGroup(key, userId) {
    if (groupOf.value[userId]) return
    const group = groups.value.find((g) => g.key === key)
    if (group) group.members.push({ userId, isAdmin: false, isIC: false })
  }

  function removeFromGroups(userId) {
    for (const g of groups.value) g.members = g.members.filter((m) => m.userId !== userId)
  }

  // ---------- Checks before Next (the database checks them all again on Confirm) ----------
  // Returns { field: message } - empty when the step is fine
  function validate(stepNumber) {
    const errors = {}
    if (stepNumber === 1) {
      const d = details.value
      if (!d.name.trim()) errors.name = 'Give the event a name'
      else if (d.name.trim().length > 80) errors.name = 'At most 80 characters'
      if (d.description.length > 1000) errors.description = 'At most 1000 characters'
      if (d.venue.length > 120) errors.venue = 'At most 120 characters'
      if (!d.startsAt) errors.startsAt = 'Pick a start date and time'
      if (!d.endsAt) errors.endsAt = 'Pick an end date and time'
      else if (d.startsAt && new Date(d.endsAt) <= new Date(d.startsAt)) errors.endsAt = 'The end must be after the start'
    }
    if (stepNumber === 3) {
      const seen = new Set()
      for (const g of groups.value) {
        const name = g.name.trim()
        if (!name) errors['group-' + g.key] = 'Every group needs a name'
        else if (name.length > 50) errors['group-' + g.key] = 'Group names can be at most 50 characters'
        else if (seen.has(name.toLowerCase())) errors['group-' + g.key] = 'Two groups are called "' + name + '"'
        else if (g.members.length > 0 && !g.members.some((m) => m.isIC)) {
          errors['group-' + g.key] = '"' + name + '" needs at least one IC (the phone that shares the group\'s location)'
        }
        seen.add(name.toLowerCase())
      }
    }
    return errors
  }

  // What create_event_with_setup() takes
  function toPayload() {
    const d = details.value
    return {
      event: {
        name: d.name.trim(),
        description: d.description.trim(),
        venue: d.venue.trim(),
        starts_at: new Date(d.startsAt).toISOString(), // datetime-local is local time -> UTC
        ends_at: new Date(d.endsAt).toISOString(),
      },
      members: people.value.map((p) => ({ user_id: p.id, role: p.role })),
      groups: groups.value.map((g) => ({
        name: g.name.trim(),
        colour: g.colour,
        members: g.members.map((m) => ({ user_id: m.userId, is_admin: m.isAdmin, is_ic: m.isIC })),
      })),
    }
  }

  return {
    ownerId,
    step,
    details,
    people,
    groups,
    groupOf,
    reset,
    addPerson,
    removePerson,
    addGroup,
    suggestedColour,
    removeGroup,
    addToGroup,
    removeFromGroups,
    validate,
    toPayload,
  }
})
