package edu.buaa.v6only;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/** 开机自启：恢复自动模式（默认开），挂上校园网检测回调 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        SharedPreferences p = ctx.getSharedPreferences("v6only", Context.MODE_PRIVATE);
        if (p.getBoolean("auto", true)) {
            CampusWatcher.start(ctx);
        }
    }
}
