package edu.buaa.v6only;

import java.util.Locale;

/** Pure detection policy, also used by the host regression tests. */
final class CampusPolicy {
    private CampusPolicy() {}

    static boolean matchesDomain(String domains) {
        if (domains == null) return false;
        for (String domain : domains.toLowerCase(Locale.ROOT).split("[\\s,;]+")) {
            if (domain.endsWith(".")) domain = domain.substring(0, domain.length() - 1);
            if (domain.equals("buaa.edu.cn") || domain.endsWith(".buaa.edu.cn")) return true;
        }
        return false;
    }

    static boolean matchesDns(String address) {
        return "202.112.128.50".equals(address) || "202.112.128.51".equals(address);
    }

    static boolean matchesSsid(String ssid) {
        if (ssid == null) return false;
        String value = ssid.replace("\"", "").toUpperCase(Locale.ROOT);
        return value.equals("BUAA") || value.startsWith("BUAA-") || value.startsWith("BUAA_");
    }

    static boolean shouldConnect(boolean enabled, boolean automatic,
                                 boolean campus, boolean networkAvailable) {
        // Manual mode must not apply campus DNS/VPN policy on ordinary networks.
        return enabled && networkAvailable && campus;
    }
}
