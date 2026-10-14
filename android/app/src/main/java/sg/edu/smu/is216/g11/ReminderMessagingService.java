package sg.edu.smu.is216.g11;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import com.capacitorjs.plugins.pushnotifications.MessagingService;
import com.google.firebase.messaging.RemoteMessage;
import java.util.Map;

/**
 * Draws the "Event started - share your location" push reminder ourselves, so it can have a
 * "Start sharing" button. (Pushes drawn by Firebase can't have buttons.)
 *
 * The server (Edge Function send-reminders) sends these as DATA messages
 * { kind: "event-start", eventId, title, body }, which reach this code even when the app is
 * closed. Tapping the notification or its button opens the app with the same extras a normal
 * Firebase notification would have, so @capacitor/push-notifications reports a
 * "pushNotificationActionPerformed" and the app opens the event and starts sharing
 * (usePushNotifications.js + EventView.vue ?share=1).
 *
 * Every other message goes to the Capacitor plugin as before (super.onMessageReceived).
 */
public class ReminderMessagingService extends MessagingService {

    static final String CHANNEL_ID = "event-start"; // same id the app creates in usePushNotifications.js

    @Override
    public void onMessageReceived(@NonNull RemoteMessage message) {
        Map<String, String> data = message.getData();
        if ("event-start".equals(data.get("kind")) && data.get("eventId") != null) {
            showReminder(message, data);
        }
        super.onMessageReceived(message); // app open: JavaScript also gets it (shows a toast)
    }

    private void showReminder(RemoteMessage message, Map<String, String> data) {
        String eventId = data.get("eventId");
        String title = data.containsKey("title") ? data.get("title") : "Event started";
        String body = data.containsKey("body") ? data.get("body") : "Tap Start sharing to share your location.";

        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Event start reminders", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("Reminds ICs to share their location when an event starts");
            manager.createNotificationChannel(channel);
        }

        // Same notification for one event: a newer reminder replaces the older one
        String tag = "event-start-" + eventId;
        int requestCode = eventId.hashCode();

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_location)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setOngoing(true) // stays until sharing starts (Android 14+ still lets people swipe it away)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(message, data, requestCode, "tap"))
            .addAction(0, "Start sharing", openAppIntent(message, data, requestCode + 1, "start-sharing"));

        manager.notify(tag, 1, builder.build());
    }

    // Opens the app with the extras the Capacitor push plugin looks for ("google.message_id")
    private PendingIntent openAppIntent(RemoteMessage message, Map<String, String> data, int requestCode, String actionId) {
        Intent intent = new Intent(this, MainActivity.class);
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        intent.putExtra("google.message_id", message.getMessageId() != null ? message.getMessageId() : "reminder");
        for (Map.Entry<String, String> entry : data.entrySet()) {
            intent.putExtra(entry.getKey(), entry.getValue());
        }
        intent.putExtra("actionId", actionId);
        return PendingIntent.getActivity(this, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }
}
