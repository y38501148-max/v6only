package edu.buaa.v6only;

import android.app.Activity;
import android.os.*;
import android.view.View;
import android.widget.*;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;

public class ConnectionsActivity extends Activity {
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private LinearLayout rows;
    private Spinner filter;
    private boolean loading;
    private final Runnable tick=new Runnable(){public void run(){load();handler.postDelayed(this,5000);}};
    @Override protected void onCreate(Bundle saved){super.onCreate(saved);LinearLayout page=Screen.page(this,"当前连接");filter=new Spinner(this);filter.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"全部目标","哔哩哔哩"}));filter.setMinimumHeight(Screen.dp(this,48));page.addView(filter);rows=new LinearLayout(this);rows.setOrientation(LinearLayout.VERTICAL);page.addView(rows);filter.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int pos,long id){load();}});}
    private void load(){if(loading||worker.isShutdown())return;loading=true;final boolean bili=filter.getSelectedItemPosition()==1;worker.execute(()->{List<JSONObject> flows=new ArrayList<>();try{JSONArray all=new JSONArray(CoreNative.flows());for(int i=0;i<all.length();i++){JSONObject f=all.getJSONObject(i);String h=f.optString("host");if(!bili||h.matches(".*(?:bilibili|bilivideo|biliapi|hdslb|bilicdn)\\.(?:com|cn)$"))flows.add(f);}flows.sort((a,b)->Long.compare(b.optLong("upload_bytes")+b.optLong("download_bytes"),a.optLong("upload_bytes")+a.optLong("download_bytes")));}catch(Exception ignored){}handler.post(()->{loading=false;if(isDestroyed())return;if(bili!=(filter.getSelectedItemPosition()==1)){load();return;}rows.removeAllViews();if(flows.isEmpty())Screen.text(this,rows,"暂无连接",16);for(int i=0;i<Math.min(flows.size(),32);i++){JSONObject f=flows.get(i);Screen.text(this,rows,f.optString("host")+"\n"+(f.optString("network").endsWith("6")?"IPv6":"IPv4")+"  "+f.optString("remote")+"\n↑ "+TrafficActivity.bytes(f.optLong("upload_bytes"))+"　↓ "+TrafficActivity.bytes(f.optLong("download_bytes")),14);}});});}
    @Override protected void onResume(){super.onResume();handler.post(tick);}
    @Override protected void onPause(){handler.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){handler.removeCallbacksAndMessages(null);worker.shutdown();super.onDestroy();}
}
