package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.TextView;
import edu.buaa.v6only.MainActivity;
import edu.buaa.v6only.R;
import org.json.JSONObject;

/** A future release is injected only into emulator-local cached metadata. */
public final class UpdateSmoke extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result=new Bundle();Activity activity=null;
        Context context=getTargetContext();
        SharedPreferences updates=context.getSharedPreferences("app_updates",Context.MODE_PRIVATE);
        try {
            String version=context.getPackageManager().getPackageInfo(context.getPackageName(),0).versionName;
            JSONObject cached=new JSONObject();
            cached.put("current_version",version).put("latest_version","9.0.0").put("available",true)
                .put("download_url","https://github.com/y38501148-max/v6only/releases/download/v9.0.0/V6Only-9.0.0-Android.apk")
                .put("release_url","https://github.com/y38501148-max/v6only/releases/tag/v9.0.0");
            updates.edit().clear().putString("result",cached.toString()).putLong("checked_at",System.currentTimeMillis()).commit();
            context.getSharedPreferences("v6only",Context.MODE_PRIVATE).edit().putBoolean("enabled",false).commit();
            activity=startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitForIdleSync();
            Activity screen=activity;
            if(screen.findViewById(R.id.update_banner).getVisibility()!=View.VISIBLE)throw new AssertionError("missing release notice");
            if(!((TextView)screen.findViewById(R.id.update_title)).getText().toString().contains("9.0.0"))throw new AssertionError("wrong release version");
            if(!screen.findViewById(R.id.check_update).isEnabled())throw new AssertionError("manual check unavailable");
            final String[] opened={null};
            ActivityMonitor monitor=new ActivityMonitor(){
                @Override public ActivityResult onStartActivity(Intent intent){
                    if(Intent.ACTION_VIEW.equals(intent.getAction())){opened[0]=intent.getDataString();return new ActivityResult(Activity.RESULT_OK,null);}return null;
                }
            };
            addMonitor(monitor);
            runOnMainSync(()->screen.findViewById(R.id.download_update).performClick());
            if(!cached.getString("download_url").equals(opened[0]))throw new AssertionError("wrong Android download link");
            runOnMainSync(()->screen.findViewById(R.id.release_notes).performClick());
            if(!cached.getString("release_url").equals(opened[0]))throw new AssertionError("wrong release notes link");
            removeMonitor(monitor);
            runOnMainSync(()->screen.findViewById(R.id.dismiss_update).performClick());
            if(screen.findViewById(R.id.update_banner).getVisibility()!=View.GONE)throw new AssertionError("dismiss failed");
            if(!"9.0.0".equals(updates.getString("dismissed","")))throw new AssertionError("dismiss not persisted");
            result.putString("stream","PASS: Android update notice, matching download, release notes and dismissal\n");finish(Activity.RESULT_OK,result);
        } catch(Throwable failure) {
            result.putString("stream","FAIL: "+failure+"\n");finish(Activity.RESULT_CANCELED,result);
        } finally {
            if(activity!=null){Activity screen=activity;runOnMainSync(screen::finish);}
            updates.edit().clear().commit();
        }
    }
}
