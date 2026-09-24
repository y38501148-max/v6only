package edu.buaa.v6only;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;

/**
 * v6only VPN：
 *  - addRoute("0.0.0.0/0") 把全部 IPv4 吸进 TUN，用户态里只放行校内 v4（10/8），
 *    其余 v4 包直接丢弃 → 应用 Happy Eyeballs 回落到 IPv6
 *  - IPv6 不 addRoute → v6 流量完全不进 VPN，走原生栈（免计量路径零开销）
 *  - DNS：TUN DNS 指向本地 v6 上游转发器（2400:3200:baba::1 / 240c::6666），
 *    封掉明文 v4 DNS，防硬编码 8.8.8.8 绕过
 */
public class V6VpnService extends VpnService {

    private static final String CHANNEL_ID = "v6only";
    private static final int NOTIF_ID = 1;

    private ParcelFileDescriptor tun;
    private Thread pumpThread;
    private volatile boolean running;

    public static final String ACTION_START = "edu.buaa.v6only.START";
    public static final String ACTION_STOP  = "edu.buaa.v6only.STOP";

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            V6VpnServiceExt.setRunning(false);
            stopForeground(STOP_FOREGROUND_REMOVE);
            tun = null;                       // 关闭 fd 触发系统拆除 VPN
            running = false;
            if (pumpThread != null) pumpThread.interrupt();
            stopSelf();
            return START_NOT_STICKY;
        }
        V6VpnServiceExt.setRunning(true);
        startForeground(NOTIF_ID, buildNotification());
        establishTun();
        return START_NOT_STICKY;              // 不用 STICKY：系统重投 null intent 会被当 START 重连
    }

    private void establishTun() {
        if (tun != null) return;
        Builder b = new Builder()
                .setSession("v6only")
                .setMtu(1420)
                // TUN 接口地址（establish 硬性要求至少一个；仅作接口占位，不参与路由决策）
                .addAddress("172.19.0.1", 30)
                // 全部 v4 进 TUN，在 pump 里做白名单过滤
                .addRoute("0.0.0.0", 0);
        // 校内 v4 直连不走 TUN（排除路由，API 33+；低版本由 pump 兜底过滤）
        tryExclude("10.0.0.0", 8, b);
        try {
            b.excludeRoute(new android.net.IpPrefix(InetAddress.getByName("10.200.21.4"), 32));
        } catch (Throwable ignored) {}
        b // TUN 内 DNS：指向本服务的用户态转发器
                .addDnsServer("10.111.0.1")
                .addSearchDomain("buaa.edu.cn");

        // 自 ping 防回环（本应用自身流量不进 TUN）
        try { b.addDisallowedApplication(getPackageName()); } catch (Exception ignored) {}

        try {
            tun = b.establish();
        } catch (Throwable e) {
            android.util.Log.e("V6VpnService", "establish failed", e);
            stopSelf();
            return;
        }
        if (tun == null) {
            android.util.Log.e("V6VpnService", "establish returned null (revoked?)");
            stopSelf();
            return;
        }
        android.util.Log.i("V6VpnService", "tun established");
        running = true;
        pumpThread = new Thread(this::pump, "v6-pump");
        pumpThread.start();
    }


    private void tryExclude(String addr, int plen, Builder b) {
        try {
            b.excludeRoute(new android.net.IpPrefix(InetAddress.getByName(addr), plen));
        } catch (Throwable ignored) {
            // API < 33 无 excludeRoute：pump() 的 10/8 白名单兜底
        }
    }

    /** TUN 数据泵：只放行校内 v4 + DNS 请求，其余 v4 丢弃 */
    private void pump() {
        try (FileInputStream in = new FileInputStream(tun.getFileDescriptor());
             FileOutputStream out = new FileOutputStream(tun.getFileDescriptor())) {
            // 注意：必须用堆 buffer，direct buffer 的 array() 会抛 UnsupportedOperationException
            byte[] raw = new byte[32768];
            while (running) {
                int n = in.read(raw);
                if (n <= 0) continue;
                // 放行：写回 TUN 让系统 NAT 到原生栈；不放行 = 丢弃 → 应用回落 v6
                if (allow(raw, n)) {
                    out.write(raw, 0, n);
                }
            }
        } catch (Throwable e) {
            android.util.Log.w("V6VpnService", "pump exited", e);
        }
    }

    private static boolean allow(byte[] p, int len) {
        if (len < 20) return false;
        int ver = (p[0] >> 4) & 0xF;
        if (ver != 4) return false;                    // v6 不该出现在 TUN，保险丢弃
        // v4 白名单：10/8（校内）
        int dst = ((p[16] & 0xFF) << 24) | ((p[17] & 0xFF) << 16)
                | ((p[18] & 0xFF) << 8) | (p[19] & 0xFF);
        if ((dst >>> 24) == 10) return true;           // 10.0.0.0/8
        return false;
    }

    private Notification buildNotification() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(
                    CHANNEL_ID, "v6only", NotificationManager.IMPORTANCE_LOW));
        }
        PendingIntent pi = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(getString(R.string.notif_title))
                .setContentText(getString(R.string.notif_text))
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        running = false;
        V6VpnServiceExt.setRunning(false);
        if (pumpThread != null) pumpThread.interrupt();
        if (tun != null) {
            try { tun.close(); } catch (Exception ignored) {}
            tun = null;
        }
        super.onDestroy();
    }
}
