from pathlib import Path
root=Path(__file__).resolve().parent
files=[('controller.py','/config/freifunk/mango-update-controller.py'),('config.example.json','/config/freifunk/mango-update-controller.json'),('home-assistant.yaml','/config/packages/mango_update_control.yaml')]
s='''#!/bin/sh
set -eu
umask 077
command -v ha >/dev/null
test -d /config/packages
test -s /config/freifunk/ssh/mango_zuhause_update
test -s /config/freifunk/ssh/mango_zuhause_backup
test -s /config/freifunk/ssh/mango_monitor
test -s /config/freifunk/ssh/known_hosts_mango
'''
for _,target in files:
    s+=f'test ! -e "{target}" || {{ echo "Abbruch: {target} existiert bereits." >&2; exit 1; }}\n'
s+='''work=$(mktemp -d /config/freifunk/.controller-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
'''
for i,(name,target) in enumerate(files):
    s+=f'cat > "$work/{name}" <<\'MANGO_PI_FILE_{i}\'\n'+(root/'pi'/name).read_text()+f'MANGO_PI_FILE_{i}\n'
for name,target in files:
    s+=f'cp "$work/{name}" "{target}"\nchmod 600 "{target}"\n'
s+='''echo '--- Home-Assistant-Konfiguration pruefen ---'
if ! ha core check; then
    save="/config/freifunk/mango-update-control-fehler-$(date +%Y%m%d-%H%M%S).yaml"
    mv /config/packages/mango_update_control.yaml "$save"
    echo "Konfigurationspruefung fehlgeschlagen. Neue YAML-Datei entfernt: $save" >&2
    exit 1
fi
echo 'ERFOLG: Pi-Steuerung eingerichtet. Shell-Befehle muessen noch geladen werden.'
echo 'Keine Zeitautomatik eingerichtet. Installation ist weiterhin deaktiviert.'
'''
(root/'install-pi-control.sh').write_text(s)
