import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('gpg'), 'GnuPG required for archive round-trip test')
class PCArchiveTests(unittest.TestCase):
    def test_encrypted_round_trip_keeps_sources_keys_and_excludes_build_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);home=root/'home';home.mkdir()
            win=root/'windows';win.mkdir();out=root/'out';out.mkdir()
            files={
                home/'mango-firmware/gluon/openwrt/package/custom.patch':b'local unique patch\n',
                home/'mango-firmware/gluon/openwrt/build_dir/generated.o':b'rebuildable',
                home/'mango-firmware/gluon/openwrt/staging_dir/compiler':b'rebuildable',
                home/'mango-firmware/gluon/openwrt/dl/download.tar':b'redownloadable',
                home/'mango-firmware/gluon/output/test6.bin':b'old recovery firmware',
                home/'mango-firmware-private/autoupdater/mango-autoupdater.secret':b'fake signing secret',
                win/'.ssh/mango_freifunk':b'fake SSH secret',
                win/'.ssh/mango_freifunk.pub':b'fake SSH public key',
                win/'AppData/Local/Temp/zz-mango-uplink':b'old unique script',
            }
            for p,content in files.items():p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content)
            tools=root/'bin';tools.mkdir()
            # Only fixtures use a fixed passphrase; production always prompts.
            gpg=tools/'gpg';gpg.write_text('#!/bin/sh\nexec '+shutil.which('gpg')+' --batch --passphrase unittest-only "$@"\n');gpg.chmod(0o700)
            tty=tools/'tty';tty.write_text('#!/bin/sh\necho /dev/null\n');tty.chmod(0o700)
            gnupg=root/'gnupg';gnupg.mkdir(mode=0o700)
            env=dict(os.environ,PATH=str(tools)+':'+os.environ['PATH'],GNUPGHOME=str(gnupg))
            source=(ROOT/'archive-pc-for-cloud.sh').read_text().replace('base=/home/Patrick','base='+str(home))
            script=root/'archive.sh';script.write_text(source)
            try:
                r=subprocess.run(['bash',str(script),str(out),str(win)],env=env,capture_output=True,text=True,timeout=60)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                self.assertTrue((out/'Mango-PC-Archiv.tar.gz.gpg').is_file())
                members=(out/'Archiv-Inhalt.txt').read_text()
                self.assertIn('mango-firmware/gluon/openwrt/package/custom.patch',members)
                self.assertIn('mango-firmware/gluon/output/test6.bin',members)
                self.assertIn('Windows-Extras/zz-mango-uplink',members)
                self.assertNotIn('generated.o',members)
                self.assertNotIn('staging_dir/compiler',members)
                self.assertNotIn('dl/download.tar',members)
                for p,content in files.items():self.assertEqual(p.read_bytes(),content)
                self.assertFalse(list(home.glob('.mango-cloud-archive.*')))
                check=subprocess.run(['sha256sum','-c','SHA256SUMS.txt'],cwd=out,capture_output=True,text=True)
                self.assertEqual(check.returncode,0,check.stderr)
                self.assertNotIn('fake signing secret',r.stdout+r.stderr)
                self.assertNotIn('fake SSH secret',r.stdout+r.stderr)
            finally:
                if shutil.which('gpgconf'):
                    subprocess.run(['gpgconf','--homedir',str(gnupg),'--kill','gpg-agent'],capture_output=True)


if __name__=='__main__':unittest.main()
