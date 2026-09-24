package edu.buaa.v6only;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final int VPN_PERMISSION = 1;
    private static final int NOTIFICATION_PERMISSION = 2;
    private static final int WIFI_PERMISSION = 3;
    private TextView status;
    private Button toggleBtn, autoBtn;
    private SharedPreferences prefs;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { refresh(); }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("v6only", MODE_PRIVATE);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(padding, padding, padding, padding);
        status = new TextView(this);
        status.setTextSize(17);
        status.setPadding(0, 0, 0, padding);
        root.addView(status);

        toggleBtn = button(root, "启动服务", () -> {
            if (prefs.getBoolean("enabled", false) || V6VpnServiceExt.monitoring()) {
                // Save the explicit stop before sending an asynchronous command.
                prefs.edit().putBoolean("enabled", false).commit();
                sendCommand(V6VpnService.ACTION_STOP);
            } else {
                Intent permission = VpnService.prepare(this);
                if (permission == null) startVpn();
                else startActivityForResult(permission, VPN_PERMISSION);
            }
            refresh();
        });
        autoBtn = button(root, "", () -> {
            prefs.edit().putBoolean("auto", !prefs.getBoolean("auto", true)).commit();
            if (prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
            refresh();
        });
        button(root, "授权校园 Wi-Fi 名称识别", this::requestWifiPermission);
        button(root, "电池后台设置", () -> openSettings(
                new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)));
        button(root, "应用设置（通知／自启动）", () -> openSettings(new Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))));

        TextView help = new TextView(this);
        help.setPadding(0, padding, 0, 0);
        help.setText("自动模式：仅在识别到校园网时连接，离开后保持后台监听。关闭自动模式可在当前网络手动连接。\n\n"
                + "保留 IPv4 网站访问和原生 IPv6；实际地址选择由系统与浏览器决定。\n\n"
                + "Wi-Fi 名称识别需要精确位置权限和系统定位开关；后台识别新接入的 Wi-Fi 需将位置权限设为“始终允许”。未授权时仍可通过校园 DNS／域名识别。\n\n"
                + "iQOO／vivo：请在系统设置中允许 v6only 自启动、后台高耗电／不限制后台运行，并在最近任务中锁定应用（菜单名称随系统版本不同）。\n\n"
                + "划掉界面后服务会继续运行；点击“停止服务”才会停止自动监听。系统“强行停止”后需再次打开应用。");
        root.addView(help);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        setContentView(scroll);
    }

    private Button button(LinearLayout parent, String text, Runnable action) {
        Button button = new Button(this);
        button.setText(text);
        button.setOnClickListener(view -> action.run());
        parent.addView(button);
        return button;
    }

    private void requestWifiPermission() {
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_COARSE_LOCATION,
                    Manifest.permission.ACCESS_FINE_LOCATION}, WIFI_PERMISSION);
        } else if (checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            new AlertDialog.Builder(this).setTitle("后台识别 Wi-Fi 名称")
                    .setMessage("若需要在退出界面后识别新接入的校园 Wi-Fi，请在应用权限的位置设置中选择“始终允许”，并开启系统定位。应用只读取 Wi-Fi 名称，不读取坐标。未授权时仍可通过校园 DNS／域名识别。")
                    .setNegativeButton("暂不设置", null)
                    .setPositiveButton("前往设置", (dialog, which) -> openSettings(new Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))))
                    .show();
        } else {
            Toast.makeText(this, "已授权；请同时开启系统定位开关", Toast.LENGTH_LONG).show();
        }
    }

    private void openSettings(Intent intent) {
        try { startActivity(intent); }
        catch (RuntimeException error) {
            Toast.makeText(this, "请在系统设置中打开 v6only 的应用设置", Toast.LENGTH_LONG).show();
        }
    }

    private void sendCommand(String action) {
        try {
            startForegroundService(new Intent(this, V6VpnService.class).setAction(action));
        } catch (RuntimeException error) {
            Toast.makeText(this, "服务启动失败：" + error.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void startVpn() {
        sendCommand(V6VpnService.ACTION_START);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION);
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == VPN_PERMISSION && result == RESULT_OK) startVpn();
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == WIFI_PERMISSION) {
            if (prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED)
                requestWifiPermission();
        }
        refresh();
    }

    @Override protected void onStart() {
        super.onStart();
        IntentFilter filter = new IntentFilter(V6VpnService.ACTION_STATUS);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(receiver, filter);
    }

    @Override protected void onResume() {
        super.onResume();
        // Foreground restoration after an OEM kill is permitted. Never enable after user stop.
        if (prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
        refresh();
    }

    @Override protected void onStop() {
        unregisterReceiver(receiver);
        super.onStop();
    }

    private void refresh() {
        boolean enabled = prefs.getBoolean("enabled", false);
        boolean automatic = prefs.getBoolean("auto", true);
        boolean monitoring = V6VpnServiceExt.monitoring();
        boolean exempt = getSystemService(PowerManager.class).isIgnoringBatteryOptimizations(getPackageName());
        status.setText("校园网：" + (monitoring
                ? (V6VpnServiceExt.campus() ? "已接入（" + V6VpnServiceExt.reason() + "）" : "未识别到")
                : "启动服务后检测")
                + "\nVPN：" + (V6VpnServiceExt.running(this) ? "已连接" : "未连接")
                + "\n后台监听：" + (monitoring ? "运行中" : "已停止")
                + "\n状态：" + V6VpnServiceExt.message()
                + "\n电池优化：" + (exempt ? "已豁免" : "受系统限制，可在下方设置"));
        toggleBtn.setText(enabled || monitoring ? "停止服务（含自动监听）" : "启动服务");
        autoBtn.setText(automatic ? "自动模式：开（点击切换手动）" : "自动模式：关（点击开启）");
    }
}
