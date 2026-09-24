package edu.buaa.v6only;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;
import android.util.Log;
import java.io.IOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;

/** DNS configuration VPN. All real traffic uses Android's native IP/TCP/UDP stack. */
public class V6VpnService extends VpnService {
    public static final String ACTION_START = "edu.buaa.v6only.START";
    public static final String ACTION_STOP = "edu.buaa.v6only.STOP";
    public static final String ACTION_APPLY = "edu.buaa.v6only.APPLY";
    public static final String ACTION_STATUS = "edu.buaa.v6only.STATUS";
    private static final String CHANNEL_ID = "v6only";
    private static final int NOTIF_ID = 1;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private SharedPreferences prefs;
    private CampusWatcher watcher;
    private final Runnable retry = () -> { if (watcher != null) watcher.refresh(); };
    private ParcelFileDescriptor tun;
    private String configuration = "";
    private boolean destroyed;

    @Override public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences("v6only", MODE_PRIVATE);
        getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL_ID, "v6only 后台服务", NotificationManager.IMPORTANCE_LOW));
        watcher = new CampusWatcher(this, handler, this::reconcile);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        // Foreground first, including stop/restore intents delivered via startForegroundService.
        startForeground(NOTIF_ID, notification("正在检查网络"));
        if (ACTION_STOP.equals(action)) {
            prefs.edit().putBoolean("enabled", false).commit();
            stopEverything();
            return START_NOT_STICKY;
        }
        if (ACTION_START.equals(action)) prefs.edit().putBoolean("enabled", true).commit();
        if (!prefs.getBoolean("enabled", false)) {
            stopEverything();
            return START_NOT_STICKY;
        }
        if (prepare(this) != null) {
            prefs.edit().putBoolean("enabled", false).commit();
            stopEverything();
            publish("需要重新授权 VPN");
            return START_NOT_STICKY;
        }
        V6VpnServiceExt.setMonitoring(true);
        // Re-register after a permission change so SSID callbacks can include location info.
        if (ACTION_APPLY.equals(action)) watcher.stop();
        watcher.start();
        watcher.refresh();
        return START_STICKY;
    }

    private void reconcile(CampusWatcher.State state) {
        if (destroyed || !prefs.getBoolean("enabled", false)) return;
        handler.removeCallbacks(retry);
        V6VpnServiceExt.setCampus(state.isCampus(), state.campusReason);
        boolean automatic = prefs.getBoolean("auto", true);
        if (!CampusPolicy.shouldConnect(true, automatic, state.isCampus(), state.network != null)) {
            closeTun();
            if (!automatic && state.network != null && !state.isCampus()) {
                prefs.edit().putBoolean("enabled", false).commit();
                stopEverything();
                publish("当前非校园网，手动服务已停止");
                return;
            }
            publish(state.network == null ? "等待网络连接" : "自动模式：等待接入校园网");
            return;
        }
        if (prepare(this) != null) {
            onRevoke();
            return;
        }
        // Keep the network-provided DNS servers so campus/internal names continue to work.
        // Prefer IPv6 DNS transport where the physical network has a matching route.
        List<InetAddress> dns = new ArrayList<>(state.links.getDnsServers());
        dns.removeIf(address -> address.isAnyLocalAddress() || address.isLoopbackAddress()
                || state.links.getRoutes().stream().noneMatch(route -> route.matches(address)));
        dns.sort((a, b) -> Boolean.compare(!(a instanceof Inet6Address), !(b instanceof Inet6Address)));
        if (dns.isEmpty()) {
            closeTun();
            publish("等待网络提供可用 DNS");
            return;
        }
        boolean metered = !state.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        String key = state.network + ":" + dns + ":" + state.links.getDomains() + ":" + metered;
        if (tun != null && key.equals(configuration)) {
            publish(automatic ? "自动模式：校园网已连接" : "手动模式：已连接");
            return;
        }
        try {
            Builder builder = new Builder().setSession("v6only · IPv6 优先")
                    .setMtu(1500)
                    .addAddress("192.0.2.1", 32)
                    // Not adding IPv6 addresses/routes alone would BLOCK IPv6. Both families
                    // must be allowed explicitly so unmatched traffic falls through natively.
                    .allowFamily(OsConstants.AF_INET)
                    .allowFamily(OsConstants.AF_INET6)
                    .setMetered(metered)
                    .setUnderlyingNetworks(new Network[]{state.network})
                    .setConfigureIntent(openActivity());
            for (InetAddress address : dns) builder.addDnsServer(address);
            String domains = state.links.getDomains();
            if (domains != null) {
                for (String domain : domains.trim().split("\\s+")) {
                    if (!domain.isEmpty()) builder.addSearchDomain(domain);
                }
            }
            // No default route, fake DNS, exclusion whitelist, or TUN packet echo. Android
            // reaches these real resolvers (including TCP/Private DNS) on the physical network.
            ParcelFileDescriptor next = builder.establish();
            if (next == null) throw new IOException("VPN authorization was revoked");
            closeTun();
            tun = next;
            configuration = key;
            V6VpnServiceExt.setRunning(true);
            Log.i("V6VpnService", "DNS VPN established on " + state.network + ", DNS=" + dns);
            publish(automatic ? "自动模式：校园网已连接" : "手动模式：已连接");
        } catch (Exception error) {
            // Fail open: never leave a broken tunnel behind and black-hole browser traffic.
            closeTun();
            Log.e("V6VpnService", "Cannot configure VPN", error);
            publish("连接失败，已恢复系统网络；稍后重试");
            handler.postDelayed(retry, 5000);
        }
    }

    private PendingIntent openActivity() {
        return PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private Notification notification(String message) {
        PendingIntent stop = PendingIntent.getService(this, 1,
                new Intent(this, V6VpnService.class).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("v6only 后台服务")
                .setContentText(message)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentIntent(openActivity())
                .addAction(new Notification.Action.Builder(null, "停止服务", stop).build())
                .setOnlyAlertOnce(true).setOngoing(true).build();
    }

    private void publish(String message) {
        V6VpnServiceExt.setMessage(message);
        if (V6VpnServiceExt.monitoring())
            getSystemService(NotificationManager.class).notify(NOTIF_ID, notification(message));
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
    }

    private void closeTun() {
        if (tun != null) {
            try { tun.close(); } catch (IOException error) { Log.w("V6VpnService", "Close TUN", error); }
            tun = null;
        }
        configuration = "";
        V6VpnServiceExt.setRunning(false);
    }

    private void stopEverything() {
        handler.removeCallbacks(retry);
        watcher.stop();
        closeTun();
        V6VpnServiceExt.setMonitoring(false);
        V6VpnServiceExt.setCampus(false, "");
        publish("服务已停止");
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    @Override public void onTaskRemoved(Intent rootIntent) {
        // Swiping the activity from Recents must not stop this foreground service.
        Log.i("V6VpnService", "Activity removed; foreground monitoring continues");
        super.onTaskRemoved(rootIntent);
    }

    @Override public void onRevoke() {
        // Can be called off the main thread. A user/system revocation is an explicit stop.
        handler.post(() -> {
            prefs.edit().putBoolean("enabled", false).commit();
            stopEverything();
            publish("VPN 授权已撤销，请在应用内重新启动");
        });
    }

    @Override public void onDestroy() {
        destroyed = true;
        handler.removeCallbacksAndMessages(null);
        watcher.stop();
        closeTun();
        V6VpnServiceExt.setMonitoring(false);
        publish("服务已停止");
        super.onDestroy();
    }
}
