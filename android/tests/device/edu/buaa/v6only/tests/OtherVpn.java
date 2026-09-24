package edu.buaa.v6only.tests;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;

/** Test APK's separate UID simulates an already authorized, unrelated VPN. */
public final class OtherVpn extends VpnService {
    private ParcelFileDescriptor tun;
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("fixture","Fixture",NotificationManager.IMPORTANCE_LOW));
        startForeground(10,new Notification.Builder(this,"fixture").setContentTitle("Emulator other-VPN fixture").setSmallIcon(android.R.drawable.ic_lock_lock).build());
        if (intent!=null&&"stop".equals(intent.getAction())) {closeTun();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();return START_NOT_STICKY;}
        if (!android.os.Build.HARDWARE.contains("ranchu")&&!android.os.Build.HARDWARE.contains("goldfish")) throw new IllegalStateException("Emulator only");
        if (prepare(this)!=null)throw new IllegalStateException("Fixture VPN not authorized");
        tun=new Builder().setSession("Other VPN fixture").addAddress("192.0.2.1",32)
                .addRoute("198.18.254.254",32).allowFamily(OsConstants.AF_INET).allowFamily(OsConstants.AF_INET6).establish();
        return START_NOT_STICKY;
    }
    private void closeTun(){if(tun!=null){try{tun.close();}catch(Exception ignored){}tun=null;}}
    @Override public void onDestroy(){closeTun();super.onDestroy();}
    @Override public void onRevoke(){closeTun();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
}
