<script setup>
import { RouterLink } from 'vue-router'
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
      <div class="col-12 col-md-6">
        <div class="card h-100">
          <div class="card-body">
            <h2 class="h5 card-title">Polygons</h2>
            <p class="card-text">Draw zones, no-go areas and exits on the map.</p>
            <RouterLink to="/polygon" class="btn btn-primary">Open polygon test</RouterLink>
          </div>
        </div>
      </div>
    </div>
  </main>
</template>
