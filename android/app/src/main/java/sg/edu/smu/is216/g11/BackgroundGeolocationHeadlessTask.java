package sg.edu.smu.is216.g11;

import android.content.Context;
import android.util.Log;
import com.transistorsoft.locationmanager.adapter.BackgroundGeolocation;
import com.transistorsoft.locationmanager.config.TSConfig;
import com.transistorsoft.locationmanager.event.HeadlessEvent;
import com.transistorsoft.locationmanager.http.HttpResponse;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.greenrobot.eventbus.Subscribe;
import org.json.JSONObject;

/**
 * Runs while the app is CLOSED (swiped away) but location sharing is still on.
 * Transistorsoft finds this class by its name (package + "BackgroundGeolocationHeadlessTask")
 * when the tracker config has app.enableHeadless = true (useLocationTracker.js).
 *
 * 1. "Stop sharing" button in the sharing notification: stop the tracker, delete readings still
 *    queued on the phone, and tell the server (stop_sharing_with_pass: cancels the tracking pass
 *    and shows "Stopped sharing" on the map).
 * 2. An upload refused with 401 / 403 (event ended, a planner stopped this person, no longer IC,
 *    pass expired): stop the tracker instead of retrying forever.
 *
 * While the app is open, useLocationTracker.js handles both itself (onNotificationAction / onHttp).
 */
public class BackgroundGeolocationHeadlessTask {

    private static final String TAG = "HeadlessTask";

    @Subscribe
    public void onHeadlessTask(HeadlessEvent event) {
        String name = event.getName();
        Context context = event.getContext();

        if ("notificationaction".equals(name)) {
            if ("notificationButtonStop".equals(event.getNotificationEvent())) {
                Log.i(TAG, "Stop sharing pressed in the notification (app closed)");
                stopSharing(context, true);
            }
        } else if ("http".equals(name)) {
            HttpResponse response = event.getHttpEvent();
            int status = response.getStatus();
            if (status == 401 || status == 403) {
                Log.i(TAG, "Upload refused (" + status + "): stopping sharing");
                stopSharing(context, false);
            }
        }
    }

    private void stopSharing(Context context, boolean tellServer) {
        // Read the tracking pass + server address BEFORE stopping (they're in the tracker's settings)
        String token = null;
        String url = null;
        String apiKey = null;
        try {
            JSONObject config = TSConfig.getInstance(context).toJson(false);
            JSONObject http = config.optJSONObject("http") != null ? config.optJSONObject("http") : config;
            JSONObject params = http.optJSONObject("params");
            JSONObject headers = http.optJSONObject("headers");
            url = http.optString("url", null);
            token = params != null ? params.optString("p_token", null) : null;
            apiKey = headers != null ? headers.optString("apikey", null) : null;
        } catch (Exception e) {
            Log.e(TAG, "Could not read the tracker settings", e);
        }

        BackgroundGeolocation bg = BackgroundGeolocation.getInstance(context);
        bg.stop(); // also removes the "Sharing your location" notification
        bg.destroyLocations(); // queued readings would only be refused with the cancelled pass

        if (tellServer && token != null && url != null && url.contains("/rpc/report_location")) {
            final String stopUrl = url.replace("/rpc/report_location", "/rpc/stop_sharing_with_pass");
            final String body = "{\"p_token\":\"" + token + "\"}";
            final String key = apiKey;
            new Thread(() -> post(stopUrl, body, key)).start(); // no network on the main thread
        }
    }

    private static void post(String address, String body, String apiKey) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(address).openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(15000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json");
            if (apiKey != null) connection.setRequestProperty("apikey", apiKey);
            try (OutputStream out = connection.getOutputStream()) {
                out.write(body.getBytes(StandardCharsets.UTF_8));
            }
            Log.i(TAG, "stop_sharing_with_pass -> HTTP " + connection.getResponseCode());
        } catch (Exception e) {
            Log.e(TAG, "Could not tell the server that sharing stopped", e); // offline: map shows "lost contact"
        } finally {
            if (connection != null) connection.disconnect();
        }
    }
}
