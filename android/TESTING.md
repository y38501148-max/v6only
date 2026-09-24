# Android regression checks

## Host checks

Requirements: JDK 17+, Android SDK platform API 34+ and build-tools, `ANDROID_HOME`.

```sh
bash android/build-apk.sh
bash android/test.sh
shellcheck -S warning android/build-apk.sh android/sdk-env.sh android/test.sh android/device-test.sh
```

`test.sh` covers 32 detection/mode cases, including campus domain boundaries, exact DNS servers, ordinary 10/8 DNS, fake VPN DNS, SSIDs, explicit stop, offline state and manual/automatic behavior. CI builds the same script used locally, verifies the signature, runs these checks and uploads the APK.

## Campus-only policy update

All modes now require campus evidence. Manual mode cannot connect on an ordinary emulator/home network; leaving campus stops manual service. Automatic mode remains in standby outside campus. The 32 host checks cover this stricter condition.

The device script has two branches: a normal non-campus emulator verifies manual refusal, automatic standby, task removal and explicit stop; tunnel routing checks run only with a recognized campus fixture. Its output explicitly reports skipped tunnel checks. The older full-network results below describe PR #1 before the campus-only constraint and must not be reported as a fresh full-device pass for this policy update.

Lifecycle tests default to non-campus automatic standby. Set `EXPECT_CAMPUS_VPN=1` only for a recognized campus fixture. The service is expected to recover after Wi-Fi/boot/process changes while respecting the campus boundary.

## Device networking and task removal

Use a **disposable Android 16/API 36 emulator**, with its default dual-stack Wi-Fi enabled. The emulator must have external HTTPS/DNS access. Tests install the app and an instrumentation APK, grant VPN consent, change app settings and remove its activity from Recents. Python 3 serves controlled HTTP and DNS/TCP fixtures on host loopback ports 18765 and 18753. Do not run on a personal phone.

```sh
ANDROID_SERIAL=emulator-5580 bash android/device-test.sh
```

Verified on the API 36 arm64 Google APIs emulator:

- Test app's default network is the actual VPN (the app is not excluded).
- No default IPv4 capture route or nonexistent `10.111.0.1` DNS address.
- Real A and AAAA resolution through Android's resolver.
- DNS over TCP to a controlled resolver, with sockets explicitly bound to the VPN.
- IPv6 HTTP using the emulator's `fec0::2` host gateway.
- IPv4-only/private HTTP using `10.0.2.2`, plus external HTTPS.
- Automatic mode drops the tunnel on non-campus 10/8 while retaining its foreground monitor.
- Switching to manual reconnects; repeating settings does not replace an unchanged tunnel.
- `finishAndRemoveTask()` removes the activity task while the foreground service and VPN remain alive.
- Explicit stop closes the TUN, clears persisted enablement and is not undone by a restore command.

`device-test.sh` writes the full result to `android/build/device-tests/result.txt`. A failed assertion or missing final success marker fails the script. The emulator's built-in DNS proxy does not provide reliable TCP DNS service; a separate controlled DNS/TCP fixture avoids mistaking that emulator limitation for an app regression.

## Device lifecycle recovery

After `device-test.sh`, on the same disposable, rootable emulator:

```sh
ANDROID_SERIAL=emulator-5580 python3 android/tests/device/lifecycle-test.py
```

This changes emulator airplane/Wi-Fi/data settings, kills only the v6only process, then reboots the emulator. It checks offline foreground monitoring, reconnection, sticky restart after process death, restoration from BOOT_COMPLETED and explicit-stop teardown. It requires `adb root` (not a production phone). These recovery scenarios were also verified on API 36; they do not override an OEM force-stop policy.

## iQOO 15 acceptance checks

An API 36 emulator cannot validate OriginOS/iQOO process management. On the phone:

1. Install a package signed with the original release key, or uninstall the old APK before installing a differently signed test APK (old settings are removed).
2. Start the service and grant VPN permission. Enable notifications, self-start and unrestricted background/battery operation in system settings; lock the app in Recents if the system offers this option.
3. On campus, enable automatic mode and confirm the displayed detection reason. If matching by Wi-Fi name, enable system location and grant precise/always-allowed location access. The application does not request coordinates.
4. Open a dual-stack site, an IPv4-only site and campus authentication/internal pages. Browser Secure DNS and system Private DNS should also be checked in the configurations actually used on the phone.
5. Remove the app's activity from Recents, then check browsing and the ongoing notification after screen-off/on.
6. Leave campus Wi-Fi: VPN should disconnect and the background monitor should remain. Rejoin campus: VPN should reconnect. Repeat with Wi-Fi/cellular switching.
7. Reboot while enabled and verify restoration. Press Stop and verify that neither network changes nor a later reboot restart it.
8. Revoke VPN permission or select a different VPN: v6only must stop without repeatedly taking the VPN slot back.

Physical campus connectivity, captive portal DNS, strict Private DNS, IPv6-only/NAT64 networks, older Android releases and iQOO firmware behavior are not established by the emulator checks. The app keeps A/AAAA and native connections intact; DNS ordering does not guarantee every dual-stack browser connection uses IPv6.

Android references: [VPN routes and lifecycle](https://developer.android.com/develop/connectivity/vpn), [address-family fallback](https://developer.android.com/reference/android/net/VpnService.Builder#allowFamily(int)), [background location permission](https://developer.android.com/develop/sensors-and-location/location/permissions/background).
