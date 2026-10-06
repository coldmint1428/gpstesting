import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'

// Bootstrap 5 (MIT licence) - CSS for styling, JS bundle for the navbar collapse
import 'bootstrap/dist/css/bootstrap.min.css'
import 'bootstrap/dist/js/bootstrap.bundle.min.js'

// Pinia must be installed before the router, because the router guard uses the auth store
createApp(App).use(createPinia()).use(router).mount('#app')
