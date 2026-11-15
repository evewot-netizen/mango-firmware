import json, os, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
FILES=ROOT/'packages/mango-management/files'
MOCK=r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root=Path(os.environ['FIXTURE']); name=Path(sys.argv[0]).name; args=sys.argv[1:]
p=root/'uci.json'; db=json.loads(p.read_text())
if name=='uci':
 if args and args[0]=='-q': args=args[1:]
 op=args[0]
 if op=='get':
  if args[1] not in db: sys.exit(1)
  print(db[args[1]])
 elif op=='changes': pass
 elif op=='add_list':
  k,v=args[1].split('=',1); db[k]+=' '+v; p.write_text(json.dumps(db))
 elif op=='set':
  k,v=args[1].split('=',1); db[k]=v; p.write_text(json.dumps(db))
 elif op=='batch':
  import shlex
  for line in sys.stdin:
   parts=shlex.split(line); k,v=parts[1].split('=',1)
   db[k]=v if parts[0]=='set' else (db.get(k,'')+' '+v).strip()
  p.write_text(json.dumps(db))
 elif op in ['commit','revert']: pass
 else: sys.exit(20)
elif name=='ifstatus': print('{}')
elif name=='jsonfilter': print('true' if args[-1]=='@.up' else 'phy1-sta0')
elif name=='ip':
 if 'dev' not in args or args[-1]!='phy1-sta0': sys.exit(21)
 print('default via 192.168.99.1 dev phy1-sta0' if '-4' in args else 'default via fe80::1234 dev phy1-sta0')
elif name=='nslookup':
 (root/'dns-target').write_text(args[-1])
 if os.environ.get('DNS_FAIL'): sys.exit(1)
 print('Server: '+args[-1]+'\nAddress: '+args[-1]+':53\n\nName: fritz.box\nAddress: 192.168.99.1\nName: fritz.box\nAddress: fd99::1')
elif name=='timeout': os.execvp(args[1],args[1:])
elif name=='wg': print('A'*43+'=')
elif name=='logger': pass
elif name=='firewall':
 with (root/'reloads').open('a') as f: f.write('reload\n')
else: sys.exit(22)
'''
class MobileManagement(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
  self.d=pathlib.Path(self.tmp.name); (self.d/'bin').mkdir()
  script=self.d/'bin/mock'; script.write_text(MOCK); script.chmod(0o700)
  for n in ['uci','ip','jsonfilter','ifstatus','nslookup','timeout','logger','firewall','wg']:
   (self.d/'bin'/n).symlink_to(script)
  self.env=dict(os.environ, FIXTURE=str(self.d), PATH=str(self.d/'bin')+':'+os.environ['PATH'])
  self.db={
   'mango_management.main.enabled':'1','mango_management.main.uplink_interface':'wan',
   'mango_management.main.uplink_zone':'wan','mango_management.main.gateway_dns_name':'fritz.box',
   'mango_management.main.endpoint_host':'example.myfritz.net','mango_management.main.endpoint_port':'51820',
   'mango_management.main.server_public_key':'A'*43+'=',
   'mango_management.main.tunnel_address':'172.27.66.3','mango_management.main.server_address':'172.27.66.1',
   'mango_management.main.gateway_ipv4':'192.168.178.1','mango_management.main.gateway_ipv6':'fe80::old',
   'mango_management.main.monitor_public_key':'ssh-ed25519 AAAA test',
   'firewall.wgverwaltung.name':'wgmgmt','firewall.wgverwaltung.input':'DROP',
   'firewall.wgverwaltung.forward':'DROP','firewall.wgverwaltung.network':'wgverwaltung'}
  self.db['mango_management.main.gateway_ipv6']='fe80::1'
  for family in [4,6]:
   pre=f'firewall.mango_fritz_v{family}.'
   self.db.update({pre+'target':'REJECT',pre+'dest':'wan',pre+'proto':'tcp',pre+'dest_port':'80 443 49000 49443',pre+'dest_ip':'192.168.178.1 169.254.1.1' if family==4 else 'fe80::1 fd01::1'})
  (self.d/'key').write_text('private-test-only')
  (self.d/'firewall-config').write_text('previous')
  for name in ['common.sh','render.sh']:
   (self.d/name).write_text((FILES/'usr/lib/mango-management'/name).read_text())
  self.save()
 def save(self): (self.d/'uci.json').write_text(json.dumps(self.db))
 def run_script(self,name,extra=None):
  s=(FILES/'usr/sbin'/name).read_text()
  s=s.replace('/usr/lib/mango-management/',str(self.d)+'/')
  s=s.replace('/tmp/mango-management-refresh.lock',str(self.d/'lock'))
  s=s.replace('/tmp/mango-management-last-check',str(self.d/'last-check'))
  s=s.replace('/etc/config/firewall',str(self.d/'firewall-config'))
  s=s.replace('/etc/init.d/firewall',str(self.d/'bin/firewall'))
  s=s.replace('/etc/wireguard/mango-management.key',str(self.d/'key'))
  f=self.d/'run'; f.write_text(s)
  result=subprocess.run(['sh',str(f)],env=dict(self.env,**(extra or {})),capture_output=True,text=True)
  self.db=json.loads((self.d/'uci.json').read_text()); return result
 def test_site_change_adds_gateway_linklocal_dns_and_keeps_old(self):
  r=self.run_script('mango-management-refresh'); self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual((self.d/'dns-target').read_text(),'192.168.99.1')
  self.assertIn('192.168.99.1',self.db['firewall.mango_fritz_v4.dest_ip'])
  self.assertIn('192.168.178.1',self.db['firewall.mango_fritz_v4.dest_ip'])
  for a in ['fe80::1234','fd99::1','fd01::1']: self.assertIn(a,self.db['firewall.mango_fritz_v6.dest_ip'])
  before=(self.d/'reloads').read_text()
  r=self.run_script('mango-management-refresh'); self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(before,(self.d/'reloads').read_text())
 def test_dns_failure_still_blocks_new_gateway(self):
  r=self.run_script('mango-management-refresh',{'DNS_FAIL':'1'}); self.assertNotEqual(r.returncode,0)
  self.assertIn('192.168.99.1',self.db['firewall.mango_fritz_v4.dest_ip'])
  self.assertIn('fe80::1234',self.db['firewall.mango_fritz_v6.dest_ip'])
  self.assertFalse((self.d/'last-check').exists())
 def test_modified_rule_refuses_changes(self):
  self.db['firewall.mango_fritz_v4.target']='ACCEPT'; self.save(); before=dict(self.db)
  r=self.run_script('mango-management-refresh'); self.assertNotEqual(r.returncode,0); self.assertEqual(self.db,before)
 def test_restore_after_network_reset_and_repeat(self):
  r=self.run_script('mango-management-restore'); self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(self.db['network.wgverwaltung.addresses'],'172.27.66.3/32')
  self.assertEqual(self.db['network.wgverwaltung.tunlink'],'wan')
  self.assertEqual(self.db['network.wgverwaltung_pi.allowed_ips'],'172.27.66.1/32')
  before=dict(self.db); r=self.run_script('mango-management-restore')
  self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(before,self.db)
 def test_restore_refuses_partial_or_foreign_network(self):
  self.db['network.wgverwaltung']='interface'; self.db['network.wgverwaltung.proto']='static'; self.save()
  before=dict(self.db); r=self.run_script('mango-management-restore')
  self.assertNotEqual(r.returncode,0); self.assertEqual(before,self.db)
if __name__=='__main__': unittest.main()
