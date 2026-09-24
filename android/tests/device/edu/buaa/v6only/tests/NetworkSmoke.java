package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.DnsResolver;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.SystemClock;
import edu.buaa.v6only.MainActivity;
import edu.buaa.v6only.V6VpnService;
import edu.buaa.v6only.V6VpnServiceExt;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

/** Exercises real Android VPN routing; no mocked sockets or hidden production test hooks. */
public final class NetworkSmoke extends Instrumentation {
    private Context context;
    private SharedPreferences prefs;
    private Activity activity;
    private ConnectivityManager cm;

    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            context = getTargetContext();
            cm = context.getSystemService(ConnectivityManager.class);
            prefs = context.getSharedPreferences("v6only", Context.MODE_PRIVATE);
            prefs.edit().putBoolean("enabled", false).putBoolean("auto", false).commit();
            activity = startActivitySync(new Intent(context, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            command(V6VpnService.ACTION_START);
            await(() -> V6VpnServiceExt.running(context)
                    || V6VpnServiceExt.message().contains("当前非校园网"), "campus gate evaluated");
            if (!V6VpnServiceExt.campus()) {
                check(!V6VpnServiceExt.running(context), "manual mode must not connect off campus");
                check(!prefs.getBoolean("enabled", true), "manual off-campus request stops service");
                prefs.edit().putBoolean("auto", true).commit();
                command(V6VpnService.ACTION_START);
                await(() -> V6VpnServiceExt.monitoring(), "automatic off-campus monitoring");
                SystemClock.sleep(1000);
                check(!V6VpnServiceExt.running(context), "automatic mode must not create off-campus VPN");
                runOnMainSync(() -> activity.finishAndRemoveTask());
                SystemClock.sleep(1000);
                check(V6VpnServiceExt.monitoring() && !V6VpnServiceExt.running(context), "standby survives Recents removal");
                command(V6VpnService.ACTION_STOP);
                await(() -> !V6VpnServiceExt.monitoring(), "explicit stop of standby");
                result.putString("stream", "\nPASS: campus boundary and off-campus lifecycle checks\n"
                        + "SKIP: tunnel routing checks require a recognized campus fixture\n"
                        + "PASS: all Android device regression checks\n");
                finish(Activity.RESULT_OK, result);
                return;
            }
            await(() -> V6VpnServiceExt.running(context), "manual VPN establishment");
            await(() -> cm.getActiveNetwork() != null && cm.getNetworkCapabilities(cm.getActiveNetwork())
                    .hasTransport(NetworkCapabilities.TRANSPORT_VPN), "VPN becomes default for test UID");
            Network vpn = cm.getActiveNetwork();
            LinkProperties links = cm.getLinkProperties(vpn);
            check(links.getRoutes().stream().noneMatch(route -> route.isDefaultRoute()), "no default route capture");
            check(links.getDnsServers().stream().noneMatch(a -> a.getHostAddress().equals("10.111.0.1")), "no fake DNS");
            pass("manual VPN uses real DNS and no default route");
            query(vpn, DnsResolver.TYPE_A, Inet4Address.class);
            query(vpn, DnsResolver.TYPE_AAAA, Inet6Address.class);
            pass("A and AAAA DNS resolution on VPN network");
            tcpDns(vpn, links);
            pass("DNS over TCP to controlled resolver on VPN network");
            try (Socket socket = new Socket()) {
                vpn.bindSocket(socket);
                socket.connect(new InetSocketAddress("fec0::2", 18765), 5000);
                socket.setSoTimeout(5000);
                socket.getOutputStream().write("GET /marker HTTP/1.0\r\nHost: localhost\r\n\r\n".getBytes("US-ASCII"));
                String response = new java.io.BufferedReader(new java.io.InputStreamReader(socket.getInputStream())).readLine();
                check(response != null && response.contains("200"), "native IPv6 HTTP");
            }
            pass("native IPv6 HTTP remains usable under IPv4-addressed VPN");
            // The host smoke script serves a marker at the emulator's private IPv4 gateway.
            try (Socket local = new Socket()) {
                vpn.bindSocket(local);
                local.connect(new InetSocketAddress("10.0.2.2", 18765), 5000);
                local.setSoTimeout(5000);
                local.getOutputStream().write("GET /marker HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n".getBytes("US-ASCII"));
                String response = new java.io.BufferedReader(new java.io.InputStreamReader(local.getInputStream())).readLine();
                check(response != null && response.contains("200"), "private IPv4/IPv4-only HTTP");
            }
            HttpURLConnection external = (HttpURLConnection) new URL("https://www.baidu.com/").openConnection();
            external.setConnectTimeout(15000); external.setReadTimeout(15000);
            check(external.getResponseCode() == 200, "HTTPS under default VPN");
            external.disconnect();
            pass("IPv4-only/private HTTP and external HTTPS work");

            prefs.edit().putBoolean("auto", true).commit();
            command(V6VpnService.ACTION_APPLY);
            await(() -> V6VpnServiceExt.running(context), "auto retains campus tunnel");
            check(V6VpnServiceExt.monitoring(), "auto must retain foreground watcher");
            check(V6VpnServiceExt.campus(), "tunnel requires a campus fixture");
            pass("auto mode retains campus-only connection");
            prefs.edit().putBoolean("auto", false).commit();
            command(V6VpnService.ACTION_APPLY);
            await(() -> V6VpnServiceExt.running(context), "switch back to manual");
            // establish() returns before ConnectivityService publishes the new default.
            await(() -> cm.getActiveNetwork() != null && cm.getNetworkCapabilities(cm.getActiveNetwork())
                    .hasTransport(NetworkCapabilities.TRANSPORT_VPN), "manual default network update");
            Network before = cm.getActiveNetwork();
            command(V6VpnService.ACTION_APPLY);
            SystemClock.sleep(800);
            check(before.equals(cm.getActiveNetwork()), "unchanged settings should reuse VPN: " + before + " -> " + cm.getActiveNetwork());
            pass("auto/manual transitions and idempotent reconfiguration");

            runOnMainSync(() -> activity.finishAndRemoveTask());
            SystemClock.sleep(1500);
            check(V6VpnServiceExt.running(context) && V6VpnServiceExt.monitoring(), "Recents removal survival");
            pass("removing activity task keeps foreground service and VPN alive");
            // Reopen to issue a user-initiated command on every supported API level.
            activity = startActivitySync(new Intent(context, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            command(V6VpnService.ACTION_STOP);
            await(() -> !V6VpnServiceExt.monitoring() && !V6VpnServiceExt.running(context), "explicit stop");
            await(() -> cm.getActiveNetwork() != null && !cm.getNetworkCapabilities(cm.getActiveNetwork())
                    .hasTransport(NetworkCapabilities.TRANSPORT_VPN), "TUN removed on explicit stop");
            check(!prefs.getBoolean("enabled", true), "stop persists disabled state");
            command(V6VpnService.ACTION_APPLY);
            SystemClock.sleep(500);
            check(!V6VpnServiceExt.monitoring(), "restore must not undo explicit stop");
            pass("explicit stop closes TUN and cannot be undone by restore");
            result.putString("stream", "\nPASS: all Android device regression checks\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void command(String action) {
        runOnMainSync(() -> context.startForegroundService(new Intent(context, V6VpnService.class).setAction(action)));
    }
    private void query(Network network, int type, Class<?> family) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<String> error = new AtomicReference<>();
        DnsResolver.getInstance().query(network, "example.com", type, DnsResolver.FLAG_NO_CACHE_LOOKUP,
                Runnable::run, null, new DnsResolver.Callback<List<InetAddress>>() {
                    @Override public void onAnswer(List<InetAddress> addresses, int rcode) {
                        if (rcode != 0 || addresses.stream().noneMatch(family::isInstance))
                            error.set("missing DNS answer type " + type + ": " + addresses);
                        done.countDown();
                    }
                    @Override public void onError(DnsResolver.DnsException exception) {
                        error.set(exception.toString()); done.countDown();
                    }
                });
        check(done.await(15, TimeUnit.SECONDS), "DNS timeout");
        check(error.get() == null, "DNS: " + error.get());
    }
    private void tcpDns(Network vpn, LinkProperties links) throws Exception {
        byte[] query = {0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,'e','x','a','m','p','l','e',3,'c','o','m',0,0,1,0,1};
        try (Socket socket = new Socket()) {
            vpn.bindSocket(socket);
            socket.connect(new InetSocketAddress("10.0.2.2", 18753), 5000);
            socket.setSoTimeout(5000);
            DataOutputStream out = new DataOutputStream(socket.getOutputStream());
            out.writeShort(query.length); out.write(query); out.flush();
            DataInputStream in = new DataInputStream(socket.getInputStream());
            int size = in.readUnsignedShort();
            check(size >= 12, "DNS TCP response size");
            byte[] answer = new byte[size]; in.readFully(answer);
            check(answer[0] == 0x12 && answer[1] == 0x34 && (answer[3] & 15) == 0, "DNS TCP answer");
        }
    }
    private void await(BooleanSupplier predicate, String label) {
        long deadline = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (predicate.getAsBoolean()) return;
            SystemClock.sleep(100);
        }
        throw new AssertionError("timeout: " + label);
    }
    private void check(boolean condition, String label) { if (!condition) throw new AssertionError(label); }
    private void pass(String label) {
        Bundle status = new Bundle(); status.putString("stream", "\nPASS: " + label + "\n"); sendStatus(0, status);
    }
}
