package edu.buaa.v6only;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.location.LocationManager;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.RadioGroup;
import android.widget.TextView;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final int VPN_PERMISSION = 1;
    private static final int NOTIFICATION_PERMISSION = 2;
    private static final int WIFI_PERMISSION = 3;
    private TextView title, description, badge, network, background, modeDescription;
    private TextView wifiDetail, batteryDetail, notificationDetail;
    private Button toggle;
    private RadioGroup modes;
    private SharedPreferences prefs;
    private boolean rendering, pending, pendingStart;
    private final java.util.concurrent.ExecutorService statsWorker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private boolean statsPending;
    private final Runnable statsTick = new Runnable() { public void run() { refreshTotals(); handler.postDelayed(this, 5000); } };
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable finishPending = () -> { pending = false; refresh(); };
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { refresh(); }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("v6only", MODE_PRIVATE);
        setContentView(R.layout.activity_main);
        findViewById(R.id.scroll).setOnApplyWindowInsetsListener((v,insets) -> {
            android.graphics.Insets bars = insets.getSystemWindowInsets();
            v.setPadding(bars.left,bars.top,bars.right,bars.bottom); return insets;
        });
        title = findViewById(R.id.status_title);
        description = findViewById(R.id.status_description);
        badge = findViewById(R.id.state_badge);
        network = findViewById(R.id.network_status);
        background = findViewById(R.id.background_status);
        modeDescription = findViewById(R.id.mode_description);
        wifiDetail = findViewById(R.id.wifi_detail);
        batteryDetail = findViewById(R.id.battery_detail);
        notificationDetail = findViewById(R.id.notification_detail);
        toggle = findViewById(R.id.toggle_service);
        modes = findViewById(R.id.mode_group);
        try {
            ((TextView) findViewById(R.id.version)).setText(
                    "v" + getPackageManager().getPackageInfo(getPackageName(), 0).versionName);
        } catch (PackageManager.NameNotFoundException ignored) {}

        // Keep comfortable line lengths on tablets and in landscape; the whole page scrolls.
        View scroll = findViewById(R.id.scroll);
        View content = findViewById(R.id.content);
        scroll.addOnLayoutChangeListener((v, l, t, r, b, oldL, oldT, oldR, oldB) -> {
            int width = Math.min(r - l, dp(600));
            ViewGroup.LayoutParams params = content.getLayoutParams();
            if (width > 0 && params.width != width) { params.width = width; content.setLayoutParams(params); }
        });
        toggle.setOnClickListener(view -> {
            if (V6VpnServiceExt.permissionRequired()) {
                // Consent is requested only after the service identifies a campus network.

                Intent permission = VpnService.prepare(this);
                if (permission == null) sendCommand(V6VpnService.ACTION_APPLY);
                else startActivityForResult(permission, VPN_PERMISSION);
            } else if (prefs.getBoolean("enabled", false) || V6VpnServiceExt.monitoring()) {
                prefs.edit().putBoolean("enabled", false).commit();
                userCommand(false);
            } else {
                startVpn();
            }
        });
        modes.setOnCheckedChangeListener((group, checkedId) -> {
            if (rendering) return;
            boolean automatic = checkedId == R.id.mode_auto;
            if (prefs.getBoolean("auto", true) == automatic) return;
            prefs.edit().putBoolean("auto", automatic).commit();
            if (prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
            refresh();
        });
        findViewById(R.id.traffic_history).setOnClickListener(view -> startActivity(new Intent(this, TrafficActivity.class)));
        findViewById(R.id.connections).setOnClickListener(view -> startActivity(new Intent(this, ConnectionsActivity.class)));
        findViewById(R.id.battery_row).setOnClickListener(view -> showBackgroundHelp());
        findViewById(R.id.notification_row).setOnClickListener(view -> {
            if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS)) {
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION);
            } else {
                openSettings(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()));
            }
        });
        boolean tipsOpen = savedInstanceState != null && savedInstanceState.getBoolean("tipsOpen");
        setTipsOpen(tipsOpen);
        findViewById(R.id.tips_toggle).setOnClickListener(view ->
                setTipsOpen(findViewById(R.id.tips_content).getVisibility() != View.VISIBLE));
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private boolean granted(String permission) {
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private void setTipsOpen(boolean open) {
        findViewById(R.id.tips_content).setVisibility(open ? View.VISIBLE : View.GONE);
        ((ImageView) findViewById(R.id.tips_arrow)).setRotation(open ? 180 : 0);
        findViewById(R.id.tips_toggle).setContentDescription("使用提示，" + (open ? "收起" : "展开"));
    }

    @Override protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean("tipsOpen", findViewById(R.id.tips_content).getVisibility() == View.VISIBLE);
        super.onSaveInstanceState(outState);
    }

    private Intent appSettings() {
        return new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()));
    }

    private void showBackgroundHelp() {
        startActivity(new Intent(this, BackgroundSettingsActivity.class));
    }

    private void requestWifiPermission() {
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            new AlertDialog.Builder(this).setTitle("识别校园 Wi-Fi")
                    .setMessage("识别 Wi-Fi 名称需要精确位置权限。应用只读取名称，不读取位置坐标。\n\n无需授权也可通过校园 DNS 与域名识别。")
                    .setNegativeButton("暂不开启", null)
                    .setPositiveButton("继续", (dialog, which) -> requestPermissions(new String[]{
                            Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION}, WIFI_PERMISSION))
                    .setNeutralButton("应用设置", (dialog, which) -> openSettings(appSettings())).show();
        } else if (!getSystemService(LocationManager.class).isLocationEnabled()) {
            new AlertDialog.Builder(this).setTitle("开启系统定位")
                    .setMessage("Android 需要开启系统定位才能提供 Wi-Fi 名称。校园 DNS 与域名识别不受此设置影响。")
                    .setNegativeButton("稍后", null).setPositiveButton("定位设置", (dialog, which) ->
                            openSettings(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))).show();
        } else if (!granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)) {
            new AlertDialog.Builder(this).setTitle("后台识别 Wi-Fi 名称")
                    .setMessage("如需在退出界面后识别新接入的校园 Wi-Fi，请在应用权限的位置设置中选择“始终允许”。\n\n未授权时，后台仍可通过校园 DNS 与域名识别。")
                    .setNegativeButton("暂不设置", null)
                    .setPositiveButton("前往设置", (dialog, which) -> openSettings(appSettings())).show();
        } else {
            new AlertDialog.Builder(this).setTitle("校园网识别已就绪")
                    .setMessage("已允许前台和后台读取 Wi-Fi 名称。应用也会根据校园 DNS 与域名识别网络。")
                    .setPositiveButton("知道了", null)
                    .setNeutralButton("权限设置", (dialog, which) -> openSettings(appSettings())).show();
        }
    }

    private void openSettings(Intent intent) {
        try { startActivity(intent); }
        catch (RuntimeException error) {
            Toast.makeText(this, "请在系统设置中打开 v6only 的应用设置", Toast.LENGTH_LONG).show();
        }
    }

    private boolean sendCommand(String action) {
        try {
            startForegroundService(new Intent(this, V6VpnService.class).setAction(action));
            return true;
        } catch (RuntimeException error) {
            Toast.makeText(this, "服务启动失败：" + error.getMessage(), Toast.LENGTH_LONG).show();
            return false;
        }
    }

    private void userCommand(boolean start) {
        pendingStart = start;
        pending = sendCommand(start ? V6VpnService.ACTION_START : V6VpnService.ACTION_STOP);
        handler.removeCallbacks(finishPending);
        if (pending) handler.postDelayed(finishPending, 4000);
        refresh();
    }

    private void startVpn() {
        Intent permission = VpnService.prepare(this);
        if (permission != null) { startActivityForResult(permission, VPN_PERMISSION); return; }
        userCommand(true);
        if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS)) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION);
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == VPN_PERMISSION && result == RESULT_OK) startVpn();
        else if (request == VPN_PERMISSION) {
            Toast.makeText(this, "尚未授权 VPN，保持网络监听", Toast.LENGTH_SHORT).show();
            refresh();
        }
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == WIFI_PERMISSION && prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
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
        if (prefs.getBoolean("enabled", false)) sendCommand(V6VpnService.ACTION_APPLY);
        refresh();
        handler.removeCallbacks(statsTick); handler.post(statsTick);
    }

    @Override protected void onStop() {
        handler.removeCallbacks(statsTick);
        unregisterReceiver(receiver);
        super.onStop();
    }

    @Override protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        statsWorker.shutdown();
        super.onDestroy();
    }

    private void showState(String heading, String detail, String label, int badgeColor, int textColor) {
        title.setText(heading);
        description.setText(detail);
        badge.setText(label);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(badgeColor);
        shape.setCornerRadius(dp(24));
        badge.setBackground(shape);
        badge.setTextColor(textColor);
    }

    private void refreshTotals() {
        if (statsPending || statsWorker.isShutdown()) return;
        statsPending = true;
        statsWorker.execute(() -> {
            try {
                org.json.JSONObject r = new org.json.JSONObject(CoreNative.stats(new java.io.File(getFilesDir(), "traffic.sqlite").getAbsolutePath(), 0, System.currentTimeMillis()/1000+1));
                long v6 = r.optLong("v6_up") + r.optLong("v6_down"), v4 = r.optLong("v4_up") + r.optLong("v4_down");
                handler.post(() -> { if (!isDestroyed()) { ((TextView)findViewById(R.id.traffic_total)).setText(TrafficActivity.bytes(v4+v6)); ((TextView)findViewById(R.id.traffic_split)).setText("IPv6  " + TrafficActivity.bytes(v6) + "　·　IPv4  " + TrafficActivity.bytes(v4)); } statsPending=false; });
            } catch (Exception error) { handler.post(() -> statsPending=false); }
        });
    }

    private void refresh() {
        boolean enabled = prefs.getBoolean("enabled", false);
        boolean automatic = prefs.getBoolean("auto", true);
        boolean monitoring = V6VpnServiceExt.monitoring();
        boolean connected = V6VpnServiceExt.running(this);
        if (pending && (monitoring == pendingStart
                || (!enabled && V6VpnServiceExt.message().contains("当前非校园网")))) {
            pending = false;
            handler.removeCallbacks(finishPending);
        }
        int neutral = getColor(R.color.hero_badge);
        if (pending || (enabled && !monitoring)) {
            showState(pending && !pendingStart ? "正在停止" : "正在启动", "正在更新服务状态，请稍候。", "处理中", neutral, Color.WHITE);
        } else if (connected) {
            showState("连接已开启", "正在记录流量。", "已连接", Color.rgb(162, 236, 214), Color.rgb(12, 65, 59));
        } else if (monitoring && V6VpnServiceExt.permissionRequired()) {
            showState("等待 VPN 授权", "授权后开始连接。", "待授权", neutral, Color.WHITE);
        } else if (monitoring) {
            String message = V6VpnServiceExt.message();
            if (message.contains("失败") || message.contains("DNS")) {
                showState("等待网络就绪", message, "等待中", Color.rgb(252, 218, 151), Color.rgb(83, 56, 10));
            } else if (message.contains("等待网络连接")) {
                showState("等待网络", "服务仍在后台运行，网络恢复后会继续连接。", "监听中", neutral, Color.WHITE);
            } else {
                showState(automatic ? "等待校园网" : "正在连接", automatic
                        ? "已保持后台监听，接入校园网后会自动连接。" : "正在为当前网络开启连接。", "监听中", neutral, Color.WHITE);
            }
        } else if (V6VpnServiceExt.message().contains("当前非校园网")) {
            showState("仅限校园网", "当前网络无需启用。接入校园网后可手动启动，或选择自动模式等待。", "未启动", neutral, Color.WHITE);
        } else {
            showState("连接未开启", "连接后开始记录流量。", "未启动", neutral, Color.WHITE);
        }
        boolean alwaysOn = V6VpnServiceExt.alwaysOn();
        toggle.setEnabled(!pending && !alwaysOn);
        toggle.setAlpha(pending ? 0.65f : 1f);
        toggle.setText(alwaysOn ? "常驻连接" : pending ? (pendingStart ? "正在启动…" : "正在停止…")
                : V6VpnServiceExt.permissionRequired() ? "授权并连接"
                : enabled || monitoring ? "停止服务" : "启动服务");
        network.setText("网络  ·  " + (connected ? "已连接" : "未连接"));
        background.setText("后台监听  ·  " + (monitoring ? "持续运行" : enabled ? "正在恢复" : "已停止"));
        rendering = true;
        modes.check(automatic ? R.id.mode_auto : R.id.mode_manual);
        rendering = false;
        modeDescription.setText(automatic ? "重启手机后恢复连接。" : "打开应用后手动连接。");
        boolean location = getSystemService(LocationManager.class).isLocationEnabled();
        wifiDetail.setText(!granted(Manifest.permission.ACCESS_FINE_LOCATION) ? "DNS / 域名可用 · Wi-Fi 名称需授权"
                : !location ? "Wi-Fi 名称识别需开启系统定位"
                : !granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ? "前台已授权 · 后台识别可设置" : "Wi-Fi 名称识别已就绪");
        boolean exempt = getSystemService(PowerManager.class).isIgnoringBatteryOptimizations(getPackageName());
        batteryDetail.setText(exempt ? "电池优化已豁免 · 查看自启动设置" : "设置自启动与后台耗电管理");
        boolean notifications = getSystemService(NotificationManager.class).areNotificationsEnabled();
        notificationDetail.setText(notifications ? "已允许 · 可查看后台运行状态" : "尚未允许 · 点击开启运行通知");
    }
}
