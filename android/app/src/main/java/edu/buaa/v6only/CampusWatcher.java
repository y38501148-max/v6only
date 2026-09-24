package edu.buaa.v6only;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import java.net.InetAddress;
import java.util.LinkedHashMap;
import java.util.Map;

/** Owned by the foreground service; callbacks never start/stop Android services. */
final class CampusWatcher {
    interface Listener { void onNetworkChanged(State state); }

    static final class State {
        final Network network;
        final LinkProperties links;
        final NetworkCapabilities capabilities;
        final String campusReason;

        State(Network network, LinkProperties links, NetworkCapabilities capabilities,
              String campusReason) {
            this.network = network;
            this.links = links;
            this.capabilities = capabilities;
            this.campusReason = campusReason;
        }
        boolean isCampus() {
            return network != null && links != null && isPhysical(capabilities)
                    && campusTransport(capabilities)
                    && !campusReason.isEmpty();
        }
    }

    private static final class Entry {
        LinkProperties links;
        NetworkCapabilities capabilities;
        boolean campusSsid;
    }

    private final Context context;
    private final ConnectivityManager cm;
    private final Handler handler;
    private final Listener listener;
    private final Map<Network, Entry> networks = new LinkedHashMap<>();
    private final Runnable evaluate = this::evaluate;
    private ConnectivityManager.NetworkCallback callback, defaultCallback, bestCallback;
    private Network bestPhysical;
    private boolean bestInitialized;

    CampusWatcher(Context context, Handler handler, Listener listener) {
        this.context = context;
        this.cm = context.getSystemService(ConnectivityManager.class);
        this.handler = handler;
        this.listener = listener;
    }

