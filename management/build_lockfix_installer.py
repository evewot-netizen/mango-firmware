"""Generate a guarded repair for the observed READY/Test6 lock inheritance bug."""
from pathlib import Path
import json

root = Path(__file__).resolve().parent
original = json.loads((root / 'router-lockfix-original-hashes.json').read_text())
files = {
    'worker.sh': '/etc/mango-ha-update-worker.sh',
    'install.sh': '/etc/mango-ha-update-install.sh',
    'dispatch.sh': '/etc/mango-ha-update.sh',
}
s = '''#!/bin/sh
set -eu
umask 077
state=/tmp/mango-ha-update-job
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test6
test "$(cat /proc/sys/kernel/random/boot_id)" = 89f96f09-fb52-4881-ae04-37a186065674
test "$(cat "$state/state")" = READY
test "$(cat "$state/sha256")" = d71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c
test ! -e "$state/request-image-sha256"
test ! -e "$state/request-backup-sha256"
test -x /etc/init.d/sse-multiplexd
exec 7> /var/lock/mango-ha-update-request.lock
flock -n 7
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
echo '--- Installierte Skriptversionen pruefen ---'
'''
for name, target in files.items():
    s += f"printf '%s  %s\\n' '{original[name]}' '{target}' | sha256sum -c -\n"
s += '''work=$(mktemp -d /tmp/mango-lockfix.XXXXXX)
restart_needed=0
cleanup() {
    if test "$restart_needed" = 1; then
        /etc/init.d/sse-multiplexd start 7>&- 9>&- || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
'''
for index, (name, target) in enumerate(files.items()):
    s += f"cat > \"$work/{name}\" <<'LOCKFIX_{index}'\n"
    s += (root / 'router' / name).read_text()
    s += f'LOCKFIX_{index}\n/bin/sh -n "$work/{name}"\n'
s += '''save=$(mktemp -d /root/vor-ha-lockfix.XXXXXX)
'''
for name, target in files.items():
    s += f'cp -p "{target}" "$save/{name}"\n'
s += '''echo "Sicherung: $save"
echo '--- Statusseiten-Dienst stoppen und Sperre pruefen ---'
restart_needed=1
/etc/init.d/sse-multiplexd stop 7>&-
# Do not remove lock files: all users must continue sharing the same inode.
exec 9> /var/lock/mango-ha-update-job.lock
if ! flock -n 9; then
    echo 'ABBRUCH: Update-Sperre weiterhin belegt; Skripte unveraendert.' >&2
    exit 1
fi
test "$(cat "$state/state")" = READY
'''
for name, target in files.items():
    s += f'cp "$work/{name}" "{target}.new"\nchmod 700 "{target}.new"\nmv "{target}.new" "{target}"\n'
s += '''flock -u 9
exec 9>&-
/etc/init.d/sse-multiplexd start 7>&-
restart_needed=0
echo '--- Sperre nach Dienststart pruefen ---'
(
    exec 9< /var/lock/mango-ha-update-job.lock
    flock -n 9
    echo 'ERFOLG: Update-Sperre ist frei.'
)
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
SSH_ORIGINAL_COMMAND=vpn /bin/sh /etc/mango-ha-monitor.sh
SSH_ORIGINAL_COMMAND=job /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: Sperrvererbung korrigiert. Keine Installation gestartet.'
'''
(root / 'install-router-lockfix.sh').write_text(s)
