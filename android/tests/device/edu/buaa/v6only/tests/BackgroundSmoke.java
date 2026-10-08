package edu.buaa.v6only.tests;
import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.TextView;
import edu.buaa.v6only.BackgroundSettingsActivity;
import java.io.File;
import java.io.FileOutputStream;

public final class BackgroundSmoke extends Instrumentation {
 @Override public void onCreate(Bundle args){super.onCreate(args);start();}
 @Override public void onStart(){Bundle result=new Bundle();try{
  for(String label:new String[]{"自启动与后台管理","电池优化","始终开启 VPN","应用设置"}){
   Activity a=startActivitySync(new Intent(getTargetContext(),BackgroundSettingsActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitForIdleSync();SystemClock.sleep(300);
   if(label.equals("自启动与后台管理")){
    Bitmap b=getUiAutomation().takeScreenshot();File dir=getTargetContext().getExternalFilesDir("ui-checks");dir.mkdirs();try(FileOutputStream out=new FileOutputStream(new File(dir,"background-settings.png"))){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();
   }
   runOnMainSync(()->{View button=find(a.getWindow().getDecorView(),label);if(button==null)throw new AssertionError("Missing action: "+label);button.performClick();});waitForIdleSync();SystemClock.sleep(700);
   // The fallback notice may appear above app details; dismiss it with BACK.
   if(label.equals("自启动与后台管理")){sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK);SystemClock.sleep(400);}
   AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow();
   if(root==null||root.getPackageName()==null||!root.getPackageName().toString().startsWith("com.android.settings"))throw new AssertionError("Settings action did not open: "+label+" root="+(root==null?"null":root.getPackageName()));
   sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK);runOnMainSync(()->a.finish());
  }
  result.putString("stream","\nPASS: background settings rendered; all four system settings actions open, including unknown-OEM fallback\n");finish(Activity.RESULT_OK,result);
 }catch(Throwable e){result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}}
 private View find(View view,String label){if(view instanceof android.widget.Button && ((TextView)view).getText().toString().equals(label))return view;if(view instanceof ViewGroup){ViewGroup g=(ViewGroup)view;for(int i=0;i<g.getChildCount();i++){View v=find(g.getChildAt(i),label);if(v!=null)return v;}}return null;}
}
