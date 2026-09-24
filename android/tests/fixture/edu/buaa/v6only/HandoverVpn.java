package edu.buaa.v6only;

import android.net.NetworkCapabilities;

/** Only the disposable emulator's Wi-Fi is marked as campus; lifecycle is production code. */
public final class HandoverVpn extends V6VpnService {
    @Override public void onCreate() {
        if (!android.os.Build.HARDWARE.contains("ranchu") && !android.os.Build.HARDWARE.contains("goldfish"))
            throw new IllegalStateException("Fixture requires an emulator");
        super.onCreate();
    }
    @Override protected void reconcile(CampusWatcher.State state) {
        android.util.Log.i("HandoverVpn", "Reconcile physical=" + state.network
                + " caps=" + state.capabilities);
        if (state.capabilities != null && state.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))
            state = new CampusWatcher.State(state.network, state.links, state.capabilities, "模拟校园 Wi-Fi");
        super.reconcile(state);
    }
}
