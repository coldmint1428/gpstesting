// Which shell the app is drawn in. The phone app (Capacitor on Android, iPhone later) gets its own layout from the
// Figma "Phone app — native prototype" (WAD2 → Prototype of App): bottom tabs that follow the role, one big action
// per screen, bottom sheets. The website keeps its own layout. Decided once, at start-up: it cannot change while
// the app runs.
import { Capacitor } from '@capacitor/core'

// VITE_APP_PREVIEW=1 builds the website drawn as the phone app, to compare the two in a browser (never set for Vercel)
export const isNativeApp = Capacitor.isNativePlatform() || import.meta.env.VITE_APP_PREVIEW === '1'
