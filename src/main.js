import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'

// Bootstrap 5 (MIT licence) - CSS for styling, JS bundle for the navbar collapse
import 'bootstrap/dist/css/bootstrap.min.css'
import 'bootstrap/dist/js/bootstrap.bundle.min.js'
import './assets/map-markers.css' // person / group markers on the maps
import './assets/planova-tokens.css' // Planova design tokens (the design's own values)
import './assets/event-shell.css' // the event workspace: header, side navigation, pages
import './assets/planova-theme.css' // Planova theme for the website: Bootstrap, the event workspace and the redrawn screens (after event-shell.css)
import './assets/harbour.css' // Planova 2 colours "Harbour & Signal": tokens, Bootstrap, the plan board and the live pill (after the theme)
import './assets/controls.css' // one size system for fields, dropdowns and buttons (after the theme, before native.css)
import './assets/native.css' // the phone app's own look (Android first), only under html.native-app
import { isNativeApp } from './lib/platform'
import { installFormErrors } from './lib/formErrors'

// The phone app gets its own layout (Figma: Phone app — native prototype); the website keeps its own
if (isNativeApp) document.documentElement.classList.add('native-app')

// Form problems (a required field left empty...) in the site's own style, not the browser's grey bubble
installFormErrors()

// Pinia must be installed before the router, because the router guard uses the auth store
createApp(App).use(createPinia()).use(router).mount('#app')
