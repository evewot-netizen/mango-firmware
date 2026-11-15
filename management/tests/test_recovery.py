import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOOT = '89f96f09-fb52-4881-ae04-37a186065674'
IMAGE = 'd71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c'


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.configdir = self.base / 'config'
        self.state = self.configdir / 'freifunk/update-status/mango-zuhause.json'
        self.state.parent.mkdir(parents=True)
        self.old = dict(phase='ERROR', old_boot=BOOT,
                        old_version='2025.1-halle1-mango-test6',
                        target_version='2025.1-halle1-mango-test7',
                        image_sha=IMAGE, backup_path='old-backup', backup_sha='a'*64)
        self.state.write_text(json.dumps(self.old))
        config = self.configdir / 'freifunk/mango-update-controller.json'
        config.write_text(json.dumps(dict(installation_enabled=True, state_file=str(self.state))))
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.header = self.base / 'header'
        self.header.write_text(f'STATE=READY\nVERSION=2025.1-halle1-mango-test6\nBOOT_ID={BOOT}\nSHA256={IMAGE}\nINSTALL_ENABLED=1\n')
        ssh = self.bin / 'ssh'
        ssh.write_text('#!/bin/sh\ncat "$TEST_HEADER"\n')
        ssh.chmod(0o700)
        self.script = self.base / 'recover.sh'
        self.script.write_text((ROOT/'recover-pi-lockfix.sh').read_text().replace('/config/', str(self.configdir)+'/'))

    def run_recovery(self):
        return subprocess.run(['sh', str(self.script)], capture_output=True, text=True,
                              env=dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'],
                                       TEST_HEADER=str(self.header)))

    def test_ready_recovery_requires_new_backup(self):
        result = self.run_recovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(set(state), {'phase', 'started'})
        self.assertEqual(state['phase'], 'CHECKING')
        saved = list((self.configdir/'freifunk').glob('vor-update-wiederaufnahme.*/state.json'))
        self.assertEqual(len(saved), 1)
        self.assertEqual(json.loads(saved[0].read_text()), self.old)

    def test_changed_boot_blocks_recovery(self):
        self.header.write_text(self.header.read_text().replace(BOOT, 'new-boot'))
        self.assertNotEqual(self.run_recovery().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.old)

    def test_router_installing_blocks_recovery(self):
        self.header.write_text(self.header.read_text().replace('STATE=READY', 'STATE=INSTALLING'))
        self.assertNotEqual(self.run_recovery().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.old)

    def test_changed_image_blocks_recovery(self):
        self.header.write_text(self.header.read_text().replace(IMAGE, 'b'*64))
        self.assertNotEqual(self.run_recovery().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.old)

    def test_active_controller_lock_blocks_recovery(self):
        with self.state.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.run_recovery().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.old)

    def test_second_recovery_cannot_restart_active_run(self):
        self.assertEqual(self.run_recovery().returncode, 0)
        before = self.state.read_text()
        self.assertNotEqual(self.run_recovery().returncode, 0)
        self.assertEqual(self.state.read_text(), before)


if __name__ == '__main__':
    unittest.main()
