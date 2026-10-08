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
 private String label;
 @Override public void onCreate(Bundle args){super.onCreate(args);label=args==null?"自启动与后台管理":args.getString("action","自启动与后台管理");start();}
 @Override public void onStart(){Bundle result=new Bundle();try{
  {
   Activity a=startActivitySync(new Intent(getTargetContext(),BackgroundSettingsActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitForIdleSync();SystemClock.sleep(300);
   if(label.equals("自启动与后台管理")){
    Bitmap b=getUiAutomation().takeScreenshot();File dir=getTargetContext().getExternalFilesDir("ui-checks");dir.mkdirs();try(FileOutputStream out=new FileOutputStream(new File(dir,"background-settings.png"))){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();
   }
   runOnMainSync(()->{View button=find(a.getWindow().getDecorView(),label);if(button==null)throw new AssertionError("Missing action: "+label);button.performClick();});waitForIdleSync();SystemClock.sleep(700);
   String state;
   try(android.os.ParcelFileDescriptor fd=getUiAutomation().executeShellCommand("dumpsys activity activities");java.io.InputStream in=new android.os.ParcelFileDescriptor.AutoCloseInputStream(fd)){
    java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream();TestIo.copy(in,out);state=out.toString("UTF-8");
   }
   boolean opened=false;for(String line:state.split("\n")){if(line.toLowerCase(java.util.Locale.ROOT).contains("resumed")&&line.contains("com.android.settings")){opened=true;break;}}
   if(!opened)throw new AssertionError("Settings action did not open: "+label);


  }
  result.putString("stream","\nPASS: background setting opens: "+label+"\n");finish(Activity.RESULT_OK,result);
 }catch(Throwable e){result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}}
 private View find(View view,String label){if(view instanceof android.widget.Button && ((TextView)view).getText().toString().equals(label))return view;if(view instanceof ViewGroup){ViewGroup g=(ViewGroup)view;for(int i=0;i<g.getChildCount();i++){View v=find(g.getChildAt(i),label);if(v!=null)return v;}}return null;}
}
