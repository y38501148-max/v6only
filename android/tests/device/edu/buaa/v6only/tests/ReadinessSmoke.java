package edu.buaa.v6only.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.net.LinkProperties;
import android.os.Bundle;
import android.system.OsConstants;
import edu.buaa.v6only.NetworkReadiness;
import java.net.InetAddress;

/** Exercises source-address eligibility on the platform, without hidden Android APIs. */
public final class ReadinessSmoke extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            runChecks();
            result.putString("stream", "\nPASS: physical IPv6 readiness and address eligibility\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    /** Also runnable with app_process: no app installation or network changes required. */
    public static void main(String[] args) {
        try {
            runChecks();
            System.out.println("PASS: physical IPv6 readiness and address eligibility");
        } catch (Throwable error) {
            error.printStackTrace();
            System.exit(1);
        }
    }

    private static void runChecks() throws Exception {
        check(!NetworkReadiness.hasUsableIpv6(null), "missing physical network");
        check(!NetworkReadiness.hasUsableIpv6(new LinkProperties()), "empty physical link");
        for (String address : new String[]{"10.135.1.2", "fe80::2", "::1", "::", "fd00::2"})
            check(!NetworkReadiness.usableAddress(InetAddress.getByName(address), 0), "non-global address " + address);
        InetAddress global = InetAddress.getByName("2001:db8::2");
        check(!NetworkReadiness.usableAddress(global, OsConstants.IFA_F_TENTATIVE), "DAD must finish first");
        check(!NetworkReadiness.usableAddress(global, OsConstants.IFA_F_DADFAILED), "duplicate address rejected");
        check(NetworkReadiness.usableAddress(global, OsConstants.IFA_F_TEMPORARY), "temporary global address eligible");
        // Android permits optimistic DAD addresses while TENTATIVE remains set.
        // These combinations were reported by LinkProperties on an iQOO 15
        // even while a socket bound to the same Wi-Fi connected over IPv6.
        int optimistic = OsConstants.IFA_F_TENTATIVE | OsConstants.IFA_F_OPTIMISTIC;
        check(NetworkReadiness.usableAddress(global, optimistic), "optimistic DAD is usable");
        check(NetworkReadiness.usableAddress(global, optimistic | OsConstants.IFA_F_TEMPORARY),
                "optimistic temporary address is usable (flags 0x45)");
        // Use the observed kernel flags directly: IFA_F_MANAGETEMPADDR is not
        // exposed by OsConstants on Android 10, our oldest supported release.
        check(NetworkReadiness.usableAddress(global, 0x144),
                "optimistic managed address is usable (flags 0x144)");
        check(!NetworkReadiness.usableAddress(global, optimistic | OsConstants.IFA_F_DADFAILED),
                "optimistic flag cannot override a duplicate address");
        for (String address : new String[]{"10.135.1.2", "fe80::2", "::1", "::", "fd00::2"})
            check(!NetworkReadiness.usableAddress(InetAddress.getByName(address), optimistic),
                    "optimistic flag cannot make a non-global address usable: " + address);
    }
    private static void check(boolean condition, String label) { if (!condition) throw new AssertionError(label); }
}
