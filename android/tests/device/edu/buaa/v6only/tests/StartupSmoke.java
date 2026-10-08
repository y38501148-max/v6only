package edu.buaa.v6only.tests;

import android.app.*;
import android.content.*;
import android.os.*;
import edu.buaa.v6only.*;
import java.util.function.BooleanSupplier;

/** Production APK: global connection, task removal and persisted boot preferences. */
public final class StartupSmoke extends Instrumentation {
    private Context context;
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){Bundle result=new Bundle();try{
        context=getTargetContext();
        command(V6VpnService.ACTION_STOP);await(()->!V6VpnServiceExt.monitoring(),"initial stop");
        SharedPreferences p=context.getSharedPreferences("v6only",Context.MODE_PRIVATE);
        p.edit().putBoolean("campus_only",false).putBoolean("enabled",false).putBoolean("auto",true).commit();
        Activity a=startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        command(V6VpnService.ACTION_START);await(this::ready,"production network evaluated");
        runOnMainSync(a::finishAndRemoveTask);SystemClock.sleep(1500);
        check(V6VpnServiceExt.monitoring() && ready(),"connection or IPv6 standby survives task removal");
        command(V6VpnService.ACTION_STOP);await(()->!V6VpnServiceExt.monitoring(),"stop");
        p.edit().putBoolean("enabled",true).putBoolean("auto",false).commit();
        runOnMainSync(()->new BootReceiver().onReceive(context,new Intent(Intent.ACTION_BOOT_COMPLETED)));
        SystemClock.sleep(1200);check(!V6VpnServiceExt.monitoring(),"manual startup skips boot restoration");
        p.edit().putBoolean("auto",true).commit();
        runOnMainSync(()->new BootReceiver().onReceive(context,new Intent(Intent.ACTION_BOOT_COMPLETED)));
        await(this::ready,"automatic boot restoration");
        result.putString("stream","\nPASS: production global VPN, task removal and startup preferences\n");finish(Activity.RESULT_OK,result);
    }catch(Throwable e){result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}}
    private void command(String a){runOnMainSync(()->context.startForegroundService(new Intent(context,V6VpnService.class).setAction(a)));}
    private boolean ready(){return V6VpnServiceExt.monitoring() && (V6VpnServiceExt.running(context) || V6VpnServiceExt.message().contains("没有可用 IPv6"));}
    private void await(BooleanSupplier f,String label){long end=SystemClock.elapsedRealtime()+20000;while(SystemClock.elapsedRealtime()<end){if(f.getAsBoolean())return;SystemClock.sleep(100);}throw new AssertionError(label);}
    private void check(boolean b,String label){if(!b)throw new AssertionError(label);}
}
