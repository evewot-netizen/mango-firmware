import os, pathlib, subprocess, tempfile, unittest, tarfile, io
ROOT=pathlib.Path(__file__).resolve().parents[2]
class Backup(unittest.TestCase):
 def test_restricted_backup_stream_and_cleanup(self):
  with tempfile.TemporaryDirectory() as tmp:
   d=pathlib.Path(tmp); (d/'bin').mkdir(); (d/'payload').write_text('test config')
   mock=d/'bin/sysupgrade'; mock.write_text('#!/bin/sh\necho diagnostic >&2\ntar -czf "$2" -C "$FIXTURE" payload\n'); mock.chmod(0o700)
   script=(ROOT/'management/router/backup.sh').read_text().replace('/var/lock/mango-ha-backup.lock',str(d/'lock')).replace('/tmp/mango-ha-backup.XXXXXX',str(d/'backup.XXXXXX'))
   f=d/'backup.sh'; f.write_text(script)
   env=dict(os.environ,PATH=str(d/'bin')+':'+os.environ['PATH'],FIXTURE=str(d),SSH_ORIGINAL_COMMAND='backup')
   result=subprocess.run(['sh',str(f)],env=env,capture_output=True)
   self.assertEqual(result.returncode,0,result.stderr)
   with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:self.assertEqual(archive.extractfile('payload').read(),b'test config')
   self.assertIn(b'diagnostic',result.stderr)
   self.assertFalse(list(d.glob('backup.*[0-9]')))
   env['SSH_ORIGINAL_COMMAND']='backup; id'
   bad=subprocess.run(['sh',str(f)],env=env,capture_output=True)
   self.assertNotEqual(bad.returncode,0); self.assertEqual(bad.stdout,b'')
if __name__=='__main__': unittest.main()
