from pathlib import Path
import hashlib
r=Path(__file__).resolve().parent
backup='''#!/bin/sh
set -eu
umask 077
test "${SSH_ORIGINAL_COMMAND:-}" = backup || exit 1
exec 9> /var/lock/mango-ha-backup.lock
flock -n 9 || exit 1
work=$(mktemp -d /tmp/mango-ha-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
sysupgrade -b "$work/config.tar.gz" 9>&- >&2
tar -tzf "$work/config.tar.gz" >/dev/null
cat "$work/config.tar.gz"
'''
(r/'router/backup.sh').write_text(backup)
dispatch=(r/'router/dispatch.sh').read_text().replace('/etc/mango-fritz-adressen.sh','/usr/sbin/mango-management-refresh')
paths={
 '/etc/mango-ha-backup.sh':backup,
 '/etc/mango-ha-update.sh':dispatch,
 '/etc/mango-ha-update-worker.sh':(r/'router/worker.sh').read_text(),
 '/etc/mango-ha-update-install.sh':(r/'router/install.sh').read_text(),
 '/etc/init.d/mango-ha-update-job':(r/'router/service').read_text(),
 '/etc/mango-ha-update-install-enabled':'enabled\n',
}
s='''#!/bin/sh
# Enable restricted Pi control only; do not start preparation or installation.
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhal9483c41b9b72
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.3/32
test "$(uci -q get mango_management.main.enabled)" = 1
test "$(uci -q get autoupdater.settings.enabled)" = 0
test "$(uci -q get autoupdater.settings.branch)" = mango
test "$(uci -q get autoupdater.mango.good_signatures)" = 1
test "$(uci -q get autoupdater.mango.mirror)" = 'https://evewot-netizen.github.io/mango-firmware/updates/'
test -f /lib/functions/procd.sh
command -v flock >/dev/null
test -x /usr/sbin/mango-management-refresh
test -x /usr/sbin/mango-management-reconnect
test -x /usr/sbin/mango-management-restore
test -f /etc/dropbear/authorized_keys
test -f /etc/sysupgrade.conf
test ! -d /tmp/mango-ha-update-job
echo 'd989f0837ad73c6ff1a46ba4d4daafc09c0258d11eb84a185aad8be4ade1eb1e  /usr/lib/autoupdater/upgrade.d/10stop-network' | sha256sum -c -
'''
for p in paths:s+=f'test ! -e {p}\n'
s+='''if grep -Eq 'ha-mango-02-(backup|update)|ICKpsXrM9TrWyp38sI5wctJYaj12rCn9StZEC7sXHRhM|IL8eq56t3IAeqiJJ9baW9LNRwUldUbxHCkqEKBLQqnWD' /etc/dropbear/authorized_keys; then
    echo 'Update- oder Backup-Zugang existiert bereits. Abbruch.' >&2
    exit 1
fi
work=$(mktemp -d /tmp/mango02-update-setup.XXXXXX)
changed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$changed" = 1; then
        cp -p "$save/authorized_keys" /etc/dropbear/authorized_keys
        cp -p "$save/sysupgrade.conf" /etc/sysupgrade.conf
'''
for p in paths:s+=f'        rm -f {p}\n'
s+='''        echo 'FEHLER: Neue Update-Zugaenge wieder entfernt.' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
'''
for i,(p,c) in enumerate(paths.items()):
 s+=f"cat > \"$work/file{i}\" <<'MANGO_FILE_{i}'\n{c}MANGO_FILE_{i}\n"
 if p.endswith('.sh') or '/init.d/' in p:s+=f'sh -n "$work/file{i}"\n'
s+='''save=$(mktemp -d /root/vor-mango02-update-setup.XXXXXX)
cp -p /etc/dropbear/authorized_keys "$save/authorized_keys"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Ruecknahme-Sicherung: $save"
changed=1
'''
for i,p in enumerate(paths):
 s+=f'cp "$work/file{i}" {p}\nchmod 700 {p}\n'
for p in [*paths,'/etc/dropbear/authorized_keys','/etc/mango-ha-update-last','/usr/sbin/mango-management-refresh','/usr/sbin/mango-management-restore','/usr/sbin/mango-management-reconnect','/lib/gluon/upgrade/997-mango-management-network','/etc/crontabs/root']:
 s+=f"grep -Fxq '{p}' /etc/sysupgrade.conf || printf '%s\\n' '{p}' >> /etc/sysupgrade.conf\n"
s+='''printf '\\n' >> /etc/dropbear/authorized_keys
cat >> /etc/dropbear/authorized_keys <<'MANGO_KEYS'
command="/bin/sh /etc/mango-ha-backup.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKpsXrM9TrWyp38sI5wctJYaj12rCn9StZEC7sXHRhM ha-mango-02-backup
command="/bin/sh /etc/mango-ha-update.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8eq56t3IAeqiJJ9baW9LNRwUldUbxHCkqEKBLQqnWD ha-mango-02-update
MANGO_KEYS
chmod 600 /etc/dropbear/authorized_keys /etc/mango-ha-update-install-enabled
# This on-demand worker must never run at boot; do not enable or start it.
echo '--- Update-Zugang und Schutzregeln pruefen ---'
SSH_ORIGINAL_COMMAND=job /bin/sh /etc/mango-ha-update.sh
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
echo '--- Backup-Zugang pruefen ---'
SSH_ORIGINAL_COMMAND=backup /bin/sh /etc/mango-ha-backup.sh > "$work/backup.tar.gz"
tar -tzf "$work/backup.tar.gz" > "$work/contents"
'''
for p in paths:s+=f"grep -Fxq '{p.lstrip('/')}' \"$work/contents\"\n"
s+='''echo 'ERFOLG: Eingeschraenkter Backup- und Update-Zugang fuer Mango 02 eingerichtet.'
echo 'Keine Firmware-Pruefung, Installation oder Zeitplanung gestartet.'
'''
(r/'install-router02-update-access.sh').write_text(s)
print(hashlib.sha256(s.encode()).hexdigest())
