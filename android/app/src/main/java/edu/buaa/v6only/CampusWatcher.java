package edu.buaa.v6only;

import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.VpnService;
import android.net.wifi.WifiManager;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 校园网检测器（与 macOS 侧 v6-watch.sh 同构，多信号任一命中即认定）：
 *  1. DNS 服务器 ∈ 校园段（202.112.128.0/24 等）
 *  2. 本机/网关 IPv4 ∈ 10/8（校园大二层；模拟器网关 10.0.2.2 亦命中，便于测试）
 *  3. DHCP 域名含 buaa.edu.cn
 *  4. SSID 以 BUAA 开头（需定位权限，尽力而为）
 *
 * 注意：不过滤 NET_CAPABILITY_INTERNET —— Portal 未认证的校园网恰好没有
 * 该 capability，若按它过滤会出现「连着校园网却显示未接入」的误报。
 */
public final class CampusWatcher {

    private static final AtomicBoolean REGISTERED = new AtomicBoolean(false);
    private static ConnectivityManager cm;
    private static ConnectivityManager.NetworkCallback cb;
    private static volatile boolean lastCampus = false;
    private static volatile String lastReason = "";
    private static Context appCtx;

    /** 单网络判定：返回命中的信号名，未命中返回 null */
    private static String matchNetwork(ConnectivityManager c, Network n) {
        LinkProperties lp = c.getLinkProperties(n);
        NetworkCapabilities caps = c.getNetworkCapabilities(n);
        if (lp == null) return null;

        // 信号1：DNS 服务器地址
        List<InetAddress> dns = lp.getDnsServers();
        if (dns != null) {
            for (InetAddress d : dns) {
                if (d instanceof Inet4Address && isCampusDns(d.getAddress())) return "dns";
            }
        }
        // 信号2：本机 IPv4 ∈ 10/8
        for (android.net.LinkAddress la : lp.getLinkAddresses()) {
            InetAddress a = la.getAddress();
            if (a instanceof Inet4Address && (a.getAddress()[0] & 0xFF) == 10) return "subnet";
        }
        // 信号3：DHCP 域名
        String dom = lp.getDomains();
        if (dom != null && dom.toLowerCase().contains("buaa.edu.cn")) return "domain";

        if (caps == null) return null;
        // 信号4：SSID（有定位权限才拿得到，尽力而为）
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            try {
                WifiManager wm = (WifiManager) appCtx.getSystemService(Context.WIFI_SERVICE);
                String ssid = wm != null ? wm.getConnectionInfo().getSSID() : null;
                if (ssid != null && ssid.replace("\"", "").toUpperCase().startsWith("BUAA"))
                    return "ssid";
            } catch (Exception ignored) {}
        }
        return null;
    }

    private static boolean isCampusDns(byte[] a) {
        int b0 = a[0] & 0xFF, b1 = a[1] & 0xFF;
        return (b0 == 202 && b1 == 112)        // 202.112.128.50/51 校园 DNS
                || (b0 == 10 && b1 == 0)       // 常见校内网关型 DNS
                || (b0 == 10 && b1 == 135);    // 10.135.x 段
    }

    public static boolean isCampus(Context ctx) {
        ConnectivityManager c =
                (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (c == null) return false;
        for (Network n : c.getAllNetworks()) {
            String hit = matchNetwork(c, n);
            if (hit != null) { lastReason = hit; return true; }
        }
        lastReason = "";
        return false;
    }

    public static String lastReason() { return lastReason; }

    public static synchronized void start(Context ctx) {
        if (REGISTERED.get()) return;
        appCtx = ctx.getApplicationContext();
        cm = (ConnectivityManager) appCtx.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) return;

        cb = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) { evaluate(); }
            @Override public void onLost(Network network) { evaluate(); }
            @Override public void onLinkPropertiesChanged(Network n, LinkProperties lp) { evaluate(); }
        };
        cm.registerNetworkCallback(
                new NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .build(),
                cb);
        // callback 只覆盖带 INTERNET 的网络；再补一次全网络扫描（含 Portal 未认证网络）
        REGISTERED.set(true);
        evaluate();
    }

    public static synchronized void stop(Context ctx) {
        if (!REGISTERED.get()) return;
        try { cm.unregisterNetworkCallback(cb); } catch (Exception ignored) {}
        REGISTERED.set(false);
    }

    private static void evaluate() {
        boolean campus = isCampus(appCtx);
        if (campus == lastCampus) return;
        lastCampus = campus;
        Intent i = new Intent(appCtx, V6VpnService.class)
                .setAction(campus ? V6VpnService.ACTION_START : V6VpnService.ACTION_STOP);
        try {
            if (campus) {
                if (VpnService.prepare(appCtx) == null) {
                    appCtx.startForegroundService(i);
                }
            } else {
                appCtx.startService(i);
            }
        } catch (Exception ignored) {}
    }
}
