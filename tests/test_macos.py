"""Exercise the real Bash controller against fake OS commands, never host settings."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['FAKE_STATE']); s=json.loads(p.read_text())
name=Path(sys.argv[0]).name; a=sys.argv[1:]
s['calls'].append([name]+a)
def done(value='', code=0):
    p.write_text(json.dumps(s))
    if value: print(value)
    sys.exit(code)
def mutate():
    s['writes'].append([name]+a)
    if s.get('fail') == name+':'+a[0]:
        s.pop('fail'); done('simulated failure',1)
if name=='networksetup':
    key='dns' if 'dnsservers' in a[0] else 'bypass'
    if a[0].startswith('-get'):
        done('\n'.join(s[key]) if s[key] else ("There aren't any DNS Servers set on Wi-Fi." if key=='dns' else "There aren't any bypass domains set on Wi-Fi."))
    mutate(); s[key]=[] if a[2:]==['Empty'] else a[2:]; done()
if name=='ifconfig': done(s.get('ifconfig','inet6 2400:abcd::123 prefixlen 64'))
if name=='ipconfig': done(s['dhcp'] if a[0]=='getpacket' else s.get('summary',''))
if name=='scutil': done('nameserver[0] : 1.1.1.1')
if name=='pfctl':
    if '-n' in a: done()
    if a==['-sr']: done(s['main'])
    if a==['-s','info']: done('Status: '+('Enabled' if s['enabled'] else 'Disabled'))
    if a==['-s','References']: done('\n'.join('{} : {}'.format('Token',x) for x in s['refs']))
    if '-sr' in a and '-a' in a: done(s['anchor'])
    mutate()
    if '-f' in a:
        if '-a' not in a: done('GLOBAL PF LOAD FORBIDDEN',99)
        s['anchor']='block udp label "v6only-dns-udp"\nblock tcp label "v6only-dns-tcp"'
    elif '-F' in a:
        if '-a' not in a: done('GLOBAL FLUSH FORBIDDEN',99)
        s['anchor']=''
    elif a==['-E']:
        s['enabled']=True; s['refs'].append('12345'); done('{} : {}'.format('Token','12345'))
    elif a[0]=='-X':
        s['refs'].remove(a[1]); s['enabled']=bool(s['refs'])
    else: done('UNEXPECTED PF MUTATION',99)
    done()
done('UNEXPECTED COMMAND',99)
'''

class MacOSControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base/'bin').mkdir()
        self.state = self.base/'os.json'
        self.initial = dict(dns=['9.9.9.9'], bypass=['localhost', '*.internal'],
                            main='anchor "com.apple/*" all', anchor='',
                            enabled=True, refs=[], calls=[], writes=[],
                            dhcp='router (ip_mult): {10.135.0.1}\ndomain_name_server (ip_mult): {202.112.128.51, 202.112.128.50}')
        self.save(self.initial)
        executable=self.base/'bin/mock'
        executable.write_text(MOCK); executable.chmod(0o755)
        for name in ['networksetup','pfctl','ifconfig','ipconfig','scutil']:
            (self.base/'bin'/name).symlink_to(executable)
        self.env=dict(os.environ, PATH=str(self.base/'bin')+':'+os.environ['PATH'],
                      FAKE_STATE=str(self.state), STATE_DIR=str(self.base/'state'),
                      RUN_DIR=str(self.base/'run'), RESOLVER_DIR=str(self.base/'resolver'),
                      LOG=str(self.base/'watch.log'))
        (self.base/'run').mkdir(); (self.base/'resolver').mkdir()

    def save(self, state): self.state.write_text(json.dumps(state))
    def read(self): return json.loads(self.state.read_text())
    def script(self, body, source='v6ctl.sh', ok=True):
        code=f'source "{ROOT}/macos/{source}"\nrequire_root() {{ :; }}\n'+body
        r=subprocess.run(['/bin/bash','-c',code],env=self.env,text=True,capture_output=True)
        if ok: self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        else: self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        return r
    def on(self,ok=True): return self.script('main on',ok=ok)
    def off(self,mode='manual'): return self.script('main off '+mode)

    def test_repeated_on_and_watcher_do_not_reapply(self):
        self.on(); count=len(self.read()['writes'])
        self.on(); self.script('watch_once; watch_once',source='v6-watch.sh')
        self.assertEqual(len(self.read()['writes']),count)
        self.assertEqual(self.read()['dns'],['202.112.128.50','202.112.128.51','2400:3200::1'])

    def test_rollback_restores_custom_settings_and_resolver(self):
        resolver=self.base/'resolver/gw.buaa.edu.cn'
        resolver.write_text('nameserver 10.1.2.3\n')
        self.on(); self.off()
        self.assertEqual(self.read()['dns'],self.initial['dns'])
        self.assertEqual(self.read()['bypass'],self.initial['bypass'])
        self.assertEqual(resolver.read_text(),'nameserver 10.1.2.3\n')
        self.assertEqual(self.read()['main'],self.initial['main'])
        self.assertTrue(self.read()['enabled'])
        self.assertTrue((self.base/'run/v6only.suspend').read_text().strip().isdigit())

    def test_auto_off_does_not_suspend_reentry(self):
        self.on(); self.off('auto')
        self.assertFalse((self.base/'run/v6only.suspend').exists())
        self.on()
        self.assertTrue((self.base/'run/v6only.active').exists())

    def test_pf_failure_restores_dns_and_bypass(self):
        s=self.read(); s['fail']='pfctl:-a'; self.save(s)
        self.on(ok=False)
        self.assertEqual(self.read()['dns'],self.initial['dns'])
        self.assertEqual(self.read()['bypass'],self.initial['bypass'])
        self.assertFalse((self.base/'run/v6only.active').exists())
        self.assertFalse((self.base/'resolver/gw.buaa.edu.cn').exists())

    def test_legacy_main_rules_refused_without_mutation(self):
        s=self.read(); s['main']='block out inet all'; self.save(s)
        self.on(ok=False)
        self.assertEqual(self.read()['writes'],[])

    def test_resolver_symlink_is_not_followed(self):
        target=self.base/'user-file'; target.write_text('preserve me')
        (self.base/'resolver/gw.buaa.edu.cn').symlink_to(target)
        self.on(ok=False)
        self.assertEqual(target.read_text(),'preserve me')
        self.assertEqual(self.read()['writes'],[])

    def test_dns_write_failure_leaves_original_configuration(self):
        s=self.read(); s['fail']='networksetup:-setdnsservers'; self.save(s)
        self.on(ok=False)
        self.assertEqual(self.read()['dns'],self.initial['dns'])
        self.assertEqual(self.read()['bypass'],self.initial['bypass'])
        self.assertFalse((self.base/'run/v6only.active').exists())

    def test_dhcp_dns_and_empty_bypass_restore(self):
        s=self.read(); s['dns']=[]; s['bypass']=[]; self.save(s)
        self.on(); self.off()
        self.assertEqual(self.read()['dns'],[])
        self.assertEqual(self.read()['bypass'],[])

    def test_user_edits_are_not_overwritten_by_off(self):
        self.on()
        s=self.read(); s['dns']=['1.1.1.1']; s['bypass']=['*.new-setting']; self.save(s)
        self.off()
        self.assertEqual(self.read()['dns'],['1.1.1.1'])
        self.assertEqual(self.read()['bypass'],['*.new-setting'])

    def test_added_bypass_domains_survive_health_checks_and_off(self):
        self.on()
        s=self.read(); s['bypass'].append('*.later'); self.save(s)
        writes=len(self.read()['writes'])
        self.script('watch_once', source='v6-watch.sh')
        self.assertEqual(len(self.read()['writes']),writes)
        self.off()
        self.assertEqual(self.read()['bypass'],self.initial['bypass']+['*.later'])

    def test_campus_detection_does_not_match_generic_private_network(self):
        s=self.read(); s['dhcp']='router (ip_mult): {10.0.0.1}\ndomain_name_server (ip_mult): {10.0.0.1}'; self.save(s)
        self.script('campus',source='v6-common.sh',ok=False)
        s['dhcp']+='\ndomain_name (string): buaa.edu.cn.evil.example'; self.save(s)
        self.script('campus',source='v6-common.sh',ok=False)
        s['dhcp']+='\ndomain_name (string): student.buaa.edu.cn'; self.save(s)
        self.script('campus',source='v6-common.sh')

    def test_secondary_campus_dns_is_recognized(self):
        s=self.read(); s['dhcp']='domain_name_server (ip_mult): {1.1.1.1, 202.112.128.50}'; self.save(s)
        self.script('campus',source='v6-common.sh')

    def test_pause_expiry_and_legacy_empty_pause(self):
        pause=self.base/'run/v6only.suspend'
        pause.write_text('1\n'); self.script('suspended',source='v6-common.sh',ok=False)
        self.assertFalse(pause.exists())
        pause.touch(); self.script('suspended',source='v6-common.sh')

    def test_pf_reference_release_preserves_another_component(self):
        s=self.read(); s['enabled']=False; self.save(s)
        self.on()
        s=self.read(); s['refs'].append('88888'); self.save(s)
        self.off()
        self.assertEqual(self.read()['refs'],['88888'])
        self.assertTrue(self.read()['enabled'])

    def test_missing_anchor_is_repaired_without_losing_original_dns(self):
        self.on(); s=self.read(); s['anchor']=''; self.save(s)
        self.on(); self.off()
        self.assertEqual(self.read()['dns'],self.initial['dns'])

    def test_failed_watcher_attempt_is_backed_off(self):
        fake=self.base/'controller'; fake.mkdir()
        (fake/'v6ctl.sh').write_text('echo attempt >> "$RUN_DIR/attempts"; exit 1\n')
        self.script(f'V6_DIR="{fake}"; watch_once; watch_once',source='v6-watch.sh')
        self.assertEqual((self.base/'run/attempts').read_text().splitlines(),['attempt'])

if __name__ == '__main__': unittest.main()
