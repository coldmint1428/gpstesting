package sg.edu.smu.is216.g11;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

// PhoneSettings: what the "Set up sharing" screen (PhoneCheckView.vue) needs that the location plugin does
// not give. Apps may not change these settings themselves, so each method opens the exact screen (or the
// system's own one-tap dialog) where the IC can.
@CapacitorPlugin(name = "PhoneSettings")
public class PhoneSettingsPlugin extends Plugin {

    // Battery: is the app exempt from battery optimisation ("Unrestricted" on Samsung)?
    @PluginMethod
    public void isUnrestricted(PluginCall call) {
        JSObject result = new JSObject();
        result.put("unrestricted", unrestricted());
        call.resolve(result);
    }

    // The system's one-tap "Stop optimising battery usage?" dialog; App info if a phone does not offer it.
    // (Transistorsoft's own helper opened Android's list of all apps, which Samsung filters to apps already
    // unrestricted, so the IC could not find this app in it.)
    @PluginMethod
    public void requestUnrestricted(PluginCall call) {
        JSObject result = new JSObject();
        if (unrestricted()) {
            result.put("shown", "none");
            call.resolve(result);
            return;
        }
        try {
            open(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri()));
            result.put("shown", "dialog");
        } catch (Exception e) {
            open(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri()));
            result.put("shown", "app-info");
        }
        call.resolve(result);
    }

    // The phone's Location switch (location services)
    @PluginMethod
    public void openLocationSettings(PluginCall call) {
        openOr(call, new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS));
    }

    // This app's App info page: Permissions -> Location -> "Allow all the time" / "Use precise location"
    @PluginMethod
    public void openAppSettings(PluginCall call) {
        openOr(call, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri()));
    }

    // This app's notification settings
    @PluginMethod
    public void openNotificationSettings(PluginCall call) {
        Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS);
        intent.putExtra(Settings.EXTRA_APP_PACKAGE, getContext().getPackageName());
        openOr(call, intent);
    }

    // Battery saver
    @PluginMethod
    public void openBatterySaverSettings(PluginCall call) {
        openOr(call, new Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS));
    }

    private boolean unrestricted() {
        PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
        return pm != null && pm.isIgnoringBatteryOptimizations(getContext().getPackageName());
    }

    private Uri packageUri() {
        return Uri.parse("package:" + getContext().getPackageName());
    }

    private void open(Intent intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(intent);
    }

    // A screen some phones do not have falls back to the app's own App info page.
    private void openOr(PluginCall call, Intent intent) {
        try {
            open(intent);
        } catch (Exception e) {
            open(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri()));
        }
        call.resolve();
    }
}
