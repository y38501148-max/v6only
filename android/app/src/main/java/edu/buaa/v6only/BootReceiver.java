package edu.buaa.v6only;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/** Restore the user's enabled service after boot/update, even away from campus. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) return;
        android.content.SharedPreferences prefs = context.getSharedPreferences("v6only", Context.MODE_PRIVATE);
        if (!prefs.getBoolean("enabled", false) || !prefs.getBoolean("auto", true)) return;
        if (android.net.VpnService.prepare(context) != null) return;
        try {
            context.startForegroundService(new Intent(context, V6VpnService.class)
                    .setAction(V6VpnService.ACTION_APPLY));
        } catch (RuntimeException error) {
            Log.e("V6VpnService", "System blocked background service restoration", error);
        }
    }
}
