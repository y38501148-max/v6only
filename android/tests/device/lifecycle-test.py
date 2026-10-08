"""Run after device-test.sh on a disposable rootable emulator; reboots the emulator."""
import subprocess, time, re, os
ADB = ['adb', '-s', os.environ.get('ANDROID_SERIAL', 'emulator-5580')]
def adb(*args):
    return subprocess.check_output(ADB + list(args), text=True, stderr=subprocess.STDOUT).strip()
def shell(*args):
    return adb('shell', *args)
def wait(predicate, label, seconds=45):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            if predicate():
                print('PASS: ' + label, flush=True)
                return
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.5)
    raise AssertionError(label)
def vpn():
    return 'ni{VPN CONNECTED' in shell('dumpsys', 'connectivity')
EXPECT_VPN = os.environ.get('EXPECT_VPN', '1') == '1'
def foreground():
    return 'isForeground=true' in shell('dumpsys', 'activity', 'services', 'edu.buaa.v6only')
assert shell('getprop', 'ro.kernel.qemu') == '1', 'Use a disposable emulator'
adb('root')
wait(lambda: shell('id', '-u') == '0', 'root available for process-kill testing')
shell('am', 'start', '-n', 'edu.buaa.v6only/.MainActivity')
shell('am', 'start-foreground-service', '-n', 'edu.buaa.v6only/.V6VpnService', '-a', 'edu.buaa.v6only.START')
wait(lambda: foreground() and vpn() == EXPECT_VPN, 'automatic foreground service starts with physical network')
shell('cmd', 'connectivity', 'airplane-mode', 'enable')
shell('svc', 'data', 'disable')
shell('svc', 'wifi', 'disable')
wait(lambda: not vpn() and foreground(), 'Wi-Fi loss removes VPN but keeps service')
shell('cmd', 'connectivity', 'airplane-mode', 'disable')
shell('svc', 'wifi', 'enable')
shell('cmd', 'wifi', 'connect-network', 'AndroidWifi', 'open')
wait(lambda: vpn() == EXPECT_VPN and foreground(), 'Wi-Fi return preserves connection')
pid = shell('pidof', 'edu.buaa.v6only')
assert re.fullmatch(r'\d+', pid), pid
shell('kill', '-9', pid)
wait(lambda: foreground() and vpn() == EXPECT_VPN and shell('pidof', 'edu.buaa.v6only') != pid,
     'START_STICKY restores service and connection', 55)
adb('reboot')
adb('wait-for-device')
wait(lambda: shell('getprop', 'sys.boot_completed') == '1', 'emulator reboots', 90)
wait(lambda: foreground(), 'boot receiver restores enabled foreground service', 60)
# A cold disposable emulator does not always auto-join its synthetic AP.
shell('cmd', 'wifi', 'connect-network', 'AndroidWifi', 'open')
wait(lambda: vpn() == EXPECT_VPN, 'boot-restored service connects when physical network returns', 45)
adb('root')
wait(lambda: shell('id', '-u') == '0', 'root restored for test cleanup')
shell('am', 'start', '-n', 'edu.buaa.v6only/.MainActivity')
shell('am', 'start-foreground-service', '-n', 'edu.buaa.v6only/.V6VpnService', '-a', 'edu.buaa.v6only.STOP')
wait(lambda: not foreground() and not vpn(), 'explicit stop tears down foreground service and VPN')
shell('svc', 'data', 'enable')
print('PASS: lifecycle regression checks', flush=True)
