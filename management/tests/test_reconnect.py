import os,json,tempfile,subprocess,unittest
from pathlib import Path
FILES=Path(__file__).resolve().parents[2]/'packages/mango-management/files'
MOCK=r'''#!/usr/bin/env python3
import sys,os,json
from pathlib import Path
r=Path(os.environ['FIXTURE']); n=Path(sys.argv[0]).name;a=sys.argv[1:]
if n=='uci':
 k=a[-1];v={'mango_management.main.enabled':'1','mango_management.main.uplink_interface':'wan','network.wgverwaltung.proto':'wireguard','network.wgverwaltung.auto':'1','network.wgverwaltung.tunlink':'wan','network.wgverwaltung_pi.endpoint_host':'example.myfritz.net'}
 if k not in v: sys.exit(1)
 print(v[k])
elif n=='ifstatus':
 if a[0]=='wan': print(json.dumps({'up':os.environ.get('WAN_DOWN')!='1'}))
 else: print(json.dumps({'up':os.environ.get('UP')=='1','pending':os.environ.get('PENDING')=='1','autostart':os.environ.get('ADMIN_DOWN')!='1','errors':[{'code':os.environ.get('ERROR','NO_DEVICE')}]}))
elif n=='jsonfilter':
 d=json.loads(Path(a[a.index('-i')+1]).read_text());k=a[-1][2:]
 if k=='errors[*].code': print(d['errors'][0]['code'])
 else: print(str(d[k]).lower())
elif n=='timeout': os.execvp(a[1],a[1:])
elif n=='nslookup':
 if os.environ.get('DNS_FAIL')=='1': sys.exit(1)
 print('Server: 127.0.0.1\nAddress: 127.0.0.1:53\nName: example.myfritz.net\nAddress: 192.0.2.1')
elif n=='ubus':
 with (r/'actions').open('a') as f:f.write(json.dumps(a)+'\n')
elif n=='logger':pass
else:sys.exit(2)
'''
class Reconnect(unittest.TestCase):
 def run_case(self,**extra):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d);b=p/'bin';b.mkdir();mock=b/'mock';mock.write_text(MOCK);mock.chmod(0o700)
   for n in ['uci','ifstatus','jsonfilter','timeout','nslookup','ubus','logger']:(b/n).symlink_to(mock)
   script=(FILES/'usr/sbin/mango-management-reconnect').read_text().replace('/usr/lib/mango-management/common.sh',str(FILES/'usr/lib/mango-management/common.sh')).replace('/tmp/mango-management-reconnect.lock',str(p/'lock'))
   f=p/'run';f.write_text(script)
   r=subprocess.run(['sh',str(f)],env=dict(os.environ,PATH=str(b)+':'+os.environ['PATH'],FIXTURE=d,**extra),capture_output=True,text=True)
   self.assertEqual(r.returncode,0,r.stderr)
   return (p/'actions').read_text() if (p/'actions').exists() else ''
 def test_no_device_retry_after_dns(self):
  a=self.run_case();self.assertIn('notify_proto',a);self.assertIn('available',a);self.assertEqual(len(a.splitlines()),1)
 def test_healthy_untouched(self):self.assertEqual(self.run_case(UP='1'),'')
 def test_pending_untouched(self):self.assertEqual(self.run_case(PENDING='1'),'')
 def test_admin_down_untouched(self):self.assertEqual(self.run_case(ADMIN_DOWN='1'),'')
 def test_dns_failure_untouched(self):self.assertEqual(self.run_case(DNS_FAIL='1'),'')
 def test_wan_down_untouched(self):self.assertEqual(self.run_case(WAN_DOWN='1'),'')
 def test_other_error_untouched(self):self.assertEqual(self.run_case(ERROR='OTHER'),'')
if __name__=='__main__':unittest.main()
