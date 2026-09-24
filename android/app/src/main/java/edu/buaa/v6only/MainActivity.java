package edu.buaa.v6only;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 极简控制台：
 *  - 开关 VPN（首次弹 VpnService 授权）
 *  - 显示当前是否检测到校园网（DNS 搜索域 buaa.edu.cn 为主信号）
 *  - 「自动模式」开启时由 CampusWatcher 决定启停（默认开）
 */
public class MainActivity extends Activity {

    private TextView status;
    private Button toggleBtn, autoBtn;
    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = getSharedPreferences("v6only", MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(48, 48, 48, 48);

        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, 0, 0, 48);
        root.addView(status);

        toggleBtn = new Button(this);
        toggleBtn.setOnClickListener(v -> {
            if (V6VpnServiceExt.running(this)) {
                startService(new Intent(this, V6VpnService.class)
                        .setAction(V6VpnService.ACTION_STOP));
            } else {
                Intent i = VpnService.prepare(this);
                if (i == null) startVpn();
                else startActivityForResult(i, 1);
            }
            // 服务启停是异步的，延迟刷新避免按钮文案停留在旧状态
            toggleBtn.postDelayed(this::refresh, 1500);
            toggleBtn.postDelayed(this::refresh, 3000);
        });
        root.addView(toggleBtn);

        autoBtn = new Button(this);
        autoBtn.setOnClickListener(v -> {
            boolean now = !prefs.getBoolean("auto", true);
            prefs.edit().putBoolean("auto", now).apply();
            if (now) CampusWatcher.start(this); else CampusWatcher.stop(this);
            refresh();
        });
        root.addView(autoBtn);

        setContentView(root);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req == 1 && res == RESULT_OK) startVpn();
    }

    private void startVpn() {
        startForegroundService(new Intent(this, V6VpnService.class)
                .setAction(V6VpnService.ACTION_START));
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
        if (prefs.getBoolean("auto", true)) CampusWatcher.start(this);
    }

    private void refresh() {
        boolean running = V6VpnServiceExt.running(this);
        boolean campus = CampusWatcher.isCampus(this);
        boolean autoOn = prefs.getBoolean("auto", true);
        status.setText("校园网: " + (campus ? "✓ 已接入 (" + CampusWatcher.lastReason() + ")" : "✗ 未接入")
                + "\nVPN: " + (running ? "运行中" : "停止")
                + "\n自动模式: " + (autoOn ? "开（检测到校园网自动接管）" : "关"));
        toggleBtn.setText(running ? "停止 VPN" : "启动 VPN");
        autoBtn.setText(autoOn ? "自动模式: 开（点击关闭）" : "自动模式: 关（点击开启）");
    }
}
