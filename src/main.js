import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'

// Bootstrap 5 (MIT licence) - CSS for styling, JS bundle for the navbar collapse
import 'bootstrap/dist/css/bootstrap.min.css'
import 'bootstrap/dist/js/bootstrap.bundle.min.js'
import './assets/map-markers.css' // person / group markers on the maps
import './assets/event-shell.css' // the event workspace: header, side navigation, pages
import './assets/native.css' // the phone app's own look (Android first), only under html.native-app
import { isNativeApp } from './lib/platform'

// The phone app gets its own layout (Figma: Phone app — native prototype); the website keeps its own
if (isNativeApp) document.documentElement.classList.add('native-app')

// Pinia must be installed before the router, because the router guard uses the auth store
createApp(App).use(createPinia()).use(router).mount('#app')
