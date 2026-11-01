<script setup>
// Phone app only: warns the IC about phone settings that can pause background tracking.
// Apps aren't allowed to change these settings, so we explain and open the right screen.
import { useLocationTracker } from '../composables/useLocationTracker'

const { isNative, powerSaveOn, batteryRestricted, openBatterySettings } = useLocationTracker()
</script>

<template>
  <div v-if="isNative">
    <div v-if="powerSaveOn" class="alert alert-warning py-2" role="alert" data-testid="power-save-warning">
      <strong>Battery saver is on.</strong> Turn it off while sharing.
    </div>
    <div v-if="batteryRestricted" class="alert alert-warning py-2" role="alert" data-testid="battery-warning">
      <!-- Shown when the app is NOT "Unrestricted". That is usually Android's default ("Optimized"), not
           "Restricted", so the sentence says exactly what was checked. -->
      <strong>Set battery use to Unrestricted</strong> so sharing keeps running.
      <button class="btn btn-sm btn-warning ms-1" data-testid="battery-settings-btn" @click="openBatterySettings">
        Allow in background
      </button>
          </div>
  </div>
</template>
