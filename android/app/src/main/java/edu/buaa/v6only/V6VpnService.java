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
import android.util.Log;
import java.io.IOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;

/** Campus-only VPN with IPv6-before-IPv4 forwarding over protected physical sockets. */
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
    private boolean stopping;
    private volatile Network coreNetwork;
    private long coreGeneration;

    @Override public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences("v6only", MODE_PRIVATE);
        getSystemService(NotificationManager.class).createNotificationChannel(
                silentChannel());
        watcher = new CampusWatcher(this, handler, this::reconcile);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        // Foreground first, including stop/restore intents delivered via startForegroundService.
        startForeground(NOTIF_ID, notification("正在检查网络"));
        V6VpnServiceExt.setAlwaysOn(isAlwaysOn());
        if (ACTION_STOP.equals(action)) {
            prefs.edit().putBoolean("enabled", false).commit();
            stopEverything();
            return START_NOT_STICKY;
        }
        if (ACTION_START.equals(action) || (intent != null && VpnService.SERVICE_INTERFACE.equals(action)) || isAlwaysOn()) prefs.edit().putBoolean("enabled", true).commit();
        if (!prefs.getBoolean("enabled", false)) {
            stopEverything();
            return START_NOT_STICKY;
        }
        // Monitoring does not own a VPN. Preparing before campus detection can
        // revoke another app's VPN even though we will only stand by on cellular.
        V6VpnServiceExt.setMonitoring(true);
        // Re-register after a permission change so SSID callbacks can include location info.
        if (ACTION_APPLY.equals(action)) watcher.stop();
        watcher.start();
        watcher.refresh();
        return START_STICKY;
    }

    protected void reconcile(CampusWatcher.State state) {
        if (destroyed || !prefs.getBoolean("enabled", false)) return;
        handler.removeCallbacks(retry);
        V6VpnServiceExt.setPermissionRequired(false);
        V6VpnServiceExt.setCampus(state.isCampus(), state.campusReason);
        boolean automatic = prefs.getBoolean("auto", true);
        boolean campusOnly = prefs.getBoolean("campus_only", false);
        if (state.network == null || (campusOnly && !CampusPolicy.shouldConnect(true, automatic, state.isCampus(), true))) {
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
            closeTun();
            V6VpnServiceExt.setPermissionRequired(true);
            publish("请打开应用完成连接授权");
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
            publish("已连接");
            return;
        }
        try {
            List<String> servers = new ArrayList<>();
            for (InetAddress address : dns) servers.add(address.getHostAddress());
            establishTunnel(state.network, servers, metered);
            configuration = key;
            V6VpnServiceExt.setRunning(true);
            Log.i("V6VpnService", "IPv6 forwarding VPN established on " + state.network + ", DNS=" + dns);
            publish("已连接");
        } catch (Exception error) {
            // Fail open: never leave a broken tunnel behind and black-hole browser traffic.
            closeTun();
            Log.e("V6VpnService", "Cannot configure VPN", error);
            publish("连接失败，已恢复系统网络；稍后重试");
            handler.postDelayed(retry, 5000);
        }
    }

    // Shared by the production controller and the test-only emulator service.
    protected final void establishTunnel(Network network, List<String> dns, boolean metered) throws Exception {
            // Tear down the old stack before replacing its TUN or physical network.
            closeTun();
            coreNetwork = network;
            Builder builder = new Builder().setSession("V6Only")
                    .setMtu(1500)
                    .addAddress("198.18.0.1", 15)
                    .addAddress("fd00:198:18::1", 64)
                    .addRoute("0.0.0.0", 0)
                    .addRoute("::", 0)
                    .addDnsServer("198.18.0.2")
                    .setMetered(metered)
                    .setUnderlyingNetworks(new Network[]{network})
                    .setConfigureIntent(openActivity());
            ParcelFileDescriptor next = builder.establish();
            if (next == null) throw new IOException("VPN authorization was revoked");
            tun = next;
            org.json.JSONArray servers = new org.json.JSONArray();
            for (String address : dns) servers.put(address);
            org.json.JSONArray fallback = new org.json.JSONArray();
            for (String address : publicDns(network)) fallback.put(address);
            org.json.JSONObject config = new org.json.JSONObject().put("dns", servers).put("ipv6_dns", fallback)
                    .put("chatgpt_ipv4", true).put("stats_db", new java.io.File(getFilesDir(), "traffic.sqlite").getAbsolutePath())
                    .put("fake_dns", true).put("generation",coreGeneration);
            String error = CoreNative.start(next.getFd(), config.toString(), this);
            if (!error.isEmpty()) throw new IOException(error);
    }

    protected List<String> publicDns(Network network) {
        android.net.LinkProperties links = getSystemService(android.net.ConnectivityManager.class).getLinkProperties(network);
        boolean v6 = links != null && links.getLinkAddresses().stream().anyMatch(a -> a.getAddress() instanceof Inet6Address && (a.getAddress().getAddress()[0] & 0xe0) == 0x20);
        return java.util.Arrays.asList(v6 ? new String[]{"2400:3200::1", "2400:3200:baba::1", "223.5.5.5", "223.6.6.6"} : new String[]{"223.5.5.5", "223.6.6.6"});
    }

    private PendingIntent openActivity() {
        return PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private NotificationChannel silentChannel() {
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "连接状态", NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null, null); channel.enableVibration(false); channel.setShowBadge(false); return channel;
    }

    private Notification notification(String message) {
        PendingIntent stop = PendingIntent.getService(this, 1,
                new Intent(this, V6VpnService.class).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("V6Only").setContentText(message)
                .setSmallIcon(android.R.drawable.ic_lock_lock).setContentIntent(openActivity())
                .setOnlyAlertOnce(true).setSound(null).setVibrate(new long[0])
                .setOngoing(true).setCategory(Notification.CATEGORY_SERVICE);
        if (!isAlwaysOn()) builder.addAction(new Notification.Action.Builder(null, "停止服务", stop).build());
        return builder.build();
    }

    private void publish(String message) {
        V6VpnServiceExt.setMessage(message);
        if (V6VpnServiceExt.monitoring())
            getSystemService(NotificationManager.class).notify(NOTIF_ID, notification(message));
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
    }

    // JNI uses this for every outbound socket, including DNS, to prevent VPN loops.
    public boolean protectCoreSocket(int fd) {
        Network physical = coreNetwork;
        if (physical == null || !protect(fd)) return false;
        try (ParcelFileDescriptor copy = ParcelFileDescriptor.fromFd(fd)) {
            physical.bindSocket(copy.getFileDescriptor());
            return true;
        } catch (IOException error) { return false; }
    }

    protected final void closeTun() {
        coreGeneration++;
        boolean ownedCore = coreNetwork != null;
        // Reject outgoing sockets from the old generation as soon as handover starts.
        coreNetwork = null;
        if (tun != null) {
            try { tun.close(); } catch (IOException error) { Log.w("V6VpnService", "Close TUN", error); }
            tun = null;
        }
        if (ownedCore) {
            CoreNative.stop();
            try { setUnderlyingNetworks(null); }
            catch (SecurityException revoked) { Log.i("V6VpnService", "VPN already revoked"); }
        }
        configuration = "";
        V6VpnServiceExt.setRunning(false);
    }

    public void onCoreFailure(long generation,String error) {
        handler.post(() -> {
            if (generation!=coreGeneration || destroyed) return;
            Log.e("V6VpnService",error);
            prefs.edit().putBoolean("enabled",false).commit();
            stopEverything();
            publish("转发异常，已恢复系统网络；请检查后手动启动");
        });
    }

    private void stopEverything() {
        stopping = true;
        handler.removeCallbacks(retry);
        watcher.stop();
        closeTun();
        V6VpnServiceExt.setMonitoring(false);
        V6VpnServiceExt.setAlwaysOn(false);
        V6VpnServiceExt.setPermissionRequired(false);
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
        V6VpnServiceExt.setAlwaysOn(false);
        V6VpnServiceExt.setPermissionRequired(false);
        // Keep the reason for an explicit shutdown visible after service destruction.
        publish(stopping ? V6VpnServiceExt.message() : "服务已停止");
        super.onDestroy();
    }
}
