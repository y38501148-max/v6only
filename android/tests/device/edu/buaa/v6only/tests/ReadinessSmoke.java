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
            check(!NetworkReadiness.hasUsableIpv6(null), "missing physical network");
            check(!NetworkReadiness.hasUsableIpv6(new LinkProperties()), "empty physical link");
            for (String address : new String[]{"10.135.1.2", "fe80::2", "::1", "::", "fd00::2"})
                check(!NetworkReadiness.usableAddress(InetAddress.getByName(address), 0), "non-global address " + address);
            InetAddress global = InetAddress.getByName("2001:db8::2");
            check(!NetworkReadiness.usableAddress(global, OsConstants.IFA_F_TENTATIVE), "DAD must finish first");
            check(!NetworkReadiness.usableAddress(global, OsConstants.IFA_F_DADFAILED), "duplicate address rejected");
            check(NetworkReadiness.usableAddress(global, OsConstants.IFA_F_TEMPORARY), "temporary global address eligible");
            result.putString("stream", "\nPASS: physical IPv6 readiness and address eligibility\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private void check(boolean condition, String label) { if (!condition) throw new AssertionError(label); }
}
