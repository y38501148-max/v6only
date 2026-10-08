package edu.buaa.v6only;

import android.app.*;
import android.content.Intent;
import android.os.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.text.DateFormat;
import java.util.*;
import java.util.concurrent.*;

public class TrafficActivity extends Activity {
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler handler=new Handler(Looper.getMainLooper());
    private TextView total,v6,v4,dates;
    private Spinner ranges;
    private LinearLayout details;
    private Button export,custom;
    private long from=0,to=0,customFrom=0,customTo=0;
    private int generation;
    private JSONObject report;
    private String exporting;
    private final Runnable tick=new Runnable(){public void run(){load();handler.postDelayed(this,5000);}};
    public static String bytes(long n) {
        String[] units={"B","KiB","MiB","GiB","TiB"};double v=n;int i=0;
        while(v>=1024 && i<4){v/=1024;i++;}
        return i==0?n+" B":String.format(Locale.ROOT,"%.2f %s",v,units[i]);
    }
    private String date(long sec){return DateFormat.getDateTimeInstance(DateFormat.SHORT,DateFormat.SHORT).format(new Date(sec*1000));}
    @Override public void onCreate(Bundle saved){
        super.onCreate(saved);
        LinearLayout page=Screen.page(this,"流量记录");
        ranges=new Spinner(this);
        ranges.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"今天","近 7 天","近 30 天","全部","自定义"}));
        ranges.setMinimumHeight(Screen.dp(this,48)); page.addView(ranges);
        custom=Screen.button(this,page,"选择时间");custom.setVisibility(View.GONE);custom.setOnClickListener(v->pickTime());
        dates=Screen.text(this,page,"",14);
        total=Screen.text(this,page,"0 B",32);
        v6=Screen.text(this,page,"IPv6  0 B",18);v4=Screen.text(this,page,"IPv4  0 B",18);
        export=Screen.button(this,page,"导出 CSV");export.setEnabled(false);export.setOnClickListener(v->{
            exporting=csv(report);
            Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/csv").putExtra(Intent.EXTRA_TITLE,"V6Only-"+from+"-"+to+".csv");startActivityForResult(i,1);
        });
        Screen.text(this,page,"传输记录",20).setAccessibilityHeading(true);
        details=new LinearLayout(this);details.setOrientation(LinearLayout.VERTICAL);page.addView(details);
        if(saved!=null){customFrom=saved.getLong("from");customTo=saved.getLong("to");exporting=saved.getString("exporting");ranges.setSelection(saved.getInt("range"));}
        ranges.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){
            public void onNothingSelected(android.widget.AdapterView<?> p){}
            public void onItemSelected(android.widget.AdapterView<?> p,View v,int pos,long id){custom.setVisibility(pos==4?View.VISIBLE:View.GONE);if(pos==4 && customTo==0)pickTime();else load();}
        });
    }
    private void pickTime(){
        Calendar start=Calendar.getInstance();start.set(Calendar.HOUR_OF_DAY,0);start.set(Calendar.MINUTE,0);start.set(Calendar.SECOND,0);
        if(customFrom>0)start.setTimeInMillis(customFrom*1000);
        pick("开始时间",start,chosenStart->{Calendar end=Calendar.getInstance();if(customTo>0)end.setTimeInMillis(customTo*1000);
            pick("结束时间",end,chosenEnd->{if(chosenEnd<=chosenStart){Toast.makeText(this,"结束时间须晚于开始时间",Toast.LENGTH_LONG).show();return;}customFrom=chosenStart;customTo=chosenEnd;load();});
        });
    }
    private interface TimeChoice{void accept(long value);}
    private void pick(String title,Calendar c,TimeChoice callback){
        DatePickerDialog d=new DatePickerDialog(this,(v,y,m,day)->{c.set(y,m,day);TimePickerDialog t=new TimePickerDialog(this,(view,h,min)->{c.set(Calendar.HOUR_OF_DAY,h);c.set(Calendar.MINUTE,min);c.set(Calendar.SECOND,0);c.set(Calendar.MILLISECOND,0);callback.accept(c.getTimeInMillis()/1000);},c.get(Calendar.HOUR_OF_DAY),c.get(Calendar.MINUTE),true);t.setTitle(title);t.show();},c.get(Calendar.YEAR),c.get(Calendar.MONTH),c.get(Calendar.DAY_OF_MONTH));d.setTitle(title);d.show();
    }
    private void load(){
        if(worker.isShutdown())return;
        int range=ranges.getSelectedItemPosition();long now=System.currentTimeMillis()/1000+1;to=now;
        Calendar c=Calendar.getInstance();c.set(Calendar.HOUR_OF_DAY,0);c.set(Calendar.MINUTE,0);c.set(Calendar.SECOND,0);c.set(Calendar.MILLISECOND,0);
        from=range==0?c.getTimeInMillis()/1000:range==1?now-7*86400:range==2?now-30*86400:0;
        if(range==4){if(customTo<=customFrom)return;from=customFrom;to=customTo;}
        final long f=from,t=to;final int version=++generation;
        worker.execute(()->{try{
            JSONObject r=new JSONObject(CoreNative.stats(new File(getFilesDir(),"traffic.sqlite").getAbsolutePath(),f,t));
            handler.post(()->{if(isDestroyed()||version!=generation)return;render(r);});
        }catch(Exception e){handler.post(()->{if(!isDestroyed())dates.setText("暂时无法读取记录");});}});
    }
    private void render(JSONObject r){
        report=r;long six=r.optLong("v6_up")+r.optLong("v6_down"),four=r.optLong("v4_up")+r.optLong("v4_down");
        total.setText(bytes(six+four));v6.setText("IPv6  "+bytes(six)+"\n↑ "+bytes(r.optLong("v6_up"))+"　↓ "+bytes(r.optLong("v6_down")));
        v4.setText("IPv4  "+bytes(four)+"\n↑ "+bytes(r.optLong("v4_up"))+"　↓ "+bytes(r.optLong("v4_down")));
        dates.setText(date(from==0?r.optLong("started_at",System.currentTimeMillis()/1000):from)+" → "+date(to));
        JSONArray points=r.optJSONArray("points");export.setEnabled(points!=null && points.length()>0);details.removeAllViews();
        if(points==null||points.length()==0){Screen.text(this,details,"暂无流量记录",16);return;}
        // At most 48 display groups; the exported/report totals always include every point.
        int size=Math.max(1,(points.length()+47)/48);
        for(int i=0;i<points.length();i+=size){long fourBytes=0,sixBytes=0;JSONObject first=points.optJSONObject(i);if(first==null)continue;
            for(int j=i;j<Math.min(points.length(),i+size);j++){JSONObject p=points.optJSONObject(j);if(p==null)continue;fourBytes+=p.optLong("v4_up")+p.optLong("v4_down");sixBytes+=p.optLong("v6_up")+p.optLong("v6_down");}
            Screen.text(this,details,date(first.optLong("at"))+"\nIPv6  "+bytes(sixBytes)+"　·　IPv4  "+bytes(fourBytes),14);
        }
    }
    static String csv(JSONObject r){
        StringBuilder b=new StringBuilder("timestamp,ipv4_upload_bytes,ipv4_download_bytes,ipv6_upload_bytes,ipv6_download_bytes\n");
        JSONArray ps=r==null?null:r.optJSONArray("points");if(ps!=null)for(int i=0;i<ps.length();i++){JSONObject p=ps.optJSONObject(i);if(p!=null)b.append(p.optLong("at")).append(',').append(p.optLong("v4_up")).append(',').append(p.optLong("v4_down")).append(',').append(p.optLong("v6_up")).append(',').append(p.optLong("v6_down")).append('\n');}
        return b.toString();
    }
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==1&&result==RESULT_OK&&data!=null&&data.getData()!=null){final String content=exporting;final android.net.Uri uri=data.getData();if(content==null)return;worker.execute(()->{try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException();out.write(content.getBytes(StandardCharsets.UTF_8));handler.post(()->{if(!isDestroyed())Toast.makeText(this,"已导出",Toast.LENGTH_SHORT).show();});}catch(Exception e){handler.post(()->{if(!isDestroyed())Toast.makeText(this,"导出失败",Toast.LENGTH_LONG).show();});}});}}
    @Override protected void onSaveInstanceState(Bundle b){b.putLong("from",customFrom);b.putLong("to",customTo);b.putInt("range",ranges.getSelectedItemPosition());b.putString("exporting",exporting);super.onSaveInstanceState(b);}
    @Override protected void onResume(){super.onResume();handler.post(tick);}
    @Override protected void onPause(){handler.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){handler.removeCallbacksAndMessages(null);worker.shutdown();super.onDestroy();}
}
