import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / 'packages/mango-management/files'
COMMON = FILES / 'usr/lib/mango-management/common.sh'
RENDER = FILES / 'usr/lib/mango-management/render.sh'

class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        STATE=str(self.work / 'state.json'), CALLS=str(self.work / 'calls'))
        self.state = {
            'mango_management.main.endpoint_host': 'vpn.example.net',
            'mango_management.main.server_public_key': 'A'*43+'=',
            'mango_management.main.tunnel_address': '172.27.66.3',
            'mango_management.main.server_address': '172.27.66.1',
            'mango_management.main.gateway_ipv4': '192.168.50.1',
            'mango_management.main.gateway_ipv6': 'fe80::1 fd12:3456::1',
            'mango_management.main.uplink_zone': 'wan',
            'mango_management.main.uplink_interface': 'wan',
            'mango_management.main.endpoint_port': '51820',
            'mango_management.main.monitor_public_key': 'ssh-ed25519 '+ 'A'*68 + ' test',
            'mango_management.main.enabled': '1',
            'mango_management.main.gateway_dns_name': 'fritz.box',
            'firewall.mango_fritz_v6.target': 'REJECT',
            'firewall.mango_fritz_v6.dest_ip': 'fe80::1 fd12:3456::1',
        }
        for family in (4, 6):
            prefix = f'firewall.mango_fritz_v{family}.'
            self.state.update({prefix+'target': 'REJECT', prefix+'dest': 'wan',
                               prefix+'proto': 'tcp', prefix+'dest_port': '80 443 49000 49443'})
        self.state['firewall.mango_fritz_v4.dest_ip'] = '192.168.50.1 169.254.1.1'
        self.tool('ifstatus', '#!/bin/sh\nprintf "{}\\n"\n')
        self.tool('jsonfilter', '#!/bin/sh\ncase "$*" in *"@.up"*) echo true;; *) echo phy1-sta0;; esac\n')
        self.tool('ip', '#!/bin/sh\ncase "$*" in "-4 route show default dev phy1-sta0") echo "default via 192.168.50.1 dev phy1-sta0";; "-6 route show default dev phy1-sta0") echo "default via fe80::1 dev phy1-sta0";; *) exit 1;; esac\n')
        self.write_state()
        self.tool('uci' , '''#!/usr/bin/env python3
import json,os,sys
s=json.load(open(os.environ['STATE']))
a=sys.argv[1:]
if a and a[0]=='-q': a=a[1:]
if a[0]=='get':
    if a[1] not in s: sys.exit(1)
    print(s[a[1]])
elif a[0]=='changes': print(s.get('changes',''),end='')
else:
    with open(os.environ['CALLS'],'a') as f: f.write(' '.join(a)+'\\n')
''')
        self.tool('logger', '#!/bin/sh\nprintf "%s\\n" "$*" >&2\n')

    def write_state(self):
        Path(self.env['STATE']).write_text(json.dumps(self.state))

    def tool(self, name, body):
        p=self.bin/name; p.write_text(body); p.chmod(0o755)

    def shell(self, code):
        return subprocess.run(['sh','-c',code], env=self.env, text=True, capture_output=True)

    def render(self):
        self.write_state()
        return self.shell(f'. "{COMMON}"; . "{RENDER}"; validate_profile; render_network; render_firewall')

    def test_shell_syntax(self):
        for p in FILES.rglob('*'):
            if p.is_file() and (p.suffix=='.sh' or p.parent.name in ('sbin','iface','upgrade')):
                result=subprocess.run(['sh','-n',str(p)],capture_output=True,text=True)
                self.assertEqual(result.returncode,0, f'{p}: {result.stderr}')

    def test_disabled_by_default_and_no_key_in_firmware(self):
        self.assertIn("option enabled '0'",(FILES/'etc/config/mango_management').read_text())
        self.assertFalse(list(FILES.rglob('*.key')))
        self.assertIn('GLUON_AUTOUPDATER_ENABLED=0',(ROOT/'sources.env').read_text())

    def test_generated_rules_are_narrow_and_location_specific(self):
        r=self.render(); self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("allowed_ips='172.27.66.1/32'",r.stdout)
        self.assertIn("addresses='172.27.66.3/32'",r.stdout)
        self.assertIn('firewall.wgverwaltung.forward=DROP',r.stdout)
        self.assertIn('firewall.wgverwaltung.input=DROP',r.stdout)
        self.assertIn("firewall.mango_fritz_v4.dest_ip='192.168.50.1'",r.stdout)
        self.assertNotIn('192.168.178.',r.stdout)
        self.assertNotIn('0.0.0.0/0',r.stdout)
        self.assertNotIn('private_key',r.stdout)
        self.assertNotIn('firewall.mango_fritz_v4.src',r.stdout)
        self.assertNotIn('=forwarding',r.stdout)

    def test_endpoint_route_uses_configured_uplink(self):
        for uplink in ['wan', 'private_uplink']:
            self.state['mango_management.main.uplink_interface'] = uplink
            result = self.render()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"set network.wgverwaltung.tunlink='{uplink}'", result.stdout)

    def test_bad_profiles_produce_no_batch(self):
        for field,value in [('endpoint_host',"vpn.example.net'; reboot"),
                            ('gateway_ipv4','999.2.3.4'),
                            ('gateway_ipv6',':::'),
                            ('gateway_ipv6','1::2:3:4:5:6:7:8'),
                            ('uplink_zone',"wan\nset firewall.x=forwarding"),
                            ('uplink_interface',"wan'; reboot"),
                            ('uplink_interface',''),
                            ('endpoint_port','65536'),
                            ('server_public_key','bad'),
                            ('monitor_public_key','ssh-ed25519 AAA\nssh-ed25519 BBB'),
                            ('tunnel_address','172.27.66.1')]:
            key='mango_management.main.'+field
            old=self.state[key];self.state[key]=value
            r=self.render()
            self.assertNotEqual(r.returncode,0,field)
            self.assertEqual(r.stdout,'',field)
            self.state[key]=old

    def refresh(self,dns,fail=False):
        self.write_state()
        (self.work/'dns').write_text(dns)
        self.tool('nslookup',f'#!/bin/sh\ncat "{self.work}/dns"\nexit {1 if fail else 0}\n')
        script=(FILES/'usr/sbin/mango-management-refresh').read_text()
        script=script.replace('/usr/lib/mango-management/common.sh',str(COMMON))
        script=script.replace('/tmp/mango-management-refresh.lock',str(self.work/'lock'))
        script=script.replace('/tmp/mango-management-last-check',str(self.work/'last-check'))
        (self.work/'firewall').write_text('original firewall')
        script=script.replace('/etc/config/firewall',str(self.work/'firewall'))
        self.tool('reload', '#!/bin/sh\nprintf "reload\\n" >> "$CALLS"\nexit "${RELOAD_FAIL:-0}"\n')
        script=script.replace('/etc/init.d/firewall',str(self.bin/'reload'))
        (self.work/'refresh').write_text(script)
        return self.shell(f'sh "{self.work}/refresh"')

    def test_dns_failure_preserves_rules(self):
        r=self.refresh('connection timed out',fail=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/'calls').exists())
        self.assertFalse((self.work/'lock').exists())

    def test_dns_empty_preserves_rules(self):
        r=self.refresh('Server: 192.168.50.1\nAddress: 192.168.50.1:53\n')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/'calls').exists())

    def test_unchanged_dns_does_not_write_flash(self):
        r=self.refresh('Server: 192.168.50.1\nAddress: 192.168.50.1:53\n\nName: fritz.box\nAddress: fd12:3456::1\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.work/'calls').exists())
        self.assertTrue((self.work/'last-check').exists())

    def test_new_prefix_is_added_without_removing_old_addresses(self):
        r=self.refresh('Name: fritz.box\nAddress: 2001:db8::1\n')
        self.assertEqual(r.returncode,0,r.stderr)
        calls=(self.work/'calls').read_text()
        self.assertIn('add_list firewall.mango_fritz_v6.dest_ip=2001:db8::1',calls)
        self.assertIn('commit firewall',calls)
        self.assertEqual(calls.count('reload'),1)
        self.assertNotIn('delete',calls)
        self.assertTrue((self.work/'last-check').exists())

    def test_reload_failure_restores_config_and_reports_failure(self):
        self.env['RELOAD_FAIL']='1'
        r=self.refresh('Name: fritz.box\nAddress: 2001:db8::1\n')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.work/'firewall').read_text(),'original firewall')
        self.assertFalse((self.work/'last-check').exists())
        self.assertFalse((self.work/'lock').exists())

    def test_pending_firewall_edits_are_not_committed(self):
        self.state['changes']='firewall.other.enabled=1\n'
        r=self.refresh('')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/'calls').exists())

    def test_disabled_refresh_does_nothing(self):
        self.state['mango_management.main.enabled']='0'
        r=self.refresh('')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.work/'last-check').exists())
        self.assertFalse((self.work/'calls').exists())

    def test_monitor_rejects_arbitrary_commands(self):
        for command in ['reboot', 'vpn; reboot', 'details && cat /etc/shadow', 'backup']:
            r=subprocess.run(['sh',str(FILES/'usr/sbin/mango-management-monitor')],
                             env=dict(self.env,SSH_ORIGINAL_COMMAND=command),text=True,capture_output=True)
            self.assertNotEqual(r.returncode,0)
            self.assertEqual(r.stdout,'')

if __name__=='__main__': unittest.main()
