package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ScrollView;
import android.widget.TextView;
import edu.buaa.v6only.MainActivity;
import edu.buaa.v6only.R;
import edu.buaa.v6only.V6VpnService;
import edu.buaa.v6only.V6VpnServiceExt;
import java.io.File;
import java.io.FileOutputStream;
import java.util.function.BooleanSupplier;

/** Real view interactions plus rendered UI captures on a disposable emulator. */
public final class UiSmoke extends Instrumentation {
    private Activity activity;
    private Context context;
    private SharedPreferences prefs;
    private String scenario;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        scenario = arguments == null ? "light" : arguments.getString("scenario", "light");
        if (!scenario.matches("[a-z0-9_-]+")) throw new IllegalArgumentException("Invalid scenario");
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            context = getTargetContext();
            prefs = context.getSharedPreferences("v6only", Context.MODE_PRIVATE);
            context.startForegroundService(new Intent(context, V6VpnService.class).setAction(V6VpnService.ACTION_STOP));
            await(() -> !V6VpnServiceExt.monitoring(), "initial service stop");
            SystemClock.sleep(250);
            prefs.edit().putBoolean("campus_only", false).putBoolean("enabled", false).putBoolean("auto", true).commit();
            activity = startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitForIdleSync();
            SystemClock.sleep(400);
            check(text(R.id.status_title).equals("连接未开启"), "stopped state");
            validateLayout();
            capture("stopped");

            if (scenario.equals("light")) {
                click(R.id.mode_manual);
                check(!prefs.getBoolean("auto", true), "manual startup preference persists");
                check(!prefs.getBoolean("enabled", false), "changing startup mode does not start service");
                click(R.id.toggle_service);
                await(() -> V6VpnServiceExt.running(context), "global connection starts outside campus");
                await(() -> text(R.id.status_title).equals("连接已开启"), "connected feedback");
                check(text(R.id.toggle_service).equals("停止服务"), "stop action label");
                capture("connected");
                click(R.id.mode_auto);
                check(prefs.getBoolean("auto", false), "automatic startup preference persists");
                click(R.id.toggle_service);
                await(() -> !V6VpnServiceExt.monitoring() && text(R.id.status_title).equals("连接未开启"), "explicit stop feedback");
                check(!prefs.getBoolean("enabled", true), "stop is persisted");
            }
            click(R.id.tips_toggle);
            check(activity.findViewById(R.id.tips_content).getVisibility() == View.VISIBLE, "tips expanded");
            ActivityMonitor monitor = addMonitor(MainActivity.class.getName(), null, false);
            runOnMainSync(() -> activity.recreate());
            Activity recreated = monitor.waitForActivityWithTimeout(5000);
            removeMonitor(monitor);
            check(recreated != null, "activity recreation");
            activity = recreated;
            waitForIdleSync();
            check(activity.findViewById(R.id.tips_content).getVisibility() == View.VISIBLE, "tips survive recreation");
            validateLayout();
            runOnMainSync(() -> ((ScrollView) activity.findViewById(R.id.scroll)).fullScroll(View.FOCUS_DOWN));
            waitForIdleSync();
            SystemClock.sleep(400);
            capture("settings");
            runOnMainSync(() -> activity.finishAndRemoveTask());
            result.putString("stream", "\nPASS: Android UI checks (" + scenario + ")\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void click(int id) {
        runOnMainSync(() -> activity.findViewById(id).performClick());
        waitForIdleSync();
    }
    private String text(int id) {
        final String[] value = new String[1];
        runOnMainSync(() -> value[0] = ((TextView) activity.findViewById(id)).getText().toString());
        return value[0];
    }
    private void validateLayout() {
        final Throwable[] failure = new Throwable[1];
        runOnMainSync(() -> {
            try {
            View content = activity.findViewById(R.id.content);
            View scroll = activity.findViewById(R.id.scroll);
            check(content.getWidth() <= scroll.getWidth(), "content fits screen width");
            checkText(content);
            float density = context.getResources().getDisplayMetrics().density;
            for (int id : new int[]{R.id.toggle_service, R.id.mode_auto, R.id.mode_manual,
                    R.id.traffic_history, R.id.connections, R.id.battery_row, R.id.notification_row, R.id.tips_toggle}) {
                View target = activity.findViewById(id);
                check(target.getHeight() >= 48 * density - 1, "minimum touch target " + id);
            }
            } catch (Throwable error) { failure[0] = error; }
        });
        if (failure[0] != null) throw new AssertionError(failure[0]);
    }
    private void checkText(View view) {
        if (view.getVisibility() != View.VISIBLE) return;
        if (view instanceof TextView) {
            TextView text = (TextView) view;
            if (text.getLayout() != null) {
                int usable = text.getWidth() - text.getCompoundPaddingLeft() - text.getCompoundPaddingRight();
                for (int line = 0; line < text.getLayout().getLineCount(); line++) {
                    check(text.getLayout().getEllipsisCount(line) == 0, "ellipsized text: " + text.getText());
                    check(text.getLayout().getLineMax(line) <= usable + 2, "horizontal clipping: " + text.getLayout().getLineMax(line) + " > " + usable + ": " + text.getText());
                }
                check(text.getLayout().getHeight() <= text.getHeight() - text.getCompoundPaddingTop()
                        - text.getCompoundPaddingBottom() + 2, "vertical clipping: " + text.getText());
            }
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) checkText(group.getChildAt(i));
        }
    }
    private void capture(String state) throws Exception {
        waitForIdleSync();
        SystemClock.sleep(250);
        Bitmap bitmap = getUiAutomation().takeScreenshot();
        check(bitmap != null, "screenshot available");
        File directory = context.getExternalFilesDir("ui-checks");
        check(directory != null && (directory.isDirectory() || directory.mkdirs()), "screenshot directory");
        try (FileOutputStream out = new FileOutputStream(new File(directory, scenario + "-" + state + ".png"))) {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        }
        bitmap.recycle();
    }
    private void await(BooleanSupplier condition, String label) {
        long deadline = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition.getAsBoolean()) return;
            SystemClock.sleep(100);
        }
        throw new AssertionError(label);
    }
    private void check(boolean value, String label) { if (!value) throw new AssertionError(label); }
}
