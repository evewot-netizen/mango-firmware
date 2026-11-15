#!/bin/sh
# Terminal app installer: no Python required here. Python executes in HA Core.
set -eu
umask 077
command -v jq >/dev/null
command -v flock >/dev/null
command -v ha >/dev/null
echo '--- Bekannte Pi-Steuerung pruefen ---'
echo '8510d511f352c92007025a13e8c7552ec461e763a182d2a1792160a0cc32450f  /config/freifunk/mango-update-controller.py' | sha256sum -c -
echo '1ed1ad7444f9f3c4278a651cb541b5d4e26ab993132e4edd663eddd2d1e09925  /config/packages/mango_update_control.yaml' | sha256sum -c -
exec 9> /config/freifunk/update-status/mango-zuhause.lock
flock -n 9 || { echo 'Alte Steuerung gerade aktiv. Spaeter erneut versuchen.' >&2; exit 1; }
jq -e '.phase == "SUCCESS" or .phase == "NO_UPDATE" or .phase == "IDLE"' /config/freifunk/update-status/mango-zuhause.json >/dev/null
jq -e '.installation_enabled == true and .host == "172.30.33.2" and .port == 2222 and .state_file == "/config/freifunk/update-status/mango-zuhause.json"' /config/freifunk/mango-update-controller.json >/dev/null
test ! -e /config/freifunk/update-status/mango-fleet.json
test ! -e /config/freifunk/update-status/mango-02.json
test ! -e /config/freifunk/mango_fleet_engine.py
test ! -e /config/freifunk/mango-fleet.py
test ! -e /config/freifunk/mango-fleet.json
test -s /config/freifunk/ssh/known_hosts_mango
test -s /config/freifunk/ssh/mango_zuhause_update
test -s /config/freifunk/ssh/mango_zuhause_backup
test -s /config/freifunk/ssh/mango_monitor
test -s /config/freifunk/ssh/known_hosts_mango_02
test -s /config/freifunk/ssh/mango_02_update
test -s /config/freifunk/ssh/mango_02_backup
test -s /config/freifunk/ssh/mango_02_monitor
test "$(ssh-keygen -y -f /config/freifunk/ssh/mango_02_update | awk '{print $2}')" = AAAAC3NzaC1lZDI1NTE5AAAAIL8eq56t3IAeqiJJ9baW9LNRwUldUbxHCkqEKBLQqnWD
test "$(ssh-keygen -y -f /config/freifunk/ssh/mango_02_backup | awk '{print $2}')" = AAAAC3NzaC1lZDI1NTE5AAAAICKpsXrM9TrWyp38sI5wctJYaj12rCn9StZEC7sXHRhM
work=$(mktemp -d /tmp/mango-fleet-setup.XXXXXX)
changed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$changed" = 1; then
        cp -p "$save/mango_update_control.yaml" /config/packages/mango_update_control.yaml
        rm -f /config/freifunk/mango_fleet_engine.py /config/freifunk/mango-fleet.py /config/freifunk/mango-fleet.json
        echo 'FEHLER: Vorherige Zeitsteuerung wiederhergestellt.' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/file0" <<'MANGO_FLEET_0'
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
        self.prefix = config.get('router_id', 'mango-zuhause')
        if not re.fullmatch(r'mango-[a-z0-9-]+', self.prefix):
            raise ValueError('Ungueltige Router-ID')
        self.required = set(config.get('required_backup_files', REQUIRED))
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
        name = self.prefix + time.strftime('-%Y%m%d-%H%M%S-')+str(os.getpid())+'.tar.gz'
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
                    if path in self.required:
                        if path in names or not member.isfile() or member.size == 0:
                            raise RuntimeError('Ungueltige Pflichtdatei im Backup: '+path)
                        names.add(path)
                        content = archive.extractfile(member)
                        while content.read(65536):
                            pass
            missing = self.required-names
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
        files = sorted((p for p in folder.iterdir() if re.fullmatch(re.escape(self.prefix)+r'-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz', p.name)),
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
MANGO_FLEET_0
cat > "$work/file1" <<'MANGO_FLEET_1'
#!/usr/bin/env python3
"""One daily manifest lookup; persistent sequential rollout, fail closed."""
import argparse, fcntl, json, os, re, time, urllib.request
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from mango_fleet_engine import Controller, HASH, VERSION

QUIET={'IDLE','NO_UPDATE','SUCCESS'}
class Fleet:
    def __init__(self, config):
        self.c=config
        self.path=Path(config['state_file'])
        self.s=json.loads(self.path.read_text()) if self.path.exists() else {'phase':'IDLE'}
        self.routers=config['routers']
        ids=[c['router_id'] for c in self.routers]
        if not ids or len(ids)!=len(set(ids)): raise ValueError('Router-Liste ungueltig')
        if len({c['state_file'] for c in self.routers})!=len(ids): raise ValueError('Doppelte Statusdatei')
    def save(self):
        self.path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        temp=self.path.with_suffix('.new')
        with temp.open('w') as f:
            json.dump(self.s,f,ensure_ascii=False,sort_keys=True); f.flush(); os.fsync(f.fileno())
        os.chmod(temp,0o600); os.replace(temp,self.path)
    def result(self,message='',notify=False):
        return {'phase':self.s['phase'],'message':message,'notify':notify,
                'router':self.s.get('router'),'completed':self.s.get('completed',[])}
    def fail(self,message):
        message=(self.s.get('router')+': ' if self.s.get('router') else '')+message
        self.s.update(phase='ERROR',error=message,finished=time.time()); self.save()
        return self.result(message,True)
    def controller(self,index):
        config=self.routers[index]
        c=Controller(config,config['state_file'])
        def target(image_hash):
            if image_hash!=self.s['offer']['sha256']: raise RuntimeError('Firmware-Kanal seit Tagespruefung geaendert')
            return self.s['offer']['version']
        c.target_version=target
        return c
    def fetch_offer(self):
        with urllib.request.urlopen(self.c['manifest_url'],timeout=8) as r: data=r.read(131073)
        if len(data)>131072: raise RuntimeError('Manifest zu gross')
        lines=data.decode('utf-8').split('\n---',1)[0].splitlines()
        if 'BRANCH=mango' not in lines: raise RuntimeError('Falscher Firmware-Kanal')
        rows=[x.split() for x in lines if x.startswith('gl-mt300n-v2 ')]
        if len(rows)!=1 or len(rows[0])!=5: raise RuntimeError('Firmware-Angebot nicht eindeutig')
        _,version,sha,size,_=rows[0]
        if not VERSION.fullmatch(version) or not HASH.fullmatch(sha) or not size.isdigit(): raise RuntimeError('Ungueltiges Firmware-Angebot')
        return {'version':version,'sha256':sha}
    def start(self):
        now=datetime.now(ZoneInfo(self.c.get('timezone','Europe/Berlin')))
        day=now.date().isoformat()
        if self.s['phase']=='RUNNING': return self.result('Vorhandene Runde wird fortgesetzt.')
        if self.s['phase']=='ERROR': return self.result('Fehler bleibt gesperrt; manuelle Pruefung erforderlich.',True)
        if self.s.get('day')==day: return self.result('Heutige Runde bereits bearbeitet.')
        if now.hour<21: return self.result('Start erst ab 21 Uhr.')
        for i in range(len(self.routers)):
            if self.controller(i).s['phase'] not in QUIET: raise RuntimeError('Vorhandener Router-Auftrag oder Fehler; Abbruch')
        self.s={'phase':'RUNNING','day':day,'started':time.time(),'index':0,'stage':'OFFER','completed':[]}
        self.save()  # record daily attempt before network activity
        self.s['offer']=self.fetch_offer(); self.s['stage']='NEXT'; self.save()
        return self.result('Tagesangebot gelesen; Mango Zuhause ist zuerst an der Reihe.')
    def healthy(self,c):
        if c.ssh('health').strip()!='HEALTH=OK': raise RuntimeError('Schutzpruefung fehlgeschlagen')
        if c.ssh('vpn',key='monitor_key').strip()!='Verbunden': raise RuntimeError('Freifunk-VPN nicht verbunden')
        details=c.ssh('details',key='monitor_key').splitlines()
        if not details or details[0]!='Aktiv': raise RuntimeError('Mesh nicht aktiv')
    def advance(self,router,outcome):
        self.s['completed'].append({'router':router,'result':outcome})
        self.s['index']+=1;self.s['stage']='NEXT'
        if self.s['index']==len(self.routers):
            self.s.update(phase='SUCCESS',finished=time.time());self.save()
            return self.result('Update-Runde abgeschlossen: '+', '.join(x['router']+': '+x['result'] for x in self.s['completed']),True)
        self.save();return self.result(router+' abgeschlossen; naechster Router folgt.')
    def tick(self):
        if self.s['phase']!='RUNNING': return self.result()
        if time.time()-self.s['started']>len(self.routers)*2100+300: raise RuntimeError('Zeitlimit der Runde erreicht')
        if self.s['stage']=='OFFER': raise RuntimeError('Tagesabfrage unterbrochen; keine automatische Wiederholung')
        i=self.s['index'];c=self.controller(i);router=self.routers[i]['router_id'];self.s['router']=router
        if self.s['stage']=='NEXT':
            if c.s['phase'] not in QUIET: raise RuntimeError('Router-Auftrag nicht im Ruhezustand')
            job=c.job()
            if job['STATE'] not in {'IDLE','NO_UPDATE'}: raise RuntimeError('Router hat bereits einen offenen Auftrag')
            if job.get('INSTALL_ENABLED')!='1': raise RuntimeError('Router-Installation nicht freigegeben')
            current=job['VERSION'];target=self.s['offer']['version']
            if current==target:
                self.s['stage']='CHECK_CURRENT';self.save();return self.result('Firmware bereits aktuell; Verbindung wird geprueft.')
            a=re.fullmatch(r'(.+)-test([0-9]+)',current); b=re.fullmatch(r'(.+)-test([0-9]+)',target)
            if not a or not b or a[1]!=b[1] or int(b[2])<=int(a[2]): raise RuntimeError('Versionswechsel oder Downgrade erfordert manuelle Pruefung')
            self.s.update(stage='STARTING',router_started=time.time());self.save()
            result=c.execute('start')
            if result['phase']!='CHECKING': raise RuntimeError(result.get('message') or 'Vorbereitung nicht gestartet')
            self.s['stage']='ACTIVE';self.save();return self.result(router+': Firmware-Pruefung gestartet.')
        if self.s['stage']=='CHECK_CURRENT':
            self.healthy(c);return self.advance(router,'Aktuell')
        if self.s['stage']=='STARTING':
            if c.s.get('started',0)<self.s['router_started']: raise RuntimeError('Vorbereitungsauftrag unterbrochen; manuelle Pruefung erforderlich')
            self.s['stage']='ACTIVE';self.save()
        result=c.execute('tick')
        phase=result['phase']
        if phase=='SUCCESS': return self.advance(router,'Aktualisiert und geprueft')
        if phase=='NO_UPDATE': raise RuntimeError('Router meldet kein Update trotz abweichendem Tagesangebot')
        if phase in {'ERROR','AWAITING_ACTIVATION','IDLE'}: raise RuntimeError(result.get('message') or 'Router-Ablauf angehalten')
        return self.result(router+': '+result.get('message',''))
    def execute(self,action):
        try:
            if action=='start': return self.start()
            if action=='tick': return self.tick()
            if action=='status': return dict(self.s)
            if action=='verify':
                for c in self.routers:
                    for k in ['known_hosts','update_key','backup_key','monitor_key']:
                        if not Path(c[k]).is_file(): raise RuntimeError('Zugangsdatei fehlt: '+k)
                    if not c.get('installation_enabled'): raise RuntimeError('Installation nicht aktiviert')
                    if self.controller(self.routers.index(c)).s['phase'] not in QUIET: raise RuntimeError('Offener Router-Auftrag')
                return {'phase':'READY','message':'Konfiguration geprueft. Kein Update gestartet.','notify':False}
            raise RuntimeError('Unbekannte Aktion')
        except Exception as e:return self.fail(str(e))

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['start','tick','status','verify']);p.add_argument('--config',default='/config/freifunk/mango-fleet.json');a=p.parse_args()
    os.umask(0o077);config=json.loads(Path(a.config).read_text());state=Path(config['state_file']);state.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with state.with_suffix('.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'phase':'BUSY','notify':True,'message':'Update-Steuerung bereits aktiv.'}));return
        fleet=Fleet(config);print(json.dumps(fleet.execute(a.action),ensure_ascii=False))
if __name__=='__main__': main()
MANGO_FLEET_1
cat > "$work/file2" <<'MANGO_FLEET_2'
{
  "timezone": "Europe/Berlin",
  "manifest_url": "https://evewot-netizen.github.io/mango-firmware/updates/mango.manifest",
  "state_file": "/config/freifunk/update-status/mango-fleet.json",
  "routers": [
    {
      "installation_enabled": true,
      "host": "172.30.33.2",
      "port": 2222,
      "host_key_alias": "192.168.178.20",
      "known_hosts": "/config/freifunk/ssh/known_hosts_mango",
      "update_key": "/config/freifunk/ssh/mango_zuhause_update",
      "backup_key": "/config/freifunk/ssh/mango_zuhause_backup",
      "monitor_key": "/config/freifunk/ssh/mango_monitor",
      "manifest_url": "https://evewot-netizen.github.io/mango-firmware/updates/mango.manifest",
      "backup_dir": "/config/freifunk/backups/mango-zuhause/automatisch",
      "state_file": "/config/freifunk/update-status/mango-zuhause.json",
      "router_id": "mango-zuhause",
      "required_backup_files": [
        "etc/config/firewall",
        "etc/config/network",
        "etc/config/wireless",
        "etc/crontabs/root",
        "etc/dropbear/authorized_keys",
        "etc/hotplug.d/iface/95-mango-fritz",
        "etc/init.d/mango-ha-update-job",
        "etc/mango-fritz-adressen.sh",
        "etc/mango-ha-backup.sh",
        "etc/mango-ha-monitor.sh",
        "etc/mango-ha-restore-wireguard.sh",
        "etc/mango-ha-update-install-enabled",
        "etc/mango-ha-update-install.sh",
        "etc/mango-ha-update-worker.sh",
        "etc/mango-ha-update.sh",
        "etc/sysupgrade.conf",
        "etc/wireguard/mango-management.key",
        "lib/gluon/upgrade/997-mango-ha-wireguard",
        "lib/gluon/upgrade/zz-heimwlan"
      ]
    },
    {
      "installation_enabled": true,
      "host": "172.30.33.2",
      "port": 2223,
      "host_key_alias": "mango-02",
      "known_hosts": "/config/freifunk/ssh/known_hosts_mango_02",
      "update_key": "/config/freifunk/ssh/mango_02_update",
      "backup_key": "/config/freifunk/ssh/mango_02_backup",
      "monitor_key": "/config/freifunk/ssh/mango_02_monitor",
      "manifest_url": "https://evewot-netizen.github.io/mango-firmware/updates/mango.manifest",
      "backup_dir": "/config/freifunk/backups/mango-02/automatisch",
      "state_file": "/config/freifunk/update-status/mango-02.json",
      "router_id": "mango-02",
      "required_backup_files": [
        "etc/config/firewall",
        "etc/config/mango_management",
        "etc/config/mango_uplinks",
        "etc/config/network",
        "etc/config/wireless",
        "etc/crontabs/root",
        "etc/dropbear/authorized_keys",
        "etc/init.d/mango-ha-update-job",
        "etc/init.d/mango-uplinkwahl",
        "etc/mango-ha-backup.sh",
        "etc/mango-ha-update-install-enabled",
        "etc/mango-ha-update-install.sh",
        "etc/mango-ha-update-worker.sh",
        "etc/mango-ha-update.sh",
        "etc/sysupgrade.conf",
        "etc/wireguard/mango-management.key",
        "lib/gluon/upgrade/997-mango-management-network",
        "lib/gluon/upgrade/zz-mango-uplink",
        "usr/sbin/mango-management-reconnect",
        "usr/sbin/mango-management-refresh",
        "usr/sbin/mango-management-restore",
        "usr/sbin/mango-uplinkwahl"
      ]
    }
  ]
}
MANGO_FLEET_2
cat > "$work/file3" <<'MANGO_FLEET_3'
shell_command:
  mango_update_start: "python3 /config/freifunk/mango-fleet.py start"
  mango_update_schritt: "python3 /config/freifunk/mango-fleet.py tick"
  mango_update_status: "python3 /config/freifunk/mango-fleet.py status"
  mango_update_pruefen: "python3 /config/freifunk/mango-fleet.py verify"

automation:
  - id: mango_zuhause_kontrolliertes_nachtupdate
    alias: "Mango – gemeinsame Update-Runde um 21 Uhr"
    initial_state: true
    description: "Ein Tagesangebot; Router nacheinander. Fehler halten die Runde an."
    triggers:
      - trigger: time
        at: "21:00:00"
        id: nacht
      - trigger: homeassistant
        event: start
        id: fortsetzen
    conditions: []
    actions:
      - choose:
          - conditions: "{{ trigger.id == 'nacht' }}"
            sequence:
              - action: shell_command.mango_update_start
                response_variable: ergebnis
                continue_on_error: true
        default:
          - action: shell_command.mango_update_schritt
            response_variable: ergebnis
            continue_on_error: true
      - variables:
          antwort: "{{ ergebnis | default({}) }}"
          inhalt: "{{ antwort.get('stdout', '{}') | from_json({}) }}"
      - repeat:
          while:
            - condition: template
              value_template: >-
                {{ antwort.get('returncode', -1) == 0 and inhalt is mapping
                   and inhalt.get('phase') == 'RUNNING' }}
          sequence:
            - delay: "00:01:00"
            - variables:
                ergebnis: {}
            - action: shell_command.mango_update_schritt
              response_variable: ergebnis
              continue_on_error: true
            - variables:
                antwort: "{{ ergebnis | default({}) }}"
                inhalt: "{{ antwort.get('stdout', '{}') | from_json({}) }}"
      - choose:
          - conditions: >-
              {{ antwort.get('returncode', -1) != 0 or inhalt is not mapping
                 or inhalt.get('phase', '') in ['', 'BUSY', 'ERROR'] }}
            sequence:
              - action: persistent_notification.create
                data:
                  notification_id: mango_fleet_update_status
                  title: "Mango-Update-Runde angehalten"
                  message: >-
                    {{ inhalt.get('message', inhalt.get('error', 'Steuerung pruefen.'))
                       if inhalt is mapping else 'Ungueltige Antwort der Steuerung.' }}
          - conditions: "{{ inhalt is mapping and inhalt.get('notify', false) }}"
            sequence:
              - action: persistent_notification.create
                data:
                  notification_id: mango_fleet_update_status
                  title: "Mango-Update-Runde abgeschlossen"
                  message: "{{ inhalt.get('message', 'Alle Router bearbeitet.') }}"
    mode: single
    max_exceeded: silent
MANGO_FLEET_3
save=$(mktemp -d /config/freifunk/vor-fleet-21uhr.XXXXXX)
cp -p /config/packages/mango_update_control.yaml "$save/mango_update_control.yaml"
cp -p /config/freifunk/mango-update-controller.py "$save/"
cp -p /config/freifunk/mango-update-controller.json "$save/"
cp -p /config/freifunk/update-status/mango-zuhause.json "$save/"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/file0" /config/freifunk/mango_fleet_engine.py
chmod 600 /config/freifunk/mango_fleet_engine.py
cp "$work/file1" /config/freifunk/mango-fleet.py
chmod 600 /config/freifunk/mango-fleet.py
cp "$work/file2" /config/freifunk/mango-fleet.json
chmod 600 /config/freifunk/mango-fleet.json
cp "$work/file3" /config/packages/mango_update_control.yaml
chmod 600 /config/packages/mango_update_control.yaml
echo '--- Home-Assistant-Konfiguration pruefen ---'
ha core check
echo 'ERFOLG: Gemeinsame 21-Uhr-Steuerung gespeichert und HA-Konfiguration geprueft.'
echo 'Reihenfolge: Mango Zuhause, dann Mango 02. Fehler stoppen die Runde.'
echo 'Noch nicht geladen. Home Assistant muss anschliessend neu gestartet werden.'
echo 'Keine Firmware-Pruefung und keine Installation gestartet.'