    void start() {
        if (callback != null) return;
        int flags = Build.VERSION.SDK_INT >= 31
                && context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED
                ? ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO : 0;
        callback = Build.VERSION.SDK_INT >= 31 ? new Callback(flags) : new Callback();
        // Do not require INTERNET or VALIDATED: captive portals must still be observed.
        cm.registerNetworkCallback(new NetworkRequest.Builder().clearCapabilities()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
                callback, handler);
        // Initial snapshot, outside a callback. Future updates use callback arguments, not
        // synchronous getLinkProperties/getNetworkCapabilities calls with stale state.
        for (Network network : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(network);
            if (isPhysical(caps)) {
                Entry entry = new Entry();
                entry.capabilities = caps;
                entry.links = cm.getLinkProperties(network);
                networks.put(network, entry);
            }
        }
        defaultCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network n) { refresh(); }
            @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) { refresh(); }
            @Override public void onLost(Network n) { refresh(); }
        };
        cm.registerDefaultNetworkCallback(defaultCallback, handler);
        if (Build.VERSION.SDK_INT >= 31) {
            bestCallback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network n) {
                    if (bestCallback != this) return;
                    bestInitialized = true;
                    bestPhysical = n; refresh();
                }
                @Override public void onLost(Network n) {
                    if (bestCallback != this) return;
                    bestInitialized = true;
                    if (n.equals(bestPhysical)) bestPhysical = null;
                    refresh();
                }
            };
            // Follow Android's choice even while our own VPN is the app's default.
            cm.registerBestMatchingNetworkCallback(new NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), bestCallback, handler);
        }
        refresh();
    }

    private final class Callback extends ConnectivityManager.NetworkCallback {
        Callback() { super(); }
        Callback(int flags) { super(flags); }
        @Override public void onAvailable(Network n) {
            if (callback != this) return;
            if (!networks.containsKey(n)) networks.put(n, new Entry());
        }
        @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) {
            if (callback != this) return;
            if (!networks.containsKey(n)) networks.put(n, new Entry());
            networks.get(n).capabilities = caps;
            refresh();
        }
        @Override public void onLinkPropertiesChanged(Network n, LinkProperties links) {
            if (callback != this) return;
            if (!networks.containsKey(n)) networks.put(n, new Entry());
            networks.get(n).links = links;
            refresh();
        }
        @Override public void onLost(Network n) {
            if (callback != this) return;
            networks.remove(n);
            refresh();
        }
    }

    void refresh() {
        handler.removeCallbacks(evaluate);
        if (callback != null) handler.post(evaluate);
    }

    void stop() {
        handler.removeCallbacks(evaluate);
        if (callback != null) cm.unregisterNetworkCallback(callback);
        if (defaultCallback != null) cm.unregisterNetworkCallback(defaultCallback);
        if (bestCallback != null) cm.unregisterNetworkCallback(bestCallback);
        callback = defaultCallback = bestCallback = null;
        bestPhysical = null;
        bestInitialized = false;
        networks.clear();
    }

    private static boolean isPhysical(NetworkCapabilities caps) {
        return caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN);
    }

    private static boolean campusTransport(NetworkCapabilities caps) {
        return CampusPolicy.campusTransport(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN));
    }

    static boolean cellularDefault(Context context) {
        ConnectivityManager cm = context.getSystemService(ConnectivityManager.class);
        Network active = cm.getActiveNetwork();
        NetworkCapabilities caps = active == null ? null : cm.getNetworkCapabilities(active);
        return isPhysical(caps) && caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
    }

    private void evaluate() {
        if (callback == null) return;
        Network active = cm.getActiveNetwork();
        // A cellular default wins even if an old campus Wi-Fi is still in the map.
        if (active != null && isPhysical(cm.getNetworkCapabilities(active))) {
            deliver(active, networks.get(active));
            return;
        }
        if (Build.VERSION.SDK_INT >= 31) {
            // Re-registering on Activity resume must not drop a healthy VPN while
            // waiting for the initial best-match callback. A real loss still closes it.
            if (!bestInitialized && networks.values().stream().anyMatch(e -> isPhysical(e.capabilities)
                    && e.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))) return;
            deliver(bestPhysical, networks.get(bestPhysical));
            return;
        }
        Network best = null;
        Entry selected = null;
        int bestScore = -1;
        // Executed after callback dispatch, not from inside the callback itself.
        for (Map.Entry<Network, Entry> item : networks.entrySet()) {
            Entry entry = item.getValue();
            if (entry.links == null || !isPhysical(entry.capabilities)
                    || !entry.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
            NetworkCapabilities caps = entry.capabilities;
            int score = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ? 100 : 0;
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) score += 200;
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) score += 30;
            else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 20;
            else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) score += 10;
            else continue;
            if (item.getKey().equals(active)) score += 1000;
            if (score > bestScore) {
                bestScore = score;
                best = item.getKey();
                selected = entry;
            }
        }
        deliver(best, selected);
    }

    private void deliver(Network network, Entry entry) {
        listener.onNetworkChanged(entry == null || entry.links == null || !isPhysical(entry.capabilities)
                ? new State(null, null, null, "")
                : new State(network, entry.links, entry.capabilities, match(entry)));
    }

    private String match(Entry entry) {
        NetworkCapabilities caps = entry.capabilities;
        if (!campusTransport(caps)) return "";
        for (InetAddress dns : entry.links.getDnsServers()) {
            if (CampusPolicy.matchesDns(dns.getHostAddress())) return "校园 DNS";
        }
        if (CampusPolicy.matchesDomain(entry.links.getDomains())) return "校园域名";
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            try {
                WifiInfo info = caps.getTransportInfo() instanceof WifiInfo
                        ? (WifiInfo) caps.getTransportInfo() : null;
                String ssid = info == null ? null : info.getSSID();
                if (ssid == null || ssid.equals(WifiManager.UNKNOWN_SSID)) {
                    WifiManager wifi = context.getSystemService(WifiManager.class);
                    if (wifi != null) ssid = wifi.getConnectionInfo().getSSID();
                }
                rememberSsid(entry, ssid);
            } catch (SecurityException ignored) {
                // DNS/domain detection is still available without location permission.
            }
            if (entry.campusSsid) return "校园 Wi-Fi";
        }
        // 10/8 is also used by cellular, home routers and emulators. Never identify it
        // as campus, and never inspect our own VPN DNS/search domain as campus evidence.
        return "";
    }
    private static void rememberSsid(Entry entry, String ssid) {
        // Location redaction can change while the same network stays connected. Retain a
        // confirmed SSID only for this Network; onLost discards it, a new SSID replaces it.
        if (ssid != null && !ssid.equals(WifiManager.UNKNOWN_SSID) && !ssid.isEmpty())
            entry.campusSsid = CampusPolicy.matchesSsid(ssid);
    }

}
