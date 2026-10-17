package sg.edu.smu.is216.g11;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.util.Base64;
import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.OutputStream;

// SaveFile: lets the phone app save a file the page made (run sheet Excel export and template, merger Stage 5).
// A browser download (<a download>) does nothing inside the app's WebView, so the page sends the bytes here and
// Android's own "Save to..." screen opens (Downloads, Drive, ...). No storage permission is needed: the person
// picks the place, and the app may write only that one file.
@CapacitorPlugin(name = "SaveFile")
public class SaveFilePlugin extends Plugin {

    // { name: "Run sheet - Rehearsal 2.xlsx", mimeType, base64 } -> { saved: true | false (cancelled) }
    @PluginMethod
    public void save(PluginCall call) {
        String name = call.getString("name");
        String data = call.getString("base64");
        if (name == null || data == null) {
            call.reject("Nothing to save");
            return;
        }
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType(call.getString("mimeType", "application/octet-stream"));
        intent.putExtra(Intent.EXTRA_TITLE, name);
        startActivityForResult(call, intent, "written");
    }

    @ActivityCallback
    private void written(PluginCall call, ActivityResult result) {
        if (call == null) return;
        JSObject out = new JSObject();
        Uri uri = result.getData() == null ? null : result.getData().getData();
        if (result.getResultCode() != Activity.RESULT_OK || uri == null) {
            out.put("saved", false);
            call.resolve(out);
            return;
        }
        try (OutputStream stream = getContext().getContentResolver().openOutputStream(uri, "w")) {
            if (stream == null) throw new Exception("The place picked cannot be written to");
            stream.write(Base64.decode(call.getString("base64"), Base64.DEFAULT));
            out.put("saved", true);
            call.resolve(out);
        } catch (Exception e) {
            call.reject("Could not save the file: " + e.getMessage());
        }
    }
}
