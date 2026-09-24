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
import edu.buaa.v6only.CoreNative;
import edu.buaa.v6only.MainActivity;
import java.io.*;
import java.net.*;
import java.util.function.BooleanSupplier;

/** Exercises actual JNI, TUN, DNS and upstream sockets in a disposable emulator. */
public class TunnelSmoke extends Instrumentation {
    private Context context;
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){
        Bundle result=new Bundle();
        try{
            context=getTargetContext();
            Activity activity=startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            command("start");
            ConnectivityManager cm=context.getSystemService(ConnectivityManager.class);
            await(()->isVpn(cm),"VPN default network");
            Network vpn=cm.getActiveNetwork();
            for(String[] item:new String[][]{{"dual.test","6"},{"v4.test","4"},{"broken6.test","4"},{"v6.test","6"}}){
                String ip=query(vpn,item[0],false);
                check(ip.equals(query(vpn,item[0],true)),"UDP/TCP DNS agree");
                try(Socket socket=new Socket()){
                    vpn.bindSocket(socket);socket.connect(new InetSocketAddress(ip,18080),10000);socket.setSoTimeout(10000);
                    socket.getOutputStream().write(("GET / HTTP/1.0\r\nHost: "+item[0]+"\r\n\r\n").getBytes("US-ASCII"));
                    ByteArrayOutputStream out=new ByteArrayOutputStream();socket.getInputStream().transferTo(out);
                    check(out.toString("US-ASCII").endsWith("tcp"+item[1]+"\n"),"TCP family for "+item[0]);
                }
                try(DatagramSocket socket=new DatagramSocket()){
                    vpn.bindSocket(socket);socket.setSoTimeout(10000);
                    socket.send(new DatagramPacket(new byte[]{'x'},1,InetAddress.getByName(ip),18080));
                    DatagramPacket p=new DatagramPacket(new byte[100],100);socket.receive(p);
                    check(new String(p.getData(),0,p.getLength(),"US-ASCII").equals("udp"+item[1]+":x"),"UDP family for "+item[0]);
                }
                status("PASS "+item[0]+" TCP/UDP chooses IPv"+item[1]);
            }
            check(CoreNative.flows().contains("tcp6"),"native flow diagnostics");
            command("stop");await(()->!isVpn(cm),"VPN routes removed on stop");
            try(Socket socket=new Socket()){
                socket.connect(new InetSocketAddress("10.0.2.2",18080),5000);
            }
            status("PASS stopped VPN restores physical connectivity");
            runOnMainSync(activity::finishAndRemoveTask);
            result.putString("stream","\nPASS: Android native tunnel integration\n");finish(Activity.RESULT_OK,result);
        }catch(Throwable e){if(context!=null)command("stop");result.putString("stream","\nFAIL: "+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}
    }
    private boolean isVpn(ConnectivityManager cm){Network n=cm.getActiveNetwork();NetworkCapabilities c=n==null?null:cm.getNetworkCapabilities(n);return c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_VPN);}
    private void command(String action){runOnMainSync(()->context.startForegroundService(new Intent().setClassName(context.getPackageName(),"edu.buaa.v6only.FixtureVpn").setAction(action)));}
    private String query(Network vpn,String host,boolean tcp)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream q=new DataOutputStream(bytes);
        q.writeShort(0x1234);q.writeShort(0x100);q.writeShort(1);q.writeShort(0);q.writeShort(0);q.writeShort(0);
        for(String label:host.split("\\.")){q.writeByte(label.length());q.writeBytes(label);}q.writeByte(0);q.writeShort(1);q.writeShort(1);
        byte[] wire=bytes.toByteArray(),answer;
        if(tcp){try(Socket s=new Socket()){vpn.bindSocket(s);s.connect(new InetSocketAddress("198.18.0.2",53),8000);s.setSoTimeout(8000);
            DataOutputStream out=new DataOutputStream(s.getOutputStream());out.writeShort(wire.length);out.write(wire);out.flush();DataInputStream in=new DataInputStream(s.getInputStream());answer=new byte[in.readUnsignedShort()];in.readFully(answer);}}
        else{try(DatagramSocket s=new DatagramSocket()){vpn.bindSocket(s);s.setSoTimeout(8000);s.send(new DatagramPacket(wire,wire.length,InetAddress.getByName("198.18.0.2"),53));DatagramPacket p=new DatagramPacket(new byte[4096],4096);s.receive(p);answer=java.util.Arrays.copyOf(p.getData(),p.getLength());}}
        check(answer.length>=wire.length+16 && (answer[3]&15)==0,"DNS answer "+host);
        int n=answer.length;return InetAddress.getByAddress(java.util.Arrays.copyOfRange(answer,n-4,n)).getHostAddress();
    }
    private void await(BooleanSupplier predicate,String name){long end=SystemClock.elapsedRealtime()+12000;while(SystemClock.elapsedRealtime()<end){if(predicate.getAsBoolean())return;SystemClock.sleep(100);}throw new AssertionError("Timeout "+name);}
    private void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    private void status(String message){Bundle b=new Bundle();b.putString("stream","\n"+message+"\n");sendStatus(0,b);}
}
