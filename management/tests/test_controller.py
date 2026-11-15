import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import time
import unittest
from unittest.mock import Mock

spec=importlib.util.spec_from_file_location('controller',Path(__file__).resolve().parents[1]/'pi/controller.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name)
        self.config={'backup_dir':str(self.base/'backups'),'installation_enabled':True}
        self.controller=module.Controller(self.config,self.base/'state.json')
        self.c=self.controller
        self.c.s={'phase':'CHECKING','started':time.time()}
        self.hash='a'*64
        self.job={'STATE':'READY','SHA256':self.hash,'VERSION':'test6','BOOT_ID':'old-boot'}
        self.c.job=Mock(return_value=self.job)
        self.c.target_version=Mock(return_value='test7')
        self.c.ssh=Mock(return_value='STATE=INSTALL_QUEUED\n')

    def stage_install(self):
        archive=self.base/'backup.tar.gz';archive.write_bytes(b'checked backup')
        self.c.s.update(phase='INSTALL_READY',image_sha=self.hash,old_version='test6',old_boot='old-boot',target_version='test7',backup_path=str(archive),backup_sha=hashlib.sha256(archive.read_bytes()).hexdigest())
        return archive

    def test_no_update_never_creates_backup(self):
        self.c.job.return_value=dict(self.job,STATE='NO_UPDATE')
        self.c.backup=Mock(side_effect=AssertionError('must not back up'))
        result=self.c.execute('tick')
        self.assertEqual(result['phase'],'NO_UPDATE')
        self.c.backup.assert_not_called();self.c.ssh.assert_not_called()

    def test_ready_image_records_target_before_backup(self):
        self.assertEqual(self.c.execute('tick')['phase'],'BACKUP_REQUIRED')
        self.assertEqual(self.c.s['image_sha'],self.hash)
        self.assertEqual(self.c.s['target_version'],'test7')
        self.c.ssh.assert_not_called()

    def test_backup_failure_blocks_installation(self):
        self.c.s['phase']='BACKUP_REQUIRED'
        self.c.backup=Mock(side_effect=RuntimeError('Backup failed'))
        self.assertEqual(self.c.execute('tick')['phase'],'ERROR')
        self.c.ssh.assert_not_called()

    def test_activation_disabled_blocks_installation(self):
        self.stage_install();self.config['installation_enabled']=False
        self.assertEqual(self.c.execute('tick')['phase'],'AWAITING_ACTIVATION')
        self.c.ssh.assert_not_called()

    def test_tampered_backup_blocks_installation(self):
        self.stage_install().write_bytes(b'corrupted')
        self.assertEqual(self.c.execute('tick')['phase'],'ERROR')
        self.c.ssh.assert_not_called()

    def test_changed_candidate_blocks_installation(self):
        self.stage_install();self.c.job.return_value=dict(self.job,SHA256='b'*64)
        self.assertEqual(self.c.execute('tick')['phase'],'ERROR')
        self.c.ssh.assert_not_called()

    def test_install_uses_both_exact_hashes(self):
        self.stage_install()
        self.assertEqual(self.c.execute('tick')['phase'],'INSTALLING')
        self.c.ssh.assert_called_once_with('install '+self.hash+' '+self.c.s['backup_sha'])
        self.assertEqual(json.loads(self.c.file.read_text())['phase'],'INSTALLING')

    def test_lost_acknowledgement_does_not_repeat_install(self):
        self.stage_install();self.c.ssh.side_effect=RuntimeError('connection lost')
        self.assertEqual(self.c.execute('tick')['phase'],'INSTALLING')
        self.c.execute('tick')
        self.assertEqual(self.c.ssh.call_count,1)

    def test_wrong_release_after_reboot_halts(self):
        self.stage_install();self.c.s.update(phase='INSTALLING',install_started=time.time())
        self.c.job.return_value=dict(self.job,STATE='IDLE',VERSION='test8',BOOT_ID='new-boot')
        self.assertEqual(self.c.execute('tick')['phase'],'ERROR')

    def test_two_healthy_checks_required(self):
        self.stage_install();self.c.s.update(phase='INSTALLING',install_started=time.time())
        self.c.job.return_value=dict(self.job,STATE='IDLE',VERSION='test7',BOOT_ID='new-boot')
        self.c.ssh.side_effect=lambda command,**kw: 'Verbunden\n' if command=='vpn' else 'Aktiv\n1/0\n'
        self.assertEqual(self.c.execute('tick')['phase'],'INSTALLING')
        self.assertEqual(self.c.execute('tick')['phase'],'SUCCESS')

    def test_error_cannot_be_restarted_by_daily_trigger(self):
        self.c.s['phase']='ERROR'
        self.assertEqual(self.c.execute('start')['phase'],'ERROR')
        self.c.ssh.assert_not_called()

    def make_tar(self,missing=None):
        path=self.base/'remote.tar.gz'
        with tarfile.open(path,'w:gz') as archive:
            for name in module.REQUIRED:
                if name==missing:continue
                content=b'config data\n'
                info=tarfile.TarInfo(name);info.size=len(content)
                archive.addfile(info,io.BytesIO(content))
        self.c.argv=lambda key,command:['cat',str(path)]

    def test_real_backup_archive_is_verified(self):
        self.make_tar()
        path,digest=self.c.backup()
        self.assertTrue(Path(path).exists())
        self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(),digest)
        self.assertEqual(Path(path).stat().st_mode & 0o777,0o600)

    def test_backup_missing_update_worker_is_rejected(self):
        self.make_tar('etc/mango-ha-update-install.sh')
        with self.assertRaisesRegex(RuntimeError,'Pflichtdatei fehlt'):self.c.backup()
        self.assertFalse(list(Path(self.config['backup_dir']).glob('*.tar.gz')))

    def test_retention_uses_creation_order_not_timezone_in_filename(self):
        folder=Path(self.config['backup_dir']);folder.mkdir()
        for i,hour in enumerate([12,13,14,11]):
            p=folder/f'mango-zuhause-20261115-{hour}0000-1.tar.gz';p.write_bytes(b'valid')
            p.with_name(p.name+'.sha256').write_text(hashlib.sha256(b'valid').hexdigest()+'  '+p.name+'\n')
            os.utime(p,(1000+i,1000+i))
        self.c.prune()
        self.assertTrue((folder/'mango-zuhause-20261115-110000-1.tar.gz').exists())
        self.assertFalse((folder/'mango-zuhause-20261115-120000-1.tar.gz').exists())

    def test_retention_keeps_three_pairs(self):
        folder=Path(self.config['backup_dir']);folder.mkdir()
        for i in range(5):
            p=folder/f'mango-zuhause-20261115-12000{i}-1.tar.gz';p.write_bytes(b'valid')
            p.with_name(p.name+'.sha256').write_text(hashlib.sha256(b'valid').hexdigest()+'  '+p.name+'\n')
        self.c.prune()
        self.assertEqual(len(list(folder.glob('*.tar.gz'))),3)
        self.assertEqual(len(list(folder.glob('*.sha256'))),3)
        self.assertTrue((folder/'mango-zuhause-20261115-120004-1.tar.gz').exists())

if __name__=='__main__':unittest.main()
