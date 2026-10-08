package edu.buaa.v6only;

import android.app.Notification;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import java.io.IOException;

/** Compiled only into v6only-fixture.apk. Never part of a release APK. */
public class FixtureVpn extends V6VpnService {
    @Override protected java.util.List<String> publicDns(android.net.Network network) { return java.util.Collections.emptyList(); }

    private Network physical;
    public static volatile String failure = "";
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        startForeground(2,new Notification.Builder(this,"v6only").setContentTitle("Disposable emulator test")
                .setSmallIcon(android.R.drawable.ic_lock_lock).build());
        if ("stop".equals(intent.getAction())) {closeTun();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();return START_NOT_STICKY;}
        if (!android.os.Build.HARDWARE.contains("ranchu") && !android.os.Build.HARDWARE.contains("goldfish"))
            throw new IllegalStateException("Fixture service requires an emulator");
        try {
            if (prepare(this)!=null) throw new IOException("VPN permission missing");
            ConnectivityManager cm=getSystemService(ConnectivityManager.class);
            for (Network network:cm.getAllNetworks()) {
                NetworkCapabilities caps=cm.getNetworkCapabilities(network);
                if(caps!=null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)){
                    physical=network;if(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))break;
                }
            }
            if(physical==null)throw new IOException("No physical network");
            android.util.Log.i("FixtureVpn","Physical network "+physical+" "+cm.getLinkProperties(physical));
            establishTunnel(physical, java.util.Collections.singletonList("10.0.2.2:15353"), false);
        }catch(Exception e){failure=e.toString();android.util.Log.e("FixtureVpn",failure,e);closeTun();stopSelf();}
        return START_NOT_STICKY;
    }
}
