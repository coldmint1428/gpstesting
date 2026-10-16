<script setup>
// Phone app only: warns the IC about phone settings that can pause background tracking.
// Apps aren't allowed to change these settings, so we explain and open the right screen.
import { useLocationTracker } from '../composables/useLocationTracker'

const { isNative, powerSaveOn, batteryRestricted, openBatterySettings } = useLocationTracker()
</script>

<template>
  <div v-if="isNative">
    <div v-if="powerSaveOn" class="alert alert-warning py-2" role="alert" data-testid="power-save-warning">
      <strong>Battery saver is on.</strong> Your phone may pause GPS and uploads when the screen is off, so
      planners could see you as "lost contact". Turn it off while you are sharing.
    </div>
    <div v-if="batteryRestricted" class="alert alert-warning py-2" role="alert" data-testid="battery-warning">
      <!-- Shown when the app is NOT "Unrestricted". That is usually Android's default ("Optimized"), not
           "Restricted", so the sentence says exactly what was checked. -->
      <strong>Battery use for this app is not set to Unrestricted.</strong> Android may pause sharing when the
      screen is off. Tap the button and choose <strong>Allow</strong>.
      <button class="btn btn-sm btn-warning ms-1" data-testid="battery-settings-btn" @click="openBatterySettings">
        Allow in background
      </button>
      <div class="small mt-1">
        Or: Settings → Apps → Event Tracker → Battery → Unrestricted.
      </div>
    </div>
  </div>
</template>
