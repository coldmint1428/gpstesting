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
  <main class="container py-4">
    <BenchAlert v-if="errorMsg" data-testid="join-error" @dismiss="errorMsg = ''">
      Could not join: {{ errorMsg }}
      <div class="mt-2"><RouterLink to="/events">Back to my events</RouterLink></div>
    </BenchAlert>
    <p v-else class="text-muted">Joining event {{ code }}...</p>
  </main>
</template>
