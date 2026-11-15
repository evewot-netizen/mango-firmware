from pathlib import Path
import json, hashlib, importlib.util
r=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('controller',r/'pi/controller.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
first=json.loads((r/'pi/config.example.json').read_text());first.update(installation_enabled=True,router_id='mango-zuhause')
first['required_backup_files']=sorted(module.REQUIRED | {'etc/mango-ha-restore-wireguard.sh','lib/gluon/upgrade/997-mango-ha-wireguard'})
second=dict(first,router_id='mango-02',port=2223,host_key_alias='mango-02',known_hosts='/config/freifunk/ssh/known_hosts_mango_02',update_key='/config/freifunk/ssh/mango_02_update',backup_key='/config/freifunk/ssh/mango_02_backup',monitor_key='/config/freifunk/ssh/mango_02_monitor',backup_dir='/config/freifunk/backups/mango-02/automatisch',state_file='/config/freifunk/update-status/mango-02.json')
required=module.REQUIRED-{'etc/mango-ha-monitor.sh','etc/mango-fritz-adressen.sh','etc/hotplug.d/iface/95-mango-fritz','lib/gluon/upgrade/zz-heimwlan'}
required|={'etc/config/mango_management','etc/config/mango_uplinks','usr/sbin/mango-uplinkwahl','etc/init.d/mango-uplinkwahl','lib/gluon/upgrade/zz-mango-uplink','usr/sbin/mango-management-refresh','usr/sbin/mango-management-restore','usr/sbin/mango-management-reconnect','lib/gluon/upgrade/997-mango-management-network'}
second['required_backup_files']=sorted(required)
config={'timezone':'Europe/Berlin','manifest_url':first['manifest_url'],'state_file':'/config/freifunk/update-status/mango-fleet.json','routers':[first,second]}
(r/'pi/fleet-config.json').write_text(json.dumps(config,indent=2)+'\n')
files={
 '/config/freifunk/mango_fleet_engine.py':(r/'pi/mango_fleet_engine.py').read_text(),
 '/config/freifunk/mango-fleet.py':(r/'pi/mango-fleet.py').read_text(),
 '/config/freifunk/mango-fleet.json':json.dumps(config,indent=2)+'\n',
 '/config/packages/mango_update_control.yaml':(r/'pi/home-assistant-fleet.yaml').read_text()}
s='''#!/bin/sh
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
'''
for p in files:
 if not p.endswith('.yaml'):s+=f'test ! -e {p}\n'
for c in [first,second]:
 for k in ['known_hosts','update_key','backup_key','monitor_key']:s+=f'test -s {c[k]}\n'
s+='''test "$(ssh-keygen -y -f /config/freifunk/ssh/mango_02_update | awk '{print $2}')" = AAAAC3NzaC1lZDI1NTE5AAAAIL8eq56t3IAeqiJJ9baW9LNRwUldUbxHCkqEKBLQqnWD
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
'''
for i,(p,c) in enumerate(files.items()):s+=f"cat > \"$work/file{i}\" <<'MANGO_FLEET_{i}'\n{c}MANGO_FLEET_{i}\n"
s+='''save=$(mktemp -d /config/freifunk/vor-fleet-21uhr.XXXXXX)
cp -p /config/packages/mango_update_control.yaml "$save/mango_update_control.yaml"
cp -p /config/freifunk/mango-update-controller.py "$save/"
cp -p /config/freifunk/mango-update-controller.json "$save/"
cp -p /config/freifunk/update-status/mango-zuhause.json "$save/"
echo "Ruecknahme-Sicherung: $save"
changed=1
'''
for i,p in enumerate(files):s+=f'cp "$work/file{i}" {p}\nchmod 600 {p}\n'
s+='''echo '--- Home-Assistant-Konfiguration pruefen ---'
ha core check
echo 'ERFOLG: Gemeinsame 21-Uhr-Steuerung gespeichert und HA-Konfiguration geprueft.'
echo 'Reihenfolge: Mango Zuhause, dann Mango 02. Fehler stoppen die Runde.'
echo 'Noch nicht geladen. Home Assistant muss anschliessend neu gestartet werden.'
echo 'Keine Firmware-Pruefung und keine Installation gestartet.'
'''
(r/'install-pi-fleet.sh').write_text(s)
print(hashlib.sha256(s.encode()).hexdigest())
