import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name)
        self.state=self.base/'state';self.state.mkdir()
        (self.base/'locks').mkdir()
        self.bin=self.base/'bin';self.bin.mkdir()
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],CALLS=str(self.base/'calls'))
        self.hash=hashlib.sha256(b'signed-image').hexdigest()
        for name,value in {'state':'INSTALL_QUEUED','firmware.bin':'signed-image','sha256':self.hash,'request-image-sha256':self.hash,'request-backup-sha256':'b'*64,'old-version':'test6','prepared-at':str(int(time.time()))}.items():
            (self.state/name).write_text(value)
        (self.base/'version').write_text('test6')
        (self.base/'enabled').write_text('enabled')
        self.tool('uci','''case "$3" in
 autoupdater.settings.enabled) echo 0;;
 autoupdater.settings.branch) echo mango;;
 autoupdater.mango.good_signatures) echo 1;;
esac
''')
        self.tool('sync','exit 0\n')
        self.tool('sysupgrade','''echo "sysupgrade $*" >> "$CALLS"
if test "${FAIL_TEST:-0}" = 1 && test "$1" = --test; then exit 1; fi
exit 0
''')
        for directory,label in [('download.d','download'),('upgrade.d','upgrade'),('abort.d','abort')]:
            d=self.base/directory;d.mkdir()
            p=d/'10test';p.write_text(f'#!/bin/sh\necho {label} >> "$CALLS"\n'+('test "${FAIL_HOOK:-0}" = 0\n' if label=='upgrade' else ''))
            p.chmod(0o700)

    def tool(self,name,body):
        p=self.bin/name;p.write_text('#!/bin/sh\n'+body);p.chmod(0o700)

    def run_worker(self):
        code=(ROOT/'router/install.sh').read_text()
        for old,new in {
            '/tmp/mango-ha-update-job':str(self.state),
            '/var/lock':str(self.base/'locks'),
            '/etc/mango-ha-update-install-enabled':str(self.base/'enabled'),
            '/lib/gluon/release':str(self.base/'version'),
            '/sbin/sysupgrade':str(self.bin/'sysupgrade'),
            '/etc/mango-ha-update-last':str(self.base/'last'),
            '/usr/lib/autoupdater/':str(self.base)+'/',
        }.items():code=code.replace(old,new)
        p=self.base/'worker';p.write_text(code)
        return subprocess.run(['sh',str(p)],env=self.env,capture_output=True,text=True)

    def calls(self):
        p=self.base/'calls';return p.read_text() if p.exists() else ''

    def test_disabled_install_never_touches_hooks_or_flash(self):
        (self.base/'enabled').unlink()
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_valid_handoff_preserves_config_and_exact_image(self):
        r=self.run_worker();self.assertEqual(r.returncode,0,r.stderr)
        lines=self.calls().splitlines()
        self.assertEqual(lines,[f'sysupgrade --test {self.state}/firmware.bin','download','upgrade',f'sysupgrade {self.state}/firmware.bin'])
        self.assertEqual((self.state/'state').read_text().strip(),'INSTALLING')
        self.assertIn('BACKUP_SHA256='+'b'*64,(self.base/'last').read_text())

    def test_tampered_image_is_rejected_before_hooks(self):
        (self.state/'firmware.bin').write_text('changed')
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_request_cannot_select_another_image(self):
        (self.state/'request-image-sha256').write_text('a'*64)
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_missing_backup_receipt_hash_is_rejected(self):
        (self.state/'request-backup-sha256').unlink()
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_changed_installed_version_blocks_stale_candidate(self):
        (self.base/'version').write_text('test7')
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_expired_candidate_is_rejected(self):
        (self.state/'prepared-at').write_text(str(int(time.time())-3601))
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

    def test_incompatible_image_is_not_forced(self):
        self.env['FAIL_TEST']='1'
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(len(self.calls().splitlines()),1)
        self.assertIn('sysupgrade --test',self.calls())

    def test_hook_failure_runs_abort_hooks_without_flashing(self):
        self.env['FAIL_HOOK']='1'
        self.assertNotEqual(self.run_worker().returncode,0)
        lines=self.calls().splitlines()
        self.assertEqual(lines[-3:],['download','upgrade','abort'])
        self.assertEqual(sum(x.startswith('sysupgrade') for x in lines),1)
        self.assertEqual((self.state/'state').read_text().strip(),'ERROR')

    def test_abort_daemon_does_not_keep_install_locks(self):
        self.env['FAIL_HOOK']='1'
        hook=self.base/'abort.d/10test'
        hook.write_text(hook.read_text()+'sleep 60 >/dev/null 2>&1 &\necho $! > "$CALLS.daemon"\n')
        try:
            self.assertNotEqual(self.run_worker().returncode,0)
            for name in ['mango-ha-update-job.lock','autoupdater.lock']:
                r=subprocess.run(['flock','-n',str(self.base/'locks'/name),'true'])
                self.assertEqual(r.returncode,0,name)
        finally:
            pidfile=self.base/'calls.daemon'
            if pidfile.exists():
                os.kill(int(pidfile.read_text()),15)

    def test_generated_installer_matches_sources(self):
        for name in ['worker.sh','service','dispatch.sh','install.sh']:
            self.assertIn((ROOT/'router'/name).read_text(),(ROOT/'install-router-control.sh').read_text())
        r=subprocess.run(['sh','-n',str(ROOT/'install-router-control.sh')],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)

if __name__=='__main__':unittest.main()
