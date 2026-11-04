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
import './assets/motion.css' // hover, press, page and tab transitions, skeletons while loading
import './assets/native.css' // the phone app's own look (Android first), only under html.native-app
import './assets/kinetic-tokens.css' // Planova Kinetic design tokens
import './assets/kinetic.css' // Planova Kinetic components
import './assets/kinetic-bridge.css' // Kinetic look for Bootstrap and the older screens' classes (last, so it wins)
import './assets/kinetic-pages.css' // Kinetic layouts for the inner pages (event workspace, create event, profile, share)
import './assets/kinetic-2.css' // Kinetic v2: the event workspace and its pages (last, so it wins)
import { isNativeApp } from './lib/platform'
import { installFormErrors } from './lib/formErrors'
import { installTooltips } from './lib/tooltips'
import { installSegSlide } from './lib/segSlide'
import { installSelectWidth } from './lib/selectWidth'
import { installNotifyMotion, hushNotifyMotion } from './lib/notifyMotion'

// The phone app gets its own layout (Figma: Phone app — native prototype); the website keeps its own
if (isNativeApp) document.documentElement.classList.add('native-app')

// Form problems (a required field left empty...) in the site's own style, not the browser's grey bubble
installFormErrors()
// Hover hints (an element's title) as a pill in the site's style, not the browser's grey box
installTooltips()
installSegSlide() // the lit pill of a segmented control slides to the chosen item
installSelectWidth() // a dropdown keeps one width whichever option is chosen; long text gets smaller, not the box wider
installNotifyMotion() // banners and alerts ease in and out
// iPhone browsers only apply :active (the press-in effect in motion.css) once the page listens for touches at all
document.addEventListener('touchstart', () => {}, { passive: true })

// Pinia must be installed before the router, because the router guard uses the auth store
router.beforeEach(() => hushNotifyMotion()) // a page's notices show with it, not slide in after it
createApp(App).use(createPinia()).use(router).mount('#app')
