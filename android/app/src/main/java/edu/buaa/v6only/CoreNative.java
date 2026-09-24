package edu.buaa.v6only;
/** Shared, audited gVisor packet stack and strict IPv6 dialer. */
public final class CoreNative {
    static { System.loadLibrary("v6core"); }
    private CoreNative() {}
    public static synchronized native String start(int fd, String config, V6VpnService owner);
    public static synchronized native void stop();
    public static synchronized native String flows();
}
