package edu.buaa.v6only;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Foreground release notices. Installation remains a user action. */
final class AppUpdates {
    private static final long INTERVAL = 6 * 60 * 60 * 1000L;
    private final Activity activity;
    private final SharedPreferences prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final TextView status, title, detail;
    private final View banner;
    private final Button check;
    private String version = "";
    private JSONObject available;
    private boolean pending, closed;
    private long retryAfter;
    private final Runnable tick = new Runnable() {
        @Override public void run() { check(false); handler.postDelayed(this, 60_000); }
    };

    AppUpdates(Activity activity) {
        this.activity = activity;
        prefs = activity.getSharedPreferences("app_updates", Activity.MODE_PRIVATE);
        status = activity.findViewById(R.id.update_status);
        title = activity.findViewById(R.id.update_title);
        detail = activity.findViewById(R.id.update_detail);
        banner = activity.findViewById(R.id.update_banner);
        check = activity.findViewById(R.id.check_update);
        try { version = activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0).versionName; }
        catch (Exception ignored) {}
        check.setOnClickListener(v -> check(true));
        activity.findViewById(R.id.download_update).setOnClickListener(v -> open("download_url"));
        activity.findViewById(R.id.release_notes).setOnClickListener(v -> open("release_url"));
        activity.findViewById(R.id.dismiss_update).setOnClickListener(v -> {
            if (available != null) prefs.edit().putString("dismissed", available.optString("latest_version")).apply();
            banner.setVisibility(View.GONE);
        });
        try {
            JSONObject cached = new JSONObject(prefs.getString("result", "{}"));
            if (version.equals(cached.optString("current_version"))) render(cached, false);
            else prefs.edit().remove("checked_at").apply();
        } catch (Exception ignored) { prefs.edit().remove("checked_at").apply(); }
    }

    void resume() { handler.removeCallbacks(tick); handler.post(tick); }
    void pause() { handler.removeCallbacks(tick); }
    void close() { closed = true; handler.removeCallbacksAndMessages(null); worker.shutdown(); }

    private void check(boolean manual) {
        long now = System.currentTimeMillis(), last = prefs.getLong("checked_at", 0);
        if (closed || pending || (!manual && (now < retryAfter || (now >= last && now - last < INTERVAL)))) return;
        pending = true; check.setEnabled(false);
        if (manual) status.setText("正在检查更新…");
        worker.execute(() -> {
            JSONObject result = null;
            try { result = new JSONObject(CoreNative.checkUpdate(version)); }
            catch (Exception ignored) {}
            final JSONObject response = result;
            handler.post(() -> {
                if (closed || activity.isFinishing() || activity.isDestroyed()) return;
                pending = false; check.setEnabled(true);
                if (response == null || response.has("error")) {
                    retryAfter = System.currentTimeMillis() + 15 * 60 * 1000L;
                    if (manual) status.setText("检查失败，请稍后重试");
                    return;
                }
                prefs.edit().putLong("checked_at", System.currentTimeMillis()).putString("result", response.toString()).apply();
                render(response, manual);
            });
        });
    }

    private void render(JSONObject response, boolean manual) {
        available = response.optBoolean("available") ? response : null;
        String latest = response.optString("latest_version");
        if (manual) prefs.edit().remove("dismissed").apply();
        boolean show = available != null && (manual || !latest.equals(prefs.getString("dismissed", "")));
        banner.setVisibility(show ? View.VISIBLE : View.GONE);
        if (available != null) {
            title.setText("发现新版本 " + latest); detail.setText("当前版本 " + version);
            status.setText("可更新至 " + latest);
        } else if (!response.optString("release_url").isEmpty()) {
            status.setText("新版暂未提供当前设备安装包");
        } else { status.setText(latest.isEmpty() ? "暂无可用更新" : "已是当前设备可用的最新版本"); }
    }

    private void open(String field) {
        if (available == null) return;
        String url = available.optString(field);
        if (!url.startsWith("https://github.com/y38501148-max/v6only/releases/")) return;
        try { activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); }
        catch (Exception ignored) { Toast.makeText(activity, "无法打开更新链接，请稍后重试", Toast.LENGTH_SHORT).show(); }
    }
}
