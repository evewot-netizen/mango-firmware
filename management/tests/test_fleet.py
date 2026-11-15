import importlib.util, json, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock, patch
from datetime import datetime
from zoneinfo import ZoneInfo
PI=Path(__file__).resolve().parents[1]/'pi'
sys.path.insert(0,str(PI))
spec=importlib.util.spec_from_file_location('fleet',PI/'mango-fleet.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class FleetTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);d=Path(self.tmp.name)
  self.f=m.Fleet({'state_file':str(d/'fleet.json'),'routers':[{'router_id':'mango-zuhause','state_file':str(d/'one.json')},{'router_id':'mango-02','state_file':str(d/'two.json')}]})
  self.cs=[Mock(),Mock()]
  for c in self.cs:
   c.s={'phase':'SUCCESS'};c.job.return_value={'STATE':'IDLE','VERSION':'2025.1-test7','INSTALL_ENABLED':'1'}
   c.ssh.side_effect=lambda command,**kwargs: {'health':'HEALTH=OK','vpn':'Verbunden','details':'Aktiv\n0/1'}[command]
  self.f.controller=lambda i:self.cs[i]
  self.f.fetch_offer=Mock(return_value={'version':'2025.1-test8','sha256':'a'*64})
  now=Mock();now.now.return_value=datetime(2026,11,15,21,0,tzinfo=ZoneInfo('Europe/Berlin'))
  self.clock=patch.object(m,'datetime',now);self.clock.start();self.addCleanup(self.clock.stop)
 def test_single_daily_offer_and_no_refetch_ticks(self):
  self.f.start();self.f.start();self.f.fetch_offer.assert_called_once()
  self.cs[0].execute.return_value={'phase':'CHECKING'};self.f.tick();self.f.tick();self.f.fetch_offer.assert_called_once()
 def test_serial_waits_for_success(self):
  self.f.start();self.cs[0].execute.return_value={'phase':'CHECKING'};self.f.tick()
  self.f.tick();self.cs[1].job.assert_not_called()
  self.cs[0].execute.return_value={'phase':'SUCCESS'};self.f.tick();self.cs[1].job.assert_not_called()
  self.cs[1].execute.return_value={'phase':'CHECKING'};self.f.tick();self.cs[1].job.assert_called_once()
 def test_error_stops_second_router_and_next_day(self):
  self.f.start();self.cs[0].execute.return_value={'phase':'ERROR','message':'Backup fehlt'}
  self.assertEqual(self.f.execute('tick')['phase'],'ERROR');self.f.execute('tick');self.f.execute('start');self.cs[1].job.assert_not_called();self.f.fetch_offer.assert_called_once()
 def test_same_version_no_prepare_no_backup(self):
  self.f.fetch_offer.return_value['version']='2025.1-test7';self.f.start()
  for _ in range(4):self.f.tick()
  self.assertEqual(self.f.s['phase'],'SUCCESS')
  for c in self.cs:c.execute.assert_not_called();c.backup.assert_not_called()
  self.f.start();self.f.fetch_offer.assert_called_once()
 def test_downgrade_refused(self):
  self.f.fetch_offer.return_value['version']='2025.1-test6';self.f.start()
  self.assertEqual(self.f.execute('tick')['phase'],'ERROR');self.cs[0].execute.assert_not_called()
 def test_offer_failure_not_retried(self):
  self.f.fetch_offer.side_effect=RuntimeError('offline');self.assertEqual(self.f.execute('start')['phase'],'ERROR');self.f.execute('start');self.f.fetch_offer.assert_called_once()
 def test_resume_without_new_offer(self):
  self.f.start();self.f.s['stage']='ACTIVE';self.f.save()
  new=m.Fleet(self.f.c);new.controller=lambda i:self.cs[i];new.fetch_offer=Mock(side_effect=AssertionError('refetch'))
  self.cs[0].execute.return_value={'phase':'INSTALLING'};self.assertEqual(new.execute('tick')['phase'],'RUNNING');new.fetch_offer.assert_not_called()
 def test_interrupted_start_not_reissued(self):
  self.f.start();self.f.s.update(stage='STARTING',router_started=100);self.cs[0].s={'phase':'SUCCESS','started':50}
  self.assertEqual(self.f.execute('tick')['phase'],'ERROR');self.cs[0].execute.assert_not_called()
 def test_interrupted_offer_not_reissued(self):
  self.f.start();self.f.s['stage']='OFFER';self.assertEqual(self.f.execute('tick')['phase'],'ERROR');self.f.fetch_offer.assert_called_once()
 def test_idle_tick_no_network(self):
  self.f.tick();self.f.fetch_offer.assert_not_called();self.cs[0].job.assert_not_called()
if __name__=='__main__':unittest.main()
