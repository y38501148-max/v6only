package edu.buaa.v6only;

import android.net.LinkProperties;
import android.net.RouteInfo;
import android.system.OsConstants;
import java.net.Inet6Address;

/** Only the selected physical network can supply the strict tunnel's IPv6 path. */
public final class NetworkReadiness {
    private NetworkReadiness() {}

    public static boolean hasUsableIpv6(LinkProperties links) {
        if (links == null) return false;
        boolean address = links.getLinkAddresses().stream().anyMatch(a -> usableAddress(a.getAddress(), a.getFlags()));
        return address && links.getRoutes().stream().anyMatch(r -> r.isDefaultRoute()
                && r.getDestination().getAddress() instanceof Inet6Address
                && r.getType() == RouteInfo.RTN_UNICAST);
    }

    public static boolean usableAddress(java.net.InetAddress address, int flags) {
        return address instanceof Inet6Address && (address.getAddress()[0] & 0xe0) == 0x20
                && (flags & (OsConstants.IFA_F_TENTATIVE | OsConstants.IFA_F_DADFAILED)) == 0;
    }
}
