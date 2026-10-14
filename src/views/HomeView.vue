<script setup>
import { RouterLink } from 'vue-router'

const isDev = import.meta.env.DEV // the demo bench is only reachable on local dev
</script>

<template>
  <main class="container py-4">
    <h1 class="h3 mb-4">Test pages</h1>
    <div class="row g-3">
      <div class="col-12 col-md-6">
        <div class="card h-100">
          <div class="card-body">
            <h2 class="h5 card-title">GPS tracking</h2>
            <p class="card-text">Share this device's live location and see it on the map.</p>
            <RouterLink to="/gps" class="btn btn-primary">Open GPS test</RouterLink>
          </div>
        </div>
      </div>
      <!-- Zones are drawn in each event's Zones tab; the demo bench is a local-dev tool only -->
      <div v-if="isDev" class="col-12 col-md-6">
        <div class="card h-100">
          <div class="card-body">
            <h2 class="h5 card-title">Demo bench <span class="badge text-bg-warning align-middle">dev only</span></h2>
            <p class="card-text">The polygon editor without an event, for testing. Real zones: open an event → Zones.</p>
            <RouterLink to="/polygon" class="btn btn-outline-primary">Open demo bench</RouterLink>
          </div>
        </div>
      </div>
    </div>
  </main>
</template>
