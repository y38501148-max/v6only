See [Android 2.0.4](README.md) for the current production lifecycle and new startup/global-network tests.

# Android regression tests

Use a disposable Android emulator, never a personal phone. The native core requires Go (see `core/go.mod`), NDK 29.0.13846066, JDK 17+, Android SDK/API 34+ and build-tools. `ANDROID_HOME` locates the SDK.

## Production campus gate and lifecycle

```sh
bash android/test.sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a bash android/device-test.sh
```

The host policy suite checks campus DNS/domain/SSID boundaries, ordinary private networks, explicit stop and manual/automatic state. `NetworkSmoke` installs the production APK on an ordinary non-campus emulator and verifies manual refusal, automatic standby without a VPN, Recents removal and explicit stop.

## Cellular startup and Wi-Fi handover regressions

```sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a V6ONLY_TEST_SUITE=cellular bash android/device-test.sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a V6ONLY_TEST_SUITE=other-vpn bash android/device-test.sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a V6ONLY_TEST_SUITE=handover bash android/device-test.sh
```

`CellularSmoke` disables emulator Wi-Fi and refuses pre-authorization. Starting from the real UI must enter standby without a VPN consent dialog; unbound HTTP and DNS sockets must keep working before/after startup, reapply and manual refusal. `OtherVpnSmoke` runs an unrelated split-route VPN in the test APK's separate UID and verifies that previously authorized v6only startup, reapply, package-update restoration and stop do not revoke it. Both regressions fail against 1.1.0.

`HandoverSmoke` uses real Wi-Fi/cellular transport switching. The fixture-only `HandoverVpn` labels emulator Wi-Fi as campus; all selection callbacks, authorization, establishment and teardown use the production service. Automatic/manual modes must remove VPN routes and synthetic DNS on mobile and preserve unbound HTTP connectivity. Reapplying settings while connected must preserve the existing tunnel. The host Mac network is never changed. The CI emulator matrix exercises Android 10 / 15 in isolated Linux VMs.

The handover fixture uses an inert foreground activity so `MainActivity.onResume` cannot start a second controller beside the fixture service. Cellular startup still exercises the real UI. Fresh emulator modem registration is a precondition checked before starting the app, separately from the shorter service assertions. Handover HTTP recovery is bounded and its latency is printed; sustained failures retain connectivity, route and logcat diagnostics.

The disposable device script disables public captive-portal probes and explicitly reconnects the controlled AndroidWifi AP on newer emulators. CI public-probe availability must not decide whether this loopback-only fixture can establish its pre-test Wi-Fi default. These settings affect only the disposable emulator, not the host or production APK.

## Real native tunnel integration

```sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a V6ONLY_TEST_SUITE=tunnel bash android/device-test.sh
```

This creates `v6only-fixture.apk`, using the same production `establishTunnel`, `closeTun`, JNI and physical-socket protection implementation. A test-only service supplies the emulator network and controlled DNS in place of campus discovery. Fixture services, activity and manifest entries are absent from production builds and cannot be signed using the release-key build option. CI inspects the production manifest for leakage.

Loopback fixture servers on the host provide controlled IPv4/IPv6 endpoints and DNS at port 15353. The emulator accesses them via 10.0.2.2 and fec0::2. Tests exercise real Android VPN routes, A queries over TCP/UDP, IPv4-entry flows upgraded to IPv6, IPv4-only origins, explicit IPv6 failure without IPv4 fallback, native diagnostics, and physical connectivity after stop. No host route, DNS or firewall settings are modified.

Results are written to `android/build/device-tests/result.txt`; assertions and missing success markers fail the script. Use `V6ONLY_TEST_SUITE=ui` for the existing UI suite, or `android/tests/device/lifecycle-test.py` for process/reboot checks. Debug signing differs from release signing; use only disposable emulator data when replacing an installed app.

These checks do not establish physical campus behavior, strict private DNS/ECH/proxy combinations, NAT64-only networks, or vendor background-process policies. The complete emulator fixture is independent from the optional campus gate; both suites must pass.
