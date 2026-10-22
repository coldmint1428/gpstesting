<script setup>
// "Create an event" in 4 steps: details -> people -> groups -> preview.
// Answers live in the eventWizard store; the database is only written on Confirm, in one call.
import { ref, computed, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useEventWizardStore } from '../stores/eventWizard'
import { createEventWithSetup } from '../services/eventService'
import { askConfirm } from '../composables/useNotify'
import BenchAlert from '../components/BenchAlert.vue'
import StepDetails from '../components/eventWizard/StepDetails.vue'
import StepPeople from '../components/eventWizard/StepPeople.vue'
import StepGroups from '../components/eventWizard/StepGroups.vue'
import StepPreview from '../components/eventWizard/StepPreview.vue'

const STEPS = [
  { n: 1, label: 'Event details', short: 'Details' },
  { n: 2, label: 'Add people', short: 'People' },
  { n: 3, label: 'Groups & assign', short: 'Groups' },
  { n: 4, label: 'Preview', short: 'Preview' },
]

const auth = useAuthStore()
const wizard = useEventWizardStore()
const router = useRouter()

const errors = ref({}) // { field: message } for the current step
const saveError = ref('')
const saving = ref(false)

// Answers left by someone else who used this browser are not mine
onMounted(() => {
  if (wizard.ownerId !== auth.user.id) wizard.reset(auth.user.id)
})

// The creator (root) plus everyone added in step 2: the people groups are made from
const everyone = computed(() => [
  { id: auth.user.id, display_name: auth.profile.display_name, email: auth.user.email, role: 'root' },
  ...wizard.people,
])

function scrollUp() {
  window.scrollTo({ top: 0, behavior: 'smooth' })
}

function next() {
  errors.value = wizard.validate(wizard.step)
  if (Object.keys(errors.value).length) return
  wizard.step++
  scrollUp()
}

function back() {
  errors.value = {}
  saveError.value = ''
  wizard.step--
  scrollUp()
}

// The stepper: earlier steps can always be reopened; later ones only through Next (so they're checked)
function goTo(n) {
  if (n >= wizard.step) return
  errors.value = {}
  saveError.value = ''
  wizard.step = n
}

async function confirm() {
  // Check every step again (something may have been changed after going back)
  for (const n of [1, 3]) {
    const found = wizard.validate(n)
    if (Object.keys(found).length) {
      wizard.step = n
      errors.value = found
      return
    }
  }

  saving.value = true
  saveError.value = ''
  try {
    const id = await createEventWithSetup(wizard.toPayload())
    wizard.reset(auth.user.id)
    router.push({ name: 'event', params: { id } })
  } catch (error) {
    saveError.value = error.message // stay on the preview with everything kept
  } finally {
    saving.value = false
  }
}

async function startOver() {
  const ok = await askConfirm({
    title: 'Start over?',
    message: 'Everything entered so far will be cleared.',
    confirmText: 'Start over',
    danger: true,
  })
  if (!ok) return
  errors.value = {}
  saveError.value = ''
  wizard.reset(auth.user.id)
}
</script>

<template>
  <main class="container py-3 wizard">
    <div class="d-flex align-items-center gap-2 mb-3">
      <h1 class="h4 mb-0 me-auto">Create an event</h1>
      <button type="button" class="btn btn-sm btn-link text-danger" @click="startOver">Start over</button>
      <RouterLink to="/events" class="btn btn-sm btn-outline-secondary">Cancel</RouterLink>
    </div>

    <!-- Stepper -->
    <nav aria-label="Steps" class="mb-4">
      <ol class="stepper list-unstyled d-flex gap-1 mb-0">
        <li v-for="s in STEPS" :key="s.n" class="flex-fill">
          <button
            type="button"
            class="btn btn-sm w-100"
            :class="s.n === wizard.step ? 'btn-primary' : s.n < wizard.step ? 'btn-outline-primary' : 'btn-outline-secondary'"
            :aria-current="s.n === wizard.step ? 'step' : undefined"
            :disabled="s.n > wizard.step"
            @click="goTo(s.n)"
          >
            {{ s.n }}. <span class="d-none d-md-inline">{{ s.label }}</span><span class="d-md-none">{{ s.short }}</span>
          </button>
        </li>
      </ol>
    </nav>

    <StepDetails v-if="wizard.step === 1" :errors="errors" />
    <StepPeople v-else-if="wizard.step === 2" />
    <StepGroups v-else-if="wizard.step === 3" :errors="errors" :everyone="everyone" />
    <StepPreview v-else :everyone="everyone" />

    <p v-if="Object.keys(errors).length" class="text-danger small mt-3 mb-0" role="alert" data-testid="wiz-errors">
      Please fix the highlighted items before going on.
    </p>
    <BenchAlert v-if="saveError" class="mt-3" data-testid="wiz-save-error" @dismiss="saveError = ''">
      Could not create the event: {{ saveError }}
    </BenchAlert>

    <div class="d-flex gap-2 mt-4">
      <button v-if="wizard.step > 1" type="button" class="btn btn-outline-secondary" :disabled="saving" @click="back">Back</button>
      <button v-if="wizard.step < 4" type="button" class="btn btn-primary ms-auto" data-testid="wiz-next" @click="next">Next</button>
      <button v-else type="button" class="btn btn-success ms-auto" :disabled="saving" data-testid="wiz-confirm" @click="confirm">
        {{ saving ? 'Creating...' : 'Confirm' }}
      </button>
    </div>
  </main>
</template>

<style scoped>
.wizard {
  max-width: 52rem;
}
.stepper .btn {
  white-space: nowrap;
}
</style>
