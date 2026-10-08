package edu.buaa.v6only;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ComponentName;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class BackgroundSettingsActivity extends Activity {
    private TextView status;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String brand=BackgroundPolicy.brand(Build.MANUFACTURER,Build.BRAND);
        LinearLayout page=Screen.page(this,"后台运行设置");
        Screen.text(this,page,brand+" · "+Build.MODEL,16);
        status=Screen.text(this,page,"",16);
        Screen.text(this,page,BackgroundPolicy.guidance(brand),16);
        Screen.button(this,page,"自启动与后台管理").setOnClickListener(v->{
            for(String component:BackgroundPolicy.components(brand)) {
                Intent intent=new Intent().setComponent(ComponentName.unflattenFromString(component));
                intent.putExtra("package_name",getPackageName());intent.putExtra("packageName",getPackageName());
                if(open(intent)) return;
            }
            open(details());
            new AlertDialog.Builder(this).setTitle("应用设置").setMessage("当前系统未提供直接入口，请在应用设置中查找自启动或电池使用。")
                .setPositiveButton("知道了",null).show();
        });
        Screen.button(this,page,"电池优化").setOnClickListener(v->{if(!open(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))open(details());});
        Screen.button(this,page,"始终开启 VPN").setOnClickListener(v->{if(!open(new Intent(Settings.ACTION_VPN_SETTINGS)))open(details());});
        Screen.button(this,page,"应用设置").setOnClickListener(v->open(details()));
        Screen.text(this,page,"设置完成后，可在最近任务中锁定 V6Only。",16);
    }
    @Override public void onResume(){super.onResume();PowerManager pm=getSystemService(PowerManager.class);
        status.setText(pm!=null&&pm.isIgnoringBatteryOptimizations(getPackageName())?"电池优化已豁免":"电池优化尚未豁免");}
    private Intent details(){return new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:"+getPackageName()));}
    private boolean open(Intent intent){try{startActivity(intent);return true;}catch(RuntimeException e){return false;}}
}
