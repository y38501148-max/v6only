package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.SystemClock;
import edu.buaa.v6only.MainActivity;
import edu.buaa.v6only.R;
import edu.buaa.v6only.V6VpnService;
import edu.buaa.v6only.V6VpnServiceExt;
import java.io.*;
import java.net.*;
import java.util.function.BooleanSupplier;

/** Uses real emulator cellular routing, without pre-authorizing the VPN. */
public final class CellularSmoke extends Instrumentation {
    private Context context;
    private ConnectivityManager cm;
    private Activity activity;
    private SharedPreferences prefs;
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            context = getTargetContext();
            cm = context.getSystemService(ConnectivityManager.class);
            prefs = context.getSharedPreferences("v6only", Context.MODE_PRIVATE);
            prefs.edit().putBoolean("campus_only", true).putBoolean("enabled", false).putBoolean("auto", true).commit();
            // Fresh CI emulators may still be registering the modem. This wait is
            // before starting the app; service behavior keeps the shorter timeout.
            await(this::cellularDefault, "real cellular default network", 60000);
            checkConnectivity();
            activity = startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            runOnMainSync(() -> activity.findViewById(R.id.toggle_service).performClick());
            await(() -> V6VpnServiceExt.monitoring(), "cellular standby without VPN consent");
            SystemClock.sleep(500);
            check(cellularDefault(), "standby preserves cellular default");
            check(!V6VpnServiceExt.running(context), "cellular must never create VPN");
            checkConnectivity();
            // Activity re-entry applies persisted state; it must not prepare/claim a VPN either.
            command(V6VpnService.ACTION_APPLY);
            SystemClock.sleep(500);
            check(V6VpnServiceExt.monitoring() && cellularDefault(), "reapply preserves cellular standby");
            checkConnectivity();
            command(V6VpnService.ACTION_STOP);
            await(() -> !V6VpnServiceExt.monitoring(), "explicit stop");
            prefs.edit().putBoolean("auto", false).commit();
            command(V6VpnService.ACTION_START);
            await(() -> V6VpnServiceExt.message().contains("当前非校园网"), "manual cellular refusal");
            check(!prefs.getBoolean("enabled", true), "manual request stopped");
            checkConnectivity();
            runOnMainSync(activity::finishAndRemoveTask);
            result.putString("stream", "\nPASS: cellular startup, reapply and manual refusal preserve TCP/DNS without VPN consent\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private boolean cellularDefault() {
        Network n = cm.getActiveNetwork();
        NetworkCapabilities c = n == null ? null : cm.getNetworkCapabilities(n);
        return c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                && !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
    }
    private void checkConnectivity() throws Exception {
        check(cellularDefault(), "cellular default retained");
        // Unbound app sockets exercise default routing, not Network.bindSocket bypasses.
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress("10.0.2.2", 18765), 4000); s.setSoTimeout(4000);
            s.getOutputStream().write("GET /marker HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n".getBytes("US-ASCII"));
            ByteArrayOutputStream out = new ByteArrayOutputStream(); TestIo.copy(s.getInputStream(),out);
            check(out.toString("US-ASCII").contains("v6only network regression fixture"), "default HTTP body");
        }
        byte[] q = new byte[]{0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,'e','x','a','m','p','l','e',3,'c','o','m',0,0,1,0,1};
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress("10.0.2.2",18753),4000); s.setSoTimeout(4000);
            DataOutputStream out = new DataOutputStream(s.getOutputStream()); out.writeShort(q.length); out.write(q); out.flush();
            DataInputStream in = new DataInputStream(s.getInputStream()); byte[] answer = new byte[in.readUnsignedShort()]; in.readFully(answer);
            check(answer.length > q.length && (answer[3] & 15) == 0, "default DNS transport answer");
        }
    }
    private void command(String action) { runOnMainSync(() -> context.startForegroundService(new Intent(context,V6VpnService.class).setAction(action))); }
    private void await(BooleanSupplier condition, String name) {
        await(condition, name, 12000);
    }
    private void await(BooleanSupplier condition, String name, long timeout) {
        long end=SystemClock.elapsedRealtime()+timeout;
        while(SystemClock.elapsedRealtime()<end) { if(condition.getAsBoolean())return; SystemClock.sleep(100); }
        throw new AssertionError("Timeout: "+name);
    }
    private void check(boolean value, String name) { if(!value)throw new AssertionError(name); }
}
