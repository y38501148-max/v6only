package edu.buaa.v6only;

import android.app.Notification;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.ParcelFileDescriptor;
import java.io.IOException;

/** Compiled only into v6only-fixture.apk. Never part of a release APK. */
public class FixtureVpn extends V6VpnService {
    private ParcelFileDescriptor fixture;
    private Network physical;
    public static volatile String failure = "";
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        startForeground(2,new Notification.Builder(this,"v6only").setContentTitle("Disposable emulator test")
                .setSmallIcon(android.R.drawable.ic_lock_lock).build());
        if ("stop".equals(intent.getAction())) {release();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();return START_NOT_STICKY;}
        if (!android.os.Build.HARDWARE.contains("ranchu") && !android.os.Build.HARDWARE.contains("goldfish"))
            throw new IllegalStateException("Fixture service requires an emulator");
        try {
            if (prepare(this)!=null) throw new IOException("VPN permission missing");
            ConnectivityManager cm=getSystemService(ConnectivityManager.class);
            for (Network network:cm.getAllNetworks()) {
                NetworkCapabilities caps=cm.getNetworkCapabilities(network);
                if(caps!=null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)){physical=network;break;}
            }
            if(physical==null)throw new IOException("No physical network");
            fixture=new Builder().setSession("v6only disposable fixture").setMtu(1500)
                .addAddress("198.18.0.1",15).addAddress("fd00:198:18::1",64)
                .addRoute("0.0.0.0",0).addRoute("::",0).addDnsServer("198.18.0.2")
                .setUnderlyingNetworks(new Network[]{physical}).establish();
            if(fixture==null)throw new IOException("VPN permission missing");
            String error=CoreNative.start(fixture.getFd(),"{\"dns\":[\"10.0.2.2:15353\"],\"fake_dns\":true,\"family_timeout_ms\":1500}",this);
            if(!error.isEmpty())throw new IOException(error);
        }catch(Exception e){failure=e.toString();android.util.Log.e("FixtureVpn",failure,e);stopSelf();}
        return START_NOT_STICKY;
    }
    @Override public boolean protectCoreSocket(int fd){
        if(physical==null||!protect(fd))return false;
        try(ParcelFileDescriptor copy=ParcelFileDescriptor.fromFd(fd)){physical.bindSocket(copy.getFileDescriptor());return true;}
        catch(IOException e){return false;}
    }
    private void release(){
        CoreNative.stop();
        if(fixture!=null)try{fixture.close();}catch(IOException ignored){}
        fixture=null;
    }
    @Override public void onDestroy(){
        release();
        super.onDestroy();
    }
}
