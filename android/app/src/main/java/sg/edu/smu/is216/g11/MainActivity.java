package sg.edu.smu.is216.g11;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(PhoneSettingsPlugin.class); // the app's own plugin (PhoneSettingsPlugin.java)
        registerPlugin(SaveFilePlugin.class); // "Save to..." for files the page makes (SaveFilePlugin.java)
        super.onCreate(savedInstanceState);
    }
}
