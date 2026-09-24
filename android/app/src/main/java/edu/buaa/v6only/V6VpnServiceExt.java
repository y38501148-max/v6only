package edu.buaa.v6only;

import android.content.Context;

/**
 * VPN 运行状态的全局标志。
 * getRunningServices() 在 API 26+ 已不保证返回结果，用它判定会导致
 * 「点停止被误判为未运行 → 反而再次启动」。改由 V6VpnService 在
 * onCreate/onDestroy 维护静态标志。
 */
public final class V6VpnServiceExt {
    private static volatile boolean sRunning = false;

    public static boolean running(Context ctx) {
        return sRunning;
    }

    public static void setRunning(boolean r) {
        sRunning = r;
    }
}
