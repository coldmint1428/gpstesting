// The app's own Android plugin (android/.../PhoneSettingsPlugin.java): battery optimisation, and opening the
// exact settings screen for location, notifications, battery saver and the app's App info page. Only call it
// inside the Android app.
import { registerPlugin } from '@capacitor/core'

export const PhoneSettings = registerPlugin('PhoneSettings')
