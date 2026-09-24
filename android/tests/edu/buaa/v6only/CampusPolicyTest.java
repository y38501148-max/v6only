package edu.buaa.v6only;

/** Run with java -ea; guards against the original emulator/cellular/VPN false positives. */
public final class CampusPolicyTest {
    public static void main(String[] args) {
        check(CampusPolicy.matchesDomain("buaa.edu.cn"));
        check(CampusPolicy.matchesDomain("dept.BUAA.EDU.CN. example.org"));
        check(!CampusPolicy.matchesDomain("notbuaa.edu.cn"));
        check(!CampusPolicy.matchesDomain("buaa.edu.cn.evil.example"));
        check(!CampusPolicy.matchesDomain(null));
        check(CampusPolicy.matchesDns("202.112.128.50"));
        check(CampusPolicy.matchesDns("202.112.128.51"));
        check(!CampusPolicy.matchesDns("202.112.1.1"));
        check(!CampusPolicy.matchesDns("10.0.2.3"));
        check(!CampusPolicy.matchesDns("10.135.1.1"));
        check(!CampusPolicy.matchesDns("10.111.0.1"));
        check(CampusPolicy.matchesSsid("\"BUAA-WiFi\""));
        check(CampusPolicy.matchesSsid("buaa"));
        check(!CampusPolicy.matchesSsid("AndroidWifi"));
        check(!CampusPolicy.matchesSsid("BUAAFake"));
        check(!CampusPolicy.matchesSsid(null));
        for (boolean enabled : new boolean[]{false, true}) {
            for (boolean automatic : new boolean[]{false, true}) {
                for (boolean campus : new boolean[]{false, true}) {
                    for (boolean network : new boolean[]{false, true}) {
                        boolean actual = CampusPolicy.shouldConnect(enabled, automatic, campus, network);
                        if (!enabled || !network) check(!actual);
                        else check(actual == campus);
                    }
                }
            }
        }
        System.out.println("PASS: 32 campus detection and mode regression checks");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
