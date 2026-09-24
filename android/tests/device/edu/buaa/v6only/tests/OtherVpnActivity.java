package edu.buaa.v6only.tests;
import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
/** Starts the protected test service from its own UID, as a real VPN app would. */
public final class OtherVpnActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        startForegroundService(new Intent(this, OtherVpn.class).setAction("start"));
        finish();
    }
}
