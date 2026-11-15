import json, subprocess, unittest
import test_mobile_management as mobile

class HomeGuard(mobile.MobileManagement):
 def run_script(self,name,extra=None):
  if name != 'mango-management-refresh':
   return super().run_script(name,extra)
  s=(mobile.ROOT/'management/router/fritz-addresses.sh').read_text()
  s=s.replace('/tmp/mango-fritz-adressen.lock',str(self.d/'lock'))
  s=s.replace('/tmp/mango-fritz-last-check',str(self.d/'last-check'))
  s=s.replace('/etc/config/firewall',str(self.d/'firewall-config'))
  s=s.replace('/etc/init.d/firewall',str(self.d/'bin/firewall'))
  f=self.d/'run'; f.write_text(s)
  result=subprocess.run(['sh',str(f)],env=dict(self.env,**(extra or {})),capture_output=True,text=True)
  self.db=json.loads((self.d/'uci.json').read_text()); return result
 def test_does_not_require_new_enrollment_profile(self):
  self.db={k:v for k,v in self.db.items() if not k.startswith('mango_management.')}; self.save()
  r=self.run_script('mango-management-refresh'); self.assertEqual(r.returncode,0,r.stderr)
 def test_dns_has_deadline(self):
  s=(mobile.ROOT/'management/router/fritz-addresses.sh').read_text()
  self.assertIn('timeout 15 nslookup',s)

if __name__=='__main__': unittest.main()
