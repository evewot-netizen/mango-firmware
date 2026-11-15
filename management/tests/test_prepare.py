import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.state = self.base / 'state'
        self.state.mkdir()
        self.locks = self.base / 'locks'
        self.locks.mkdir()
        self.version = self.base / 'version'
        self.version.write_text('test6\n')
        self.image = self.base / 'firmware.bin'
        self.env = dict(os.environ, RESULT='none', ENABLED='0', TEST_IMAGE=str(self.image))
        self.uci = self.base / 'uci'
        self.uci.write_text('''#!/bin/sh
case "$3" in
 autoupdater.settings.enabled) echo "${ENABLED:-0}";;
 autoupdater.settings.branch) echo mango;;
 autoupdater.mango.good_signatures) echo 1;;
 autoupdater.mango.mirror) echo 'https://evewot-netizen.github.io/mango-firmware/updates/';;
 *) exit 1;;
esac
''')
        self.uci.chmod(0o700)
        self.updater = self.base / 'updater'
        self.updater.write_text('''#!/bin/sh
printf '%s\\n' "$*" > "$TEST_IMAGE.args"
case "$RESULT" in
 none) echo 'No new firmware available.';;
 ready) printf 'signed-image' > "$TEST_IMAGE"; echo 'autoupdater: info: Aborting successful upgrade because simulation was requested.';;
 missing) echo 'autoupdater: info: Aborting successful upgrade because simulation was requested.';;
 ambiguous) echo 'No new firmware available.'; echo 'autoupdater: info: Aborting successful upgrade because simulation was requested.';;
 error) echo 'verification failed'; exit 1;;
 *) echo 'unexpected output';;
esac
''')
        self.updater.chmod(0o700)

    def run_script(self, name, command=''):
        source = (ROOT / 'router' / name).read_text()
        replacements = {
            '/tmp/mango-ha-update-job': str(self.state),
            '/var/lock': str(self.locks),
            '/tmp/firmware.bin': str(self.image),
            '/lib/gluon/release': str(self.version),
            '/usr/sbin/autoupdater': str(self.updater),
            'uci -q': f'{self.uci} -q',
        }
        for a, b in replacements.items():
            source = source.replace(a, b)
        script = self.base / name
        script.write_text(source)
        return subprocess.run(['sh', str(script)], capture_output=True, text=True,
                              env=dict(self.env, SSH_ORIGINAL_COMMAND=command))

    def test_no_update_creates_no_candidate(self):
        r=self.run_script('worker.sh')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.state/'state').read_text().strip(),'NO_UPDATE')
        self.assertFalse((self.state/'firmware.bin').exists())
        self.assertIn('--no-action',Path(str(self.image)+'.args').read_text())

    def test_verified_candidate_is_moved_and_hashed(self):
        self.env['RESULT']='ready'
        r=self.run_script('worker.sh')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.state/'state').read_text().strip(),'READY')
        self.assertEqual((self.state/'sha256').read_text().strip(),hashlib.sha256(b'signed-image').hexdigest())
        self.assertFalse(self.image.exists())
        self.assertEqual((self.state/'old-version').read_text(),'test6\n')

    def test_failure_and_unknown_outputs_fail_closed(self):
        for result in ['error','missing','ambiguous','other']:
            with self.subTest(result=result):
                self.env['RESULT']=result
                r=self.run_script('worker.sh')
                self.assertNotEqual(r.returncode,0)
                self.assertEqual((self.state/'state').read_text().strip(),'ERROR')
                self.assertFalse((self.state/'sha256').exists())

    def test_existing_manual_image_is_not_overwritten(self):
        self.image.write_bytes(b'manual')
        r=self.run_script('worker.sh')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.image.read_bytes(),b'manual')
        self.assertFalse(Path(str(self.image)+'.args').exists())

    def test_enabled_autoupdater_blocks_preparation(self):
        self.env['ENABLED']='1'
        r=self.run_script('worker.sh')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(Path(str(self.image)+'.args').exists())

    def test_install_and_arbitrary_commands_are_rejected(self):
        for command in ['install','install '+'a'*64,'reboot','prepare; reboot','']:
            r=self.run_script('dispatch.sh',command)
            self.assertNotEqual(r.returncode,0)

    def test_ready_job_is_retained(self):
        (self.state/'state').write_text('READY\n')
        r=self.run_script('dispatch.sh','prepare')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('STATE=READY',r.stdout)

    def test_job_without_state_reports_idle(self):
        r=self.run_script('dispatch.sh','job')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('STATE=IDLE',r.stdout)

    def test_legacy_check_cannot_overwrite_ready_job(self):
        (self.state/'state').write_text('READY\n')
        r=self.run_script('dispatch.sh','check')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(Path(str(self.image)+'.args').exists())

    def test_shell_syntax(self):
        for p in [*(ROOT/'router').iterdir(),ROOT/'install-router-prepare.sh']:
            r=subprocess.run(['sh','-n',str(p)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,f'{p}: {r.stderr}')

if __name__ == '__main__':
    unittest.main()
