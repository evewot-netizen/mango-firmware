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
            '/lib/gluon/autoupdater/lib.sh':str(self.base/'updater-lib.sh'),
            '/sys/class/net/bat0':str(self.base/'bat0'),
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

    def network_fixture(self):
        # Exact upstream hook from the installed Gluon build.
        native='''#!/bin/sh

# shellcheck source=package/gluon-autoupdater/files/lib/gluon/autoupdater/lib.sh
. /lib/gluon/autoupdater/lib.sh

wifi down
sleep 1
stop network
ip link del bat0
'''
        p=self.base/'upgrade.d/10stop-network'
        p.write_text(native);p.chmod(0o700)
        self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),
                         'd989f0837ad73c6ff1a46ba4d4daafc09c0258d11eb84a185aad8be4ade1eb1e')
        self.env['BAT0']=str(self.base/'bat0')
        (self.base/'bat0').mkdir()
        (self.base/'updater-lib.sh').write_text('''stop() {
    echo "stop $1" >> "$CALLS"
    test "${FAIL_NETWORK:-0}" = 0 || return 1
    if test "${KEEP_BAT0:-0}" = 0; then rmdir "$BAT0"; fi
}
''')
        self.tool('wifi','echo wifi >> "$CALLS"\ntest "${FAIL_WIFI:-0}" = 0\n')
        self.tool('sleep','exit 0\n')
        self.tool('ip','echo "ip $*" >> "$CALLS"\ntest "${FAIL_DELETE:-0}" = 0 || exit 2\nrmdir "$BAT0"\n')

    def test_network_shutdown_already_removed_bat0_still_flashes(self):
        self.network_fixture()
        r=self.run_worker()
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('ip link del',self.calls())
        self.assertEqual(sum(x.startswith('sysupgrade') for x in self.calls().splitlines()),2)
        self.assertIn('bat0 already removed', (self.state/'log').read_text())

    def test_remaining_bat0_is_deleted_before_flash(self):
        self.network_fixture();self.env['KEEP_BAT0']='1'
        self.assertEqual(self.run_worker().returncode,0)
        lines=self.calls().splitlines()
        self.assertIn('ip link del bat0',lines)
        self.assertTrue(lines[-1].startswith('sysupgrade '))

    def test_real_network_errors_are_not_ignored(self):
        for failure in ['FAIL_WIFI','FAIL_NETWORK','FAIL_DELETE']:
            with self.subTest(failure=failure):
                # Separate fixture per failure to retain a complete candidate.
                test=InstallTests();test.setUp()
                try:
                    test.network_fixture();test.env[failure]='1';test.env['KEEP_BAT0']='1'
                    self.assertNotEqual(test.run_worker().returncode,0)
                    self.assertEqual(sum(x.startswith('sysupgrade') for x in test.calls().splitlines()),1)
                    self.assertEqual((test.state/'state').read_text().strip(),'ERROR')
                    self.assertIn('abort',test.calls().splitlines())
                finally:test.doCleanups()

    def test_changed_upstream_network_hook_is_not_substituted(self):
        self.network_fixture()
        p=self.base/'upgrade.d/10stop-network';p.write_text(p.read_text()+'echo changed\n')
        self.assertNotEqual(self.run_worker().returncode,0)
        self.assertEqual(self.calls(),'')

if __name__=='__main__':unittest.main()
