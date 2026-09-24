package edu.buaa.v6only;

import android.content.Context;

/** Process-local observed state; persisted user intent lives in SharedPreferences. */
public final class V6VpnServiceExt {
    private static volatile boolean running;
    private static volatile boolean monitoring;
    private static volatile boolean campus;
    private static volatile boolean permissionRequired;
    private static volatile String reason = "";
    private static volatile String message = "服务已停止";

    private V6VpnServiceExt() {}
    public static boolean running(Context context) { return running; }
    public static boolean monitoring() { return monitoring; }
    public static boolean campus() { return campus; }
    public static boolean permissionRequired() { return permissionRequired; }
    static void setPermissionRequired(boolean value) { permissionRequired = value; }
    public static String reason() { return reason; }
    public static String message() { return message; }
    static void setRunning(boolean value) { running = value; }
    static void setMonitoring(boolean value) { monitoring = value; }
    static void setCampus(boolean value, String detail) { campus = value; reason = detail; }
    static void setMessage(String value) { message = value; }
}
