package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.SystemClock;
import edu.buaa.v6only.MainActivity;
import edu.buaa.v6only.R;
import edu.buaa.v6only.V6VpnService;
import edu.buaa.v6only.V6VpnServiceExt;
import java.util.function.BooleanSupplier;

/** Mobile standby must not revoke another app's working VPN, even if previously authorized. */
public final class OtherVpnSmoke extends Instrumentation {
    private Context context;
    private ConnectivityManager cm;
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){
        Bundle result=new Bundle();
        try {
            context=getTargetContext();cm=context.getSystemService(ConnectivityManager.class);
            context.getSharedPreferences("v6only",Context.MODE_PRIVATE).edit().putBoolean("enabled",false).putBoolean("auto",true).commit();
            Activity activity=startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            try(android.os.ParcelFileDescriptor p=getUiAutomation().executeShellCommand("am start -n edu.buaa.v6only.tests/.OtherVpnActivity");
                java.io.InputStream in=new android.os.ParcelFileDescriptor.AutoCloseInputStream(p)) {TestIo.copy(in,new java.io.ByteArrayOutputStream());}
            await(()->vpn()!=null,"other VPN active");
            Network other=vpn();
            runOnMainSync(()->activity.findViewById(R.id.toggle_service).performClick());
            await(()->V6VpnServiceExt.monitoring(),"standby started");SystemClock.sleep(600);
            check(other.equals(vpn()),"cellular startup must preserve other VPN");
            runOnMainSync(()->context.startForegroundService(new Intent(context,V6VpnService.class).setAction(V6VpnService.ACTION_APPLY)));
            SystemClock.sleep(600);check(other.equals(vpn()),"reapply must preserve other VPN");
            // Package-update/boot restoration must also avoid calling prepare off campus.
            runOnMainSync(()->new edu.buaa.v6only.BootReceiver().onReceive(context,new Intent(Intent.ACTION_MY_PACKAGE_REPLACED)));
            SystemClock.sleep(600);check(other.equals(vpn()),"boot/update restore must preserve other VPN");
            runOnMainSync(()->context.startForegroundService(new Intent(context,V6VpnService.class).setAction(V6VpnService.ACTION_STOP)));
            await(()->!V6VpnServiceExt.monitoring(),"explicit stop");
            check(other.equals(vpn()),"stop must preserve other VPN");
            runOnMainSync(activity::finishAndRemoveTask);
            result.putString("stream","\nPASS: cellular start/reapply/update/stop preserve another VPN\n");finish(Activity.RESULT_OK,result);
        }catch(Throwable e){result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}
        finally{try{getUiAutomation().executeShellCommand("am force-stop edu.buaa.v6only.tests").close();}catch(Exception ignored){}}
    }
    private Network vpn(){for(Network n:cm.getAllNetworks()){NetworkCapabilities c=cm.getNetworkCapabilities(n);if(c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_VPN))return n;}return null;}
    private void await(BooleanSupplier p,String name){long end=SystemClock.elapsedRealtime()+12000;while(SystemClock.elapsedRealtime()<end){if(p.getAsBoolean())return;SystemClock.sleep(100);}throw new AssertionError("Timeout "+name);}
    private void check(boolean ok,String label){if(!ok)throw new AssertionError(label);}
}
