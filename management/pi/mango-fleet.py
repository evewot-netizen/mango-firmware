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
