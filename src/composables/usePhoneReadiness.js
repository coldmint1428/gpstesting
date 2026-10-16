// usePhoneReadiness - "Set up sharing": the phone settings background sharing depends on, each with what
// is wrong and a Fix that opens the exact screen (apps may not change these settings themselves).
//
//   REQUIRED (sharing cannot work without them): location "Allow all the time", precise location, the
//   phone's Location switch.
//   RECOMMENDED (sharing works, but less reliably): notifications, battery use Unrestricted, battery saver off.
//
// Phone app only; in a browser everything reads as fine (the browser asks for location itself).
import { Capacitor } from '@capacitor/core'
import { useLocationTracker } from './useLocationTracker'
import { notificationPermission, askNotificationPermission } from './usePushNotifications'
import { PhoneSettings } from '../lib/phoneSettings'

// Transistorsoft's AuthorizationStatus / AccuracyAuthorization values
const STATUS = { NotDetermined: 0, Restricted: 1, Denied: 2, Always: 3, WhenInUse: 4, DeniedAlways: 5 }
const PRECISE = 0

const isNative = Capacitor.isNativePlatform()
const isAndroid = Capacitor.getPlatform() === 'android'

export function usePhoneReadiness() {
  const tracker = useLocationTracker()

  // Reads every item. Returns { items, requiredOk, allOk }; an item is
  //   { key, label, why, required, ok, howTo (where to look if Fix is not enough), fixLabel }
  async function check() {
    if (!isNative) return { items: [], requiredOk: true, allOk: true }
    const bg = await tracker.plugin()
    const items = []

    let state = null
    try {
      state = await bg.getProviderState()
    } catch {
      state = null
    }
    const status = state ? state.status : STATUS.NotDetermined

    items.push({
      key: 'location',
      icon: '📍',
      label: 'Location: Allow all the time',
      title: 'Allow location all the time',
      why: 'So sharing keeps going when your screen is off or the app is closed.',
      body: 'Planners need to see your group even while your phone is in your pocket.',
      action: status === STATUS.NotDetermined ? 'Allow location' : 'Open location permission',
      tapHint: status === STATUS.NotDetermined
        ? 'Choose "Allow all the time" (or "While using the app" first, then "Allow all the time").'
        : 'Tap Permissions → Location → Allow all the time, then come back.',
      required: true,
      ok: status === STATUS.Always,
      state: status,
      fixLabel: status === STATUS.NotDetermined ? 'Allow' : 'Open settings',
      howTo: 'Permissions → Location → Allow all the time',
    })
    items.push({
      key: 'precise',
      icon: '🎯',
      label: 'Precise location on',
      title: 'Turn on precise location',
      why: 'Without it your position can be off by a few kilometres.',
      body: 'Without it your position can be off by a few kilometres, and zones would not work.',
      action: 'Open location permission',
      tapHint: 'Tap Permissions → Location → turn on "Use precise location", then come back.',
      required: true,
      // Only meaningful once location is allowed at all
      ok: Boolean(state) && status !== STATUS.NotDetermined && state.accuracyAuthorization === PRECISE,
      fixLabel: 'Open settings',
      howTo: 'Permissions → Location → Use precise location',
    })
    items.push({
      key: 'gps',
      icon: '🛰️',
      label: 'Location turned on',
      title: 'Turn on Location',
      why: "Your phone's Location switch must be on.",
      body: "Your phone's Location switch is off, so no app can find where you are.",
      action: 'Open Location settings',
      tapHint: 'Turn on "Location" at the top, then come back.',
      required: true,
      ok: Boolean(state && state.enabled),
      fixLabel: 'Turn on',
      howTo: 'Swipe down from the top → Location',
    })

    let notes = 'granted'
    try {
      notes = await notificationPermission()
    } catch {
      notes = 'granted' // cannot tell: do not nag
    }
    items.push({
      key: 'notifications',
      icon: '🔔',
      label: 'Notifications allowed',
      title: 'Allow notifications',
      why: 'For the "Sharing your location" notice with its Stop button, and event reminders.',
      body: 'You will see a notice while sharing, with a Stop button, and a reminder when the event starts.',
      action: notes === 'prompt' ? 'Allow notifications' : 'Open notification settings',
      tapHint: 'Turn on "Allow notifications", then come back.',
      required: false,
      ok: notes === 'granted',
      state: notes,
      fixLabel: notes === 'prompt' ? 'Allow' : 'Open settings',
      howTo: 'Notifications → Allow notifications',
    })

    if (isAndroid) {
      let unrestricted = true
      try {
        unrestricted = (await PhoneSettings.isUnrestricted()).unrestricted
      } catch {
        unrestricted = true
      }
      items.push({
        key: 'battery',
        icon: '🔋',
        label: 'Battery use: Unrestricted',
        title: 'Let Event Tracker run in the background',
        why: "So Android doesn't pause sharing in the background.",
        body: 'Otherwise Android may pause sharing to save battery, and planners lose sight of you.',
        action: 'Allow in background',
        tapHint: 'Choose "Allow". If no box appears: Settings → Apps → Event Tracker → Battery → Unrestricted.',
        required: false,
        ok: unrestricted,
        fixLabel: 'Allow',
        howTo: 'Settings → Apps → Event Tracker → Battery → Unrestricted',
      })
    }

    let saver = false
    try {
      saver = await bg.isPowerSaveMode()
    } catch {
      saver = false
    }
    items.push({
      key: 'saver',
      icon: '⚡',
      label: isAndroid ? 'Battery saver off' : 'Low Power Mode off',
      title: isAndroid ? 'Turn off Power saving' : 'Turn off Low Power Mode',
      why: 'It can pause GPS and uploads while sharing.',
      body: 'Power saving can pause GPS and uploads while you share.',
      action: isAndroid ? 'Open Power saving' : '',
      tapHint: isAndroid ? 'Turn "Power saving" off, then come back.' : 'Settings → Battery → turn off Low Power Mode.',
      required: false,
      ok: !saver,
      fixLabel: isAndroid ? 'Open settings' : '',
      howTo: isAndroid ? 'Swipe down from the top → Power saving' : 'Settings → Battery → Low Power Mode',
    })

    // Keep the warnings shown while sharing in step with what was just read
    tracker.checkPhoneSettings()

    const requiredOk = items.every((i) => !i.required || i.ok)
    return { items, requiredOk, allOk: items.every((i) => i.ok) }
  }

  // Opens the screen (or system prompt) that fixes one item. Resolves when a prompt has been answered; a
  // settings page resolves at once, and the page re-checks when the IC comes back to the app.
  async function fix(item) {
    if (!isNative) return
    try {
      if (item.key === 'location') {
        if (item.state === STATUS.NotDetermined) {
          const bg = await tracker.plugin()
          await bg.requestPermission()
        } else if (isAndroid) {
          await PhoneSettings.openAppSettings()
        } else {
          const bg = await tracker.plugin()
          await bg.requestPermission()
        }
      } else if (item.key === 'precise') {
        if (isAndroid) await PhoneSettings.openAppSettings()
        else await (await tracker.plugin()).requestTemporaryFullAccuracy('Live location for event planners')
      } else if (item.key === 'gps') {
        if (isAndroid) await PhoneSettings.openLocationSettings()
      } else if (item.key === 'notifications') {
        if (item.state === 'prompt') await askNotificationPermission()
        else if (isAndroid) await PhoneSettings.openNotificationSettings()
      } else if (item.key === 'battery') {
        await PhoneSettings.requestUnrestricted()
      } else if (item.key === 'saver') {
        if (isAndroid) await PhoneSettings.openBatterySaverSettings()
      }
    } catch (err) {
      console.error('[phone check] could not open the fix for ' + item.key + ':', err)
    }
  }

  return { isNative, isAndroid, check, fix }
}
