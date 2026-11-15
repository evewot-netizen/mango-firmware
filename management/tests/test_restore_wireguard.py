import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = 'SmviIyXKGp6LeiQe7xE4aTZNBF6xRz7iXK3LNMedUD0='


class RestoreWireGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base/'bin';self.bin.mkdir()
        self.db = self.base/'db.json'
        self.initial = {'network.wan':'interface', 'network.wan.proto':'dhcp',
                        'network.mesh_vpn':'interface', 'network.mesh_vpn.mtu':'1312'}
        self.db.write_text(json.dumps(self.initial))
        self.key = self.base/'private.key';self.key.write_text('TEST-PRIVATE-KEY\n')
        (self.base/'wireguard.sh').touch()
        (self.base/'network').touch()
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'],
                        DB=str(self.db), PUBLIC=PUBLIC)
        uci = self.bin/'uci'
        uci.write_text('''#!/usr/bin/env python3
import json, os, shlex, sys
p=os.environ['DB'];s=json.load(open(p));args=sys.argv[1:]
if args[0]=='-q':args=args[1:]
if args[0]=='get':
    if args[1] not in s:sys.exit(1)
    print(s[args[1]]);sys.exit(0)
commands=[shlex.split(line) for line in sys.stdin if line.strip()] if args[0]=='batch' else [args]
for command in commands:
    if command[0] in ('set','add_list'):
        k,v=command[1].split('=',1)
        s[k]=(s.get(k,'')+' '+v).strip() if command[0]=='add_list' else v
    elif command[0]!='commit':sys.exit(2)
json.dump(s,open(p,'w'))
''')
        uci.chmod(0o700)
        wg = self.bin/'wg';wg.write_text('#!/bin/sh\ncat >/dev/null\nprintf "%s\\n" "$PUBLIC"\n');wg.chmod(0o700)
        code = (ROOT/'router/restore-home-wireguard.sh').read_text()
        for old,new in {
            '/etc/wireguard/mango-management.key':str(self.key),
            '/lib/netifd/proto/wireguard.sh':str(self.base/'wireguard.sh'),
            '/etc/config/network':str(self.base/'network'),
        }.items():code=code.replace(old,new)
        self.script=self.base/'restore.sh';self.script.write_text(code)

    def run_restore(self):
        return subprocess.run(['sh',str(self.script)],env=self.env,capture_output=True,text=True)

    def test_restore_after_reset_keeps_uplink_and_mesh(self):
        r=self.run_restore();self.assertEqual(r.returncode,0,r.stderr)
        state=json.loads(self.db.read_text())
        for k,v in self.initial.items():self.assertEqual(state[k],v)
        self.assertEqual(state['network.wgverwaltung.tunlink'],'wan')
        self.assertEqual(state['network.wgverwaltung.private_key'],'TEST-PRIVATE-KEY')
        self.assertEqual(state['network.wgverwaltung_pi.allowed_ips'],'172.27.66.1/32')
        self.assertNotIn('TEST-PRIVATE-KEY',r.stdout+r.stderr)

    def test_second_run_does_not_duplicate_addresses(self):
        self.assertEqual(self.run_restore().returncode,0)
        before=self.db.read_text()
        self.assertEqual(self.run_restore().returncode,0)
        self.assertEqual(self.db.read_text(),before)

    def test_another_router_key_cannot_be_enrolled(self):
        self.env['PUBLIC']='other-router'
        self.assertNotEqual(self.run_restore().returncode,0)
        self.assertEqual(json.loads(self.db.read_text()),self.initial)

    def test_missing_key_does_not_create_network(self):
        self.key.unlink()
        self.assertNotEqual(self.run_restore().returncode,0)
        self.assertEqual(json.loads(self.db.read_text()),self.initial)

    def test_partial_existing_network_is_not_overwritten(self):
        partial=dict(self.initial,**{'network.wgverwaltung':'interface'})
        self.db.write_text(json.dumps(partial))
        self.assertNotEqual(self.run_restore().returncode,0)
        self.assertEqual(json.loads(self.db.read_text()),partial)

    def test_changed_existing_endpoint_is_not_overwritten(self):
        self.assertEqual(self.run_restore().returncode,0)
        state=json.loads(self.db.read_text());state['network.wgverwaltung_pi.endpoint_host']='192.0.2.1'
        self.db.write_text(json.dumps(state))
        self.assertNotEqual(self.run_restore().returncode,0)
        self.assertEqual(json.loads(self.db.read_text()),state)


if __name__=='__main__':unittest.main()
