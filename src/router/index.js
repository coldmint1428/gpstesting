import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import GpsTestView from '../views/GpsTestView.vue'
import PolygonTestView from '../views/PolygonTestView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'home', component: HomeView },
    { path: '/gps', name: 'gps', component: GpsTestView },
    { path: '/polygon', name: 'polygon', component: PolygonTestView },
  ],
})

export default router
