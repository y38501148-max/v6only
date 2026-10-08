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

/** Verifies the production campus gate and off-campus foreground lifecycle. */
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
            prefs.edit().putBoolean("campus_only", true).putBoolean("enabled", false).putBoolean("auto", false).commit();
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
                        + "Forwarding is independently tested by the emulator-only TunnelSmoke fixture\n"
                        + "PASS: all Android device regression checks\n");
                finish(Activity.RESULT_OK, result);
                return;
            }
            throw new AssertionError("NetworkSmoke requires a non-campus emulator; use TunnelSmoke for controlled forwarding tests");
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void command(String action) {
        runOnMainSync(() -> context.startForegroundService(new Intent(context, V6VpnService.class).setAction(action)));
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
