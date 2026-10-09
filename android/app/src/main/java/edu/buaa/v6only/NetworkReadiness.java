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
        // Like Android's LinkAddress.isPreferred(), accept optimistic DAD:
        // IFA_F_OPTIMISTIC is set together with IFA_F_TENTATIVE, but the address
        // may already carry traffic. LinkProperties can retain both flags even
        // after the kernel completes DAD (observed on iQOO 15 / OriginOS).
        // A detected duplicate must still fail, including optimistic addresses.
        return address instanceof Inet6Address && (address.getAddress()[0] & 0xe0) == 0x20
                && (flags & OsConstants.IFA_F_DADFAILED) == 0
                && ((flags & OsConstants.IFA_F_TENTATIVE) == 0
                    || (flags & OsConstants.IFA_F_OPTIMISTIC) != 0);
    }
}
