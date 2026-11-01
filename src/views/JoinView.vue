<script setup>
// Opened from an invite link or QR code (/join/ABC123): join the event, then open it.
// If not logged in, the router guard sends the user to /login first and back here after.
import { ref, onMounted } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { joinEventByCode } from '../services/eventService'
import BenchAlert from '../components/BenchAlert.vue'

const props = defineProps({ code: { type: String, required: true } })
const router = useRouter()
const errorMsg = ref('')

onMounted(async () => {
  try {
    const id = await joinEventByCode(props.code)
    router.replace({ name: 'event', params: { id } })
  } catch (error) {
    errorMsg.value = error.message
  }
})
</script>

<template>
  <main class="kp-page kp-page-sm">
    <div class="kp-card kp-setup">
      <h1>Join event</h1>
      <BenchAlert v-if="errorMsg" class="text-start" data-testid="join-error" @dismiss="errorMsg = ''">
        Could not join: {{ errorMsg }}
        <div class="mt-2"><RouterLink to="/events">Back to events</RouterLink></div>
      </BenchAlert>
      <p v-else class="kp-sub mb-0" role="status">Joining <strong>{{ code }}</strong>…</p>
    </div>
  </main>
</template>
