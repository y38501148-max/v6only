# Android 1.1.0 tests

Use a disposable Android emulator, never a personal phone. The native core requires Go (see `core/go.mod`), NDK 29.0.13846066, JDK 17+, Android SDK/API 34+ and build-tools. `ANDROID_HOME` locates the SDK.

## Production campus gate and lifecycle

```sh
bash android/test.sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a bash android/device-test.sh
```

The host policy suite checks campus DNS/domain/SSID boundaries, ordinary private networks, explicit stop and manual/automatic state. `NetworkSmoke` installs the production APK on an ordinary non-campus emulator and verifies manual refusal, automatic standby without a VPN, Recents removal and explicit stop.

## Real native tunnel integration

```sh
ANDROID_SERIAL=emulator-5580 V6ONLY_ANDROID_ABIS=arm64-v8a V6ONLY_TEST_SUITE=tunnel bash android/device-test.sh
```

This creates `v6only-fixture.apk`, using the same production `establishTunnel`, `closeTun`, JNI and physical-socket protection implementation. A test-only service supplies the emulator network and controlled DNS in place of campus discovery. The fixture service and manifest entry are absent from production builds and cannot be signed using the release-key build option. CI inspects the production manifest for leakage.

Loopback fixture servers on the host provide controlled IPv4/IPv6 endpoints and DNS at port 15353. The emulator accesses them via 10.0.2.2 and fec0::2. Tests exercise real Android VPN routes, A queries over TCP/UDP, IPv4-entry flows upgraded to IPv6, IPv4-only origins, explicit IPv6 failure with IPv4 fallback, native diagnostics, and physical connectivity after stop. No host route, DNS or firewall settings are modified.

Results are written to `android/build/device-tests/result.txt`; assertions and missing success markers fail the script. Use `V6ONLY_TEST_SUITE=ui` for the existing UI suite, or `android/tests/device/lifecycle-test.py` for process/reboot checks. Debug signing differs from release signing; use only disposable emulator data when replacing an installed app.

These checks do not establish physical campus behavior, strict private DNS/ECH/proxy combinations, NAT64-only networks, or vendor background-process policies. The complete emulator fixture is independent from the production campus gate; both suites must pass.
