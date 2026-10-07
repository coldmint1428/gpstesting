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
      <strong>Battery use is restricted for this app.</strong> Android may stop sharing in the background.
      <button class="btn btn-sm btn-warning ms-1" data-testid="battery-settings-btn" @click="openBatterySettings">
        Allow unrestricted
      </button>
    </div>
  </div>
</template>
