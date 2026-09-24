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
import edu.buaa.v6only.V6VpnService;
import edu.buaa.v6only.V6VpnServiceExt;
import java.io.*;
import java.net.*;
import java.util.function.BooleanSupplier;

/** Starts the production VPN on controlled campus Wi-Fi, then changes the real default transport. */
public final class HandoverSmoke extends Instrumentation {
    private Context context;
    private ConnectivityManager cm;
    private SharedPreferences prefs;
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result=new Bundle();
        try {
            context=getTargetContext();cm=context.getSystemService(ConnectivityManager.class);
            prefs=context.getSharedPreferences("v6only",Context.MODE_PRIVATE);
            prefs.edit().putBoolean("enabled",false).commit();
            runOnMainSync(() -> context.startForegroundService(new Intent(context,V6VpnService.class).setAction(V6VpnService.ACTION_STOP)));
            SystemClock.sleep(300);
            // MainActivity.onResume applies the production service. That would run
            // a second controller beside the test-only campus service in this APK.
            Activity activity=startActivitySync(new Intent().setClassName(context.getPackageName(),
                    "edu.buaa.v6only.HandoverActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            shell("svc data enable");
            for(boolean automatic:new boolean[]{true,false}) {
                shell("svc wifi enable");await(()->transport(NetworkCapabilities.TRANSPORT_WIFI),"Wi-Fi default");
                prefs.edit().putBoolean("enabled",false).putBoolean("auto",automatic).commit();
                command(V6VpnService.ACTION_START);
                await(()->V6VpnServiceExt.running(context)&&transport(NetworkCapabilities.TRANSPORT_VPN),"campus VPN established");
                Network before = stableTunnel();
                checkHttp();
                command(V6VpnService.ACTION_APPLY);
                SystemClock.sleep(500);
                check(before.equals(cm.getActiveNetwork()), "reapply must preserve healthy tunnel");
                shell("svc wifi disable");
                await(()->transport(NetworkCapabilities.TRANSPORT_CELLULAR)&&!V6VpnServiceExt.running(context),"VPN removed after mobile handover");
                awaitMobileHttp();
                check(cm.getLinkProperties(cm.getActiveNetwork()).getDnsServers().stream()
                        .noneMatch(a->a.getHostAddress().equals("198.18.0.2")),"VPN DNS removed on cellular");
                SystemClock.sleep(1000);
                check(V6VpnServiceExt.monitoring()==automatic,"automatic waits; manual stops");
                command(V6VpnService.ACTION_STOP);await(()->!V6VpnServiceExt.monitoring(),"stop after handover");
                status("PASS "+(automatic?"automatic":"manual")+" campus VPN -> cellular: routes/DNS removed, default HTTP works");
            }
            runOnMainSync(activity::finishAndRemoveTask);
            result.putString("stream","\nPASS: Android campus-to-cellular handover\n");finish(Activity.RESULT_OK,result);
        } catch(Throwable error) {
            result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(error));finish(Activity.RESULT_CANCELED,result);
        } finally {
            if(context!=null)command(V6VpnService.ACTION_STOP);
            try {shell("svc wifi enable");}catch(Exception ignored){}
        }
    }
    private void awaitMobileHttp() throws Exception {
        // Android 10 can publish the cellular default before netd finishes removing
        // the VPN's UID routing rules. Require real recovery within a bounded window.
        long started=SystemClock.elapsedRealtime(),deadline=started+8000;
        IOException last=null;
        while(SystemClock.elapsedRealtime()<deadline) {
            try {
                checkHttp();
                status("Mobile default HTTP usable after "+(SystemClock.elapsedRealtime()-started)+" ms");
                return;
            } catch(IOException error) {last=error;SystemClock.sleep(100);}
        }
        throw new AssertionError("Mobile data still unreachable after VPN teardown",last);
    }
    private Network stableTunnel() {
        // Emulator IPv6 RA/DNS can arrive after DHCP and legitimately rebuild the VPN.
        Network previous=null;long unchanged=0,end=SystemClock.elapsedRealtime()+20000;
        while(SystemClock.elapsedRealtime()<end) {
            Network current=cm.getActiveNetwork();
            if(!transport(NetworkCapabilities.TRANSPORT_VPN)||!current.equals(previous)) {
                previous=current;unchanged=SystemClock.elapsedRealtime();
            } else if(SystemClock.elapsedRealtime()-unchanged>=2000)return current;
            SystemClock.sleep(100);
        }
        throw new AssertionError("VPN did not settle after DHCP/IPv6 RA");
    }
    private void checkHttp() throws Exception {
        try(Socket s=new Socket()) {
            s.connect(new InetSocketAddress("10.0.2.2",18765),5000);s.setSoTimeout(5000);
            s.getOutputStream().write("GET /marker HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n".getBytes("US-ASCII"));
            ByteArrayOutputStream out=new ByteArrayOutputStream();TestIo.copy(s.getInputStream(),out);
            check(out.toString("US-ASCII").contains("v6only network regression fixture"),"default HTTP response");
        }
    }
    private boolean transport(int type) {
        Network n=cm.getActiveNetwork();NetworkCapabilities c=n==null?null:cm.getNetworkCapabilities(n);
        return c!=null&&c.hasTransport(type)&&(type==NetworkCapabilities.TRANSPORT_VPN||!c.hasTransport(NetworkCapabilities.TRANSPORT_VPN));
    }
    private void shell(String cmd) throws Exception {
        try(android.os.ParcelFileDescriptor p=getUiAutomation().executeShellCommand(cmd);InputStream in=new android.os.ParcelFileDescriptor.AutoCloseInputStream(p)) { TestIo.copy(in,new ByteArrayOutputStream()); }
    }
    private void command(String action) {runOnMainSync(()->context.startForegroundService(new Intent().setClassName(context.getPackageName(),"edu.buaa.v6only.HandoverVpn").setAction(action)));}
    private void await(BooleanSupplier predicate,String name) {long end=SystemClock.elapsedRealtime()+20000;while(SystemClock.elapsedRealtime()<end){if(predicate.getAsBoolean())return;SystemClock.sleep(100);}throw new AssertionError("Timeout "+name);}
    private void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    private void status(String text){Bundle b=new Bundle();b.putString("stream","\n"+text+"\n");sendStatus(0,b);}
}
