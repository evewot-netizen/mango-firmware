from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent
router='''#!/bin/sh
set -eu
umask 077
test -f /etc/mango-ha-update-install.sh
test -f /etc/mango-ha-update.sh
test ! -e /etc/mango-ha-update-install-enabled
case "$(cat /tmp/mango-ha-update-job/state 2>/dev/null || printf IDLE)" in
    IDLE|NO_UPDATE) ;;
    *) echo 'Routerauftrag nicht im Ruhezustand. Abbruch.' >&2; exit 1;;
esac
save="/root/vor-ha-nachtupdate-$(date +%Y%m%d-%H%M%S)"
mkdir "$save"
cp -p /etc/mango-ha-update.sh "$save/dispatch"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Sicherung: $save"
work=$(mktemp -d /tmp/mango-final-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/dispatch" <<'MANGO_DISPATCH'
'''+(root/'router/dispatch.sh').read_text()+'''MANGO_DISPATCH
/bin/sh -n "$work/dispatch"
cp "$work/dispatch" /etc/mango-ha-update.sh.new
chmod 700 /etc/mango-ha-update.sh.new
mv /etc/mango-ha-update.sh.new /etc/mango-ha-update.sh
echo '--- Aktive Sicherheitsmassnahmen pruefen ---'
if ! SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh; then
    cp -p "$save/dispatch" /etc/mango-ha-update.sh
    echo 'Gesundheitspruefung fehlgeschlagen. Vorheriger Zugang wiederhergestellt.' >&2
    exit 1
fi
file=/etc/mango-ha-update-install-enabled
grep -Fxq "$file" /etc/sysupgrade.conf || printf '%s\n' "$file" >> /etc/sysupgrade.conf
printf '%s\n' enabled > "$file"
chmod 600 "$file"
SSH_ORIGINAL_COMMAND=job /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: Router fuer kontrollierte Installationsauftraege freigeschaltet.'
echo 'Es wurde kein Update gestartet. Der Pi-Zeitplan folgt separat.'
'''
(root/'install-router-final.sh').write_text(router)
config=(root/'pi/config.example.json').read_bytes()
expected=hashlib.sha256(config).hexdigest()
night_config=json.loads(config);night_config['installation_enabled']=True
pi='''#!/bin/sh
set -eu
umask 077
controller=/config/freifunk/mango-update-controller.py
config=/config/freifunk/mango-update-controller.json
package=/config/packages/mango_update_control.yaml
state=/config/freifunk/update-status/mango-zuhause.json
test -s "$controller"
test -s "$config"
test -s "$package"
test -s "$state"
grep -Eq '"phase"[[:space:]]*:[[:space:]]*"(IDLE|NO_UPDATE|SUCCESS)"' "$state" || {
    echo 'Pi-Ablauf nicht im Ruhezustand. Abbruch.' >&2; exit 1;
}
printf '%s  %s\n' '''+expected+''' "$config" | sha256sum -c -
work=$(mktemp -d /config/freifunk/.night-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
mango() {
    ssh -T -p 2222 -i /config/freifunk/ssh/mango_zuhause_update \\
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \\
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \\
        -o HostKeyAlias=192.168.178.20 -o HostKeyAlgorithms=ssh-ed25519 \\
        -o StrictHostKeyChecking=yes \\
        -o UserKnownHostsFile=/config/freifunk/ssh/known_hosts_mango \\
        root@172.30.33.2 "$@"
}
echo '--- Router-Freigabe und Sicherheitsmassnahmen pruefen ---'
mango health > "$work/health"
grep -Fxq 'HEALTH=OK' "$work/health"
mango job > "$work/job"
grep -Fxq 'INSTALL_ENABLED=1' "$work/job"
grep -Eq '^STATE=(IDLE|NO_UPDATE)$' "$work/job"
cat "$work/health"
save="/config/freifunk/vor-nachtupdate-$(date +%Y%m%d-%H%M%S)"
mkdir "$save"
cp -p "$controller" "$save/controller.py"
cp -p "$config" "$save/config.json"
cp -p "$package" "$save/package.yaml"
echo "Sicherung: $save"
'''
for i,(name,content) in enumerate([('controller.py',(root/'pi/controller.py').read_text()),('package.yaml',(root/'pi/home-assistant-nightly.yaml').read_text()),('config.json',json.dumps(night_config,indent=2)+'\n')]):
    pi+=f'cat > "$work/{name}" <<\'MANGO_FINAL_{i}\'\n'+content+f'MANGO_FINAL_{i}\n'
pi+='''cp "$work/controller.py" "$controller.new"
chmod 600 "$controller.new"
mv "$controller.new" "$controller"
cp "$work/package.yaml" "$package.new"
chmod 600 "$package.new"
mv "$package.new" "$package"
echo '--- Home-Assistant-Konfiguration pruefen ---'
if ! ha core check; then
    cp -p "$save/controller.py" "$controller"
    cp -p "$save/package.yaml" "$package"
    echo 'Pruefung fehlgeschlagen. Alte Dateien wiederhergestellt; Pi-Installation bleibt gesperrt.' >&2
    exit 1
fi
cp "$work/config.json" "$config.new"
chmod 600 "$config.new"
mv "$config.new" "$config"
echo 'ERFOLG: Nachtsteuerung fuer Mango Zuhause vorbereitet.'
echo 'Jetzt shell_command.reload und danach automation.reload ausfuehren.'
echo '04:15 Uhr: pruefen; nur bei neuer Firmware Backup und Update.'
'''
(root/'install-pi-nightly.sh').write_text(pi)
