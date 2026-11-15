import importlib.util, io, json, pathlib, tarfile, unittest
import test_controller
spec=importlib.util.spec_from_file_location('fleet_engine',pathlib.Path(__file__).resolve().parents[1]/'pi/mango_fleet_engine.py');engine=importlib.util.module_from_spec(spec);spec.loader.exec_module(engine)
class FleetEngine(test_controller.ControllerTests):
 def setUp(self):
  super().setUp()
  # Run all established controller tests against the fleet engine too.
  self.c.__class__=engine.Controller
  self.c.prefix='mango-zuhause';self.c.required=set(engine.REQUIRED)
 def test_router02_required_files_and_filename(self):
  self.make_tar();self.c.prefix='mango-02'
  self.c.required=set(engine.REQUIRED)|{'etc/config/mango_management'}
  with self.assertRaisesRegex(RuntimeError,'mango_management'):self.c.backup()
  self.c.required=set(engine.REQUIRED)
  path,_=self.c.backup();self.assertTrue(pathlib.Path(path).name.startswith('mango-02-'))
 def test_pinned_offer_rejects_changed_image_hash(self):
  import sys
  sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'pi'))
  spec=importlib.util.spec_from_file_location('f',pathlib.Path(__file__).resolve().parents[1]/'pi/mango-fleet.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
  cfg={'router_id':'mango-02','state_file':str(self.base/'two.json')}
  fleet=f.Fleet({'state_file':str(self.base/'fleet.json'),'routers':[cfg]});fleet.s['offer']={'sha256':'a'*64,'version':'test8'}
  with self.assertRaisesRegex(RuntimeError,'geaendert'):fleet.controller(0).target_version('b'*64)
if __name__=='__main__':unittest.main()
