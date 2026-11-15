#!/bin/sh
set -eu
umask 077
command -v ha >/dev/null
test -d /config/packages
test -s /config/freifunk/ssh/mango_zuhause_update
test -s /config/freifunk/ssh/mango_zuhause_backup
test -s /config/freifunk/ssh/mango_monitor
test -s /config/freifunk/ssh/known_hosts_mango
test ! -e "/config/freifunk/mango-update-controller.py" || { echo "Abbruch: /config/freifunk/mango-update-controller.py existiert bereits." >&2; exit 1; }
test ! -e "/config/freifunk/mango-update-controller.json" || { echo "Abbruch: /config/freifunk/mango-update-controller.json existiert bereits." >&2; exit 1; }
test ! -e "/config/packages/mango_update_control.yaml" || { echo "Abbruch: /config/packages/mango_update_control.yaml existiert bereits." >&2; exit 1; }
work=$(mktemp -d /config/freifunk/.controller-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/controller.py" <<'MANGO_PI_FILE_0'
#!/usr/bin/env python3
"""One-router staged controller. Each invocation is short enough for HA actions.
No credentials are embedded. Scheduling and rollout activation are separate.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tarfile
import tempfile
import time
import urllib.request

HASH = re.compile(r'^[0-9a-f]{64}$')
VERSION = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$')
ARCHIVE = re.compile(r'^mango-zuhause-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz$')
REQUIRED = {
    'etc/config/network', 'etc/config/firewall', 'etc/config/wireless',
    'etc/wireguard/mango-management.key', 'etc/dropbear/authorized_keys',
    'etc/mango-ha-backup.sh', 'etc/mango-ha-monitor.sh',
    'etc/mango-ha-update.sh', 'etc/mango-ha-update-worker.sh',
    'etc/mango-ha-update-install.sh', 'etc/init.d/mango-ha-update-job',
    'etc/mango-ha-update-install-enabled',
    'etc/mango-fritz-adressen.sh', 'etc/hotplug.d/iface/95-mango-fritz',
    'etc/crontabs/root', 'etc/sysupgrade.conf',
    'lib/gluon/upgrade/zz-heimwlan',
}

class Controller:
    def __init__(self, config, state_file):
        self.c = config
        self.file = Path(state_file)
        self.s = json.loads(self.file.read_text()) if self.file.exists() else {'phase': 'IDLE'}

    def save(self):
        self.file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temp = self.file.with_suffix('.new')
        with temp.open('w') as f:
            json.dump(self.s, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, self.file)

    def result(self, message='', notify=False):
        return {'phase': self.s['phase'], 'message': message, 'notify': notify}

    def fail(self, message):
        self.s.update(phase='ERROR', error=message, finished=time.time())
        self.save()
        return self.result(message, True)

    def argv(self, key, command):
        return ['ssh', '-T', '-p', str(self.c['port']), '-i', self.c[key],
                '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=5',
                '-o', 'ServerAliveCountMax=1',
                '-o', 'HostKeyAlias='+self.c['host_key_alias'],
                '-o', 'HostKeyAlgorithms=ssh-ed25519',
                '-o', 'StrictHostKeyChecking=yes',
                '-o', 'UserKnownHostsFile='+self.c['known_hosts'],
                'root@'+self.c['host'], command]

    def ssh(self, command, key='update_key', timeout=12):
        r = subprocess.run(self.argv(key, command), capture_output=True, timeout=timeout)
        if r.returncode:
            raise RuntimeError('SSH-Aufruf fehlgeschlagen: '+command.split()[0])
        if len(r.stdout) > 65536:
            raise RuntimeError('Unerwartet grosse SSH-Antwort')
        return r.stdout.decode('utf-8', 'strict')

    def job(self):
        text = self.ssh('job')
        values = {}
        # Parse only the machine-readable header, never the updater log below it.
        for line in text.splitlines():
            if not re.match(r'^(STATE|VERSION|BOOT_ID|SHA256|INSTALL_ENABLED)=', line):
                break
            name, value = line.split('=', 1)
            if name in values:
                raise RuntimeError('Doppeltes Statusfeld')
            values[name] = value
        if not {'STATE', 'VERSION', 'BOOT_ID'} <= values.keys():
            raise RuntimeError('Unvollstaendige Router-Antwort')
        return values

    def target_version(self, image_hash):
        # The image hash was verified by the router against a signed manifest.
        # Only accept release metadata referring to that SAME hash. If the
        # channel changes between requests, stop rather than guessing a target.
        with urllib.request.urlopen(self.c['manifest_url'], timeout=8) as r:
            data = r.read(131073)
        if len(data) > 131072:
            raise RuntimeError('Manifest zu gross')
        text = data.decode('utf-8')
        lines = text.split('\n---', 1)[0].splitlines()
        if 'BRANCH=mango' not in lines:
            raise RuntimeError('Falscher Manifest-Kanal')
        matches = [x.split() for x in lines if x.startswith('gl-mt300n-v2 ')]
        if len(matches) != 1 or len(matches[0]) != 5:
            raise RuntimeError('Firmware-Ziel nicht eindeutig')
        _, version, sha, size, _ = matches[0]
        if sha != image_hash or not VERSION.fullmatch(version) or not size.isdigit():
            raise RuntimeError('Manifest passt nicht zur bereitgelegten Firmware')
        return version

    def backup(self):
        folder = Path(self.c['backup_dir'])
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(folder, 0o700)
        name = time.strftime('mango-zuhause-%Y%m%d-%H%M%S-')+str(os.getpid())+'.tar.gz'
        target = folder/name
        if target.exists():
            raise RuntimeError('Backup-Dateiname bereits vorhanden')
        fd, raw = tempfile.mkstemp(prefix='.abruf-', dir=folder)
        temp = Path(raw)
        try:
            # Bound both duration and size of remote output.
            with os.fdopen(fd, 'wb') as out, tempfile.TemporaryFile() as errors:
                p = subprocess.Popen(self.argv('backup_key', 'backup'), stdout=subprocess.PIPE, stderr=errors)
                try:
                    selector = selectors.DefaultSelector()
                    selector.register(p.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic()+30
                    count = 0
                    try:
                        while True:
                            remaining = deadline-time.monotonic()
                            if remaining <= 0:
                                raise RuntimeError('Backup-Abruf hat das Zeitlimit erreicht')
                            events = selector.select(min(remaining, 1))
                            if not events:
                                continue
                            chunk = os.read(p.stdout.fileno(), 65536)
                            if not chunk:
                                break
                            count += len(chunk)
                            if count > 16*1024*1024:
                                raise RuntimeError('Backup unerwartet gross')
                            out.write(chunk)
                        if p.wait(timeout=max(.1, deadline-time.monotonic())):
                            raise RuntimeError('Backup-Zugang meldet einen Fehler')
                    finally:
                        selector.close()
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.wait()
                    p.stdout.close()
                out.flush()
                os.fsync(out.fileno())
            names = set()
            unpacked = 0
            with tarfile.open(temp, 'r:gz') as archive:
                for number, member in enumerate(archive):
                    if number > 10000:
                        raise RuntimeError('Zu viele Dateien im Backup')
                    unpacked += member.size
                    if unpacked > 32*1024*1024:
                        raise RuntimeError('Entpackter Backup-Inhalt unerwartet gross')
                    path = member.name.removeprefix('./')
                    if path in REQUIRED:
                        if path in names or not member.isfile() or member.size == 0:
                            raise RuntimeError('Ungueltige Pflichtdatei im Backup: '+path)
                        names.add(path)
                        content = archive.extractfile(member)
                        while content.read(65536):
                            pass
            missing = REQUIRED-names
            if missing:
                raise RuntimeError('Pflichtdatei fehlt: '+', '.join(sorted(missing)))
            digest = hashlib.sha256(temp.read_bytes()).hexdigest()
            os.replace(temp, target)
            target.with_name(name+'.sha256').write_text(digest+'  '+name+'\n')
            os.chmod(target.with_name(name+'.sha256'), 0o600)
            self.check_backup(str(target), digest)
            return str(target), digest
        finally:
            temp.unlink(missing_ok=True)

    def check_backup(self, path, digest):
        p = Path(path)
        if not HASH.fullmatch(digest) or hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Backup fehlt oder Pruefsumme stimmt nicht')

    def prune(self):
        folder = Path(self.c['backup_dir'])
        files = sorted((p for p in folder.iterdir() if ARCHIVE.fullmatch(p.name)),
                       key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
        # Validate the entire set before deleting anything.
        for p in files:
            checksum = p.with_name(p.name+'.sha256').read_text().split()
            if len(checksum) != 2 or checksum[1] != p.name:
                raise RuntimeError('Ungueltige Backup-Pruefsummendatei')
            self.check_backup(str(p), checksum[0])
        for p in files[3:]:
            p.unlink()
            p.with_name(p.name+'.sha256').unlink()

    def start(self):
        if self.s['phase'] not in {'IDLE', 'NO_UPDATE', 'SUCCESS'}:
            return self.result('Vorhandener Lauf oder Fehler bleibt erhalten; kein Neustart.')
        self.s = {'phase': 'CHECKING', 'started': time.time()}
        self.save()  # before asking the router to do anything
        self.ssh('prepare')
        return self.result('Hintergrundpruefung gestartet.')

    def tick(self):
        phase = self.s['phase']
        if phase in {'IDLE', 'NO_UPDATE', 'SUCCESS', 'ERROR', 'AWAITING_ACTIVATION'}:
            return self.result()
        if time.time()-self.s['started'] > 1800:
            return self.fail('Zeitlimit des Update-Ablaufs erreicht; keine automatische Wiederholung.')
        if phase == 'CHECKING':
            job = self.job()
            if job['STATE'] == 'NO_UPDATE':
                self.s['phase'] = 'NO_UPDATE'; self.save()
                return self.result('Kein Update: kein Backup und keine Installation.')
            if job['STATE'] in {'QUEUED', 'PREPARING'}:
                return self.result('Router prueft noch.')
            if job['STATE'] != 'READY' or not HASH.fullmatch(job.get('SHA256', '')):
                raise RuntimeError('Router hat keine eindeutig gepruefte Firmware bereitgestellt')
            if self.c.get('installation_enabled') and job.get('INSTALL_ENABLED') != '1':
                raise RuntimeError('Installationszugang auf dem Router ist nicht aktiviert')
            target = self.target_version(job['SHA256'])
            if target == job['VERSION']:
                raise RuntimeError('Zielversion entspricht bereits installierter Version')
            self.s.update(phase='BACKUP_REQUIRED', image_sha=job['SHA256'],
                          old_version=job['VERSION'], old_boot=job['BOOT_ID'], target_version=target)
            self.save()
            return self.result('Neue Firmware geprueft; Backup ist der naechste Schritt.')
        if phase == 'BACKUP_REQUIRED':
            if self.ssh('health').strip() != 'HEALTH=OK':
                raise RuntimeError('Router-Sicherheitspruefung vor Backup fehlgeschlagen')
            path, digest = self.backup()
            self.s.update(backup_path=path, backup_sha=digest)
            self.s['phase'] = 'INSTALL_READY' if self.c.get('installation_enabled') else 'AWAITING_ACTIVATION'
            self.save()
            self.prune()
            return self.result('Backup geprueft. '+('Installationsauftrag steht an.' if self.c.get('installation_enabled') else 'Installation bleibt gesperrt.'))
        if phase == 'INSTALL_READY':
            if not self.c.get('installation_enabled'):
                self.s['phase']='AWAITING_ACTIVATION';self.save()
                return self.result('Installation deaktiviert.')
            self.check_backup(self.s['backup_path'], self.s['backup_sha'])
            if self.target_version(self.s['image_sha']) != self.s['target_version']:
                raise RuntimeError('Firmware-Freigabe hat sich seit der Vorbereitung geaendert')
            job=self.job()
            if job['STATE']!='READY' or job.get('SHA256')!=self.s['image_sha'] or job['BOOT_ID']!=self.s['old_boot'] or job['VERSION']!=self.s['old_version']:
                raise RuntimeError('Bereitgelegte Firmware oder Routerzustand hat sich geaendert')
            self.s.update(phase='INSTALLING', install_started=time.time())
            self.save()  # no duplicate install, even if SSH acknowledgement is lost
            try:
                self.ssh('install '+self.s['image_sha']+' '+self.s['backup_sha'])
            except (RuntimeError, subprocess.TimeoutExpired):
                return self.result('Installationsantwort unklar; nur Zustand pruefen, Auftrag nicht wiederholen.')
            return self.result('Installationsauftrag uebergeben.')
        if phase == 'INSTALLING':
            if time.time()-self.s['install_started'] > 900:
                return self.fail('Router nach Update nicht rechtzeitig gesund zurueckgekehrt.')
            try:
                job=self.job()
            except (RuntimeError, subprocess.TimeoutExpired):
                if self.s.get('healthy_checks'):
                    self.s['healthy_checks']=0; self.save()
                return self.result('Warte auf Router nach Installation.')
            if job['STATE']=='ERROR':
                raise RuntimeError('Router meldet Installationsfehler')
            if job['BOOT_ID']==self.s['old_boot']:
                return self.result('Warte auf Neustart.')
            if job['VERSION']!=self.s['target_version']:
                raise RuntimeError('Router mit unerwarteter Firmware-Version zurueckgekehrt')
            # SSH itself traverses WireGuard. Check Freifunk and mesh separately.
            try:
                guards_ok=self.ssh('health').strip()=='HEALTH=OK'
            except (RuntimeError, subprocess.TimeoutExpired):
                guards_ok=False
            vpn=self.ssh('vpn',key='monitor_key').strip()
            details=self.ssh('details',key='monitor_key').splitlines()
            if not guards_ok or vpn!='Verbunden' or not details or details[0]!='Aktiv':
                if self.s.get('healthy_checks'):
                    self.s['healthy_checks']=0; self.save()
                return self.result('Router zurueck; Sicherheitspruefung, Freifunk oder Mesh noch nicht bereit.')
            self.s['healthy_checks']=self.s.get('healthy_checks',0)+1
            if self.s['healthy_checks']>=2:
                self.s.update(phase='SUCCESS', finished=time.time())
            self.save()
            return self.result('Update-Funktionspruefung erfolgreich.',self.s['phase']=='SUCCESS')
        raise RuntimeError('Unbekannter Ablaufzustand')

    def execute(self, action):
        try:
            if action=='start':return self.start()
            if action=='tick':return self.tick()
            if action=='status':return dict(self.s)
            raise RuntimeError('Unbekannte Aktion')
        except Exception as error:
            return self.fail(str(error))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['start','tick','status'])
    parser.add_argument('--config',default='/config/freifunk/mango-update-controller.json')
    args=parser.parse_args()
    os.umask(0o077)
    config=json.loads(Path(args.config).read_text())
    state=Path(config['state_file'])
    state.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with state.with_suffix('.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'phase':'BUSY','message':'Ablauf bereits aktiv.','notify':False}));return
        controller=Controller(config,state)
        print(json.dumps(controller.execute(args.action),ensure_ascii=False))

if __name__=='__main__':main()
MANGO_PI_FILE_0
cat > "$work/config.example.json" <<'MANGO_PI_FILE_1'
{
  "installation_enabled": false,
  "host": "172.30.33.2",
  "port": 2222,
  "host_key_alias": "192.168.178.20",
  "known_hosts": "/config/freifunk/ssh/known_hosts_mango",
  "update_key": "/config/freifunk/ssh/mango_zuhause_update",
  "backup_key": "/config/freifunk/ssh/mango_zuhause_backup",
  "monitor_key": "/config/freifunk/ssh/mango_monitor",
  "manifest_url": "https://evewot-netizen.github.io/mango-firmware/updates/mango.manifest",
  "backup_dir": "/config/freifunk/backups/mango-zuhause/automatisch",
  "state_file": "/config/freifunk/update-status/mango-zuhause.json"
}
MANGO_PI_FILE_1
cat > "$work/home-assistant.yaml" <<'MANGO_PI_FILE_2'
shell_command:
  mango_update_start: "python3 /config/freifunk/mango-update-controller.py start"
  mango_update_schritt: "python3 /config/freifunk/mango-update-controller.py tick"
  mango_update_status: "python3 /config/freifunk/mango-update-controller.py status"
MANGO_PI_FILE_2
cp "$work/controller.py" "/config/freifunk/mango-update-controller.py"
chmod 600 "/config/freifunk/mango-update-controller.py"
cp "$work/config.example.json" "/config/freifunk/mango-update-controller.json"
chmod 600 "/config/freifunk/mango-update-controller.json"
cp "$work/home-assistant.yaml" "/config/packages/mango_update_control.yaml"
chmod 600 "/config/packages/mango_update_control.yaml"
echo '--- Home-Assistant-Konfiguration pruefen ---'
if ! ha core check; then
    save="/config/freifunk/mango-update-control-fehler-$(date +%Y%m%d-%H%M%S).yaml"
    mv /config/packages/mango_update_control.yaml "$save"
    echo "Konfigurationspruefung fehlgeschlagen. Neue YAML-Datei entfernt: $save" >&2
    exit 1
fi
echo 'ERFOLG: Pi-Steuerung eingerichtet. Shell-Befehle muessen noch geladen werden.'
echo 'Keine Zeitautomatik eingerichtet. Installation ist weiterhin deaktiviert.'
